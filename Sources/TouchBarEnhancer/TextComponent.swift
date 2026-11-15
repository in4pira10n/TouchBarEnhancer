import AppKit
import os

/// The entire Text region, independently of its entries' Fill widths.
struct TextComponentWidth: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case automatic = "Auto", fixed = "Fixed", hug = "Hug" }
    var mode: Mode = .automatic
    var fixed: Double = 75
}

/// Nil is a genuine system default, not a copied numeric approximation.
struct TextComponentStyle: Codable, Equatable {
    enum Weight: String, Codable, CaseIterable {
        case ultraLight = "Ultra Light", thin = "Thin", light = "Light", regular = "Regular"
        case medium = "Medium", semibold = "Semibold", bold = "Bold", heavy = "Heavy", black = "Black"
        var value: NSFont.Weight {
            switch self {
            case .ultraLight: .ultraLight; case .thin: .thin; case .light: .light; case .regular: .regular
            case .medium: .medium; case .semibold: .semibold; case .bold: .bold; case .heavy: .heavy; case .black: .black
            }
        }
    }
    enum Truncation: String, Codable, CaseIterable {
        case clip = "Clip", head = "Truncate Head", middle = "Truncate Middle", tail = "Truncate Tail"
        var value: NSLineBreakMode {
            switch self { case .clip: .byClipping; case .head: .byTruncatingHead; case .middle: .byTruncatingMiddle; case .tail: .byTruncatingTail }
        }
    }
    var fontName: String?
    var fontSize: Double?
    var weight: Weight?
    var italic: Bool?
    var color: String?
    var opacity: Double?
    var tracking: Double?
    var baselineOffset: Double?
    var underline: Bool?
    var strikethrough: Bool?
    var alignment: ScrollingComponentAlignment?
    var truncation: Truncation?
    var backgroundColor: String?
    var horizontalPadding: CGFloat { backgroundColor == nil ? 0 : 4 }

    @MainActor var font: NSFont {
        let native = NSTextField(labelWithString: "").font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let size = CGFloat(fontSize ?? Double(native.pointSize))
        var font = fontName.flatMap { NSFont(name: $0, size: size) }
            ?? (fontSize == nil ? native : .systemFont(ofSize: size))
        if let weight {
            let descriptor = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.value.rawValue]])
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        if let italic {
            font = italic ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                : NSFontManager.shared.convert(font, toNotHaveTrait: .italicFontMask)
        }
        return font
    }
    @MainActor var textAlignment: NSTextAlignment {
        guard let alignment else { return NSTextField(labelWithString: "").alignment }
        switch alignment { case .left: return .left; case .center: return .center; case .right: return .right }
    }
    @MainActor var lineBreakMode: NSLineBreakMode {
        truncation?.value ?? NSTextField(labelWithString: "").lineBreakMode
    }
    @MainActor func attributedString(_ text: String, chineseSpacing: Bool = false) -> NSAttributedString {
        var foreground = color.flatMap(ChatColor.resolve) ?? .white
        if let opacity { foreground = foreground.withAlphaComponent(CGFloat(opacity)) }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: foreground]
        if let tracking { attributes[.kern] = tracking }
        if let baselineOffset { attributes[.baselineOffset] = baselineOffset }
        if let underline { attributes[.underlineStyle] = underline ? NSUnderlineStyle.single.rawValue : 0 }
        if let strikethrough { attributes[.strikethroughStyle] = strikethrough ? NSUnderlineStyle.single.rawValue : 0 }
        let paragraph = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        paragraph.alignment = textAlignment; paragraph.lineBreakMode = lineBreakMode
        attributes[.paragraphStyle] = paragraph
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        if chineseSpacing { ChineseLyricTypography.apply(to: result, fontSize: font.pointSize, tracking: tracking ?? 0) }
        return result
    }
}

