import AppKit
import UniformTypeIdentifiers

private final class AppDetailsDocument: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class AppsPane: NSView, NSTableViewDelegate, NSTableViewDataSource {
    private let store: SettingsStore
    private let sidebar = NSTableView()
    private let title = NSTextField(labelWithString: "")
    private let appIcon = NSImageView()
    private let detail = NSStackView()
    private let components = NSStackView()
    private let detailScroll = NSScrollView()
    private let addButton = NSButton(title: "Add App…", target: nil, action: nil)
    private let emptyState = NSTextField(wrappingLabelWithString: "Add apps in Applications to customize their Touch Bars.")
    private let chatGPTConnectionReader: (() -> ChatGPTAdapter.Snapshot)?
    private(set) var selectedApp: LayoutApp?
    private var apps: [LayoutApp] = []
    private var hasLoadedApps = false
    var onSelect: ((LayoutApp?) -> Void)?
    var onCustomize: ((LayoutApp) -> Void)?

    init(store: SettingsStore, chatGPTConnectionReader: (() -> ChatGPTAdapter.Snapshot)? = nil) {
        self.store = store
        self.chatGPTConnectionReader = chatGPTConnectionReader
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("app"))
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.rowHeight = 40
        sidebar.delegate = self
        sidebar.dataSource = self
        let scroll = NSScrollView()
        scroll.documentView = sidebar
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let add = addButton
        add.target = self
        add.action = #selector(addApp)
        let left = NSStackView(views: [scroll, add])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        left.translatesAutoresizingMaskIntoConstraints = false
        add.setAccessibilityIdentifier("addLayoutApp")
        addSubview(left)
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 12
        detail.translatesAutoresizingMaskIntoConstraints = false
        let document = AppDetailsDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(detail)
        detailScroll.documentView = document
        detailScroll.hasVerticalScroller = true
        detailScroll.drawsBackground = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailScroll)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            left.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            left.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            left.widthAnchor.constraint(equalToConstant: 180),
            scroll.widthAnchor.constraint(equalTo: left.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            detailScroll.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 24),
            detailScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            detailScroll.topAnchor.constraint(equalTo: left.topAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: left.bottomAnchor),
            document.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor),
            detail.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: document.topAnchor),
            detail.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        appIcon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let header = NSStackView(views: [appIcon, title])
        header.spacing = 10
        header.alignment = .centerY
        detail.addArrangedSubview(header)
        let customize = NSButton(title: "Customize Touch Bar…", target: self, action: #selector(customize))
        customize.bezelStyle = .rounded
        customize.setAccessibilityIdentifier("customizeAppBar")
        customize.toolTip = "Drag components to add or arrange them on the Touch Bar."
        detail.addArrangedSubview(customize)
        components.orientation = .vertical
        components.alignment = .leading
        components.spacing = 10
        detail.addArrangedSubview(components)
        components.widthAnchor.constraint(equalTo: detail.widthAnchor).isActive = true
        emptyState.textColor = .secondaryLabelColor
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: detailScroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: detailScroll.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: detailScroll.topAnchor, constant: 20)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh() {
        let selectedID = selectedApp?.bundleID
        let candidates = store.configurableApps
        addButton.isHidden = store.autoPolicy == .selection
        guard !hasLoadedApps || candidates != apps else { return }
        hasLoadedApps = true
        apps = candidates
        sidebar.reloadData()
        detailScroll.isHidden = apps.isEmpty
        emptyState.isHidden = !apps.isEmpty
        guard !apps.isEmpty else {
            selectedApp = nil
            onSelect?(nil)
            return
        }
        let row = apps.firstIndex { $0.bundleID == selectedID } ?? 0
        sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectRow(row)
    }

    func beginPreview() { if let selectedApp { onSelect?(selectedApp) } }
    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = apps[row]
        let cell = NSTableCellView()
        let image = NSImageView()
        image.image = icon(for: app)
        let text = NSTextField(labelWithString: app.name)
        text.lineBreakMode = .byTruncatingTail
        cell.imageView = image
        cell.textField = text
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 26),
            image.heightAnchor.constraint(equalToConstant: 26),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { selectRow(sidebar.selectedRow) }

    private func selectRow(_ row: Int) {
        guard apps.indices.contains(row) else { return }
        let app = apps[row]
        selectedApp = app
        title.stringValue = app.name
        title.toolTip = app.bundleID
        appIcon.image = icon(for: app)
        components.arrangedSubviews.forEach { components.removeArrangedSubview($0); $0.removeFromSuperview() }
        if app.isChatGPT {
            let pane = ChatGPTPane(store: store, app: app, connectionReader: chatGPTConnectionReader)
            components.addArrangedSubview(pane)
            pane.widthAnchor.constraint(equalTo: components.widthAnchor).isActive = true
        } else {
            let phrases = ShortcutCategoryEditor(store: store, kind: .phrases, appBundleID: app.bundleID)
            components.addArrangedSubview(phrases)
            phrases.widthAnchor.constraint(equalTo: components.widthAnchor).isActive = true
            let keyboard = ShortcutCategoryEditor(store: store, kind: .keyboard, appBundleID: app.bundleID)
            components.addArrangedSubview(keyboard)
            keyboard.widthAnchor.constraint(equalTo: components.widthAnchor).isActive = true
        }
        let text = TextComponentEditor(store: store, appBundleID: app.bundleID)
        components.addArrangedSubview(text)
        text.widthAnchor.constraint(equalTo: components.widthAnchor).isActive = true
        detailScroll.contentView.scroll(to: .zero)
        onSelect?(app)
    }

    private func icon(for app: LayoutApp) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    @objc private func customize() { if let selectedApp { onCustomize?(selectedApp) } }

    @objc private func addApp() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url,
                  let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return }
            let app = LayoutApp(bundleID: id, name: url.deletingPathExtension().lastPathComponent)
            if !self.store.layoutApps.contains(where: { $0.bundleID == id }) {
                self.store.layoutApps.append(app)
                self.store.save()
            }
            self.selectedApp = app
            self.refresh()
        }
    }
}
