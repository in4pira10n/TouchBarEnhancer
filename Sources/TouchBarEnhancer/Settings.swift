import AppKit
import UniformTypeIdentifiers

enum AppMode: String, Codable, CaseIterable {
    case auto = "Auto"
    case enabled = "Enabled"
    case native = "Native"
}

enum AutoPolicy: String, CaseIterable {
    case exclusion = "Exclusion Mode"
    case selection = "Selection Mode"
}

struct AppRule: Codable {
    var bundleID: String
    var name: String
    var mode: AppMode
}

@MainActor
final class SettingsStore {
    private let defaults: UserDefaults
    var rules: [AppRule] = []
    var paused = false
    var launchSilently = true
    var autoPolicy: AutoPolicy = .exclusion
    var selectedAppIDs: Set<String> = []
    var layoutApps: [LayoutApp] = []
    var chatGPTControlsEnabled = true
    var chatShortcuts: [ChatShortcut] = ChatShortcut.initial
    var quickPhrasesByApp: [String: [QuickPhrase]] = [:]
    var keyboardButtons: [String: KeyboardButtonsConfiguration] = [:]
    var componentDisplayModes: [String: [String: ComponentDisplayMode]] = [:]
    var componentPresentations: [String: [String: ComponentPresentation]] = [:]
    var textComponents: [String: [TextComponentItem]] = [:]
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "componentPresentations"),
           let saved = try? JSONDecoder().decode([String: [String: ComponentPresentation]].self, from: data) {
            componentPresentations = saved
        }
        if let data = defaults.data(forKey: "textComponents"),
           let saved = try? JSONDecoder().decode([String: [TextComponentItem]].self, from: data) { textComponents = saved }
        launchSilently = defaults.object(forKey: "launchSilently") as? Bool ?? true
        if let data = defaults.data(forKey: "componentDisplayModes"),
           let saved = try? JSONDecoder().decode([String: [String: ComponentDisplayMode]].self, from: data) {
            componentDisplayModes = saved
        }
        if let data = defaults.data(forKey: "keyboardButtons"),
           let saved = try? JSONDecoder().decode([String: KeyboardButtonsConfiguration].self, from: data) { keyboardButtons = saved }
        chatGPTControlsEnabled = defaults.object(forKey: "chatGPTControlsEnabled") as? Bool ?? true
        if let data = defaults.data(forKey: "chatShortcuts"),
           let saved = try? JSONDecoder().decode([ChatShortcut].self, from: data) { chatShortcuts = saved }
        if let data = defaults.data(forKey: "appRules"),
           let saved = try? JSONDecoder().decode([AppRule].self, from: data) {
            rules = saved
        }
        paused = defaults.bool(forKey: "paused")
        autoPolicy = AutoPolicy(rawValue: defaults.string(forKey: "autoPolicy") ?? "") ?? .exclusion
        // Existing listed apps start checked. Their explicit modes remain authoritative.
        selectedAppIDs = Set(defaults.stringArray(forKey: "selectedAppIDs") ?? rules.map(\.bundleID))
        if let data = defaults.data(forKey: "layoutApps"),
           let saved = try? JSONDecoder().decode([LayoutApp].self, from: data) { layoutApps = saved }
        if let data = defaults.data(forKey: "quickPhrasesByApp") {
            quickPhrasesByApp = (try? JSONDecoder().decode([String: [QuickPhrase]].self, from: data)) ?? [:]
        } else if let data = defaults.data(forKey: "quickPhrases"),
                  let legacy = try? JSONDecoder().decode([QuickPhrase].self, from: data) {
            // One-time copies preserve existing content without a shared fallback
            // for apps added later. Retain the old key as an untouched backup.
            let knownApps = Set((LayoutApp.builtIn + layoutApps).map(\.bundleID) + rules.map(\.bundleID)
                + Array(keyboardButtons.keys) + Array(componentDisplayModes.keys) + Array(componentPresentations.keys)
                + Array(textComponents.keys) + Array(selectedAppIDs))
            quickPhrasesByApp = Dictionary(uniqueKeysWithValues: knownApps.map { ($0, legacy) })
            if let migrated = try? JSONEncoder().encode(quickPhrasesByApp) {
                defaults.set(migrated, forKey: "quickPhrasesByApp")
            }
        }
    }

    func mode(for bundleID: String) -> AppMode {
        rules.first { $0.bundleID == bundleID }?.mode ?? .auto
    }

    func presentation(for component: String, app bundleID: String) -> ComponentPresentation {
        if let saved = componentPresentations[bundleID]?[component] { return saved }
        if component == "keyboard", let old = keyboardButtons[bundleID] {
            return ComponentPresentation(layout: old.layout, alignment: old.alignment)
        }
        return .init()
    }

    func setPresentation(_ value: ComponentPresentation, for component: String, app bundleID: String) {
        componentPresentations[bundleID, default: [:]][component] = value
        // Preserve the existing keyboard configuration format for older builds.
        if component == "keyboard" {
            keyboardButtons[bundleID, default: .init()].layout = value.layout
            keyboardButtons[bundleID, default: .init()].alignment = value.alignment
        }
        save()
    }

    var configurableApps: [LayoutApp] {
        let listed = rules.map { LayoutApp(bundleID: $0.bundleID, name: $0.name) }
        let candidates = autoPolicy == .selection ? listed : LayoutApp.builtIn + layoutApps + listed
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.bundleID).inserted }
    }

    func shouldEnhance(_ bundleID: String, manuallyHidden: Bool) -> Bool {
        guard !paused, !manuallyHidden else { return false }
        switch mode(for: bundleID) {
        case .auto:
            let selected = selectedAppIDs.contains(bundleID)
            return autoPolicy == .exclusion ? !selected : selected
        case .enabled: return true
        case .native: return false
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "appRules") }
        defaults.set(paused, forKey: "paused")
        defaults.set(launchSilently, forKey: "launchSilently")
        defaults.set(autoPolicy.rawValue, forKey: "autoPolicy")
        defaults.set(selectedAppIDs.sorted(), forKey: "selectedAppIDs")
        defaults.set(chatGPTControlsEnabled, forKey: "chatGPTControlsEnabled")
        if let data = try? JSONEncoder().encode(componentDisplayModes) { defaults.set(data, forKey: "componentDisplayModes") }
        if let data = try? JSONEncoder().encode(componentPresentations) { defaults.set(data, forKey: "componentPresentations") }
        if let data = try? JSONEncoder().encode(textComponents) { defaults.set(data, forKey: "textComponents") }
        if let data = try? JSONEncoder().encode(keyboardButtons) { defaults.set(data, forKey: "keyboardButtons") }
        if let data = try? JSONEncoder().encode(chatShortcuts) { defaults.set(data, forKey: "chatShortcuts") }
        if let data = try? JSONEncoder().encode(quickPhrasesByApp) { defaults.set(data, forKey: "quickPhrasesByApp") }
        if let data = try? JSONEncoder().encode(layoutApps) { defaults.set(data, forKey: "layoutApps") }
        onChange?()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate, NSWindowDelegate {
    private let store: SettingsStore
    private let table = NSTableView()
    private let policyPopup = NSPopUpButton()
    private let policyHelp = NSTextField(wrappingLabelWithString: "")
    private var appIcons: [String: NSImage] = [:]
    private let pauseButton = NSButton(checkboxWithTitle: "Pause Touch Bar enhancement", target: nil, action: nil)
    private let silentLaunchButton = NSButton(checkboxWithTitle: "Launch silently", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let generalPane = NSView()
    private let applicationsPane = NSView()
    private let generalID = NSToolbarItem.Identifier("general")
    private let applicationsID = NSToolbarItem.Identifier("applications")
    private let appsID = NSToolbarItem.Identifier("apps")
    private var appsPane: AppsPane!
    private var showingApps = false
    private weak var currentPane: NSView?
    private var paneSizes: [ObjectIdentifier: NSSize] = [:]
    var onPreviewApp: ((LayoutApp?) -> Void)?
    var onCustomizeApp: ((LayoutApp) -> Void)?
    private let generalStatusLabel = NSTextField(wrappingLabelWithString: "")

    init(store: SettingsStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Applications"
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 590, height: 480)
        super.init(window: window)
        window.delegate = self
        window.center()
        buildContent()
        buildGeneralPane()
        appsPane = AppsPane(store: store)
        appsPane.onSelect = { [weak self] app in
            guard let self, self.showingApps else { return }
            self.onPreviewApp?(app)
        }
        appsPane.onCustomize = { [weak self] app in self?.onCustomizeApp?(app) }
        let toolbar = NSToolbar(identifier: "settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = applicationsID
        showPane(applicationsPane)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildContent() {
        let content = applicationsPane
        policyPopup.addItems(withTitles: AutoPolicy.allCases.map(\.rawValue))
        policyPopup.selectItem(withTitle: store.autoPolicy.rawValue)
        policyPopup.target = self
        policyPopup.action = #selector(changePolicy)
        policyPopup.setAccessibilityLabel("Auto behavior")
        let policyRow = NSStackView(views: [NSTextField(labelWithString: "Auto behavior:"), policyPopup])
        policyRow.spacing = 10
        policyRow.alignment = .centerY
        policyHelp.font = .systemFont(ofSize: 11)
        policyHelp.textColor = .secondaryLabelColor

        let selectionColumn = NSTableColumn(identifier: .init("selected"))
        selectionColumn.width = 60
        selectionColumn.minWidth = 60
        selectionColumn.maxWidth = 60
        let appColumn = NSTableColumn(identifier: .init("app"))
        appColumn.title = "Application"
        appColumn.width = 315
        let modeColumn = NSTableColumn(identifier: .init("mode"))
        modeColumn.title = "Mode"
        modeColumn.width = 125
        table.addTableColumn(selectionColumn)
        table.addTableColumn(appColumn)
        table.addTableColumn(modeColumn)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 48
        table.style = .inset
        table.allowsMultipleSelection = false
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let addButton = NSButton(title: "Add App…", target: self, action: #selector(addApp))
        removeButton.target = self
        removeButton.action = #selector(removeApp)
        removeButton.isEnabled = false
        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.spacing = 8
        buttons.alignment = .centerY
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("ruleStatus")
        statusLabel.isHidden = true

        let stack = NSStackView(views: [policyRow, policyHelp, scroll, buttons, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            policyHelp.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        refreshPolicyDescription()
    }

    private func buildGeneralPane() {
        silentLaunchButton.target = self
        silentLaunchButton.action = #selector(toggleSilentLaunch)
        silentLaunchButton.state = store.launchSilently ? .on : .off
        silentLaunchButton.toolTip = "Keep Settings closed at launch."
        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.state = store.paused ? .on : .off
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Startup:"), silentLaunchButton],
            [NSTextField(labelWithString: "Enhancement:"), pauseButton]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.yPlacement = .center
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        generalPane.addSubview(grid)
        generalStatusLabel.font = .systemFont(ofSize: 11)
        generalStatusLabel.textColor = .secondaryLabelColor
        generalStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        generalPane.addSubview(generalStatusLabel)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: generalPane.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: generalPane.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: generalPane.trailingAnchor, constant: -24),
            generalStatusLabel.leadingAnchor.constraint(equalTo: generalPane.leadingAnchor, constant: 24),
            generalStatusLabel.trailingAnchor.constraint(equalTo: generalPane.trailingAnchor, constant: -24),
            generalStatusLabel.bottomAnchor.constraint(equalTo: generalPane.bottomAnchor, constant: -24)
        ])
    }

    private func showPane(_ pane: NSView, size: NSSize? = nil) {
        guard let content = window?.contentView else { return }
        if let currentPane { paneSizes[ObjectIdentifier(currentPane)] = content.bounds.size }
        content.subviews.forEach { $0.removeFromSuperview() }
        // Remove the outgoing pane's minimum sizes before shrinking the window.
        if let size {
            window?.contentMinSize = size
            let saved = paneSizes[ObjectIdentifier(pane)] ?? size
            resizeContent(to: NSSize(width: max(saved.width, size.width), height: max(saved.height, size.height)))
        }
        currentPane = pane
        pane.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pane.topAnchor.constraint(equalTo: content.topAnchor),
            pane.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [generalID, applicationsID, appsID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [generalID, applicationsID, appsID]
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [generalID, applicationsID, appsID]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let general = identifier == generalID
        item.label = general ? "General" : (identifier == appsID ? "Apps" : "Applications")
        item.image = NSImage(systemSymbolName: general ? "gearshape" : (identifier == appsID ? "rectangle.3.group" : "app.badge"), accessibilityDescription: item.label)
        item.target = self
        item.action = #selector(selectPane(_:))
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        let general = sender.itemIdentifier == generalID
        showingApps = sender.itemIdentifier == appsID
        window?.title = sender.label
        if showingApps {
            showPane(appsPane, size: NSSize(width: 760, height: 520))
            appsPane.refresh()
            appsPane.beginPreview()
        } else {
            onPreviewApp?(nil)
            showPane(general ? generalPane : applicationsPane,
                size: NSSize(width: 590, height: general ? 200 : 480))
        }
    }

    private func resizeContent(to size: NSSize) {
        guard let window else { return }
        let top = window.frame.maxY
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: top - window.frame.height))
    }

    func windowWillClose(_ notification: Notification) {
        window?.touchBar = nil
        onPreviewApp?(nil)
    }

    func resumePreviewIfNeeded() {
        if showingApps { appsPane.refresh(); appsPane.beginPreview() }
    }

    func refreshAppsIfNeeded() {
        if showingApps { appsPane.refresh() }
    }

    func update(status: String) {
        statusLabel.stringValue = status
        statusLabel.isHidden = status.isEmpty
        generalStatusLabel.stringValue = status
        pauseButton.state = store.paused ? .on : .off
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.rules.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rule = store.rules[row]
        if tableColumn?.identifier.rawValue == "selected" {
            let checkbox = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleSelection(_:)))
            checkbox.state = store.selectedAppIDs.contains(rule.bundleID) ? .on : .off
            checkbox.tag = row
            checkbox.isEnabled = rule.mode == .auto
            checkbox.setAccessibilityLabel("\(store.autoPolicy == .exclusion ? "Exclude" : "Include") \(rule.name)")
            checkbox.toolTip = rule.mode == .auto ? "Apply Auto policy to this app" : "Select Auto to use this checkbox"
            let cell = NSView()
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(checkbox)
            NSLayoutConstraint.activate([
                checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        if tableColumn?.identifier.rawValue == "mode" {
            let popup = NSPopUpButton()
            popup.addItems(withTitles: AppMode.allCases.map(\.rawValue))
            popup.selectItem(withTitle: rule.mode.rawValue)
            popup.tag = row
            popup.target = self
            popup.action = #selector(changeMode(_:))
            popup.setAccessibilityLabel("Mode for \(rule.name)")
            popup.toolTip = "Enabled and Native override the Auto policy."
            let cell = NSView()
            popup.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(popup)
            NSLayoutConstraint.activate([
                popup.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                popup.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                popup.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        let name = NSTextField(labelWithString: rule.name)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        let bundle = NSTextField(labelWithString: rule.bundleID)
        bundle.font = .systemFont(ofSize: 10)
        bundle.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        bundle.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [name, bundle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        let cell = NSView()
        let icon = NSImageView()
        if let cached = appIcons[rule.bundleID] {
            icon.image = cached
        } else {
            let image: NSImage
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) {
                image = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                image = NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
            }
            appIcons[rule.bundleID] = image
            icon.image = image
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(icon)
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            name.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bundle.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        removeButton.isEnabled = table.selectedRow >= 0
    }

    @objc private func togglePause() {
        store.paused = pauseButton.state == .on
        store.save()
    }

    @objc private func toggleSilentLaunch() {
        store.launchSilently = silentLaunchButton.state == .on
        store.save()
    }

    @objc private func changeMode(_ sender: NSPopUpButton) {
        guard store.rules.indices.contains(sender.tag),
              let title = sender.titleOfSelectedItem, let mode = AppMode(rawValue: title) else { return }
        store.rules[sender.tag].mode = mode
        table.reloadData()
        store.save()
    }

    private func refreshPolicyDescription() {
        let exclusion = store.autoPolicy == .exclusion
        table.tableColumn(withIdentifier: .init("selected"))?.title = exclusion ? "Exclude" : "Include"
        policyHelp.stringValue = exclusion
            ? "Checked apps use their native bar in Auto mode."
            : "Only checked apps use the enhanced bar in Auto mode."
    }

    @objc private func changePolicy() {
        guard let title = policyPopup.titleOfSelectedItem, let policy = AutoPolicy(rawValue: title) else { return }
        store.autoPolicy = policy
        refreshPolicyDescription()
        table.reloadData()
        store.save()
    }

    @objc private func toggleSelection(_ sender: NSButton) {
        guard store.rules.indices.contains(sender.tag) else { return }
        let id = store.rules[sender.tag].bundleID
        if sender.state == .on { store.selectedAppIDs.insert(id) }
        else { store.selectedAppIDs.remove(id) }
        store.save()
    }

    @objc private func addApp() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            for url in panel.urls {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                guard !self.store.rules.contains(where: { $0.bundleID == id }) else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                self.store.rules.append(AppRule(bundleID: id, name: name, mode: .auto))
                self.store.selectedAppIDs.insert(id)
            }
            self.store.rules.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.table.reloadData()
            self.store.save()
        }
    }

    @objc private func removeApp() {
        let row = table.selectedRow
        guard store.rules.indices.contains(row) else { return }
        let removed = store.rules.remove(at: row)
        store.selectedAppIDs.remove(removed.bundleID)
        table.reloadData()
        removeButton.isEnabled = false
        store.save()
    }
}
