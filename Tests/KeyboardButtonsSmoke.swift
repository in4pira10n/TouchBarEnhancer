import AppKit

@main @MainActor
struct KeyboardButtonsSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func render(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill()
            view.displayIgnoringOpacity(view.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
        }
        try! bitmap.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: ".build/keyboard-checks/\(name).png"))
    }
    static func key(_ code: UInt16, _ character: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: code)!
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suite = "TouchBarEnhancer.KeyboardButtonsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try! FileManager.default.createDirectory(atPath: ".build/keyboard-checks", withIntermediateDirectories: true)
        let store = SettingsStore(defaults: defaults)
        let target = "com.apple.Safari"
        let shortcut = KeyboardShortcut(event: key(40, "k", [.command, .shift]))!
        precondition(shortcut.display == "⇧⌘K")
        let events = KeyboardShortcutSender.events(for: shortcut)!
        precondition(events.0.type == .keyDown && events.1.type == .keyUp)
        precondition(events.0.getIntegerValueField(.keyboardEventKeycode) == 40)
        precondition(events.0.flags.contains([.maskCommand, .maskShift]) && events.1.flags == events.0.flags)
        precondition(KeyboardShortcutSender.events(for: .init(keyCode: 255, modifiers: 0, keyLabel: "Invalid")) == nil)
        precondition(KeyboardShortcut(event: key(55, "", .command)) == nil)
        precondition(KeyboardShortcut(event: key(123, ""))?.display == "←")
        // No key events are posted by this test, especially into the user's foreground app.
        precondition(KeyboardShortcutSender.send(shortcut, to: "test.not.frontmost") != nil)

        var configuration = KeyboardButtonsConfiguration(buttons: [
            KeyboardButton(title: "Search", symbol: "magnifyingglass", shortcut: shortcut, description: "Find in this app"),
            KeyboardButton(title: "New Tab", symbol: "plus", color: "blue", shortcut: .init(keyCode: 17,
                modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "T")),
            KeyboardButton(title: "下一页", symbol: "arrow.right", color: "teal", shortcut: .init(keyCode: 124,
                modifiers: NSEvent.ModifierFlags.option.rawValue, keyLabel: "→"))])
        store.keyboardButtons[target] = configuration; store.save()
        precondition(SettingsStore(defaults: defaults).keyboardButtons[target] == configuration)
        precondition(SettingsStore(defaults: defaults).keyboardButtons["another.app"] == nil)

        let component = KeyboardButtonsComponent(targetBundleID: target, configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 685, height: 30),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = component.region
        var taps: [UUID] = []
        component.onSelect = { taps.append($0.id) }
        for count in [1, 2, 3] {
            configuration.layout = .fill
            configuration.buttons = Array(store.keyboardButtons[target]!.buttons.prefix(count))
            component.configure(configuration)
            for width: CGFloat in [685, 240, 96] {
                window.setContentSize(NSSize(width: width, height: 30))
                component.region.layoutSubtreeIfNeeded()
                let actualWidth = component.region.bounds.width
                let scrubber = component.scroller.scrubber
                let frames = (0..<count).map { scrubber.scrubberLayout.layoutAttributesForItem(at: $0)!.frame }
                let expected = (actualWidth - CGFloat(count - 1) * 8) / CGFloat(count)
                precondition(frames.allSatisfy { abs($0.width - expected) < 1.1 && $0.height == 30 }, "Equal fill widths: \(frames)")
                precondition(abs(frames[0].minX) < 0.5 && abs(frames.last!.maxX - actualWidth) < 0.5)
                for index in 1..<count { precondition(abs(frames[index].minX - frames[index - 1].maxX - 8) < 0.5) }
                component.scroller.scrubber(scrubber, didSelectItemAt: 0)
                component.scroller.scrubber(scrubber, didSelectItemAt: 0)
                precondition(taps.suffix(2).allSatisfy { $0 == configuration.buttons[0].id })
                let firstItem = component.scroller.scrubber(scrubber, viewForItemAt: 0)
                firstItem.isHighlighted = true
                precondition(firstItem.isHighlighted && scrubber.selectedIndex == -1)
                firstItem.isHighlighted = false
                if width == 685 { render(component.region, "fill-\(count)") }
            }
        }
        configuration.buttons = [store.keyboardButtons[target]!.buttons[0]]
        configuration.layout = .scrolling
        for alignment in ScrollingComponentAlignment.allCases {
            configuration.alignment = alignment
            component.configure(configuration)
            window.setContentSize(NSSize(width: 685, height: 30))
            component.region.layoutSubtreeIfNeeded()
            let scrubber = component.scroller.scrubber
            let frame = scrubber.convert(scrubber.bounds, to: component.region)
            let natural = ScrollingComponentItemView.width(for: configuration.buttons[0].scrollingItem)
            precondition(abs(frame.width - natural) < 1)
            let expected: CGFloat = alignment == .left ? 0 : (alignment == .center ? (685 - natural) / 2 : 685 - natural)
            precondition(abs(frame.minX - expected) < 1, "Scroll alignment \(alignment): \(frame)")
            component.scroller.scrubber(scrubber, didSelectItemAt: 0)
            component.scroller.scrubber(scrubber, didSelectItemAt: 0)
            precondition(scrubber.selectedIndex == -1)
            render(component.region, "scroll-\(alignment.rawValue.lowercased())")
        }
        configuration.buttons = (1...12).map { KeyboardButton(title: "Long title 项目 \($0)", shortcut: shortcut) }
        component.configure(configuration)
        window.setContentSize(NSSize(width: 96, height: 30))
        component.region.layoutSubtreeIfNeeded()
        precondition(abs(component.scroller.scrubber.frame.width - 96) < 1)
        component.scroller.scrubber.scrollItem(at: 11, to: .trailing)
        precondition(component.scroller.scrubber.selectedIndex == -1)

        let provider = AppBar(app: LayoutApp(bundleID: target, name: "Safari"),
            keyboardButtons: configuration, persistsLayout: false)
        let keyboardView = (provider.bar.item(forIdentifier: AppBar.itemID("keyboard")) as! NSCustomTouchBarItem).view
        precondition(provider.bar.customizationAllowedItemIdentifiers.contains(AppBar.itemID("keyboard")))
        let live = descendants(keyboardView).compactMap { $0 as? NSScrubber }.first!
        store.onChange = { provider.configureKeyboardButtons(store.keyboardButtons[target] ?? .init()) }
        let editor = ShortcutCategoryEditor(store: store, kind: .keyboard, appBundleID: target)
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        let document = NSView()
        settings.contentView = document
        editor.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(editor)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            editor.topAnchor.constraint(equalTo: document.topAnchor)
        ])
        descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Keyboard Shortcuts" }!.performClick(nil)
        settings.layoutIfNeeded()
        let editingTable = descendants(editor).compactMap { $0 as? NSTableView }.first!
        for column in 0..<editingTable.numberOfColumns { _ = editingTable.view(atColumn: column, row: 0, makeIfNecessary: true) }
        let name = descendants(editor).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Button title" }!
        let recorder = descendants(editor).compactMap { $0 as? KeyboardShortcutRecorder }.first!
        let originalShortcut = recorder.shortcut
        recorder.performClick(nil)
        precondition(recorder.isRecording)
        recorder.keyDown(with: key(53, ""))
        precondition(!recorder.isRecording && recorder.shortcut == originalShortcut)
        recorder.performClick(nil)
        precondition(recorder.performKeyEquivalent(with: key(8, "c", [.command, .option])))
        precondition(store.keyboardButtons[target]!.buttons[0].shortcut?.display == "⌥⌘C")
        recorder.performClick(nil); recorder.keyDown(with: key(51, ""))
        precondition(store.keyboardButtons[target]!.buttons[0].shortcut == nil)
        recorder.performClick(nil); recorder.keyDown(with: key(40, "k", [.command, .shift]))
        settings.layoutIfNeeded()
        precondition(settings.makeFirstResponder(name))
        let fieldEditor = name.currentEditor() as! NSTextView
        fieldEditor.selectAll(nil)
        fieldEditor.insertText("Updated Search", replacementRange: fieldEditor.selectedRange())
        precondition(store.keyboardButtons[target]!.buttons[0].title == "Updated Search")
        precondition(settings.firstResponder === fieldEditor)
        let first = live.dataSource!.scrubber(live, viewForItemAt: 0)
        precondition(descendants(first).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Updated Search" })
        settings.endEditing(for: nil)
        let fields = descendants(editor).compactMap { $0 as? NSTextField }
        let color = fields.first { $0.placeholderString == "Default" }!
        color.stringValue = "purple"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: color))
        precondition(store.keyboardButtons[target]!.buttons[0].color == "purple")
        precondition(store.keyboardButtons[target]!.buttons[1].color == "blue", "Background is per button")
        color.stringValue = ""
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: color))
        precondition(store.keyboardButtons[target]!.buttons[0].scrollingItem.background == .standard)
        precondition(SettingsStore(defaults: defaults).keyboardButtons[target]!.buttons[0].color.isEmpty)
        color.stringValue = "#FF5500"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: color))
        descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Default" }!.performClick(nil)
        precondition(color.stringValue.isEmpty && store.keyboardButtons[target]!.buttons[0].color.isEmpty)
        precondition(store.keyboardButtons[target]!.buttons[1].color == "blue")
        let description = fields.first { $0.placeholderString == "Optional description" }!
        description.stringValue = "Search this application"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: description))
        precondition(store.keyboardButtons[target]!.buttons[0].scrollingItem.toolTip.contains("Search this application"))
        let layout = descendants(editor).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "keyboardLayout" }!
        layout.selectItem(withTitle: "Fill"); layout.sendAction(layout.action, to: layout.target)
        precondition(store.keyboardButtons[target]!.layout == .fill)
        precondition(live.numberOfItems == 3)
        layout.selectItem(withTitle: "Scrolling"); layout.sendAction(layout.action, to: layout.target)
        let alignment = descendants(editor).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "keyboardAlignment" }!
        alignment.selectItem(withTitle: "Right"); alignment.sendAction(alignment.action, to: alignment.target)
        precondition(SettingsStore(defaults: defaults).keyboardButtons[target]!.alignment == .right)
        render(editor, "editor-dark")
        settings.appearance = NSAppearance(named: .aqua)
        render(editor, "editor-light")
        precondition(!window.isVisible && !settings.isVisible)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        print("Keyboard button checks passed: per-app persistence, recording, key events, foreground guard, live editing, repeated taps, fill 1/2/3, 8pt gaps, left/center/right scrolling, narrow overflow, no activation")
    }
}
