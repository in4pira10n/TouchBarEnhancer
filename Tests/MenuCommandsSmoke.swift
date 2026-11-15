import AppKit

@main @MainActor
struct MenuCommandsSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func render(_ view: NSView, name: String) {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill()
            view.displayIgnoringOpacity(view.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
        }
        try! bitmap.representation(using: .png, properties: [:])!.write(to:
            URL(fileURLWithPath: ".build/menu-checks/\(name).png"))
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suite = "TouchBarEnhancer.MenuCommandsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let target = "test.menu.app"
        let command = MenuCommandBinding(title: "Show Sidebar", parentPath: "View", alternateTitle: "Hide Sidebar")
        precondition(command.isValid && command.display == "View → Show Sidebar")
        precondition(!MenuCommandBinding(title: " ").isValid)
        precondition(!MenuCommandBinding(title: "Open", parentPath: "File →").isValid)
        precondition(MenuCommandBinding(title: "Open", parentPath: "File → Recent").path == ["File", "Recent"])
        let entries: [MenuCommandSender.Entry] = [
            .init(path: ["View", "Show Sidebar"], enabled: true),
            .init(path: ["View", "Hide Sidebar"], enabled: false),
            .init(path: ["File", "Show Sidebar"], enabled: true),
            .init(path: ["File", "Export…"], enabled: true),
            .init(path: ["File", "Recent", "文档"], enabled: true)]
        func resolves(_ binding: MenuCommandBinding, _ values: [MenuCommandSender.Entry] = entries,
                      complete: Bool = true) -> Bool {
            if case .success = MenuCommandSender.resolve(binding, in: .init(entries: values, complete: complete)) { return true }
            return false
        }
        precondition(resolves(command))
        precondition(!resolves(.init(title: "Show Sidebar")), "Duplicate names require a path")
        precondition(!resolves(.init(title: "show sidebar", parentPath: "View")))
        precondition(!resolves(.init(title: "Export...", parentPath: "File")))
        precondition(resolves(.init(title: "Export…", parentPath: "File")))
        precondition(resolves(.init(title: "文档", parentPath: "File → Recent")))
        precondition(!resolves(command, complete: false))
        precondition(!resolves(command, [.init(path: ["View", "Show Sidebar"], enabled: false)]))
        precondition(!resolves(command, [.init(path: ["View", "Show Sidebar"], enabled: true),
                                        .init(path: ["View", "Show Sidebar"], enabled: false)]))
        precondition(resolves(command, [.init(path: ["View", "Hide Sidebar"], enabled: true)]))
        precondition(!resolves(command, [.init(path: ["View", "Show Sidebar"], enabled: true),
                                        .init(path: ["View", "Hide Sidebar"], enabled: true)]))
        var presses = 0
        var reads = 0
        var current = MenuCommandSender.Target(bundleID: target, pid: 123)
        var environment = MenuCommandSender.Environment(trusted: { true }, foreground: { current }, read: { pid, path in
            precondition(pid == 123 && path == ["View"]); reads += 1
            return .init(entries: entries)
        }, press: { entry in presses += 1; return entry.path == ["View", "Show Sidebar"] })
        precondition(MenuCommandSender.send(command, to: target, environment: environment) == nil)
        precondition(presses == 1 && reads == 1)
        precondition(MenuCommandSender.send(command, to: "other.app", environment: environment) != nil)
        precondition(reads == 1 && presses == 1)
        environment.trusted = { false }
        precondition(MenuCommandSender.send(command, to: target, environment: environment) != nil)
        precondition(reads == 1 && presses == 1)
        environment.trusted = { true }
        environment.read = { _, _ in current.pid = 456; return .init(entries: entries) }
        precondition(MenuCommandSender.send(command, to: target, environment: environment) != nil)
        precondition(presses == 1, "Recheck foreground PID before AXPress")
        current.pid = 123
        environment.read = { _, _ in .init(entries: entries) }
        environment.press = { _ in false }
        precondition(MenuCommandSender.send(command, to: target, environment: environment) != nil)
        // Legacy keyboard records decode with no command and stay keyboard actions.
        let legacy = Data(#"{"title":"Legacy","symbol":"keyboard","color":"","description":""}"#.utf8)
        let legacyWithID = Data((String(data: legacy, encoding: .utf8)!.dropLast() + ",\"id\":\"\(UUID())\"}").utf8)
        precondition(try! JSONDecoder().decode(KeyboardButton.self, from: legacyWithID).menuCommand == nil)
        let config = KeyboardButtonsConfiguration(buttons: [
            .init(title: "Sidebar", symbol: "sidebar.left", description: "Toggle sidebar", menuCommand: command),
            .init(title: "Export", symbol: "square.and.arrow.up", color: "blue", fillWidth: .init(mode: .hug),
                  menuCommand: .init(title: "Export…", parentPath: "File"))])
        store.menuButtons[target] = config
        store.keyboardButtons[target] = .init(buttons: [.init(title: "Keyboard")])
        store.save()
        precondition(SettingsStore(defaults: defaults).menuButtons[target] == config)
        precondition(SettingsStore(defaults: defaults).menuButtons["other.app"] == nil)
        let provider = AppBar(app: .init(bundleID: target, name: "Test App"), keyboardButtons: store.keyboardButtons[target]!,
            menuButtons: config, persistsLayout: false)
        precondition(provider.bar.customizationAllowedItemIdentifiers.contains(AppBar.itemID("menu")))
        let firstView = (provider.bar.item(forIdentifier: AppBar.itemID("menu")) as! NSCustomTouchBarItem).view
        let secondBar = NSTouchBar(); secondBar.delegate = provider
        let secondView = (secondBar.item(forIdentifier: AppBar.itemID("menu")) as! NSCustomTouchBarItem).view
        precondition(firstView !== secondView)
        let scrubbers = [firstView, secondView].map { descendants($0).compactMap { $0 as? NSScrubber }.first! }
        precondition(scrubbers.allSatisfy { $0.numberOfItems == 2 })
        store.onChange = {
            provider.configureMenuButtons(store.menuButtons[target] ?? .init())
            provider.configureComponentPresentations(store.componentPresentations[target] ?? [:])
            provider.configureComponentDisplayModes(store.componentDisplayModes[target] ?? [:])
        }
        let editor = ShortcutCategoryEditor(store: store, kind: .menu, appBundleID: target)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let root = NSView(); window.contentView = root
        editor.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(editor)
        NSLayoutConstraint.activate([editor.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: root.trailingAnchor), editor.topAnchor.constraint(equalTo: root.topAnchor)])
        descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Menu Commands" }!.performClick(nil)
        window.layoutIfNeeded()
        let table = descendants(editor).compactMap { $0 as? NSTableView }.first!
        for column in 0..<table.numberOfColumns { _ = table.view(atColumn: column, row: 0, makeIfNecessary: true) }
        let name = descendants(editor).compactMap { $0 as? ComponentInlineTextField }.first { $0.placeholderString == "Exact menu name" }!
        precondition(window.makeFirstResponder(name))
        let fieldEditor = name.currentEditor() as! NSTextView
        fieldEditor.selectAll(nil); fieldEditor.insertText("Hide Sidebar", replacementRange: fieldEditor.selectedRange())
        precondition(window.firstResponder === fieldEditor)
        precondition(store.menuButtons[target]!.buttons[0].menuCommand?.title == "Hide Sidebar")
        precondition(store.keyboardButtons[target]!.buttons[0].title == "Keyboard")
        window.endEditing(for: nil)
        let fields = descendants(editor).compactMap { $0 as? NSTextField }
        let path = fields.first { $0.accessibilityIdentifier() == "menuParentPath" }!
        path.stringValue = "View → Layout"
        editor.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: path))
        precondition(store.menuButtons[target]!.buttons[0].menuCommand?.parentPath == "View → Layout")
        precondition(scrubbers.allSatisfy { $0.numberOfItems == 2 })
        let layout = descendants(editor).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "componentLayout.menu" }!
        layout.selectItem(withTitle: "Fill"); layout.sendAction(layout.action, to: layout.target)
        precondition(store.presentation(for: "menu", app: target).layout == .fill)
        precondition(table.tableColumns.first { $0.identifier.rawValue == "width" }!.isHidden == false)
        let color = fields.first { $0.placeholderString == "Default" }!
        color.stringValue = "orange"
        editor.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: color))
        precondition(store.menuButtons[target]!.buttons[0].color == "orange")
        color.stringValue = ""
        editor.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: color))
        precondition(store.menuButtons[target]!.buttons[0].scrollingItem.background == .standard)
        precondition(store.menuButtons[target]!.buttons[1].color == "blue")
        precondition(SettingsStore(defaults: defaults).menuButtons[target] == store.menuButtons[target])
        precondition(store.menuButtons[target]!.buttons[0].menuCommand?.title == "Hide Sidebar", "Inspector preserves inline edits")
        let component = KeyboardButtonsComponent(targetBundleID: target, configuration: config, usesMenuCommands: true)
        var taps: [UUID] = []
        component.onSelect = { taps.append($0.id) }
        for _ in 0..<2 { component.scroller.scrubber(component.scroller.scrubber, didSelectItemAt: 0) }
        precondition(taps == [config.buttons[0].id, config.buttons[0].id])
        precondition(component.scroller.scrubber.selectedIndex == -1)
        render(editor, name: "editor-light")
        window.appearance = NSAppearance(named: .darkAqua)
        render(editor, name: "editor-dark")
        precondition(!window.isVisible && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        print("Menu command checks passed: exact/path/alternate matching, duplicate/disabled/partial guards, foreground PID, mock AXPress, shared editor, live views, persistence and repeated taps; no user actions executed")
    }
}