/// EchoDiary's Pangu-style quarter-em gaps, expressed as native glyph spacing.
/// Characters, cache data and accessibility text remain exactly as supplied.
enum ChineseLyricTypography {
    private static let boundaries = try! NSRegularExpression(
        pattern: #"[\p{Han}\p{Hiragana}\p{Katakana}](?=[A-Za-z0-9])|[A-Za-z0-9](?=[\p{Han}\p{Hiragana}\p{Katakana}])"#)
    private static let urls = try! NSRegularExpression(pattern: #"(?:https?://|www\.)[^\s<>]+"#, options: .caseInsensitive)

    static func apply(to text: NSMutableAttributedString, fontSize: CGFloat, tracking: Double) {
        let range = NSRange(location: 0, length: text.length)
        let excluded = urls.matches(in: text.string, range: range).map(\.range)
        for match in boundaries.matches(in: text.string, range: range) {
            let pair = NSRange(location: match.range.location, length: match.range.length + 1)
            guard !excluded.contains(where: { NSIntersectionRange($0, pair).length > 0 }) else { continue }
            text.addAttribute(.kern, value: tracking + Double(fontSize) * 0.25, range: match.range)
        }
    }
}

struct TextComponentItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var text = "Text"
    var style = TextComponentStyle()
    var fillWidth: ComponentItemWidth?
    static let initial = [TextComponentItem(id: UUID(uuidString: "E3C60628-B679-4844-9EAF-D95DE9763EAA")!)]
    var scrollingItem: ScrollingComponentItem {
        ScrollingComponentItem(title: text, symbol: "", background: style.backgroundColor.map { .color($0) } ?? .none, accessibilityLabel: text,
            toolTip: text, displayModeOverride: .iconAndText, textStyle: style, fillWidth: fillWidth)
    }
}

@MainActor
final class TextComponent {
    let scroller = ShortcutScroller(label: "Text")
    private var width = TextComponentWidth()
    init(items: [TextComponentItem]) {
        scroller.onNaturalWidthChange = { [weak self] in self?.updateWidth() }
        configure(items)
    }
    func configure(_ items: [TextComponentItem], chineseSpacing: Bool = false) {
        scroller.configure(items.map {
            var item = $0.scrollingItem; item.chineseSpacing = chineseSpacing; return item
        })
    }
    func configurePresentation(_ presentation: ComponentPresentation) {
        width = presentation.textWidth ?? .init()
        scroller.configurePresentation(presentation)
        updateWidth()
    }
    private func updateWidth() {
        let requested: CGFloat?
        switch width.mode {
        case .automatic: requested = nil
        case .fixed: requested = max(1, CGFloat(ComponentItemWidth.valid(width.fixed) ? width.fixed : 75))
        case .hug:
            let scale = max(1, scroller.scrollRegion.window?.backingScaleFactor ?? 1)
            requested = max(1, ceil(scroller.naturalContentWidth * scale) / scale)
        }
        scroller.scrollRegion.requestedWidth = requested
    }
}

@MainActor
final class TextComponentWidthControl: NSStackView {
    private let store: SettingsStore
    private let appBundleID: String
    private let component: String
    private let mode: ComponentInlinePopup
    private let number: ComponentInlineTextField
    private let unit = NSTextField(labelWithString: "pt")

