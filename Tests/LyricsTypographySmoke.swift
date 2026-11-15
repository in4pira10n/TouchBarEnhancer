import AppKit

@main @MainActor
struct LyricsTypographySmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func label(_ scrubber: NSScrubber) -> NSTextField {
        descendants(scrubber.dataSource!.scrubber(scrubber, viewForItemAt: 0)).compactMap { $0 as? NSTextField }.first!
    }
    static func render(_ view: NSView, name: String) throws {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill()
            view.displayIgnoringOpacity(view.bounds, in: context); NSGraphicsContext.restoreGraphicsState()
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/lyrics-typography/\(name).png"))
    }
    static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory); application.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let clipboard = NSPasteboard.general.changeCount
        let suite = "TouchBarEnhancer.LyricsTypographyTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults), app = LayoutApp.enhancedBar
        let legacy = try JSONDecoder().decode(LyricsComponentConfiguration.self, from: Data(#"{"fillWidth":{"mode":"Fixed","relative":12,"fixed":96}}"#.utf8))
        precondition(legacy.style == nil && legacy.resolvedStyle == LyricsComponentConfiguration.defaultStyle)
        let empty = try JSONDecoder().decode(LyricsComponentConfiguration.self, from: Data("{}".utf8))
        precondition(empty.resolvedStyle.alignment == .center && empty.resolvedStyle.truncation == .tail)
        let lineWidth = ComponentItemWidth(mode: .fixed, fixed: 96)
        let custom = TextComponentStyle(fontName: "Menlo-Regular", fontSize: 18, weight: .bold, italic: true,
            color: "#12ABEF", opacity: 0.5, tracking: 2, baselineOffset: 1, underline: true, strikethrough: true,
            alignment: .right, truncation: .middle, backgroundColor: "#363636")
        store.lyricsComponents[app.bundleID] = .init(fillWidth: lineWidth, style: custom)
        store.lyricsComponents["test.other-app"] = .init(style: .init(fontSize: 10))
        store.textComponents[app.bundleID] = [TextComponentItem(text: "Unchanged text", style: .init(fontSize: 12))]
        store.save()
        let provider = AppBar(app: app, persistsLayout: false)
        provider.configureLyrics(store.lyricsComponents[app.bundleID]!)
        provider.configureComponentPresentations(["lyrics": .init(alignment: .center, textWidth: .init(mode: .hug))])
        provider.configureLyricsDisplay(.init(text: "Swift 歌词 🧑‍💻", detail: "Fixture"))
        let secondBar = NSTouchBar(); secondBar.delegate = provider
        let views = [provider.bar, secondBar].map { ($0.item(forIdentifier: AppBar.itemID("lyrics")) as! NSCustomTouchBarItem).view }
        let scrubbers = views.map { descendants($0).compactMap { $0 as? NSScrubber }.first! }
        precondition(views[0] !== views[1])
        store.onChange = { provider.configureLyrics(store.lyricsComponents[app.bundleID] ?? .init()) }
        for scrubber in scrubbers {
            let attributes = label(scrubber).attributedStringValue.attributes(at: 0, effectiveRange: nil)
            precondition((attributes[.font] as! NSFont).pointSize == 18)
            precondition((attributes[.kern] as! Double) == 2 && (attributes[.baselineOffset] as! Double) == 1)
            precondition((attributes[.foregroundColor] as! NSColor).alphaComponent == 0.5)
        }
        let editor = LyricsComponentEditor(store: store, appBundleID: app.bundleID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        let document = NSView(); window.contentView = document
        editor.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(editor)
        NSLayoutConstraint.activate([editor.leadingAnchor.constraint(equalTo: document.leadingAnchor), editor.trailingAnchor.constraint(equalTo: document.trailingAnchor), editor.topAnchor.constraint(equalTo: document.topAnchor)])
        descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Lyrics" }!.performClick(nil)
        descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Advanced Typography" }!.performClick(nil)
        window.layoutIfNeeded()
        let typography = descendants(editor).compactMap { $0 as? TextStyleEditor }.first!
        func field(_ key: String) -> NSTextField {
            descendants(typography).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "lyrics.\(key)" }!
        }
        func edit(_ key: String, _ value: String) {
            let control = field(key); control.stringValue = value
            control.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: control))
        }
        for (key, invalid) in [("fontSize", "nan"), ("fontSize", "201"), ("opacity", "1.1"), ("tracking", "inf"), ("baselineOffset", "-101"), ("color", "invalid"), ("backgroundColor", "#oops")] {
            let before = store.lyricsComponents[app.bundleID]
            edit(key, invalid); precondition(store.lyricsComponents[app.bundleID] == before)
        }
        let size = field("fontSize")
        precondition(window.makeFirstResponder(size))
        let fieldEditor = size.currentEditor() as! NSTextView
        fieldEditor.selectAll(nil); fieldEditor.insertText("17", replacementRange: fieldEditor.selectedRange())
        precondition(window.firstResponder === fieldEditor && size.currentEditor() === fieldEditor)
        precondition(store.lyricsComponents[app.bundleID]?.resolvedStyle.fontSize == 17)
        window.endEditing(for: nil)
        let region = (views[0] as! TouchBarComponentView).content as! ScrollingComponentRegion
        let beforeTracking = region.requestedWidth!
        edit("tracking", "8"); precondition(region.requestedWidth! > beforeTracking)
        edit("color", "orange"); edit("backgroundColor", "blue")
        precondition(store.lyricsComponents[app.bundleID]?.resolvedStyle.color == "orange")
        let beforeClearingBackground = region.requestedWidth!
        edit("backgroundColor", ""); precondition(abs(region.requestedWidth! - beforeClearingBackground + 8) < 0.01)
        edit("backgroundColor", "#363636")
        let alignment = descendants(typography).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "lyrics.alignment" }!
        alignment.selectItem(withTitle: "Left"); precondition(alignment.sendAction(alignment.action, to: alignment.target))
        precondition(label(scrubbers[1]).alignment == .left)
        provider.configureLyricsDisplay(.init(text: "A new lyric line after a track change", detail: "Next fixture"))
        for scrubber in scrubbers {
            let current = label(scrubber)
            precondition(current.stringValue == "A new lyric line after a track change")
            precondition((current.attributedStringValue.attribute(.kern, at: 0, effectiveRange: nil) as! Double) == 8)
            precondition((current.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize == 17)
        }
        typography.reload()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            try render(editor, name: appearance.rawValue)
        }
        let keys = ["fontName", "fontSize", "weight", "italic", "color", "opacity", "tracking", "baselineOffset", "underline", "strikethrough", "alignment", "truncation", "backgroundColor"]
        let baseline = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LyricsComponentConfiguration.defaultStyle)) as! [String: NSObject]
        for key in keys {
            let before = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.lyricsComponents[app.bundleID]!.resolvedStyle)) as! [String: NSObject]
            let reset = descendants(typography).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "lyrics.default.\(key)" }!
            reset.performClick(nil)
            let after = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.lyricsComponents[app.bundleID]!.resolvedStyle)) as! [String: NSObject]
            var expected = before; expected[key] = baseline[key]
            precondition(after == expected, "Reset must affect only \(key)")
            let reloaded = SettingsStore(defaults: defaults)
            precondition(reloaded.lyricsComponents == store.lyricsComponents)
            precondition(reloaded.lyricsComponents[app.bundleID]?.fillWidth == lineWidth)
        }
        precondition(store.lyricsComponents[app.bundleID]?.style == nil)
        precondition(store.lyricsComponents["test.other-app"]?.resolvedStyle.fontSize == 10)
        precondition(store.textComponents[app.bundleID]![0].style.fontSize == 12)
        precondition(store.lyricsComponents["new-app"] == nil)
        for scrubber in scrubbers {
            let current = label(scrubber)
            let attributes = current.attributedStringValue.attributes(at: 0, effectiveRange: nil)
            precondition((attributes[.foregroundColor] as! NSColor) == .white && attributes[.kern] == nil)
            precondition(current.alignment == .center && current.lineBreakMode == .byTruncatingTail)
        }
        precondition(!window.isVisible && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        precondition(NSPasteboard.general.changeCount == clipboard)
        print("Lyrics typography checks passed: legacy defaults, shared native editor, validation, field-editor retention, live independent views and line changes, Hug/background measurement, individual resets, per-app persistence and no activation/media/network")
    }
}
