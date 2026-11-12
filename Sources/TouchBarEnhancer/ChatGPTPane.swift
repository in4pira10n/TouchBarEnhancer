import AppKit
import UniformTypeIdentifiers

@MainActor
final class ComponentInlinePopup: NSPopUpButton {
    var onChange: ((Int) -> Void)?
    init(titles: [String], selected: Int) {
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles); selectItem(at: selected)
        target = self; action = #selector(changed)
        controlSize = .small
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { onChange?(indexOfSelectedItem) }
}

/// Shared native cell editor; saves valid values without replacing its field editor.
@MainActor
final class ComponentItemWidthControl: NSStackView {
    private var value: ComponentItemWidth
    private let mode: ComponentInlinePopup
    private let number: ComponentInlineTextField
    private let unit = NSTextField(labelWithString: "")
    var onChange: ((ComponentItemWidth) -> Void)?

    init(value: ComponentItemWidth?) {
        self.value = value ?? .init()
        mode = ComponentInlinePopup(titles: ComponentItemWidth.Mode.allCases.map(\.rawValue),
            selected: ComponentItemWidth.Mode.allCases.firstIndex(of: self.value.mode)!)
        number = ComponentInlineTextField(value: "", placeholder: "12")
        super.init(frame: .zero)
        orientation = .horizontal; alignment = .centerY; spacing = 6
        mode.setAccessibilityIdentifier("itemWidthMode")
        mode.setAccessibilityLabel("Button width mode")
        number.setAccessibilityIdentifier("itemWidthValue")
        number.controlSize = .small
        number.widthAnchor.constraint(equalToConstant: 60).isActive = true
        unit.font = .systemFont(ofSize: NSFont.smallSystemFontSize); unit.textColor = .secondaryLabelColor
        addArrangedSubview(mode); addArrangedSubview(number); addArrangedSubview(unit)
        mode.onChange = { [weak self] index in
            guard let self else { return }
            self.value.mode = ComponentItemWidth.Mode.allCases[index]
            self.refresh(); self.onChange?(self.value)
        }
        number.onEdit = { [weak self] text in self?.editNumber(text) }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func refresh() {
        number.isHidden = value.mode == .hug; unit.isHidden = value.mode == .hug
        let scalar = value.mode == .fixed ? value.fixed : value.relative
        number.stringValue = scalar.formatted(.number.grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
        number.textColor = .labelColor
        number.setAccessibilityLabel(value.mode == .fixed ? "Width in points" : "Relative width weight")
        number.toolTip = value.mode == .fixed ? "Width in points." : "Proportional weight; 6, 6, 12 gives 1:1:2."
        unit.stringValue = value.mode == .fixed ? "pt" : ""
    }
    private func editNumber(_ text: String) {
        guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), ComponentItemWidth.valid(number) else {
            self.number.textColor = .systemRed
            self.number.toolTip = "Enter a positive number up to 1,000,000."
            return
        }
        guard value.mode != .hug else { return }
        if value.mode == .fixed { value.fixed = number } else { value.relative = number }
        self.number.textColor = .labelColor
        onChange?(value)
    }
}

/// Shared native options for every component with a list of entries.
@MainActor
final class ComponentPresentationControls: NSGridView {
    var onLayoutChange: ((ComponentLayout) -> Void)?
    static var labelWidth: CGFloat { NSTextField(labelWithString: "Text alignment:").fittingSize.width }
    private let store: SettingsStore
    private let appBundleID: String
    private let component: String
    private let layoutPopup = NSPopUpButton()
    private let alignmentPopup = NSPopUpButton()
    private var alignmentRow: NSGridRow?
    private let display = NSSegmentedControl(labels: ComponentDisplayMode.allCases.map(\.rawValue),
        trackingMode: .selectOne, target: nil, action: nil)

