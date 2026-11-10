import AppKit

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
    @MainActor func attributedString(_ text: String) -> NSAttributedString {
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
        return NSAttributedString(string: text, attributes: attributes)
    }
}

struct TextComponentItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var text = "Text"
    var style = TextComponentStyle()
    static let initial = [TextComponentItem(id: UUID(uuidString: "E3C60628-B679-4844-9EAF-D95DE9763EAA")!)]
    var scrollingItem: ScrollingComponentItem {
        ScrollingComponentItem(title: text, symbol: "", background: style.backgroundColor.map { .color($0) } ?? .none, accessibilityLabel: text,
            toolTip: text, displayModeOverride: .iconAndText, textStyle: style)
    }
}

@MainActor
final class TextComponent {
    let scroller = ShortcutScroller(label: "Text")
    init(items: [TextComponentItem]) { configure(items) }
    func configure(_ items: [TextComponentItem]) { scroller.configure(items.map(\.scrollingItem)) }
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

/// Text is a peer component. The list holds content; the inspector holds styling.
@MainActor
final class TextComponentEditor: NSStackView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSFontChanging {
    private let store: SettingsStore
    private let appBundleID: String
    private let body = NSStackView()
    private let disclosure = NSButton()
    private let table = NSTableView()
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
        body.addArrangedSubview(options)
        let column = NSTableColumn(identifier: .init("text")); column.title = "Text"; column.width = 420
        table.addTableColumn(column); table.rowHeight = 32; table.style = .inset
        table.delegate = self; table.dataSource = self
        table.registerForDraggedTypes([Self.dragType]); table.setDraggingSourceOperationMask(.move, forLocal: true)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        body.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 126).isActive = true
        let actions = NSStackView(views: [NSButton(title: "Add Text", target: self, action: #selector(add)),
            NSButton(title: "Delete Text", target: self, action: #selector(remove))]); actions.spacing = 8
        body.addArrangedSubview(actions)
        inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing = 8
        body.addArrangedSubview(inspector); inspector.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
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
            control.setAccessibilityIdentifier("text.\(key)")
        }
        for (control, key) in [(italic, "italic"), (underline, "underline"), (strike, "strikethrough")] {
            control.identifier = .init(key); control.target = self; control.action = #selector(checkChanged(_:))
        }
        var rows: [[NSView]] = []
        func row(_ label: String, _ value: NSView, _ key: String) {
            let reset = NSButton(title: "Default", target: self, action: #selector(reset(_:)))
            reset.identifier = .init(key); reset.setAccessibilityIdentifier("text.default.\(key)")
            reset.toolTip = "Restore the system default for \(label.lowercased())."
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
        table.reloadData(); table.selectRowIndexes([0], byExtendingSelection: false); loadSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func field(_ key: String, placeholder: String) -> NSTextField {
        let field = NSTextField(); field.placeholderString = placeholder; field.identifier = .init(key)
        field.setAccessibilityIdentifier("text.\(key)"); field.delegate = self
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        fields[key] = field; return field
    }
    @objc private func toggle() { body.isHidden = disclosure.state != .on }
    @objc private func toggleTitle() { disclosure.state = disclosure.state == .on ? .off : .on; toggle() }
    @objc private func toggleAdvanced() { advanced.isHidden = advancedToggle.state != .on }
    @objc private func toggleAdvancedTitle() { advancedToggle.state = advancedToggle.state == .on ? .off : .on; toggleAdvanced() }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let field = ComponentInlineTextField(value: item.text, placeholder: "Text")
        field.setAccessibilityIdentifier("text.content.\(item.id)")
        field.onEdit = { [weak self] value in
            guard let self, let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index].text = value; self.store.save()
        }
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { loadSelection() }
    private func loadSelection() {
        loading = true; defer { loading = false }
        inspector.isHidden = selected == nil
        guard let index = selected else { return }
        let style = items[index].style
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
        guard !loading, let index = selected else { return }
        edit(&items[index].style); error.isHidden = true; store.save()
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
            case "fontName": style.fontName = nil
            case "fontSize": style.fontSize = nil
            case "weight": style.weight = nil
            case "italic": style.italic = nil
            case "color": style.color = nil
            case "opacity": style.opacity = nil
            case "tracking": style.tracking = nil
            case "baselineOffset": style.baselineOffset = nil
            case "underline": style.underline = nil
            case "strikethrough": style.strikethrough = nil
            case "alignment": style.alignment = nil
            case "truncation": style.truncation = nil
            case "backgroundColor": style.backgroundColor = nil
            default: break
            }
        }
        loadSelection()
    }
    @objc private func chooseFont() {
        guard let index = selected else { return }
        window?.makeFirstResponder(self)
        let manager = NSFontManager.shared
        manager.target = self; manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(items[index].style.font, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }
    func changeFont(_ sender: NSFontManager?) {
        guard let index = selected, window?.isKeyWindow == true, let sender else { return }
        let font = sender.convert(items[index].style.font)
        update { $0.fontName = font.fontName; $0.fontSize = Double(font.pointSize); $0.weight = nil; $0.italic = nil }
        loadSelection()
    }
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