    init(store: SettingsStore, appBundleID: String, component: String = "text") {
        self.store = store; self.appBundleID = appBundleID; self.component = component
        let width = store.presentation(for: component, app: appBundleID).textWidth ?? .init()
        mode = ComponentInlinePopup(titles: TextComponentWidth.Mode.allCases.map(\.rawValue),
            selected: TextComponentWidth.Mode.allCases.firstIndex(of: width.mode)!)
        number = ComponentInlineTextField(value: width.fixed.formatted(.number.grouping(.never).locale(Locale(identifier: "en_US_POSIX"))), placeholder: "75")
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 6
        mode.setAccessibilityIdentifier("\(component)ComponentWidthMode")
        mode.setAccessibilityLabel("\(component.capitalized) component width")
        mode.toolTip = "Auto shares space with other components. Fixed uses points. Hug fits the content."
        number.setAccessibilityIdentifier("\(component)ComponentWidthValue")
        number.setAccessibilityLabel("\(component.capitalized) component width in points")
        number.widthAnchor.constraint(equalToConstant: 60).isActive = true
        unit.textColor = .secondaryLabelColor
        addArrangedSubview(mode); addArrangedSubview(number); addArrangedSubview(unit)
        number.isHidden = width.mode != .fixed; unit.isHidden = number.isHidden
        mode.onChange = { [weak self] index in
            guard let self else { return }
            var presentation = self.store.presentation(for: self.component, app: self.appBundleID)
            var width = presentation.textWidth ?? .init()
            width.mode = TextComponentWidth.Mode.allCases[index]
            self.number.isHidden = width.mode != .fixed; self.unit.isHidden = self.number.isHidden
            self.number.stringValue = width.fixed.formatted(.number.grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
            self.number.textColor = .labelColor
            presentation.textWidth = width
            self.store.setPresentation(presentation, for: self.component, app: self.appBundleID)
        }
        number.onEdit = { [weak self] text in
            guard let self else { return }
            guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), ComponentItemWidth.valid(value) else {
                self.number.textColor = .systemRed
                self.number.toolTip = "Enter a positive number up to 1,000,000."
                return
            }
            var presentation = self.store.presentation(for: self.component, app: self.appBundleID)
            var width = presentation.textWidth ?? .init()
            guard width.mode == .fixed else { return }
            width.fixed = value; presentation.textWidth = width
            self.number.textColor = .labelColor
            self.store.setPresentation(presentation, for: self.component, app: self.appBundleID)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Presentation preferences only; playback and fetching are owned by the shared backend.
struct LyricsComponentConfiguration: Codable, Equatable {
    var fillWidth: ComponentItemWidth?
    var style: TextComponentStyle?
    static let defaultStyle = TextComponentStyle(alignment: .center, truncation: .tail)
    var resolvedStyle: TextComponentStyle { style ?? Self.defaultStyle }
}

/// A lyrics-only hit surface. It occupies the allocated region without adding
/// an intrinsic width or changing the shared scroller's text measurement.
@MainActor
final class LyricsInteractionView: NSView {
    private let gestureLog = Logger(subsystem: "local.starfruit.TouchBarEnhancer", category: "LyricsTouch")
    var onSearch: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    private var origin: NSPoint?
    private var maximumTravel: CGFloat = 0
    private var cancelled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizingMask = [.width, .height]
        addGestureRecognizer(LyricsTouchRecognizer(target: nil, action: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Lyrics")
        setAccessibilityHelp("Open lyrics search. Swipe right to advance 5 seconds; left to rewind 5 seconds.")
    }
    required init?(coder: NSCoder) { nil }
    override func accessibilityPerformPress() -> Bool {
        guard window != nil, !isHiddenOrHasHiddenAncestor, let onSearch else { return false }
        onSearch(); return true
    }
    func begin(at point: NSPoint) {
        cancel()
        guard window != nil, !isHiddenOrHasHiddenAncestor, bounds.contains(point) else { return }
        origin = point; maximumTravel = 0; cancelled = false
    }
    func move(to point: NSPoint) {
        guard let origin else { return }
        maximumTravel = max(maximumTravel, hypot(point.x - origin.x, point.y - origin.y))
        // Keep a horizontal swipe when the finger leaves the narrow region at
        // either end. Leaving its vertical band cancels, as does a hidden view.
        if point.y < bounds.minY - 8 || point.y > bounds.maxY + 8 || isHiddenOrHasHiddenAncestor { cancelled = true }
    }
    func end(at point: NSPoint) {
        guard let origin else { gestureLog.notice("End without active origin"); return }
        move(to: point)
        let dx = point.x - origin.x, dy = point.y - origin.y
        let valid = !cancelled && window != nil && !isHiddenOrHasHiddenAncestor
        let travel = maximumTravel
        cancel()
        gestureLog.notice("Interaction ended: dx=\(dx, privacy: .public), dy=\(dy, privacy: .public), travel=\(travel, privacy: .public), valid=\(valid, privacy: .public)")
        guard valid else { return }
        if abs(dx) >= 20 && abs(dx) > abs(dy) * 2 { onSeek?(dx > 0 ? 5 : -5) }
        else if travel <= 8, bounds.contains(point) { onSearch?() }
    }
    func cancel() { origin = nil; cancelled = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); cancel() }
    override func viewDidHide() { super.viewDidHide(); cancel() }
    override func mouseDown(with event: NSEvent) { begin(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { move(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { end(at: convert(event.locationInWindow, from: nil)) }
}

/// Claim direct touches before NSScrubber can turn a swipe release into a tap
/// or scroll the current lyric out of view. Mouse events use the view fallback.
@MainActor
final class LyricsTouchRecognizer: NSGestureRecognizer {
    private let gestureLog = Logger(subsystem: "local.starfruit.TouchBarEnhancer", category: "LyricsTouch")
    private var identity: (any NSObjectProtocol)?
    private var surface: LyricsInteractionView? { view as? LyricsInteractionView }
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action); allowedTouchTypes = .direct
    }
    required init?(coder: NSCoder) { nil }
    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        let touches = event.touches(matching: .began, in: view).filter { $0.type == .direct }
        gestureLog.notice("Touches began: count=\(touches.count, privacy: .public), state=\(self.state.rawValue, privacy: .public), tracked=\(self.identity != nil, privacy: .public)")
        guard !touches.isEmpty else { return }
        guard identity == nil, touches.count == 1, let touch = touches.first,
              let surface, !surface.isHiddenOrHasHiddenAncestor,
              surface.bounds.contains(touch.location(in: surface)) else { cancelTouch(); return }
        identity = touch.identity; state = .began
        surface.begin(at: touch.location(in: surface))
    }
    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        if let touch = tracked(event, phase: .moved), let surface {
            state = .changed
            surface.move(to: touch.location(in: surface))
        }
    }
    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        gestureLog.notice("Touches ended: count=\(event.touches(matching: .ended, in: self.view).count, privacy: .public), state=\(self.state.rawValue, privacy: .public)")
        guard let touch = tracked(event, phase: .ended), let surface else { return }
        let point = touch.location(in: surface)
        state = .ended
        surface.end(at: point)
    }
    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        if tracked(event, phase: .cancelled) != nil { cancelTouch() }
    }
    private func tracked(_ event: NSEvent, phase: NSTouch.Phase) -> NSTouch? {
        guard let identity else { return nil }
        return event.touches(matching: phase, in: view).first { $0.type == .direct && identity.isEqual($0.identity) }
    }
    private func cancelTouch() {
        gestureLog.notice("Touch cancelled: state=\(self.state.rawValue, privacy: .public)")
        surface?.cancel(); state = state == .possible ? .failed : .cancelled
    }
    override func reset() {
        gestureLog.notice("Recognizer reset: state=\(self.state.rawValue, privacy: .public)")
        surface?.cancel(); identity = nil; super.reset()
    }
    override func canBePrevented(by preventingGestureRecognizer: NSGestureRecognizer) -> Bool { false }
}

@MainActor
final class LyricsComponent {
    static let placeholder = "No media playing"
    private let content: TextComponent
    private var configuration: LyricsComponentConfiguration
    private var display = LyricsDisplay()
    let interaction = LyricsInteractionView()
    var onSearch: (() -> Void)?
    var onSeek: ((TimeInterval) -> Void)?
    var scroller: ShortcutScroller { content.scroller }