    init(store: SettingsStore, appBundleID: String, component: String, includesDisplay: Bool = true) {
        self.store = store; self.appBundleID = appBundleID; self.component = component
        super.init(frame: .zero)
        let presentation = store.presentation(for: component, app: appBundleID)
        if includesDisplay {
            display.selectedSegment = ComponentDisplayMode.allCases.firstIndex(of:
                store.componentDisplayModes[appBundleID]?[component] ?? .iconAndText)!
            display.target = self; display.action = #selector(changeDisplay)
            display.setAccessibilityIdentifier("componentDisplayMode.\(component)")
            display.setAccessibilityLabel("Component display")
            addRow(with: [NSTextField(labelWithString: "Display:"), display])
        }
        layoutPopup.addItems(withTitles: ComponentLayout.allCases.map(\.rawValue))
        layoutPopup.selectItem(withTitle: presentation.layout.rawValue)
        layoutPopup.target = self; layoutPopup.action = #selector(changePresentation)
        layoutPopup.setAccessibilityIdentifier(component == "keyboard" ? "keyboardLayout" : "componentLayout.\(component)")
        addRow(with: [NSTextField(labelWithString: "Layout:"), layoutPopup])
        alignmentPopup.addItems(withTitles: ScrollingComponentAlignment.allCases.map(\.rawValue))
        alignmentPopup.selectItem(withTitle: presentation.alignment.rawValue)
        alignmentPopup.target = self; alignmentPopup.action = #selector(changePresentation)
        alignmentPopup.setAccessibilityIdentifier(component == "keyboard" ? "keyboardAlignment" : "componentAlignment.\(component)")
        alignmentRow = addRow(with: [NSTextField(labelWithString: "Alignment:"), alignmentPopup])
        alignmentRow?.isHidden = presentation.layout == .fill
        column(at: 0).xPlacement = .trailing
        column(at: 0).width = Self.labelWidth
        column(at: 1).xPlacement = .leading
        rowSpacing = 8; columnSpacing = 10; rowAlignment = .firstBaseline; yPlacement = .center
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changeDisplay() {
        guard ComponentDisplayMode.allCases.indices.contains(display.selectedSegment) else { return }
        store.componentDisplayModes[appBundleID, default: [:]][component] = ComponentDisplayMode.allCases[display.selectedSegment]
        store.save()
    }
    @objc private func changePresentation() {
        guard let layout = layoutPopup.titleOfSelectedItem.flatMap(ComponentLayout.init(rawValue:)),
              let alignment = alignmentPopup.titleOfSelectedItem.flatMap(ScrollingComponentAlignment.init(rawValue:)) else { return }
        alignmentRow?.isHidden = layout == .fill
        var presentation = store.presentation(for: component, app: appBundleID)
        presentation.layout = layout; presentation.alignment = alignment
        store.setPresentation(presentation, for: component, app: appBundleID)
        onLayoutChange?(layout)
    }
}

@MainActor
final class ChatGPTPane: NSStackView {
    private let store: SettingsStore
    private let readConnection: () -> ChatGPTAdapter.Snapshot
    private let enabled = NSButton(checkboxWithTitle: "Use ChatGPT controls", target: nil, action: nil)
    private let connection = NSTextField(wrappingLabelWithString: "")

