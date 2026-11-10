import AppKit
import TouchBarBridge

/// Run inside the existing app bundle for visual checks, then restore the production executable.
@main
@MainActor
struct ChatGPTBarLayoutSmoke {
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    static func capture(_ name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-b", "-x", ".build/visual-checks/\(name).png"]
        try! process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
    }

    static func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }

    static func checkBackgrounds(_ buttons: [ChatSideButton], capture name: String, value: Int) {
        let bitmap = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: ".build/visual-checks/\(name).png")))!
        let scale = CGFloat(bitmap.pixelsHigh) / 30
        for button in buttons {
            let point = button.convert(NSPoint(x: 5, y: 15), to: nil)
            var pixel = [Int](repeating: 0, count: bitmap.samplesPerPixel)
            bitmap.getPixel(&pixel, atX: Int(point.x * scale), y: Int(point.y * scale))
            for component in pixel.prefix(3) {
                precondition(abs(component - value) <= 1, "Unexpected side-button background pixel: \(pixel)")
            }
        }
    }

    static func type(_ text: String, into field: NSTextField, window: NSWindow) {
        precondition(window.makeFirstResponder(field))
        let editor = field.currentEditor() as! NSTextView
        editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        settle()
    }

    static func main() {
        let projectRoot = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        precondition(FileManager.default.changeCurrentDirectoryPath(projectRoot.path))
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let root = NSMenuItem()
        root.submenu = NSMenu()
        menu.addItem(root)
        application.mainMenu = menu
        application.isAutomaticCustomizeTouchBarMenuItemEnabled = true
        let provider = AppBar(app: LayoutApp(bundleID: "com.openai.chat", name: "ChatGPT"), persistsLayout: false)
        let original = provider.bar.defaultItemIdentifiers
        let host = AppBarHost()
        host.display(provider)
        precondition(TBPresent(host.bar))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let chatID = AppBar.itemID("chatgpt.chats")
            let sidebarID = AppBar.itemID("chatgpt.sidebar")
            let terminalID = AppBar.itemID("chatgpt.terminal")
            let chats = (host.content.groupTouchBar.item(forIdentifier: chatID) as! NSCustomTouchBarItem).view
            let sidebar = (host.bar.item(forIdentifier: sidebarID) as! NSCustomTouchBarItem).view
            let terminal = (host.content.groupTouchBar.item(forIdentifier: terminalID) as! NSCustomTouchBarItem).view
            settle()
            let fullWidth = chats.frame.width
            capture("chatgpt-layout-full")
            let buttons = [sidebar, terminal].flatMap { descendants($0) }.compactMap { $0 as? ChatSideButton }
            precondition(buttons.count == 2 && buttons.allSatisfy(\.isEnabled))
            checkBackgrounds(buttons, capture: "chatgpt-layout-full", value: 54)
            for button in buttons {
                precondition(button.cell is ChatSideButtonCell)
                button.cell?.highlight(true, withFrame: button.bounds, in: button)
            }
            settle()
            precondition(buttons.allSatisfy(\.isHighlighted))
            capture("chatgpt-layout-pressed")
            checkBackgrounds(buttons, capture: "chatgpt-layout-pressed", value: 128)
            for button in buttons { button.cell?.highlight(false, withFrame: button.bounds, in: button) }

            provider.bar.defaultItemIdentifiers = original.filter { $0 != terminalID }
            host.display(provider)
            settle()
            let oneSideWidth = (host.content.groupTouchBar.item(forIdentifier: chatID) as! NSCustomTouchBarItem).view.frame.width
            capture("chatgpt-layout-without-terminal")
            precondition(oneSideWidth > fullWidth + 70, "Chat region did not claim removed terminal's space")

            provider.bar.defaultItemIdentifiers = original.filter { $0 != sidebarID }
            host.display(provider)
            settle()
            let withoutSidebarWidth = (host.content.groupTouchBar.item(forIdentifier: chatID) as! NSCustomTouchBarItem).view.frame.width
            capture("chatgpt-layout-without-sidebar")
            precondition(withoutSidebarWidth > fullWidth + 60, "Chat region did not claim removed sidebar's space")

            provider.bar.defaultItemIdentifiers = [chatID]
            host.display(provider)
            settle()
            let noSidesWidth = (host.content.groupTouchBar.item(forIdentifier: chatID) as! NSCustomTouchBarItem).view.frame.width
            capture("chatgpt-layout-only-chats")
            precondition(noSidesWidth > oneSideWidth + 60, "Chat region did not claim removed sidebar's space")
            provider.bar.defaultItemIdentifiers = original
            host.display(provider)
            settle()
            precondition(abs((host.content.groupTouchBar.item(forIdentifier: chatID) as! NSCustomTouchBarItem).view.frame.width - fullWidth) < 1)
            capture("chatgpt-layout-restored")
            print("Chat viewport widths: \(fullWidth), \(oneSideWidth), \(withoutSidebarWidth), \(noSidesWidth)")
            _ = TBDismiss(host.bar)

            let suite = "TouchBarEnhancer.ChatEditTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let store = SettingsStore(defaults: defaults)
            store.onChange = { provider.configureChats(store.chatShortcuts) }
            let pane = ChatGPTPane(store: store, app: provider.app, connectionReader: {
                ChatGPTAdapter.Snapshot(trusted: false, running: false, entries: [])
            })
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = pane
            window.touchBar = provider.bar
            pane.touchBar = provider.bar
            window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            // Activation must finish on the main run loop before checking the native preview.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let previewChats = (provider.bar.item(forIdentifier: chatID) as! NSCustomTouchBarItem).view
                precondition(previewChats !== chats)
                let fields = descendants(pane).compactMap { $0 as? NSTextField }
                type("Edited Chat", into: fields.first { $0.placeholderString == "Chat name" }!, window: window)
                precondition(store.chatShortcuts[0].name == "Edited Chat", "Typing a name did not update the chat")
                type("star.fill", into: fields.first { $0.placeholderString == "bubble.left" }!, window: window)
                precondition(store.chatShortcuts[0].symbol == "star.fill")
                type("#123456", into: fields.first { $0.placeholderString == "blue or #0088FF" }!, window: window)
                precondition(store.chatShortcuts[0].color == "#123456")
                let popup = descendants(pane).compactMap { $0 as? NSPopUpButton }.first!
                popup.selectItem(at: 6)
                _ = popup.sendAction(popup.action, to: popup.target)
                precondition(store.chatShortcuts[0].slot == 7)
                precondition(SettingsStore(defaults: defaults).chatShortcuts[0] == store.chatShortcuts[0])
                settle()
                capture("chatgpt-live-edit-preview")
                let previewScrubber = descendants(previewChats).compactMap { $0 as? NSScrubber }.first!
                let previewItem = previewScrubber.dataSource!.scrubber(previewScrubber, viewForItemAt: 0)
                precondition(descendants(previewItem).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Edited Chat" },
                             "Saved edits did not refresh the preview data source")
                window.touchBar = nil
                pane.touchBar = nil
                window.orderOut(nil)
                application.hide(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    host.display(provider)
                    precondition(TBPresent(host.bar))
                    settle()
                    capture("chatgpt-live-edit-host")
                    let modalChats = (host.content.groupTouchBar.item(forIdentifier: chatID) as! NSCustomTouchBarItem).view
                    precondition(modalChats !== previewChats)
                    precondition(descendants(modalChats).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Edited Chat" })
                    print("Live name, symbol, color and shortcut edits propagated to preview data, persistence and modal host")
                    _ = TBDismiss(host.bar)
                    window.close()
                    store.onChange = nil
                    defaults.removePersistentDomain(forName: suite)
                    application.terminate(nil)
                }
            }
        }
        application.run()
    }
}
