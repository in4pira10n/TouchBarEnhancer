import AppKit

@main @MainActor
struct TextComponentSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func render(_ view: NSView, name: String) {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill()
            view.displayIgnoringOpacity(view.bounds, in: context); NSGraphicsContext.restoreGraphicsState()
        }
        try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/text-component/\(name).png"))
    }
    static func label(_ scrubber: NSScrubber) -> NSTextField {
        descendants(scrubber.dataSource!.scrubber(scrubber, viewForItemAt: 0)).compactMap { $0 as? NSTextField }.first!
    }
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory); application.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suite = "TouchBarEnhancer.TextTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try! FileManager.default.createDirectory(atPath: ".build/text-component", withIntermediateDirectories: true)
        let store = SettingsStore(defaults: defaults)
        let app = LayoutApp.builtIn[1]
        let defaultStyle = TextComponentStyle()
        let native = NSTextField(labelWithString: "Native")
        let attrs = defaultStyle.attributedString("Native").attributes(at: 0, effectiveRange: nil)
        precondition((attrs[.font] as! NSFont) == native.font)
        precondition((attrs[.foregroundColor] as! NSColor) == .white)
        precondition(attrs[.kern] == nil && attrs[.baselineOffset] == nil && attrs[.underlineStyle] == nil)
        precondition(defaultStyle.textAlignment == native.alignment && defaultStyle.lineBreakMode == native.lineBreakMode)
        let custom = TextComponentStyle(fontName: "Menlo-Regular", fontSize: 18, weight: .bold, italic: true,
            color: "#12ABEF", opacity: 0.5, tracking: 2, baselineOffset: 1, underline: true, strikethrough: true,
            alignment: .right, truncation: .tail, backgroundColor: "#363636")
        store.textComponents[app.bundleID] = [TextComponentItem(text: "Swift 文字 🧑‍💻", style: custom)]
        store.textComponents["test.other-app"] = [TextComponentItem(text: "Other")]
        store.save()
        let provider = AppBar(app: app, textItems: store.textComponents[app.bundleID]!, persistsLayout: false)
        let secondBar = NSTouchBar(); secondBar.delegate = provider
        let views = [provider.bar, secondBar].map { bar in
            (bar.item(forIdentifier: AppBar.itemID("text")) as! NSCustomTouchBarItem).view
        }
        let scrubbers = views.map { descendants($0).compactMap { $0 as? NSScrubber }.first! }
        store.onChange = { provider.configureText(store.textComponents[app.bundleID] ?? []) }
        precondition(label(scrubbers[0]).stringValue == "Swift 文字 🧑‍💻")
        let styled = label(scrubbers[0]).attributedStringValue.attributes(at: 0, effectiveRange: nil)
        precondition((styled[.font] as! NSFont).pointSize == 18)
        precondition((styled[.kern] as! Double) == 2 && (styled[.baselineOffset] as! Double) == 1)
        precondition((styled[.foregroundColor] as! NSColor).alphaComponent == 0.5)
        let editor = TextComponentEditor(store: store, appBundleID: app.bundleID)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 1050), styleMask: [.titled], backing: .buffered, defer: false)
        let document = NSView(); host.contentView = document
        editor.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(editor)
        NSLayoutConstraint.activate([editor.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: document.trailingAnchor), editor.topAnchor.constraint(equalTo: document.topAnchor)])
        descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Text" }!.performClick(nil)
        host.layoutIfNeeded()
        let table = descendants(editor).compactMap { $0 as? NSTableView }.first!
        let inline = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! ComponentInlineTextField
        precondition(host.makeFirstResponder(inline))
        let fieldEditor = inline.currentEditor() as! NSTextView
        fieldEditor.selectAll(nil); fieldEditor.insertText("Live text", replacementRange: fieldEditor.selectedRange())
        precondition(store.textComponents[app.bundleID]![0].text == "Live text")
        precondition(host.firstResponder === fieldEditor && inline.currentEditor() === fieldEditor)
        host.endEditing(for: nil)
        for scrubber in scrubbers { precondition(label(scrubber).stringValue == "Live text") }
        let size = descendants(editor).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "text.fontSize" }!
        size.stringValue = "nan"; editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: size))
        precondition(store.textComponents[app.bundleID]![0].style.fontSize == 18)
        size.stringValue = "17"; editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: size))
        precondition(label(scrubbers[1]).font?.pointSize == 17 || (label(scrubbers[1]).attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 17)
        render(editor, name: "basic")
        descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Advanced Typography" }!.performClick(nil)
        render(editor, name: "advanced")
        // Every configurable style attribute has its own native reset action.
        let keys = ["fontName", "fontSize", "weight", "italic", "color", "opacity", "tracking", "baselineOffset", "underline", "strikethrough", "alignment", "truncation", "backgroundColor"]
        for key in keys {
            let before = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(store.textComponents[app.bundleID]![0].style)) as! [String: NSObject]
            let reset = descendants(editor).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "text.default.\(key)" }!
            reset.performClick(nil)
            let after = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(store.textComponents[app.bundleID]![0].style)) as! [String: NSObject]
            precondition(before[key] != nil && after[key] == nil && after.count == before.count - 1)
            precondition(after.allSatisfy { before[$0.key] == $0.value }, "Reset only the selected property")
            let persisted = SettingsStore(defaults: defaults)
            precondition(persisted.textComponents[app.bundleID] == store.textComponents[app.bundleID])
        }
        precondition(store.textComponents[app.bundleID]![0].style == .init())
        precondition(store.textComponents["test.other-app"]![0].text == "Other")
        precondition(store.textComponents["test.new-app"] == nil)
        // The text presentation has zero button inset, no icon and no bezel.
        let item = store.textComponents[app.bundleID]![0].scrollingItem
        let width = ScrollingComponentItemView.width(for: item)
        let natural = NSTextField(labelWithString: ""); natural.attributedStringValue = item.textStyle!.attributedString(item.title)
        precondition(width == ceil(natural.fittingSize.width))
        let textView = ScrollingComponentItemView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        let barWindow = NSWindow(contentRect: textView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        barWindow.contentView = textView; barWindow.appearance = NSAppearance(named: .darkAqua)
        textView.configure(item); textView.layoutSubtreeIfNeeded()
        precondition(descendants(textView).compactMap { $0 as? NSImageView }.allSatisfy(\.isHidden))
        let textFrame = label(scrubbers[0])
        precondition(!textFrame.isHidden)
        render(textView, name: "plain-bar")
        var colored = item
        colored.textStyle!.backgroundColor = "#363636"; colored.background = .color("#363636")
        precondition(ScrollingComponentItemView.width(for: colored) == width + 8)
        textView.configure(colored); textView.layoutSubtreeIfNeeded()
        let coloredLabel = descendants(textView).compactMap { $0 as? NSTextField }.first!
        let content = coloredLabel.superview!
        let coloredFrame = content.convert(content.bounds, to: textView)
        precondition(abs(coloredFrame.minX - 4) < 0.5 && abs(coloredFrame.maxX - 296) < 0.5, "Colored content: \(coloredFrame)")
        render(textView, name: "background-bar")
        textView.configure(item); textView.layoutSubtreeIfNeeded()
        let clearFrame = content.convert(content.bounds, to: textView)
        precondition(abs(clearFrame.minX) < 0.5 && abs(clearFrame.maxX - 300) < 0.5)
        textView.configure(TextComponentItem(text: "Styled", style: custom).scrollingItem)
        textView.configure(ScrollingComponentItem(title: "Button", symbol: "star", accessibilityLabel: "Button", toolTip: "Button"))
        textView.layoutSubtreeIfNeeded()
        precondition(descendants(textView).compactMap { $0 as? NSImageView }.allSatisfy { !$0.isHidden })
        let buttonLabel = descendants(textView).compactMap { $0 as? NSTextField }.first!
        precondition(buttonLabel.stringValue == "Button" && buttonLabel.font == .systemFont(ofSize: 15))
        precondition(buttonLabel.textColor == .white && buttonLabel.lineBreakMode == .byTruncatingTail)
        precondition(buttonLabel.maximumNumberOfLines == 0 && buttonLabel.cell?.wraps == false && buttonLabel.cell?.usesSingleLineMode == false)
        let buttonAttributes = buttonLabel.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        precondition(buttonAttributes[.kern] == nil && buttonAttributes[.baselineOffset] == nil && buttonAttributes[.underlineStyle] == nil)
        precondition(!host.isVisible && !barWindow.isVisible && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        print("Text component checks passed: native defaults, attributed typography, per-property resets, isolated per-app persistence, live independent presentations, inline field editor, invalid numbers, no padding/bezel, reused button views, offscreen renders, no activation")
    }
}
