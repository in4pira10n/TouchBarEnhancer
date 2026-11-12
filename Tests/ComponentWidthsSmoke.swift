import AppKit

@main @MainActor
struct ComponentWidthsSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func near(_ actual: CGFloat, _ expected: CGFloat) {
        precondition(abs(actual - expected) < 1, "Expected \(expected), got \(actual)")
    }
    static func select(_ popup: NSPopUpButton, _ title: String) {
        popup.selectItem(withTitle: title); popup.sendAction(popup.action, to: popup.target)
    }
    static func number(_ control: NSView, _ value: String) {
        let field = descendants(control).compactMap { $0 as? ComponentInlineTextField }.first!
        field.stringValue = value
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
    static func mode(_ control: NSView, _ title: String) {
        select(descendants(control).compactMap { $0 as? NSPopUpButton }.first!, title)
    }
    static func render(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill()
            view.displayIgnoringOpacity(view.bounds, in: context); NSGraphicsContext.restoreGraphicsState()
        }
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/component-widths/\(name).png"))
    }
    static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory); application.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suite = "TouchBarEnhancer.ComponentWidths.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(atPath: ".build/component-widths", withIntermediateDirectories: true)
        let store = SettingsStore(defaults: defaults)
        let app = LayoutApp.builtIn[0]
        // Synthesized optional decoding must preserve existing records without width settings.
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(ChatShortcut.self, from: Data("{\"id\":\"E3C60628-B679-4844-9EAF-D95DE9763EAA\",\"name\":\"Old\",\"symbol\":\"star\",\"color\":\"blue\",\"slot\":1}".utf8))
        precondition(legacy.fillWidth == nil)
        let legacyPresentation = try decoder.decode(ComponentPresentation.self, from: Data("{\"layout\":\"Scrolling\",\"alignment\":\"Left\"}".utf8))
        precondition(legacyPresentation.textWidth == nil)
        store.chatShortcuts = (1...3).map { ChatShortcut(name: "Chat \($0)", slot: $0) }
        store.quickPhrasesByApp[app.bundleID] = (1...3).map { QuickPhrase(name: "Phrase \($0)", text: "Content \($0)") }
        store.keyboardButtons[app.bundleID] = .init(buttons: (1...3).map { KeyboardButton(title: "Button \($0)") })
        store.textComponents[app.bundleID] = [TextComponentItem(text: "Native Text"), TextComponentItem(text: "中文 🧑‍💻"), TextComponentItem(text: "Third")]
        let provider = AppBar(app: app, shortcuts: store.chatShortcuts, phrases: store.quickPhrasesByApp[app.bundleID]!,
            keyboardButtons: store.keyboardButtons[app.bundleID]!, textItems: store.textComponents[app.bundleID]!, persistsLayout: false)
        store.onChange = {
            provider.configureChats(store.chatShortcuts)
            provider.configurePhrases(store.quickPhrasesByApp[app.bundleID]!)
            provider.configureKeyboardButtons(store.keyboardButtons[app.bundleID]!)
            provider.configureText(store.textComponents[app.bundleID]!)
            provider.configureComponentPresentations(store.componentPresentations[app.bundleID] ?? [:])
        }
        let keys = ["chatgpt.chats", "phrases", "keyboard", "text"]
        let editors: [NSView] = [ShortcutCategoryEditor(store: store, kind: .chats, appBundleID: app.bundleID),
            ShortcutCategoryEditor(store: store, kind: .phrases, appBundleID: app.bundleID),
            ShortcutCategoryEditor(store: store, kind: .keyboard, appBundleID: app.bundleID),
            TextComponentEditor(store: store, appBundleID: app.bundleID)]
        func savedWidths(_ key: String) -> [ComponentItemWidth?] {
            switch key {
            case "chatgpt.chats": store.chatShortcuts.map(\.fillWidth)
            case "phrases": store.quickPhrasesByApp[app.bundleID]!.map(\.fillWidth)
            case "keyboard": store.keyboardButtons[app.bundleID]!.buttons.map(\.fillWidth)
            default: store.textComponents[app.bundleID]!.map(\.fillWidth)
            }
        }
        for (key, editor) in zip(keys, editors) {
            let title = key == "chatgpt.chats" ? "Chat Shortcuts" : (key == "phrases" ? "Quick Phrases" : (key == "text" ? "Text" : "Keyboard Shortcuts"))
            if key != "chatgpt.chats" { descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == title }!.performClick(nil) }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
            let root = NSView(); window.contentView = root
            editor.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(editor)
            NSLayoutConstraint.activate([editor.leadingAnchor.constraint(equalTo: root.leadingAnchor), editor.trailingAnchor.constraint(equalTo: root.trailingAnchor), editor.topAnchor.constraint(equalTo: root.topAnchor)])
            window.layoutIfNeeded()
            let table = descendants(editor).compactMap { $0 as? NSTableView }.first!
            let columnIndex = table.tableColumns.firstIndex { $0.identifier.rawValue == "width" }!
            let widthColumn = table.tableColumns[columnIndex]
            precondition(widthColumn.isHidden)
            let layout = descendants(editor).compactMap { $0 as? NSPopUpButton }.first {
                $0.accessibilityIdentifier() == (key == "keyboard" ? "keyboardLayout" : "componentLayout.\(key)")
            }!
            select(layout, "Fill"); window.layoutIfNeeded()
            precondition(!widthColumn.isHidden)
            let controls = (0..<3).map { table.view(atColumn: columnIndex, row: $0, makeIfNecessary: true) as! ComponentItemWidthControl }
            for control in controls {
                precondition(descendants(control).compactMap { $0 as? NSPopUpButton }.first!.titleOfSelectedItem == "Relative")
                precondition(descendants(control).compactMap { $0 as? ComponentInlineTextField }.first!.doubleValue == 12)
            }
            let wrapper = (provider.bar.item(forIdentifier: AppBar.itemID(key)) as! NSCustomTouchBarItem).view
            let barWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
            barWindow.contentView = wrapper
            let scrubber = descendants(wrapper).compactMap { $0 as? NSScrubber }.first!
            func frames() -> [NSRect] {
                wrapper.layoutSubtreeIfNeeded()
                let region = descendants(wrapper).compactMap { $0 as? ScrollingComponentRegion }.first!
                region.layoutSubtreeIfNeeded(); scrubber.layoutSubtreeIfNeeded()
                let frames = (0..<3).map { scrubber.scrubberLayout.layoutAttributesForItem(at: $0)!.frame }
                for pair in zip(frames, frames.dropFirst()) { near(pair.1.minX - pair.0.maxX, 8) }
                return frames
            }
            let equal = frames()
            near(equal[0].width, equal[1].width); near(equal[1].width, equal[2].width)
            // Verify live keystrokes keep the same standard field editor.
            let field = descendants(controls[0]).compactMap { $0 as? ComponentInlineTextField }.first!
            precondition(window.makeFirstResponder(field))
            let fieldEditor = field.currentEditor() as! NSTextView
            fieldEditor.selectAll(nil); fieldEditor.insertText("6", replacementRange: fieldEditor.selectedRange())
            precondition(field.currentEditor() === fieldEditor && savedWidths(key)[0]?.relative == 6)
            window.endEditing(for: nil)
            number(controls[1], "6"); number(controls[2], "12")
            var actual = frames()
            near(actual[0].width, actual[1].width); near(actual[2].width, actual[0].width * 2)
            number(controls[0], "1"); number(controls[1], "1"); number(controls[2], "2")
            let scaled = frames()
            for pair in zip(actual, scaled) { near(pair.0.width, pair.1.width) }
            mode(controls[0], "Fixed"); number(controls[0], "96")
            mode(controls[1], "Hug")
            precondition(descendants(controls[1]).compactMap { $0 as? ComponentInlineTextField }.allSatisfy(\.isHidden))
            actual = frames(); near(actual[0].width, 96)
            let fillHugWidth = actual[1].width
            near(actual.last!.maxX, scrubber.bounds.width)
            // All preferences survive Scrolling, which must ignore them entirely.
            let saved = savedWidths(key)
            select(layout, "Scrolling"); precondition(widthColumn.isHidden)
            let natural = frames()
            near(natural[1].width, fillHugWidth)
            precondition(savedWidths(key) == saved)
            select(layout, "Fill"); window.layoutIfNeeded()
            for pair in zip(frames(), actual) { near(pair.0.width, pair.1.width) }
            // Invalid edits never overwrite the last valid width.
            for invalid in ["", "0", "-1", "nan", "inf", "1e300"] { number(controls[0], invalid); precondition(savedWidths(key) == saved) }
            number(controls[0], "96")
            // Fixed and Hug can exceed the viewport without corrupting spacing.
            barWindow.setContentSize(NSSize(width: 110, height: 30))
            let overflow = frames(); near(overflow[0].width, 96); near(overflow[1].width, fillHugWidth)
            precondition(overflow[2].width >= 1 && overflow.last!.maxX > scrubber.bounds.width)
            barWindow.setContentSize(NSSize(width: 600, height: 30)); _ = frames()
            let restored = SettingsStore(defaults: defaults)
            precondition(restored.chatShortcuts == store.chatShortcuts && restored.quickPhrasesByApp == store.quickPhrasesByApp)
            precondition(restored.keyboardButtons == store.keyboardButtons && restored.textComponents == store.textComponents)
            render(editor, key.replacingOccurrences(of: ".", with: "-"))
            precondition(!window.isVisible && !barWindow.isVisible)
        }
        // Empty, fractional, missing, invalid and extreme-but-valid weights are safe.
        precondition(ComponentItemWidth.allocate([], naturalWidths: [], available: 0).isEmpty)
        let invalid = ComponentItemWidth.allocate([.init(relative: .nan), .init(relative: 12)], naturalWidths: [60, 60], available: 200)
        near(invalid[0], invalid[1])
        let fractional = ComponentItemWidth.allocate([.init(relative: 0.5), .init(relative: 1)], naturalWidths: [60, 60], available: 200)
        near(fractional[1], fractional[0] * 2)
        let fixed = ComponentItemWidth.allocate([.init(mode: .fixed, fixed: 50), .init(mode: .hug)], naturalWidths: [80, 90], available: 600)
        precondition(fixed == [50, 90], "No Relative entries: leave trailing space rather than stretch Fixed/Hug")
        // Text component width is separate from per-entry Fill width and works in both layouts.
        let textEditor = editors.last!
        let widthMode = descendants(textEditor).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityIdentifier() == "textComponentWidthMode"
        }!
        let widthValue = descendants(textEditor).compactMap { $0 as? ComponentInlineTextField }.first {
            $0.accessibilityIdentifier() == "textComponentWidthValue"
        }!
        let layoutPopup = descendants(textEditor).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityIdentifier() == "componentLayout.text"
        }!
        select(widthMode, "Fixed")
        widthValue.stringValue = "20"
        widthValue.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: widthValue))
        let textRegion = ((provider.bar.item(forIdentifier: AppBar.itemID("text")) as! NSCustomTouchBarItem).view as! TouchBarComponentView).content as! ScrollingComponentRegion
        near(textRegion.requestedWidth!, 20)
        near(textRegion.minimumWidthConstraint!.constant, 1)
        select(layoutPopup, "Scrolling")
        precondition(!widthMode.isHiddenOrHasHiddenAncestor && store.presentation(for: "text", app: app.bundleID).textWidth?.fixed == 20)
        near(textRegion.requestedWidth!, 20)
        select(widthMode, "Hug"); precondition(widthValue.isHidden)
        precondition(textRegion.requestedWidth! > 0)
        store.textComponents[app.bundleID] = [TextComponentItem(text: "I")]; store.save()
        precondition(textRegion.requestedWidth! < 32)
        let hug = textRegion.requestedWidth!
        store.textComponents[app.bundleID]![0].style.backgroundColor = "#363636"; store.save()
        near(textRegion.requestedWidth!, hug + 8)
        let persistedPresentation = SettingsStore(defaults: defaults).presentation(for: "text", app: app.bundleID)
        precondition(persistedPresentation == store.presentation(for: "text", app: app.bundleID))
        precondition(store.presentation(for: "keyboard", app: app.bundleID).textWidth == nil)
        precondition(store.presentation(for: "text", app: "test.other-app").textWidth == nil)
        select(widthMode, "Auto")
        precondition(textRegion.requestedWidth == nil && textRegion.minimumWidthConstraint!.constant == 32)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        print("Component width checks passed: all categories, legacy defaults, native Fill-only entry controls, weighted ratios, mixed Fixed/Hug/Relative, live field editing, Text region Fixed/Hug/Auto, per-app persistence, resizing, overflow, unchanged gaps, no activation")
    }
}