    init(configuration: LyricsComponentConfiguration) {
        self.configuration = configuration
        content = TextComponent(items: [])
        scroller.scrubber.setAccessibilityLabel("Lyrics")
        interaction.frame = scroller.scrollRegion.bounds
        scroller.scrollRegion.addSubview(interaction, positioned: .above, relativeTo: nil)
        interaction.onSearch = { [weak self] in self?.onSearch?() }
        interaction.onSeek = { [weak self] in self?.onSeek?($0) }
        configure(configuration)
        configurePresentation(.init(alignment: .center))
    }

    func configure(_ configuration: LyricsComponentConfiguration) {
        self.configuration = configuration
        render()
    }

    func configureDisplay(_ display: LyricsDisplay) {
        guard self.display != display else { return }
        if self.display.detail != display.detail { interaction.cancel() }
        self.display = display; render()
    }

    private func render() {
        content.configure([TextComponentItem(
            id: UUID(uuidString: "FE191D66-BC0A-474B-9E8D-77803975F57C")!,
            text: display.text, style: configuration.resolvedStyle,
            fillWidth: configuration.fillWidth)], chineseSpacing: true)
        scroller.scrubber.toolTip = display.detail
        interaction.toolTip = "\(display.detail)\nTap to search lyrics · Swipe right +5s · Swipe left −5s"
    }

    func configurePresentation(_ presentation: ComponentPresentation) { content.configurePresentation(presentation) }
}

@MainActor
final class LyricsComponentEditor: NSStackView {
    private let store: SettingsStore
    private let disclosure = NSButton()
    private let body = NSStackView()

