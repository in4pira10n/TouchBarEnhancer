import AppKit
import TouchBarBridge

@main
@MainActor
struct ScrollingComponentsSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
    static func button(_ title: String, in view: NSView) -> NSButton {
        descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title }!
    }
    static func capture(_ name: String, view: NSView) {
        view.layoutSubtreeIfNeeded()
        // Render only our own view. Actual screen capture runs in the external
        // harness, so installing a test never asks the app for Screen Recording.
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: ".build/visual-checks", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try! bitmap.representation(using: .png, properties: [:])!.write(to:
            directory.appendingPathComponent("\(name).png"))
    }
    static func main() {
        TBPrepareForImmediateTransitions()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let appRoot = NSMenuItem(); appRoot.submenu = NSMenu()
        appRoot.submenu?.addItem(withTitle: "Customize Touch Bar…", action: #selector(NSApplication.toggleTouchBarCustomizationPalette(_:)), keyEquivalent: "")
        menu.addItem(appRoot)
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editRoot.submenu = ApplicationMenus.editMenu(); menu.addItem(editRoot)
        app.mainMenu = menu
        app.isAutomaticCustomizeTouchBarMenuItemEnabled = true
        let suite = "TouchBarEnhancer.ScrollingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        let state = ChatGPTAdapter.Snapshot(trusted: false, running: false, entries: [])
        let pane = AppsPane(store: store, chatGPTConnectionReader: { state })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Apps — Scrolling Components"
        window.contentView = pane
        window.center()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true); settle()
            let chatEditor = descendants(pane).compactMap { $0 as? ShortcutCategoryEditor }.first { $0.kind == .chats }!
            let phraseEditor = descendants(pane).compactMap { $0 as? ShortcutCategoryEditor }.first { $0.kind == .phrases }!
            capture("scrolling-categories-expanded", view: pane)
            let originalHeight = chatEditor.frame.height
            button("Chat Shortcuts", in: chatEditor).performClick(nil)
            pane.layoutSubtreeIfNeeded(); settle()
            precondition(chatEditor.frame.height < originalHeight - 150)
            button("Quick Phrases", in: phraseEditor).performClick(nil)
            button("Add Phrase", in: phraseEditor).performClick(nil)
            precondition(store.quickPhrasesByApp[LayoutApp.chatGPTBundleID]!.count == 1)
            let title = descendants(phraseEditor).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Phrase title" }!
            let symbol = descendants(phraseEditor).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "text.bubble" }!
            let content = descendants(phraseEditor).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "phraseContent" }!
            title.stringValue = "Explain"
            symbol.stringValue = "text.bubble.fill"
            content.string = "请进一步解释。\nKeep this line break."
            phraseEditor.textDidChange(Notification(name: NSText.didChangeNotification, object: content))
            precondition(store.quickPhrasesByApp[LayoutApp.chatGPTBundleID]![0].name == "Explain")
            precondition(store.quickPhrasesByApp[LayoutApp.chatGPTBundleID]![0].text == "请进一步解释。\nKeep this line break.")
            precondition(SettingsStore(defaults: defaults).quickPhrasesByApp == store.quickPhrasesByApp)
            // Both adapters must produce the same actual icon/title geometry.
            // Measuring the views also catches sizing drifting from rendering.
            for item in [store.chatShortcuts[0].scrollingItem, store.quickPhrasesByApp[LayoutApp.chatGPTBundleID]![0].scrollingItem] {
                let view = ScrollingComponentItemView(frame: NSRect(x: 0, y: 0,
                    width: ScrollingComponentItemView.width(for: item), height: 30))
                view.configure(item)
                pane.addSubview(view)
                window.layoutIfNeeded()
                view.layoutSubtreeIfNeeded()
                let icon = descendants(view).compactMap { $0 as? NSImageView }.first!
                let label = descendants(view).compactMap { $0 as? NSTextField }.first!
                let iconFrame = icon.superview!.convert(icon.alignmentRect(forFrame: icon.frame), to: view)
                let titleFrame = label.superview!.convert(label.alignmentRect(forFrame: label.frame), to: view)
                print("Shared item geometry: \(iconFrame), \(titleFrame), bounds \(view.bounds)")
                fflush(stdout)
                precondition(abs(titleFrame.minX - iconFrame.maxX - 6) < 0.01)
                precondition(abs(iconFrame.midY - titleFrame.midY) < 0.01)
                precondition(iconFrame.minX >= 15 && view.bounds.maxX - titleFrame.maxX >= 15)
                view.removeFromSuperview()
            }
            pane.refresh()
            precondition(descendants(pane).contains { $0 === phraseEditor }, "Saving must not replace the active editor")
            capture("scrolling-phrases-editor", view: pane)
            let provider = AppBar(app: LayoutApp.builtIn[0], shortcuts: store.chatShortcuts,
                phrases: store.quickPhrasesByApp[LayoutApp.chatGPTBundleID]!, persistsLayout: false)
            provider.bar.defaultItemIdentifiers = ["chatgpt.sidebar", "chatgpt.chats", "phrases", "chatgpt.terminal"].map(AppBar.itemID)
            let host = AppBarHost(); host.display(provider)
            precondition(TBPresent(host.bar))
            settle()
            let phrases = (host.content.groupTouchBar.item(forIdentifier: AppBar.itemID("phrases")) as! NSCustomTouchBarItem).view
            let chats = (host.content.groupTouchBar.item(forIdentifier: AppBar.itemID("chatgpt.chats")) as! NSCustomTouchBarItem).view
            precondition(phrases !== chats)
            let previewPhrases = (provider.bar.item(forIdentifier: AppBar.itemID("phrases")) as! NSCustomTouchBarItem).view
            precondition(previewPhrases !== phrases, "Preview and modal controls must have separate views")
            let clipboardBefore = NSPasteboard.general.changeCount
            precondition(QuickPhrasePaster.paste("", into: "test.missing") != nil)
            precondition(QuickPhrasePaster.paste("Do not paste this", into: "test.missing") != nil)
            precondition(NSPasteboard.general.changeCount == clipboardBefore, "Rejected pastes must preserve the clipboard")
            let scrubber = descendants(phrases).compactMap { $0 as? NSScrubber }.first!
            let phraseItem = scrubber.dataSource!.scrubber(scrubber, viewForItemAt: 0)
            phraseItem.frame = NSRect(x: 0, y: 0, width: ScrollingComponentItemView.width(for: store.quickPhrasesByApp[LayoutApp.chatGPTBundleID]![0].scrollingItem), height: 30)
            capture("scrolling-phrase-button", view: phraseItem)
            let narrow = ShortcutScroller(label: "Narrow")
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 32, height: 30))
            narrow.scrollRegion.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(narrow.scrollRegion)
            NSLayoutConstraint.activate([
                narrow.scrollRegion.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                narrow.scrollRegion.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                narrow.scrollRegion.topAnchor.constraint(equalTo: container.topAnchor),
                narrow.scrollRegion.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            container.layoutSubtreeIfNeeded()
            precondition(narrow.scrollRegion.frame.width == 32 && narrow.scrubber.frame.width == 32)
            narrow.configure(store.quickPhrasesByApp[LayoutApp.chatGPTBundleID]!.map(\.scrollingItem))
            var selected = 0
            narrow.onSelect = { _ in selected += 1 }
            narrow.scrubber(narrow.scrubber, didSelectItemAt: 0)
            narrow.scrubber(narrow.scrubber, didSelectItemAt: 0)
            precondition(selected == 2 && narrow.scrubber.selectedIndex == -1)
            _ = TBDismiss(host.bar)
            button("Delete Phrase", in: phraseEditor).performClick(nil)
            precondition(store.quickPhrasesByApp[LayoutApp.chatGPTBundleID]!.isEmpty)
            store.rules = [AppRule(bundleID: "com.apple.Safari", name: "Safari", mode: .auto)]
            store.autoPolicy = .selection
            pane.refresh()
            let sidebar = descendants(pane).compactMap { $0 as? NSTableView }.first!
            precondition(sidebar.numberOfRows == 1 && pane.selectedApp?.bundleID == "com.apple.Safari")
            capture("scrolling-selection-mode", view: pane)
            store.rules.removeAll()
            pane.refresh()
            precondition(sidebar.numberOfRows == 0 && pane.selectedApp == nil)
            capture("scrolling-selection-empty", view: pane)
            defaults.removePersistentDomain(forName: suite)
            print("Scrolling components checks passed: collapse, phrase CRUD/live edits/persistence, shared 6pt icon/title layout, repeated taps, 32pt compression, selection catalog")
            fflush(stdout)
            app.terminate(nil)
        }
        app.run()
    }
}
