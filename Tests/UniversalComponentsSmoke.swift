import AppKit
import TouchBarBridge

@main
@MainActor
struct UniversalComponentsSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static let layouts = [
        ["chatgpt.sidebar", "chatgpt.chats", "phrases", "chatgpt.terminal"],
        ["phrases", "chatgpt.chats"],
        ["chatgpt.chats", "phrases"],
        ["phrases", "chatgpt.terminal"],
        ["phrases"],
        ["chatgpt.chats"],
        ["chatgpt.chats", "phrases", "chatgpt.sidebar"]
    ]

    static func checkHost(_ index: Int, provider: AppBar, host: AppBarHost) {
        guard index < layouts.count else {
            _ = TBDismiss(host.bar)
            checkUniversalRegistration()
            // Silent by default; interactive editor/paste testing requires an
            // explicit opt-in so routine regression runs never open a window.
            if !CommandLine.arguments.contains("--interactive") {
                print("Universal layout checks passed")
                fflush(stdout)
                NSApp.terminate(nil)
                return
            }
            checkPaste()
            return
        }
        let suffixes = layouts[index]
        provider.bar.defaultItemIdentifiers = suffixes.map(AppBar.itemID)
        host.display(provider)
        precondition(TBPresent(host.bar))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            var frames: [NSRect] = []
            var scrollingWidths: [CGFloat] = []
            for suffix in suffixes {
                let id = AppBar.itemID(suffix)
                let item = (host.bar.templateItems.first { $0.identifier == id }
                    ?? host.content.groupTouchBar.item(forIdentifier: id)) as! NSCustomTouchBarItem
                let wrapper = item.view as! TouchBarComponentView
                let view = wrapper.content
                precondition(view.window != nil && !view.isHiddenOrHasHiddenAncestor, "Every component must be visible: \(suffix)")
                let frame = view.convert(view.bounds, to: nil)
                frames.append(frame)
                if let region = view as? ScrollingComponentRegion {
                    scrollingWidths.append(region.frame.width)
                    let scrubber = descendants(region).compactMap { $0 as? NSScrubber }.first!
                    precondition(abs(scrubber.frame.minX) < 0.01, "No external inset inside the scrolling region")
                    precondition(region.frame.width >= ShortcutScroller.minimumWidth)
                }
            }
            precondition(abs(frames[0].minX) < 0.01, "The leading component must start at the bar edge")
            for pair in zip(frames, frames.dropFirst()) {
                precondition(abs(pair.1.minX - pair.0.maxX - 12) < 0.01, "Component spacing must be 12 pt")
            }
            if scrollingWidths.count == 2 {
                precondition(abs(scrollingWidths[0] - scrollingWidths[1]) < 0.01, "Scrolling components must split available width equally")
            }
            print("Layout \(suffixes): \(frames)")
            fflush(stdout)
            checkHost(index + 1, provider: provider, host: host)
        }
    }

    static func checkUniversalRegistration() {
        for app in LayoutApp.builtIn + [LayoutApp(bundleID: "test.future-app", name: "Future App")] {
            for enabled in [true, false] {
                let provider = AppBar(app: app, chatGPTControlsEnabled: enabled,
                    phrases: [QuickPhrase(name: "Initial", text: "Fixture")], persistsLayout: false)
                let id = AppBar.itemID("phrases")
                precondition(provider.bar.customizationAllowedItemIdentifiers.contains(id))
                let view = (provider.bar.item(forIdentifier: id) as! NSCustomTouchBarItem).view
                let scrubber = descendants(view).compactMap { $0 as? NSScrubber }.first!
                precondition(scrubber.dataSource!.numberOfItems(for: scrubber) == 1)
                provider.configurePhrases([QuickPhrase(name: "Updated", text: "Changed content")])
                let item = scrubber.dataSource!.scrubber(scrubber, viewForItemAt: 0)
                precondition(descendants(item).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Updated" })
            }
        }
    }

    static func checkPaste() {
        let app = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 240),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Quick Phrases — isolated input fixture"
        let input = NSTextView(frame: NSRect(x: 20, y: 20, width: 560, height: 200))
        input.isRichText = false
        window.contentView!.addSubview(input)
        window.center()
        app.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier)
            window.makeFirstResponder(input)
            let before = NSPasteboard.general.pasteboardItems?.map { item in
                item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
            } ?? []
            let count = NSPasteboard.general.changeCount
            precondition(QuickPhrasePaster.paste("", into: "test.missing") != nil)
            precondition(QuickPhrasePaster.paste("Never insert this", into: "test.missing") != nil)
            precondition(NSPasteboard.general.changeCount == count)
            let phrase = "Fixture paste ✓\n第二行"
            let error = QuickPhrasePaster.postPaste(phrase, to: ProcessInfo.processInfo.processIdentifier)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let result = input.string
                NSPasteboard.general.clearContents()
                let restore = before.map { entries in
                    let item = NSPasteboardItem(); entries.forEach { item.setData($0.1, forType: $0.0) }; return item
                }
                NSPasteboard.general.writeObjects(restore)
                precondition(error == nil && result == phrase, "Paste must reach the existing first responder, including newlines")
                let preview = AppBar(app: LayoutApp.builtIn[0], phrases: [QuickPhrase(name: "Phrase 1", text: "Fixture")], persistsLayout: false)
                checkPreview(0, provider: preview, window: window)
            }
        }
    }

    static func checkPreview(_ index: Int, provider: AppBar, window: NSWindow) {
        let layouts = [["phrases", "chatgpt.chats"], ["chatgpt.chats", "phrases"],
            ["chatgpt.sidebar", "chatgpt.chats", "phrases", "chatgpt.terminal"]]
        let app = NSApplication.shared
        let suffixes = layouts[index]
        provider.bar.defaultItemIdentifiers = suffixes.map(AppBar.itemID)
        app.isAutomaticCustomizeTouchBarMenuItemEnabled = true
        window.makeFirstResponder(window)
        window.touchBar = provider.bar
        window.contentView!.touchBar = provider.bar
        app.touchBar = provider.bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let views = suffixes.map { suffix in
                ((provider.bar.item(forIdentifier: AppBar.itemID(suffix)) as! NSCustomTouchBarItem).view as! TouchBarComponentView).content
            }
            precondition(views.allSatisfy { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor })
            let frames = views.map { $0.convert($0.bounds, to: nil) }
            precondition(abs(frames[0].minX) < 0.01, "Native preview must start at the edge too")
            for pair in zip(frames, frames.dropFirst()) {
                precondition(abs(pair.1.minX - pair.0.maxX - 12) < 0.01, "Reordering must update external spacing immediately")
            }
            let widths = views.compactMap { $0 as? ScrollingComponentRegion }.map { $0.frame.width }
            precondition(widths.count == 2 && abs(widths[0] - widths[1]) < 0.01, "Preview must also use equal widths")
            print("Native preview \(suffixes): \(frames)")
            fflush(stdout)
            if index + 1 < layouts.count { checkPreview(index + 1, provider: provider, window: window) }
            else {
                app.touchBar = nil
                window.close()
                print("Universal components checks passed: edge alignment, 12pt component spacing, equal widths in both orders, universal availability/live edits, real multiline paste, invalid-target clipboard preservation, native preview and live reordering")
                fflush(stdout)
                app.terminate(nil)
            }
        }
    }

    static func main() {
        TBPrepareForImmediateTransitions()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let appRoot = NSMenuItem(); appRoot.submenu = NSMenu(); menu.addItem(appRoot)
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editRoot.submenu = ApplicationMenus.editMenu(); menu.addItem(editRoot)
        app.mainMenu = menu
        let provider = AppBar(app: LayoutApp.builtIn[0], phrases: [QuickPhrase(name: "Phrase 1", text: "Fixture phrase")], persistsLayout: false)
        let host = AppBarHost()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { checkHost(0, provider: provider, host: host) }
        app.run()
    }
}