    init(store: SettingsStore, appBundleID: String) {
        self.store = store
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        setAccessibilityIdentifier("lyricsCategory")
        disclosure.setButtonType(.pushOnPushOff); disclosure.bezelStyle = .disclosure; disclosure.title = ""
        disclosure.target = self; disclosure.action = #selector(toggle)
        disclosure.setAccessibilityLabel("Expand Lyrics")
        let title = NSButton(title: "Lyrics", target: self, action: #selector(toggleTitle))
        title.isBordered = false; title.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [disclosure, title]); header.spacing = 4; header.alignment = .centerY
        addArrangedSubview(header)
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10; body.isHidden = true
        addArrangedSubview(body); body.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let options = ComponentPresentationControls(store: store, appBundleID: appBundleID, component: "lyrics", includesDisplay: false)
        options.addRow(with: [NSTextField(labelWithString: "Width:"),
            TextComponentWidthControl(store: store, appBundleID: appBundleID, component: "lyrics")])
        let itemWidth = ComponentItemWidthControl(value: store.lyricsComponents[appBundleID]?.fillWidth)
        itemWidth.setAccessibilityLabel("Lyric line width")
        itemWidth.onChange = { value in
            store.lyricsComponents[appBundleID, default: .init()].fillWidth = value
            store.save()
        }
        let widthRow = options.addRow(with: [NSTextField(labelWithString: "Line width:"), itemWidth])
        widthRow.isHidden = store.presentation(for: "lyrics", app: appBundleID).layout != .fill
        options.onLayoutChange = { [weak widthRow] layout in widthRow?.isHidden = layout != .fill }
        body.addArrangedSubview(options)
        let typography = TextStyleEditor(namespace: "lyrics", defaults: LyricsComponentConfiguration.defaultStyle,
            read: { store.lyricsComponents[appBundleID, default: .init()].resolvedStyle },
            write: { value in
                store.lyricsComponents[appBundleID, default: .init()].style = value == LyricsComponentConfiguration.defaultStyle ? nil : value
                store.save()
            })
        body.addArrangedSubview(typography)
        typography.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        let status = NSTextField(wrappingLabelWithString: "Timed lyrics from NetEase, QQ Music and LRCLIB. Searches only while this component is shown; results are cached locally.")
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize); status.textColor = .secondaryLabelColor
        body.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        body.addArrangedSubview(NSButton(title: "Search Lyrics & Sources…", target: self, action: #selector(openSearch)))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggle() { body.isHidden = disclosure.state != .on }
    @objc private func toggleTitle() { disclosure.state = disclosure.state == .on ? .off : .on; toggle() }
    @objc private func openSearch() { NotificationCenter.default.post(name: .openLyricsSettings, object: store) }
}

/// A native inline field keeps the same field editor while its value saves live.
@MainActor
final class ComponentInlineTextField: NSTextField, NSTextFieldDelegate {
    var onEdit: ((String) -> Void)?
    init(value: String, placeholder: String) {
        super.init(frame: .zero)
        stringValue = value; placeholderString = placeholder
        isBezeled = false; drawsBackground = false; isEditable = true; isSelectable = true
        lineBreakMode = .byTruncatingTail
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func controlTextDidChange(_ notification: Notification) { onEdit?(stringValue) }
}

/// Shared native typography editor for Text entries and the live Lyrics line.
@MainActor
final class TextStyleEditor: NSStackView, NSTextFieldDelegate, NSFontChanging {
    private let namespace: String
    private let defaults: TextComponentStyle
    private let readStyle: () -> TextComponentStyle?
    private let writeStyle: (TextComponentStyle) -> Void
    private let inspector = NSStackView()
    private let fontButton = NSButton(title: "Choose Font…", target: nil, action: nil)
    private let colorWell = NSColorWell()
    private let backgroundWell = NSColorWell()
    private let weight = NSPopUpButton()
    private let textAlignmentPopup = NSPopUpButton()
    private let truncation = NSPopUpButton()
    private let italic = NSButton(checkboxWithTitle: "Italic", target: nil, action: nil)
    private let underline = NSButton(checkboxWithTitle: "Underline", target: nil, action: nil)
    private let strike = NSButton(checkboxWithTitle: "Strikethrough", target: nil, action: nil)
    private var fields: [String: NSTextField] = [:]
    private var loading = false
    private let error = NSTextField(wrappingLabelWithString: "")
    private let advanced = NSStackView()
    private let advancedToggle = NSButton()

    init(namespace: String, defaults: TextComponentStyle = .init(),
         read: @escaping () -> TextComponentStyle?, write: @escaping (TextComponentStyle) -> Void) {
        self.namespace = namespace; self.defaults = defaults; readStyle = read; writeStyle = write
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        setAccessibilityIdentifier("\(namespace)StyleEditor")
        inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing = 8
        addArrangedSubview(inspector); inspector.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        fontButton.target = self; fontButton.action = #selector(chooseFont)
        colorWell.target = self; colorWell.action = #selector(colorChanged)
        colorWell.widthAnchor.constraint(equalToConstant: 40).isActive = true
        backgroundWell.target = self; backgroundWell.action = #selector(backgroundChanged)
        backgroundWell.widthAnchor.constraint(equalToConstant: 40).isActive = true
        weight.addItems(withTitles: ["System Default"] + TextComponentStyle.Weight.allCases.map(\.rawValue))
        textAlignmentPopup.addItems(withTitles: ["System Default"] + ScrollingComponentAlignment.allCases.map(\.rawValue))
        truncation.addItems(withTitles: ["System Default"] + TextComponentStyle.Truncation.allCases.map(\.rawValue))
        for (control, key) in [(weight, "weight"), (textAlignmentPopup, "alignment"), (truncation, "truncation")] {
            control.identifier = .init(key); control.target = self; control.action = #selector(popupChanged(_:))
            control.setAccessibilityIdentifier("\(namespace).\(key)")
        }
        for (control, key) in [(italic, "italic"), (underline, "underline"), (strike, "strikethrough")] {
            control.identifier = .init(key); control.target = self; control.action = #selector(checkChanged(_:))
        }
        var rows: [[NSView]] = []
        func row(_ label: String, _ value: NSView, _ key: String) {
            let reset = NSButton(title: "Default", target: self, action: #selector(reset(_:)))
            reset.identifier = .init(key); reset.setAccessibilityIdentifier("\(namespace).default.\(key)")
            reset.toolTip = "Restore the default for \(label.lowercased())."
            rows.append([NSTextField(labelWithString: "\(label):"), value, reset])
        }
        row("Font", fontButton, "fontName")
        row("Size", field("fontSize", placeholder: "System Default"), "fontSize")
        let color = NSStackView(views: [field("color", placeholder: "System Default"), colorWell]); color.spacing = 6
        row("Color", color, "color")
        fields["color"]?.placeholderString = "Default (White)"
        let background = NSStackView(views: [field("backgroundColor", placeholder: "None"), backgroundWell]); background.spacing = 6
        row("Background", background, "backgroundColor")
        row("Text alignment", textAlignmentPopup, "alignment")
        let basicRows = rows
        rows.removeAll()
        row("Weight", weight, "weight")
        row("Style", italic, "italic")
        row("Opacity", field("opacity", placeholder: "System Default (0–1)"), "opacity")
        row("Tracking", field("tracking", placeholder: "System Default (pt)"), "tracking")
        row("Baseline", field("baselineOffset", placeholder: "System Default (pt)"), "baselineOffset")
        row("Underline", underline, "underline")
        row("Strikethrough", strike, "strikethrough")
        row("Overflow", truncation, "truncation")
        func makeGrid(_ rows: [[NSView]]) -> NSGridView {
            let grid = NSGridView(views: rows)
            grid.column(at: 0).xPlacement = .trailing; grid.column(at: 0).width = ComponentPresentationControls.labelWidth
            grid.column(at: 1).xPlacement = .fill; grid.column(at: 2).xPlacement = .trailing
            grid.rowAlignment = .firstBaseline; grid.yPlacement = .center; grid.rowSpacing = 8; grid.columnSpacing = 10
            for control in [fontButton, weight, textAlignmentPopup, truncation, italic, underline, strike] as [NSView] {
                grid.cell(for: control)?.xPlacement = .leading
            }
            return grid
        }
        let grid = makeGrid(basicRows)
        inspector.addArrangedSubview(grid); grid.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
        advancedToggle.setButtonType(.pushOnPushOff); advancedToggle.bezelStyle = .disclosure; advancedToggle.title = ""
        advancedToggle.target = self; advancedToggle.action = #selector(toggleAdvanced)
        advancedToggle.setAccessibilityLabel("Expand Advanced Typography")
        let advancedTitle = NSButton(title: "Advanced Typography", target: self, action: #selector(toggleAdvancedTitle))
        advancedTitle.isBordered = false
        let advancedHeader = NSStackView(views: [advancedToggle, advancedTitle]); advancedHeader.spacing = 4
        inspector.addArrangedSubview(advancedHeader)
        advanced.orientation = .vertical; advanced.alignment = .leading; advanced.isHidden = true
        inspector.addArrangedSubview(advanced); advanced.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
        let advancedGrid = makeGrid(rows)
        advanced.addArrangedSubview(advancedGrid); advancedGrid.widthAnchor.constraint(equalTo: advanced.widthAnchor).isActive = true
        error.textColor = .systemRed; error.font = .systemFont(ofSize: NSFont.smallSystemFontSize); error.isHidden = true
        inspector.addArrangedSubview(error)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func field(_ key: String, placeholder: String) -> NSTextField {
        let field = NSTextField(); field.placeholderString = placeholder; field.identifier = .init(key)
        field.setAccessibilityIdentifier("\(namespace).\(key)"); field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fields[key] = field; return field
    }
    @objc private func toggleAdvanced() { advanced.isHidden = advancedToggle.state != .on }
    @objc private func toggleAdvancedTitle() { advancedToggle.state = advancedToggle.state == .on ? .off : .on; toggleAdvanced() }
    func reload() {
        loading = true; defer { loading = false }
        isHidden = readStyle() == nil
        guard let style = readStyle() else { return }
        fontButton.title = style.fontName.flatMap { NSFont(name: $0, size: 0)?.displayName } ?? "System Default…"
        fields["fontSize"]?.stringValue = style.fontSize.map { String($0) } ?? ""
        fields["color"]?.stringValue = style.color ?? ""
        fields["backgroundColor"]?.stringValue = style.backgroundColor ?? ""
        fields["opacity"]?.stringValue = style.opacity.map { String($0) } ?? ""
        fields["tracking"]?.stringValue = style.tracking.map { String($0) } ?? ""
        fields["baselineOffset"]?.stringValue = style.baselineOffset.map { String($0) } ?? ""
        weight.selectItem(withTitle: style.weight?.rawValue ?? "System Default")
        textAlignmentPopup.selectItem(withTitle: style.alignment?.rawValue ?? "System Default")
        truncation.selectItem(withTitle: style.truncation?.rawValue ?? "System Default")
        italic.state = style.italic == true ? .on : .off; underline.state = style.underline == true ? .on : .off
        strike.state = style.strikethrough == true ? .on : .off
        colorWell.color = style.color.flatMap(ChatColor.resolve) ?? .white
        backgroundWell.color = style.backgroundColor.flatMap(ChatColor.resolve) ?? .clear
        error.isHidden = true
    }
    private func update(_ edit: (inout TextComponentStyle) -> Void) {
        guard !loading, var style = readStyle() else { return }
        edit(&style); error.isHidden = true; writeStyle(style)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let key = field.identifier?.rawValue else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key == "color" || key == "backgroundColor" {
            guard value.isEmpty || ChatColor.resolve(value) != nil else { invalid("Use a system color name or six-digit hex color."); return }
            update { style in
                if key == "color" { style.color = value.isEmpty ? nil : value }
                else { style.backgroundColor = value.isEmpty ? nil : value }
            }
            if key == "color" { colorWell.color = value.isEmpty ? .white : ChatColor.resolve(value)! }
            else { backgroundWell.color = value.isEmpty ? .clear : ChatColor.resolve(value)! }
            return
        }
        let number = value.isEmpty ? nil : Double(value)
        let range: ClosedRange<Double> = switch key {
        case "fontSize": 1...200
        case "opacity": 0...1
        default: -100...100
        }
        guard value.isEmpty || (number.map { $0.isFinite && range.contains($0) } ?? false) else {
            invalid("Enter a value from \(range.lowerBound) to \(range.upperBound), or leave blank for default."); return
        }
        update { style in
            switch key {
            case "fontSize": style.fontSize = number
            case "opacity": style.opacity = number
            case "tracking": style.tracking = number
            case "baselineOffset": style.baselineOffset = number
            default: break
            }
        }
    }
    private func invalid(_ message: String) { error.stringValue = message; error.isHidden = false }
    @objc private func popupChanged(_ sender: NSPopUpButton) {
        update { style in
            switch sender.identifier?.rawValue {
            case "weight": style.weight = sender.titleOfSelectedItem.flatMap(TextComponentStyle.Weight.init(rawValue:))
            case "alignment": style.alignment = sender.titleOfSelectedItem.flatMap(ScrollingComponentAlignment.init(rawValue:))
            default: style.truncation = sender.titleOfSelectedItem.flatMap(TextComponentStyle.Truncation.init(rawValue:))
            }
        }
    }
    @objc private func checkChanged(_ sender: NSButton) {
        update { style in
            switch sender.identifier?.rawValue {
            case "italic": style.italic = sender.state == .on
            case "underline": style.underline = sender.state == .on
            default: style.strikethrough = sender.state == .on
            }
        }
    }
    @objc private func colorChanged() {
        fields["color"]?.stringValue = ChatColor.hex(colorWell.color)
        update { $0.color = ChatColor.hex(colorWell.color) }
    }
    @objc private func backgroundChanged() {
        fields["backgroundColor"]?.stringValue = ChatColor.hex(backgroundWell.color)
        update { $0.backgroundColor = ChatColor.hex(backgroundWell.color) }
    }
    @objc private func reset(_ sender: NSButton) {
        update { style in
            switch sender.identifier?.rawValue {
            case "fontName": style.fontName = defaults.fontName
            case "fontSize": style.fontSize = defaults.fontSize
            case "weight": style.weight = defaults.weight
            case "italic": style.italic = defaults.italic
            case "color": style.color = defaults.color
            case "opacity": style.opacity = defaults.opacity
            case "tracking": style.tracking = defaults.tracking
            case "baselineOffset": style.baselineOffset = defaults.baselineOffset
            case "underline": style.underline = defaults.underline
            case "strikethrough": style.strikethrough = defaults.strikethrough
            case "alignment": style.alignment = defaults.alignment
            case "truncation": style.truncation = defaults.truncation
            case "backgroundColor": style.backgroundColor = defaults.backgroundColor
            default: break
            }
        }
        reload()
    }
    @objc private func chooseFont() {
        guard let style = readStyle() else { return }
        window?.makeFirstResponder(self)
        let manager = NSFontManager.shared
        manager.target = self; manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(style.font, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }
    func changeFont(_ sender: NSFontManager?) {
        guard let style = readStyle(), !isHiddenOrHasHiddenAncestor, window?.isVisible == true,
              let sender, sender.target as? TextStyleEditor === self else { return }
        let font = sender.convert(style.font)
        update { $0.fontName = font.fontName; $0.fontSize = Double(font.pointSize); $0.weight = nil; $0.italic = nil }
        reload()
    }
}

/// Text is a peer component. The list holds content; the shared inspector holds styling.
@MainActor
final class TextComponentEditor: NSStackView, NSTableViewDataSource, NSTableViewDelegate {
    private let store: SettingsStore
    private let appBundleID: String
    private let body = NSStackView()
    private let disclosure = NSButton()
    private let table = NSTableView()
    private var styleEditor: TextStyleEditor!
    private static let dragType = NSPasteboard.PasteboardType("local.starfruit.TouchBarEnhancer.text-row")
    private var items: [TextComponentItem] {
        get { store.textComponents[appBundleID] ?? TextComponentItem.initial }
        set { store.textComponents[appBundleID] = newValue }
    }
    private var selected: Int? { items.indices.contains(table.selectedRow) ? table.selectedRow : nil }

    init(store: SettingsStore, appBundleID: String) {
        self.store = store; self.appBundleID = appBundleID
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        setAccessibilityIdentifier("textCategory")
        disclosure.setButtonType(.pushOnPushOff); disclosure.bezelStyle = .disclosure; disclosure.title = ""
        disclosure.target = self; disclosure.action = #selector(toggle)
        disclosure.setAccessibilityLabel("Expand Text")
        let title = NSButton(title: "Text", target: self, action: #selector(toggleTitle))
        title.isBordered = false; title.font = .systemFont(ofSize: 13, weight: .semibold)
        let header = NSStackView(views: [disclosure, title]); header.spacing = 4
        addArrangedSubview(header)
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10; body.isHidden = true
        addArrangedSubview(body); body.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let options = ComponentPresentationControls(store: store, appBundleID: appBundleID, component: "text", includesDisplay: false)
        options.addRow(with: [NSTextField(labelWithString: "Width:"), TextComponentWidthControl(store: store, appBundleID: appBundleID)])
        body.addArrangedSubview(options)
        let column = NSTableColumn(identifier: .init("text")); column.title = "Text"; column.width = 420
        column.minWidth = 150
        table.addTableColumn(column); table.rowHeight = 32; table.style = .inset
        let widthColumn = NSTableColumn(identifier: .init("width")); widthColumn.title = "Width"
        widthColumn.width = 195; widthColumn.minWidth = 185
        widthColumn.isHidden = store.presentation(for: "text", app: appBundleID).layout != .fill
        table.addTableColumn(widthColumn)
        options.onLayoutChange = { [weak widthColumn] layout in widthColumn?.isHidden = layout != .fill }
        table.delegate = self; table.dataSource = self
        table.registerForDraggedTypes([Self.dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder
        body.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 126).isActive = true
        let actions = NSStackView(views: [NSButton(title: "Add Text", target: self, action: #selector(add)),
            NSButton(title: "Delete Text", target: self, action: #selector(remove))]); actions.spacing = 8
        body.addArrangedSubview(actions)
        styleEditor = TextStyleEditor(namespace: "text", read: { [weak self] in
            guard let self, let index = self.selected else { return nil }
            return self.items[index].style
        }, write: { [weak self] value in
            guard let self, let index = self.selected else { return }
            self.items[index].style = value; self.store.save()
        })
        body.addArrangedSubview(styleEditor)
        styleEditor.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        table.reloadData(); table.selectRowIndexes([0], byExtendingSelection: false); loadSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggle() { body.isHidden = disclosure.state != .on }
    @objc private func toggleTitle() { disclosure.state = disclosure.state == .on ? .off : .on; toggle() }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        if tableColumn?.identifier.rawValue == "width" {
            let control = ComponentItemWidthControl(value: item.fillWidth)
            control.onChange = { [weak self] width in
                guard let self, let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                self.items[index].fillWidth = width; self.store.save()
            }
            return control
        }
        let field = ComponentInlineTextField(value: item.text, placeholder: "Text")
        field.setAccessibilityIdentifier("text.content.\(item.id)")
        field.onEdit = { [weak self] value in
            guard let self, let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index].text = value; self.store.save()
        }
        let cell = NSView()
        field.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(field)
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { loadSelection() }
    private func loadSelection() { styleEditor?.reload() }
    @objc private func add() {
        items.append(TextComponentItem()); store.save(); table.reloadData()
        table.selectRowIndexes([items.count - 1], byExtendingSelection: false); loadSelection()
    }
    @objc private func remove() {
        guard let index = selected else { return }
        items.remove(at: index); store.save(); table.reloadData()
        if !items.isEmpty { table.selectRowIndexes([min(index, items.count - 1)], byExtendingSelection: false) }
        loadSelection()
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard items.indices.contains(row) else { return nil }
        let data = NSPasteboardItem(); data.setString(items[row].id.uuidString, forType: Self.dragType); return data
    }
    private func source(_ info: any NSDraggingInfo) -> Int? {
        guard info.draggingSource as? NSTableView === table,
              let id = info.draggingPasteboard.string(forType: Self.dragType) else { return nil }
        return items.firstIndex { $0.id.uuidString == id }
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard (0...items.count).contains(row), let source = source(info), row != source, row != source + 1 else { return [] }
        table.setDropRow(row, dropOperation: .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard dropOperation == .above, (0...items.count).contains(row), let source = source(info) else { return false }
        let destination = row > source ? row - 1 : row; guard destination != source else { return false }
        let item = items.remove(at: source); items.insert(item, at: destination); store.save(); table.reloadData()
        table.selectRowIndexes([destination], byExtendingSelection: false); loadSelection(); return true
    }
}
