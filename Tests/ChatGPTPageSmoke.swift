import AppKit
import ApplicationServices
import TouchBarBridge

/// Uses menu fixtures: this test never inspects or controls the real ChatGPT app.
@main
@MainActor
struct ChatGPTPageSmoke {
    static var blankTouchBarCaptures = 0
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    static func capture(_ name: String, arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + [".build/visual-checks/\(name).png"]
        try! process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        if arguments.contains("-b"),
           let data = try? Data(contentsOf: URL(fileURLWithPath: ".build/visual-checks/\(name).png")),
           let bitmap = NSBitmapImageRep(data: data) {
            let visible = (0..<bitmap.pixelsWide).contains { x in
                (0..<bitmap.pixelsHigh).contains { y in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return max(color.redComponent, color.greenComponent, color.blueComponent) > 0.05
                }
            }
            if !visible {
                blankTouchBarCaptures += 1
                print("Visual verification unavailable: \(name) is entirely black")
            }
        }
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.isAutomaticCustomizeTouchBarMenuItemEnabled = true
        let menu = NSMenu()
        let root = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Customize Touch Bar…", action: #selector(NSApplication.toggleTouchBarCustomizationPalette(_:)), keyEquivalent: "")
        root.submenu = submenu
        menu.addItem(root)
        app.mainMenu = menu
        try! FileManager.default.createDirectory(atPath: ".build/visual-checks", withIntermediateDirectories: true)
        let suite = "TouchBarEnhancer.ChatGPTPageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        let fixture = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let entries = ChatGPTCommand.allCases.map {
            ChatGPTAdapter.MenuEntry(title: $0.menuTitles[0], enabled: $0 != .temporaryChat, element: fixture)
        }
        let state = ChatGPTAdapter.Snapshot(trusted: true, running: true, entries: entries)
        var displayedState = state
        precondition(state.entry(for: .terminalPanel)?.title == "Toggle Bottom Panel")
        precondition(state.entry(for: .temporaryChat)?.enabled == false)
        precondition(ChatGPTAdapter.Snapshot(trusted: false, running: true, entries: []).summary == "Accessibility access needed")
        let pane = AppsPane(store: store, chatGPTConnectionReader: { displayedState })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Apps — ChatGPT"
        window.isReleasedWhenClosed = false
        window.contentView = pane
        let provider = AppBar(app: LayoutApp.builtIn[0])
        window.touchBar = provider.bar
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            pane.layoutSubtreeIfNeeded()
            let checkbox = descendants(pane).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "chatGPTControlsEnabled" }!
            checkbox.performClick(nil)
            precondition(!store.chatGPTControlsEnabled)
            checkbox.performClick(nil)
            precondition(store.chatGPTControlsEnabled)
            let connection = descendants(pane).compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "chatGPTConnection" }!
            precondition(connection.stringValue == "Connected · 7 menu actions found")
            let buttons = descendants(pane).compactMap { $0 as? NSButton }
            let count = store.chatShortcuts.count
            buttons.first { $0.title == "Add Chat" }!.performClick(nil)
            precondition(store.chatShortcuts.count == count + 1)
            let name = descendants(pane).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Chat name" }!
            name.stringValue = "Longer Custom Chat"
            name.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: name))
            precondition(store.chatShortcuts.last?.name == "Longer Custom Chat")
            buttons.first { $0.title == "Delete Chat" }!.performClick(nil)
            precondition(store.chatShortcuts.count == count)
            precondition(pane.selectedApp?.isChatGPT == true)
            capture("chatgpt-settings", arguments: ["-x", "-l\(window.windowNumber)"])
            let host = AppBarHost()
            let generic = AppBar(app: LayoutApp(bundleID: "test.generic", name: "Generic"))
            host.display(generic)
            precondition(TBPresent(host.bar))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            capture("generic-host", arguments: ["-b", "-x"])
            host.display(provider)
            provider.applyChatGPTStatus(state)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            capture("chatgpt-bar", arguments: ["-b", "-x"])
            precondition(provider.bar.item(forIdentifier: AppBar.itemID("chatgpt.sidebar")) is NSCustomTouchBarItem)
            let chatRegion = (provider.bar.item(forIdentifier: AppBar.itemID("chatgpt.chats")) as? NSCustomTouchBarItem)?.view
            precondition(chatRegion.map { descendants($0).contains { $0 is NSScrubber } } == true)
            host.display(generic)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            host.display(provider)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            capture("chatgpt-host-return", arguments: ["-b", "-x"])
            provider.configureChats([
                ChatShortcut(name: "A", color: "blue", slot: 1),
                ChatShortcut(name: "Longer Custom Chat", color: "teal", slot: 2),
                ChatShortcut(name: "项目与设计", color: "orange", slot: 3),
                ChatShortcut(name: "Chat 4", color: "purple", slot: 4),
                ChatShortcut(name: "Chat 5", color: "pink", slot: 5),
                ChatShortcut(name: "Chat 6", color: "green", slot: 6)
            ])
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            capture("chatgpt-variable-widths", arguments: ["-b", "-x"])
            let scrubber = descendants(chatRegion!).compactMap { $0 as? NSScrubber }.first!
            scrubber.scrollItem(at: 5, to: .trailing)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            capture("chatgpt-scrolled", arguments: ["-b", "-x"])
            provider.configureChats(store.chatShortcuts)
            provider.applyChatGPTStatus(ChatGPTAdapter.Snapshot(trusted: false, running: true, entries: []))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            capture("chatgpt-disabled", arguments: ["-b", "-x"])
            precondition(TBDismiss(host.bar))
            displayedState = ChatGPTAdapter.Snapshot(trusted: false, running: true, entries: [])
            let check = descendants(pane).compactMap { $0 as? NSButton }.first { $0.title == "Check Connection" }!
            check.performClick(nil)
            precondition(connection.stringValue == "Accessibility access needed")
            check.scrollToVisible(check.bounds)
            pane.layoutSubtreeIfNeeded()
            precondition(check.visibleRect.height > 0)
            capture("chatgpt-accessibility", arguments: ["-x", "-l\(window.windowNumber)"])
            app.toggleTouchBarCustomizationPalette(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                for palette in app.windows where palette.isVisible && NSStringFromClass(type(of: palette)) == "NSTouchBarCustomizationPaletteOverlayWindow" {
                    capture("chatgpt-palette", arguments: ["-x", "-l\(palette.windowNumber)"])
                }
                app.toggleTouchBarCustomizationPalette(nil)
                window.close()
                defaults.removePersistentDomain(forName: suite)
                print("ChatGPT page and preference checks passed (fixture menus)")
                if blankTouchBarCaptures > 0 {
                    print("Touch Bar visual acceptance pending: \(blankTouchBarCaptures) blank captures")
                }
                app.terminate(nil)
            }
        }
        app.run()
    }
}