    init(store: SettingsStore, app: LayoutApp, connectionReader: (() -> ChatGPTAdapter.Snapshot)? = nil) {
        self.store = store
        let adapter = ChatGPTAdapter(bundleID: app.bundleID)
        readConnection = connectionReader ?? { adapter.snapshot() }
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 12
        setAccessibilityIdentifier("chatGPTAdapterPane")
        enabled.state = store.chatGPTControlsEnabled ? .on : .off
        enabled.target = self; enabled.action = #selector(toggleControls)
        enabled.setAccessibilityIdentifier("chatGPTControlsEnabled")
        addArrangedSubview(enabled)
        for kind in [ShortcutCategoryEditor.Kind.chats, .phrases] {
            let editor = ShortcutCategoryEditor(store: store, kind: kind, appBundleID: app.bundleID)
            addArrangedSubview(editor)
            editor.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        let keyboard = ShortcutCategoryEditor(store: store, kind: .keyboard, appBundleID: app.bundleID)
        addArrangedSubview(keyboard)
        keyboard.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let separator = NSBox(); separator.boxType = .separator
        addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        connection.font = .systemFont(ofSize: 11)
        connection.textColor = .secondaryLabelColor
        connection.setAccessibilityIdentifier("chatGPTConnection")
        addArrangedSubview(connection)
        connection.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let check = NSButton(title: "Check Connection", target: self, action: #selector(checkConnection))
        let access = NSButton(title: "Accessibility Settings…", target: self, action: #selector(openAccessibility))
        let buttons = NSStackView(views: [check, access]); buttons.spacing = 8; buttons.alignment = .centerY
        addArrangedSubview(buttons)
        checkConnection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggleControls() { store.chatGPTControlsEnabled = enabled.state == .on; store.save() }
    @objc private func checkConnection() { connection.stringValue = readConnection().summary }
    @objc private func openAccessibility() { ChatGPTAdapter.openAccessibilitySettings() }
}

/// Shared editing, reordering and image handling for configurable button categories.
@MainActor
final class ShortcutCategoryEditor: NSStackView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    enum Kind {
        case chats, phrases, keyboard
        var title: String {
            switch self { case .chats: "Chat Shortcuts"; case .phrases: "Quick Phrases"; case .keyboard: "Keyboard Shortcuts" }
        }
        var singular: String {
            switch self { case .chats: "Chat"; case .phrases: "Phrase"; case .keyboard: "Button" }
        }
        var componentKey: String {
            switch self { case .chats: "chatgpt.chats"; case .phrases: "phrases"; case .keyboard: "keyboard" }
        }
    }
    let kind: Kind
    private static let rowDragType = NSPasteboard.PasteboardType("local.starfruit.TouchBarEnhancer.shortcut-row")
    private let store: SettingsStore
    private let appBundleID: String
    private var phrases: [QuickPhrase] {
        get { store.quickPhrasesByApp[appBundleID] ?? [] }
        set { store.quickPhrasesByApp[appBundleID] = newValue }
    }
    private var keyboardConfiguration: KeyboardButtonsConfiguration {
        get { store.keyboardButtons[appBundleID] ?? .init() }
        set { store.keyboardButtons[appBundleID] = newValue }
    }
    private let disclosure = NSButton()
    private let body = NSStackView()
    private let table = NSTableView()
    private let symbolField = NSTextField()
    private let colorField = NSTextField()
    private let colorWell = NSColorWell()
    private let descriptionField = NSTextField()
    private let phraseText = NSTextView()
    private let error = NSTextField(wrappingLabelWithString: "")
    private let imageLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton()
    private let form = NSStackView()
    private var errorRow: NSGridRow?
    private var imageData: Data?
    private var loading = false
    private var labelColumnWidth: CGFloat {
        ComponentPresentationControls.labelWidth
    }
    private var count: Int {
        switch kind { case .chats: store.chatShortcuts.count; case .phrases: phrases.count; case .keyboard: keyboardConfiguration.buttons.count }
    }

    init(store: SettingsStore, kind: Kind, appBundleID: String = LayoutApp.chatGPTBundleID) {
        self.store = store; self.kind = kind; self.appBundleID = appBundleID
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        setAccessibilityIdentifier(kind == .chats ? "chatShortcutsCategory" : (kind == .phrases ? "quickPhrasesCategory" : "keyboardShortcutsCategory"))
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        disclosure.state = kind == .chats ? .on : .off
        disclosure.target = self; disclosure.action = #selector(toggleExpanded)
        disclosure.setAccessibilityLabel("Expand \(kind.title)")
        let title = NSButton(title: kind.title, target: self, action: #selector(toggleFromTitle))
        title.isBordered = false; title.font = .systemFont(ofSize: 13, weight: .semibold)
        let row = NSStackView(views: [disclosure, title]); row.spacing = 4; row.alignment = .centerY
        addArrangedSubview(row)
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        body.isHidden = disclosure.state != .on
        addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        let options = ComponentPresentationControls(store: store, appBundleID: appBundleID, component: kind.componentKey)
        options.column(at: 0).width = labelColumnWidth
        body.addArrangedSubview(options)
        options.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        let column = NSTableColumn(identifier: .init("title")); column.title = "Title"; column.width = 180; column.minWidth = 100
        table.addTableColumn(column)
        if kind != .phrases {
            let shortcut = NSTableColumn(identifier: .init("shortcut")); shortcut.title = "Shortcut"
            shortcut.width = 110; shortcut.minWidth = 90
            table.addTableColumn(shortcut)
        }
        let displayColumn = NSTableColumn(identifier: .init("display")); displayColumn.title = "Display"
        displayColumn.width = 170; displayColumn.minWidth = 160; table.addTableColumn(displayColumn)
        let widthColumn = NSTableColumn(identifier: .init("width")); widthColumn.title = "Width"
        widthColumn.width = 195; widthColumn.minWidth = 185
        widthColumn.isHidden = store.presentation(for: kind.componentKey, app: appBundleID).layout != .fill
        table.addTableColumn(widthColumn)
        options.onLayoutChange = { [weak widthColumn] layout in widthColumn?.isHidden = layout != .fill }
        table.rowHeight = 32; table.style = .inset
        table.allowsEmptySelection = true
        table.dataSource = self; table.delegate = self
        table.toolTip = "Drag to reorder."
        if kind == .chats { table.toolTip = "Drag to reorder. Shortcuts use ChatGPT’s Control + 1–9 slots." }
        table.registerForDraggedTypes([Self.rowDragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        body.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 126).isActive = true
        let add = NSButton(title: "Add \(kind.singular)", target: self, action: #selector(addItem))
        deleteButton.title = "Delete \(kind.singular)"; deleteButton.target = self; deleteButton.action = #selector(deleteItem)
        let buttons = NSStackView(views: [add, deleteButton]); buttons.spacing = 8; buttons.alignment = .centerY
        body.addArrangedSubview(buttons)
        form.orientation = .vertical; form.alignment = .leading; form.spacing = 10
        body.addArrangedSubview(form)
        form.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        symbolField.placeholderString = kind == .chats ? "bubble.left" : (kind == .phrases ? "text.bubble" : "keyboard")
        colorField.placeholderString = kind == .keyboard ? "Default" : "blue or #0088FF"
        descriptionField.placeholderString = "Optional description"
        for field in [symbolField, colorField, descriptionField] {
            field.delegate = self
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        colorWell.target = self; colorWell.action = #selector(pickColor)
        colorWell.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let colors = NSStackView(views: [colorField, colorWell]); colors.spacing = 6; colors.alignment = .centerY
        if kind == .keyboard {
            colors.addArrangedSubview(NSButton(title: "Default", target: self, action: #selector(clearColor)))
        }
        var rows: [[NSView]] = [[NSTextField(labelWithString: "SF Symbol:"), symbolField]]
        if kind != .phrases {
            rows.append([NSTextField(labelWithString: "Background:"), colors])
        }
        let choose = NSButton(title: "Choose Image…", target: self, action: #selector(chooseImage))
        let clear = NSButton(title: "Use SF Symbol", target: self, action: #selector(clearImage))
        imageLabel.isHidden = true
        imageLabel.font = .systemFont(ofSize: 11); imageLabel.textColor = .secondaryLabelColor
        imageLabel.lineBreakMode = .byTruncatingMiddle
        imageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let images = NSStackView(views: [choose, clear, imageLabel]); images.spacing = 8; images.alignment = .centerY
        rows.append([NSTextField(labelWithString: "Image:"), images])
        if kind == .keyboard { rows.append([NSTextField(labelWithString: "Description:"), descriptionField]) }
        if kind == .phrases {
            phraseText.isRichText = false; phraseText.allowsUndo = true
            phraseText.font = .systemFont(ofSize: NSFont.systemFontSize)
            phraseText.textContainerInset = NSSize(width: 6, height: 6)
            phraseText.isVerticallyResizable = true; phraseText.isHorizontallyResizable = false
            phraseText.autoresizingMask = [.width]
            phraseText.textContainer?.widthTracksTextView = true
            phraseText.delegate = self
            phraseText.setAccessibilityIdentifier("phraseContent")
            phraseText.toolTip = "Pastes into the focused input field without sending."
            let textScroll = NSScrollView(); textScroll.documentView = phraseText
            textScroll.hasVerticalScroller = true; textScroll.borderType = .bezelBorder
            textScroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
            rows.append([NSTextField(labelWithString: "Content:"), textScroll])
        }
        error.font = .systemFont(ofSize: 11); error.textColor = .systemRed
        error.setAccessibilityIdentifier("shortcutValidation")
        rows.append([NSGridCell.emptyContentView, error])
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        // Both category forms share a label column, including their image/content rows.
        grid.column(at: 0).width = labelColumnWidth
        grid.column(at: 1).xPlacement = .fill
        grid.yPlacement = .center
        grid.rowAlignment = .firstBaseline
        grid.columnSpacing = 10; grid.rowSpacing = 8
        if kind == .phrases {
            grid.row(at: rows.count - 2).yPlacement = .top
            grid.row(at: rows.count - 2).rowAlignment = .none
        }
        errorRow = grid.row(at: rows.count - 1)
        errorRow?.isHidden = true
        form.addArrangedSubview(grid)
        grid.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        table.reloadData()
        if count > 0 { table.selectRowIndexes([0], byExtendingSelection: false) }
        loadSelection()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggleExpanded() { body.isHidden = disclosure.state != .on }
    @objc private func toggleFromTitle() {
        disclosure.state = disclosure.state == .on ? .off : .on; toggleExpanded()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { count }
    private func displayItem(at row: Int) -> ChatShortcut {
        switch kind {
        case .chats: store.chatShortcuts[row]
        case .phrases: phrases[row].displayShortcut
        case .keyboard: keyboardConfiguration.buttons[row].displayShortcut
        }
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = displayItem(at: row)
        let cell = NSView()
        if tableColumn?.identifier.rawValue == "width" {
            let control = ComponentItemWidthControl(value: item.fillWidth)
            control.onChange = { [weak self] width in self?.editInline(item.id, .width(width)) }
            return control
        }
        if tableColumn?.identifier.rawValue == "display" {
            let popup = ComponentInlinePopup(titles: ["Follow Component", "Always Icon Only", "Always Icon + Text"],
                selected: item.displayModeOverride == .iconOnly ? 1 : (item.displayModeOverride == .iconAndText ? 2 : 0))
            popup.setAccessibilityIdentifier("itemDisplayMode")
            popup.toolTip = "Override this item’s component display setting."
            popup.onChange = { [weak self] index in self?.editInline(item.id, .display(index == 1 ? .iconOnly : (index == 2 ? .iconAndText : nil))) }
            return popup
        }
        if tableColumn?.identifier.rawValue == "shortcut" {
            if kind == .chats {
                let popup = ComponentInlinePopup(titles: (1...9).map { "⌃\($0)" }, selected: max(0, min(8, item.slot - 1)))
                popup.onChange = { [weak self] index in self?.editInline(item.id, .slot(index + 1)) }
                return popup
            }
            let recorder = KeyboardShortcutRecorder()
            recorder.shortcut = keyboardConfiguration.buttons[row].shortcut
            recorder.onChange = { [weak self, weak recorder] in
                guard let recorder else { return }; self?.editInline(item.id, .key(recorder.shortcut))
            }
            return recorder
        }
        let icon = NSImageView()
        icon.image = item.imageData.flatMap(NSImage.init(data:)) ?? NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let label = ComponentInlineTextField(value: item.name,
            placeholder: kind == .chats ? "Chat name" : (kind == .phrases ? "Phrase title" : "Button title"))
        label.setAccessibilityIdentifier("shortcutTitle.\(item.id)")
        label.onEdit = { [weak self] value in self?.editInline(item.id, .title(value)) }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let rowView = NSStackView(views: [icon, label]); rowView.spacing = 8; rowView.alignment = .centerY
        rowView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(rowView)
        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            rowView.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            rowView.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private enum InlineEdit { case title(String), display(ComponentDisplayMode?), slot(Int), key(KeyboardShortcut?), width(ComponentItemWidth) }
    private func editInline(_ id: UUID, _ edit: InlineEdit) {
        guard let row = (0..<count).first(where: { displayItem(at: $0).id == id }) else { return }
        var item = displayItem(at: row)
        switch edit {
        case .title(let value):
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { showError("Enter a title."); return }; item.name = name
        case .display(let mode): item.displayModeOverride = mode
        case .slot(let slot): item.slot = slot
        case .key(let shortcut): keyboardConfiguration.buttons[row].shortcut = shortcut
        case .width(let width): item.fillWidth = width
        }
        switch kind {
        case .chats: store.chatShortcuts[row] = item
        case .phrases:
            phrases[row].name = item.name; phrases[row].displayModeOverride = item.displayModeOverride
            phrases[row].fillWidth = item.fillWidth
        case .keyboard:
            keyboardConfiguration.buttons[row].title = item.name
            keyboardConfiguration.buttons[row].displayModeOverride = item.displayModeOverride
            keyboardConfiguration.buttons[row].fillWidth = item.fillWidth
        }
        showError(""); store.save()
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === table, (0..<count).contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(displayItem(at: row).id.uuidString, forType: Self.rowDragType)
        return item
    }
    private func draggedRow(from info: any NSDraggingInfo) -> Int? {
        guard let source = info.draggingSource as? NSTableView, source === table,
              let items = info.draggingPasteboard.pasteboardItems, items.count == 1,
              let value = items[0].string(forType: Self.rowDragType), let id = UUID(uuidString: value) else { return nil }
        return (0..<count).first { displayItem(at: $0).id == id }
    }
    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === table, (0...count).contains(row), let source = draggedRow(from: info),
              row != source, row != source + 1 else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === table, dropOperation == .above, (0...count).contains(row),
              let source = draggedRow(from: info) else { return false }
        let destination = row > source ? row - 1 : row
        guard destination != source else { return false }
        if kind == .chats {
            let item = store.chatShortcuts.remove(at: source)
            store.chatShortcuts.insert(item, at: destination)
        } else if kind == .phrases {
            let item = phrases.remove(at: source)
            phrases.insert(item, at: destination)
        } else {
            var config = keyboardConfiguration
            let item = config.buttons.remove(at: source)
            config.buttons.insert(item, at: destination)
            keyboardConfiguration = config
        }
        loading = true
        table.reloadData()
        table.selectRowIndexes([destination], byExtendingSelection: false)
        loading = false
        loadSelection()
        table.scrollRowToVisible(destination)
        store.save()
        return true
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !loading { loadSelection() }
    }
    private func loadSelection() {
        loading = true; defer { loading = false }
        let valid = (0..<count).contains(table.selectedRow)
        form.isHidden = !valid; deleteButton.isEnabled = valid
        guard valid else { return }
        let item = displayItem(at: table.selectedRow)
        symbolField.stringValue = item.symbol
        colorField.stringValue = item.color
        colorWell.color = ChatColor.resolve(item.color) ?? (kind == .keyboard ? ChatSideButton.normalBackground : .systemBlue)
        if kind == .phrases { phraseText.string = phrases[table.selectedRow].text }
        if kind == .keyboard {
            let button = keyboardConfiguration.buttons[table.selectedRow]
            descriptionField.stringValue = button.description
        }
        imageData = item.imageData; imageLabel.stringValue = imageData == nil ? "" : "Embedded Image"
        imageLabel.isHidden = imageData == nil
        showError("")
    }
    @objc private func addItem() {
        if kind == .chats {
            let used = Set(store.chatShortcuts.map(\.slot))
            let next = (1...9).first { !used.contains($0) } ?? 1
            store.chatShortcuts.append(ChatShortcut(name: "Chat \(next)", slot: next))
        } else if kind == .phrases {
            phrases.append(QuickPhrase(name: "Phrase \(count + 1)", text: "Please explain this in more detail."))
        } else {
            keyboardConfiguration.buttons.append(KeyboardButton(title: "Button \(count + 1)"))
        }
        store.save(); table.reloadData()
        table.selectRowIndexes([count - 1], byExtendingSelection: false); loadSelection()
    }
    @objc private func deleteItem() {
        let row = table.selectedRow; guard (0..<count).contains(row) else { return }
        switch kind {
        case .chats: store.chatShortcuts.remove(at: row)
        case .phrases: phrases.remove(at: row)
        case .keyboard: keyboardConfiguration.buttons.remove(at: row)
        }
        store.save(); table.reloadData()
        if count > 0 { table.selectRowIndexes([min(row, count - 1)], byExtendingSelection: false) }
        loadSelection()
    }
    private func showError(_ message: String) {
        error.stringValue = message
        errorRow?.isHidden = message.isEmpty
    }
    func controlTextDidChange(_ notification: Notification) {
        if let inline = notification.object as? ComponentInlineTextField { inline.controlTextDidChange(notification) }
        else { applyEdits() }
    }
    func textDidChange(_ notification: Notification) { applyEdits() }
    private func applyEdits() {
        let row = table.selectedRow
        guard !loading, (0..<count).contains(row) else { return }
        let selectedItem = displayItem(at: row)
        let name = selectedItem.name
        let symbol = symbolField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayOverride = selectedItem.displayModeOverride
        guard !name.isEmpty else { showError("Enter a title."); return }
        guard imageData != nil || NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil else {
            showError("Enter a valid SF Symbol or choose an image."); return
        }
        if kind != .phrases {
            let color = colorField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let resolved = color.isEmpty && kind == .keyboard ? ChatSideButton.normalBackground : ChatColor.resolve(color) else {
                showError("Use a system color name or six-digit hex color."); return
            }
            colorWell.color = resolved; showError("")
            if kind == .chats {
                var item = store.chatShortcuts[row]
                item.name = name; item.symbol = symbol; item.color = color
                item.imageData = imageData
                item.displayModeOverride = displayOverride
                guard item != store.chatShortcuts[row] else { return }
                store.chatShortcuts[row] = item
            } else {
                var item = keyboardConfiguration.buttons[row]
                item.title = name; item.symbol = symbol; item.color = color; item.imageData = imageData
                item.description = descriptionField.stringValue
                item.displayModeOverride = displayOverride
                guard item != keyboardConfiguration.buttons[row] else { return }
                keyboardConfiguration.buttons[row] = item
            }
        } else {
            var item = phrases[row]
            item.name = name; item.symbol = symbol; item.imageData = imageData; item.text = phraseText.string
            item.displayModeOverride = displayOverride
            showError("")
            guard item != phrases[row] else { return }
            phrases[row] = item
        }
        store.save()
        table.reloadData(forRowIndexes: [row], columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }
    @objc private func pickColor() { colorField.stringValue = ChatColor.hex(colorWell.color); applyEdits() }
    @objc private func clearColor() { colorField.stringValue = ""; applyEdits() }
    @objc private func chooseImage() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .tiff, .pdf]
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let data = try? Data(contentsOf: url), data.count <= 5_000_000, NSImage(data: data) != nil else {
                self.showError("Choose an image smaller than 5 MB."); return
            }
            self.imageData = data; self.imageLabel.stringValue = url.lastPathComponent
            self.imageLabel.isHidden = false
            self.applyEdits()
        }
    }
    @objc private func clearImage() {
        imageData = nil; imageLabel.stringValue = ""; imageLabel.isHidden = true
        applyEdits()
    }
}
