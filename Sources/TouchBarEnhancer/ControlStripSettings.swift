import AppKit
import IOBluetooth
import CoreBluetooth

struct ControlStripBluetoothDevice: Equatable {
    var address: String
    var name: String
    var connected: Bool

    static func normalizedAddress(_ value: String) -> String {
        value.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
    }
    var identifier: String { Self.normalizedAddress(address) }

    @MainActor static func paired() -> [Self] {
        guard CBManager.authorization != .denied && CBManager.authorization != .restricted else { return [] }
        return ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).compactMap { device in
            guard let address = device.addressString else { return nil }
            return Self(address: address, name: device.name ?? "Bluetooth Device", connected: device.isConnected())
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct ControlStripAutomationRule: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Automation Rule"
    var enabled = false
    var bluetoothConnected = true
    var mediaPlaying = false
    var deviceAddress = ""
    var deviceName = ""
    var configuration = ControlStripConfiguration()

    init() {}
    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, bluetoothConnected, mediaPlaying, deviceAddress, deviceName, configuration
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Automation Rule"
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        bluetoothConnected = try values.decodeIfPresent(Bool.self, forKey: .bluetoothConnected) ?? true
        mediaPlaying = try values.decodeIfPresent(Bool.self, forKey: .mediaPlaying) ?? false
        deviceAddress = try values.decodeIfPresent(String.self, forKey: .deviceAddress) ?? ""
        deviceName = try values.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        configuration = try values.decodeIfPresent(ControlStripConfiguration.self, forKey: .configuration) ?? .init()
    }

    var hasConditions: Bool { bluetoothConnected || mediaPlaying }
    var hasValidConditions: Bool {
        let address = ControlStripBluetoothDevice.normalizedAddress(deviceAddress)
        return hasConditions && (!bluetoothConnected || (address.count == 12 && address.allSatisfy { $0.isHexDigit }))
    }
    func matches(_ devices: [ControlStripBluetoothDevice], mediaIsPlaying: Bool?) -> Bool {
        guard enabled, hasConditions else { return false }
        if mediaPlaying && mediaIsPlaying != true { return false }
        guard bluetoothConnected else { return true }
        let address = ControlStripBluetoothDevice.normalizedAddress(deviceAddress)
        guard address.count == 12, address.allSatisfy({ $0.isHexDigit }) else { return false }
        return devices.contains { $0.connected && $0.identifier == address }
    }

    static func active(in rules: [Self], devices: [ControlStripBluetoothDevice], mediaIsPlaying: Bool?) -> Self? {
        rules.first { $0.matches(devices, mediaIsPlaying: mediaIsPlaying) }
    }
}

/// Reads existing paired-device state only; no discovery or connection requests.
/// Inactive until a configured, enabled rule needs it. Never executes an action.
@MainActor
final class ControlStripAutomationMonitor {
    private(set) var devices: [ControlStripBluetoothDevice] = []
    private(set) var activeRule: ControlStripAutomationRule?
    private(set) var isMonitoring = false
    private(set) var mediaIsPlaying: Bool?
    var onChange: (() -> Void)?
    private var rules: [ControlStripAutomationRule] = []
    private var timer: Timer?
    var isPollingBluetooth: Bool { timer != nil }
    private let readDevices: () -> [ControlStripBluetoothDevice]
    private let readMedia: (@escaping @MainActor (Bool?) -> Void) -> Void
    private let observeMedia: (@escaping @MainActor (Bool?) -> Void) -> (@MainActor () -> Void)?
    private var stopMediaObservation: (@MainActor () -> Void)?
    private var observingMedia = false
    private var observationGeneration = UUID()
    private var pendingMedia: UUID?
    private var mediaTimeout: Timer?
    private var needsBluetooth: Bool { rules.contains { $0.enabled && $0.hasValidConditions && $0.bluetoothConnected } }
    var needsMedia: Bool { rules.contains { $0.enabled && $0.hasValidConditions && $0.mediaPlaying } }

    init(readDevices: @escaping () -> [ControlStripBluetoothDevice] = { ControlStripBluetoothDevice.paired() },
         readMedia: @escaping (@escaping @MainActor (Bool?) -> Void) -> Void = { $0(nil) },
         observeMedia: @escaping (@escaping @MainActor (Bool?) -> Void) -> (@MainActor () -> Void)? = { _ in nil }) {
        self.readDevices = readDevices
        self.readMedia = readMedia
        self.observeMedia = observeMedia
    }
    func configure(enabled: Bool, rules: [ControlStripAutomationRule]) {
        let needsMonitoring = enabled && rules.contains { $0.enabled && $0.hasValidConditions }
        let changed = self.rules != rules
        if changed { cancelMediaRead() }
        self.rules = rules
        guard needsMonitoring else { stop(); return }
        let starting = !isMonitoring
        isMonitoring = true
        // Only Bluetooth uses a periodic reader. Media is entirely event-driven.
        if needsBluetooth && timer == nil {
            let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshBluetooth() }
            }
            timer.tolerance = 0.5
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else if !needsBluetooth {
            timer?.invalidate(); timer = nil
        }
        if needsMedia && !observingMedia {
            observingMedia = true
            let generation = UUID()
            observationGeneration = generation
            stopMediaObservation = observeMedia { [weak self] playing in
                guard let self, self.observationGeneration == generation,
                      self.isMonitoring, self.needsMedia else { return }
                self.cancelMediaRead()
                if let playing { self.updateMedia(playing) }
                else { self.requestMediaState() }
            }
        } else if !needsMedia { endMediaObservation() }
        if starting || changed { refresh() }
    }
    func refresh() {
        guard isMonitoring else { return }
        refreshBluetooth()
        if !needsMedia { mediaIsPlaying = nil }
        resolve()
        requestMediaState()
    }
    private func refreshBluetooth() {
        guard isMonitoring else { return }
        devices = needsBluetooth ? readDevices() : []
        resolve()
    }
    private func requestMediaState() {
        guard isMonitoring, needsMedia, pendingMedia == nil else { return }
        let token = UUID()
        pendingMedia = token
        let timeout = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.receiveMedia(nil, token: token) }
        }
        mediaTimeout = timeout
        RunLoop.main.add(timeout, forMode: .common)
        readMedia { [weak self] playing in self?.receiveMedia(playing, token: token) }
    }
    private func receiveMedia(_ playing: Bool?, token: UUID) {
        guard isMonitoring, pendingMedia == token else { return }
        cancelMediaRead()
        updateMedia(playing)
    }
    private func updateMedia(_ playing: Bool?) {
        let changed = playing != mediaIsPlaying
        mediaIsPlaying = playing
        resolve(force: changed)
    }
    private func resolve(force: Bool = false) {
        let resolved = ControlStripAutomationRule.active(in: rules, devices: devices, mediaIsPlaying: mediaIsPlaying)
        let changed = resolved != activeRule
        activeRule = resolved
        if changed || force { onChange?() }
    }
    private func cancelMediaRead() {
        pendingMedia = nil
        mediaTimeout?.invalidate(); mediaTimeout = nil
    }
    func stop() {
        timer?.invalidate(); timer = nil; isMonitoring = false
        endMediaObservation()
        cancelMediaRead()
        let changed = !devices.isEmpty || activeRule != nil || mediaIsPlaying != nil
        devices = []; activeRule = nil; mediaIsPlaying = nil
        if changed { onChange?() }
    }
    private func endMediaObservation() {
        observationGeneration = UUID()
        observingMedia = false
        stopMediaObservation?(); stopMediaObservation = nil
    }
}

enum ControlStripAction: String, Codable, CaseIterable {
    case none, toggleEnhancement, pasteClipboard, pasteText, copyText, keyboardShortcut, runShortcut, openURL
    case previousMedia, nextMedia

    var title: String {
        switch self {
        case .none: "No Action"
        case .toggleEnhancement: "Pause / Resume Enhancement"
        case .pasteClipboard: "Paste Clipboard"
        case .pasteText: "Paste Text"
        case .copyText: "Copy Text to Clipboard"
        case .keyboardShortcut: "Send Keyboard Shortcut"
        case .runShortcut: "Run Shortcut"
        case .openURL: "Open URL"
        case .previousMedia: "Previous Media"
        case .nextMedia: "Next Media"
        }
    }
}

enum ControlStripInteraction: String, Codable, CaseIterable {
    case tap, longPress, optionTap, commandTap, controlTap

    var title: String {
        switch self {
        case .tap: "Tap"
        case .longPress: "Long Press"
        case .optionTap: "Option + Tap"
        case .commandTap: "Command + Tap"
        case .controlTap: "Control + Tap"
        }
    }

    static func click(modifiers: NSEvent.ModifierFlags) -> Self? {
        switch modifiers.intersection([.option, .command, .control, .shift]) {
        case []: .tap
        case .option: .optionTap
        case .command: .commandTap
        case .control: .controlTap
        default: nil // Unconfigured multi-modifier/Shift combinations do nothing.
        }
    }
}

enum ControlStripShortcutInput: String, Codable, CaseIterable {
    case none, clipboard, text
    var title: String {
        switch self {
        case .none: "None"
        case .clipboard: "Clipboard Text"
        case .text: "Specified Text"
        }
    }
}

struct ControlStripActionBinding: Codable, Equatable {
    var action: ControlStripAction = .none
    var text = ""
    var keyboardShortcut: KeyboardShortcut?
    var shortcutName = ""
    var shortcutInput: ControlStripShortcutInput = .none
    var url = ""

    init() {}
    private enum CodingKeys: String, CodingKey {
        case action, text, keyboardShortcut, shortcutName, shortcutInput, url
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        action = try values.decodeIfPresent(ControlStripAction.self, forKey: .action) ?? .none
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        keyboardShortcut = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .keyboardShortcut)
        shortcutName = try values.decodeIfPresent(String.self, forKey: .shortcutName) ?? ""
        shortcutInput = try values.decodeIfPresent(ControlStripShortcutInput.self, forKey: .shortcutInput) ?? .none
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    var validationMessage: String? {
        switch action {
        case .pasteText, .copyText:
            return text.isEmpty ? "Enter some text." : nil
        case .keyboardShortcut:
            guard let keyboardShortcut, keyboardShortcut.keyCode <= 127,
                  !KeyboardShortcut.modifierKeyCodes.contains(keyboardShortcut.keyCode) else {
                return "Record a keyboard shortcut."
            }
        case .runShortcut:
            if shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a shortcut name or identifier." }
            if shortcutInput == .text && text.isEmpty { return "Enter input text for the shortcut." }
        case .openURL:
            guard let destination = URL(string: url), let scheme = destination.scheme, !scheme.isEmpty,
                  !url.contains(where: { $0.isWhitespace }) else { return "Enter a complete URL, including its scheme." }
        default: break
        }
        return nil
    }

    /// Arguments are passed directly to Process, never interpreted by a shell.
    func shortcutArguments(inputPath: String?) -> [String] {
        var arguments = ["run"]
        if let inputPath { arguments += ["--input-path", inputPath] }
        arguments += ["--", shortcutName]
        return arguments
    }
}

struct ControlStripConfiguration: Codable, Equatable {
    static let defaultSymbol = "rectangle.bottomthird.inset.filled"
    static let defaultLongPressDuration: TimeInterval = 0.6
    static func isValidLongPressDuration(_ value: TimeInterval) -> Bool {
        value.isFinite && (0.1...10).contains(value)
    }
    var showsButton = true
    var symbol = defaultSymbol
    var longPressDuration = defaultLongPressDuration
    // Keep the original tap fields at their existing persisted keys.
    var action: ControlStripAction = .toggleEnhancement
    var text = ""
    var keyboardShortcut: KeyboardShortcut?
    var shortcutName = ""
    var shortcutInput: ControlStripShortcutInput = .none
    var url = ""
    var interactionActions: [String: ControlStripActionBinding] = [:]

    init() {}
    private enum CodingKeys: String, CodingKey {
        case showsButton, symbol, longPressDuration, action, text, keyboardShortcut, shortcutName, shortcutInput, url, interactionActions
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        showsButton = try values.decodeIfPresent(Bool.self, forKey: .showsButton) ?? true
        symbol = try values.decodeIfPresent(String.self, forKey: .symbol) ?? Self.defaultSymbol
        let duration = try values.decodeIfPresent(TimeInterval.self, forKey: .longPressDuration) ?? Self.defaultLongPressDuration
        longPressDuration = Self.isValidLongPressDuration(duration) ? duration : Self.defaultLongPressDuration
        action = try values.decodeIfPresent(ControlStripAction.self, forKey: .action) ?? .toggleEnhancement
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        keyboardShortcut = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .keyboardShortcut)
        shortcutName = try values.decodeIfPresent(String.self, forKey: .shortcutName) ?? ""
        shortcutInput = try values.decodeIfPresent(ControlStripShortcutInput.self, forKey: .shortcutInput) ?? .none
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
        interactionActions = try values.decodeIfPresent([String: ControlStripActionBinding].self, forKey: .interactionActions) ?? [:]
    }
    func binding(for interaction: ControlStripInteraction) -> ControlStripActionBinding {
        guard interaction == .tap else { return interactionActions[interaction.rawValue] ?? .init() }
        var binding = ControlStripActionBinding()
        binding.action = action; binding.text = text; binding.keyboardShortcut = keyboardShortcut
        binding.shortcutName = shortcutName; binding.shortcutInput = shortcutInput; binding.url = url
        return binding
    }
    mutating func setBinding(_ binding: ControlStripActionBinding, for interaction: ControlStripInteraction) {
        guard interaction == .tap else { interactionActions[interaction.rawValue] = binding; return }
        action = binding.action; text = binding.text; keyboardShortcut = binding.keyboardShortcut
        shortcutName = binding.shortcutName; shortcutInput = binding.shortcutInput; url = binding.url
    }
    var validationMessage: String? { showsButton ? binding(for: .tap).validationMessage : nil }
    func shortcutArguments(inputPath: String?) -> [String] { binding(for: .tap).shortcutArguments(inputPath: inputPath) }
}

/// Independent, live editor. Building or updating it does not execute actions.
@MainActor
final class ControlStripSettingsPane: NSView, NSTextFieldDelegate, NSTextViewDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let store: SettingsStore
    private let visibility = NSButton(checkboxWithTitle: "Enable Control Strip button", target: nil, action: nil)
    private let configurationVisibility = NSButton(checkboxWithTitle: "Show button", target: nil, action: nil)
    private let hiddenExplanation = NSTextField(wrappingLabelWithString: "The button stays hidden while this configuration is in use. Automation continues checking conditions.")
    private let symbol = NSTextField(string: "")
    private let preview = NSImageView()
    private let action = NSPopUpButton()
    private let interaction = NSPopUpButton()
    private let longPressDuration = NSTextField(string: "")
    private var durationError: String?
    private var selectedInteraction: ControlStripInteraction = .tap
    private let recorder = KeyboardShortcutRecorder()
    private let shortcutName = NSTextField(string: "")
    private let shortcutInput = NSPopUpButton()
    private let destination = NSTextField(string: "")
    private let text = NSTextView()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let conditionFeedback = NSTextField(wrappingLabelWithString: "")
    private var grid: NSGridView!
    private var symbolError: String?
    private var actionError: String?
    private var conditionError: String?
    private let profiles = NSTableView()
    private var changingSelection = false
    private let editorTitle = NSTextField(labelWithString: "Default Button")
    private let editorSummary = NSTextField(wrappingLabelWithString: "Used when no automation matches.")
    private let enabled = NSButton(checkboxWithTitle: "Enable this rule", target: nil, action: nil)
    private let ruleName = NSTextField(string: "")
    private let bluetoothCondition = NSButton(checkboxWithTitle: "Bluetooth device is connected", target: nil, action: nil)
    private let mediaCondition = NSButton(checkboxWithTitle: "Music / media is playing", target: nil, action: nil)
    private let device = NSPopUpButton()
    private let automationStatus = NSTextField(wrappingLabelWithString: "Currently using: Default")
    private var activeName: String?
    private var activeButtonVisible = true
    private var playbackUnavailable = false
    private let removeRule = NSButton(title: "Remove", target: nil, action: nil)
    private let moveUp = NSButton(title: "↑", target: nil, action: nil)
    private let moveDown = NSButton(title: "↓", target: nil, action: nil)
    private var selectedRuleID: UUID?
    private var knownDevices: [ControlStripBluetoothDevice] = []
    private static let rulePasteboardType = NSPasteboard.PasteboardType("local.starfruit.TouchBarEnhancer.strip-rule")
    var deviceReader: () -> [ControlStripBluetoothDevice] = { ControlStripBluetoothDevice.paired() }

    private var selectedRuleIndex: Int? { store.controlStripAutomationRules.firstIndex { $0.id == selectedRuleID } }
    private var configuration: ControlStripConfiguration {
        get { selectedRuleIndex.map { store.controlStripAutomationRules[$0].configuration } ?? store.controlStripConfiguration }
        set {
            if let index = selectedRuleIndex { store.controlStripAutomationRules[index].configuration = newValue }
            else { store.controlStripConfiguration = newValue }
        }
    }
    private var actionBinding: ControlStripActionBinding {
        get { configuration.binding(for: selectedInteraction) }
        set { configuration.setBinding(newValue, for: selectedInteraction) }
    }
    private enum Row: Int { case heading, summary, ruleName, enabled, conditionsHeading, bluetooth, device, media, conditionFeedback, buttonHeading, visibility, hiddenExplanation, symbol, interaction, duration, action, keyboard, shortcutName, input, text, url, feedback }

    init(store: SettingsStore) {
        self.store = store
        super.init(frame: .zero)
        visibility.target = self; visibility.action = #selector(changeVisibility)
        visibility.state = store.showControlStripButton ? .on : .off
        visibility.toolTip = "Master switch for the button and automation. Each configuration can also hide the button independently."
        visibility.setAccessibilityIdentifier("stripMasterEnabled")
        configurationVisibility.target = self; configurationVisibility.action = #selector(changeConfigurationVisibility)
        configurationVisibility.state = store.controlStripConfiguration.showsButton ? .on : .off
        configurationVisibility.setAccessibilityIdentifier("stripConfigurationVisible")
        configurationVisibility.toolTip = "Show or hide the extra button whenever this configuration is in use."
        hiddenExplanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hiddenExplanation.textColor = .secondaryLabelColor
        let config = store.controlStripConfiguration
        profiles.setAccessibilityIdentifier("stripProfile")
        profiles.setAccessibilityLabel("Default button and automation rules, in priority order")
        let column = NSTableColumn(identifier: .init("configuration"))
        profiles.addTableColumn(column)
        profiles.headerView = nil; profiles.rowHeight = 56
        profiles.intercellSpacing = NSSize(width: 0, height: 2)
        profiles.style = .inset
        profiles.backgroundColor = .controlBackgroundColor
        profiles.allowsEmptySelection = false
        profiles.allowsMultipleSelection = false
        profiles.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        profiles.dataSource = self; profiles.delegate = self
        profiles.registerForDraggedTypes([Self.rulePasteboardType])
        profiles.setDraggingSourceOperationMask(.move, forLocal: true)
        let add = NSButton(title: "Add Rule", target: self, action: #selector(addAutomation))
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.imagePosition = .imageLeading
        add.toolTip = "Create a disabled rule using the Default button configuration."
        removeRule.target = self; removeRule.action = #selector(removeAutomation)
        moveUp.target = self; moveUp.action = #selector(moveAutomationUp)
        moveUp.toolTip = "Move rule earlier (higher priority)"
        moveUp.setAccessibilityLabel("Move rule earlier")
        moveDown.target = self; moveDown.action = #selector(moveAutomationDown)
        moveDown.toolTip = "Move rule later (lower priority)"
        moveDown.setAccessibilityLabel("Move rule later")
        enabled.target = self; enabled.action = #selector(changeAutomationEnabled)
        enabled.setAccessibilityIdentifier("stripRuleEnabled")
        for (condition, identifier) in [(bluetoothCondition, "stripBluetoothCondition"), (mediaCondition, "stripMediaCondition")] {
            condition.target = self; condition.action = #selector(changeConditions)
            condition.setAccessibilityIdentifier(identifier)
        }
        bluetoothCondition.toolTip = "All selected conditions must match. Reads an existing paired device's connection status only."
        mediaCondition.toolTip = "System Now Playing is playing. Includes supported music, video and browser media; paused media does not match. Requires a private macOS API."
        ruleName.delegate = self; ruleName.setAccessibilityIdentifier("stripRuleName")
        ruleName.setAccessibilityLabel("Automation rule name")
        device.target = self; device.action = #selector(changeDevice)
        device.setAccessibilityIdentifier("stripDevice")
        device.setAccessibilityLabel("Connected Bluetooth device")
        device.toolTip = "Match this exact paired device while it is connected to this Mac."
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshDevices))
        refresh.toolTip = "Read paired Bluetooth devices. macOS may request Bluetooth access. No scan or connection is started."
        let deviceRow = NSStackView(views: [device, refresh])
        deviceRow.alignment = .centerY; deviceRow.spacing = 8
        device.setContentHuggingPriority(.defaultLow, for: .horizontal)
        device.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        device.cell?.lineBreakMode = .byTruncatingTail
        automationStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        automationStatus.textColor = .secondaryLabelColor
        automationStatus.setAccessibilityIdentifier("stripAutomationStatus")
        editorTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        editorTitle.setAccessibilityIdentifier("stripEditorTitle")
        editorSummary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        editorSummary.textColor = .secondaryLabelColor
        editorSummary.setAccessibilityIdentifier("stripEditorSummary")
        for (field, identifier) in [(symbol, "stripSymbol"), (shortcutName, "stripShortcutName"), (destination, "stripURL")] {
            field.delegate = self
            field.setAccessibilityIdentifier(identifier)
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        }
        symbol.stringValue = config.symbol
        symbol.placeholderString = ControlStripConfiguration.defaultSymbol
        symbol.setAccessibilityLabel("Control Strip symbol")
        preview.imageScaling = .scaleProportionallyDown
        preview.contentTintColor = .labelColor
        preview.setAccessibilityElement(false)
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([preview.widthAnchor.constraint(equalToConstant: 24), preview.heightAnchor.constraint(equalToConstant: 24)])
        let reset = NSButton(title: "Default", target: self, action: #selector(resetSymbol))
        reset.setAccessibilityIdentifier("stripResetSymbol")
        reset.toolTip = "Restore the default symbol."
        let symbolRow = NSStackView(views: [preview, symbol, reset])
        symbolRow.alignment = .centerY; symbolRow.spacing = 8
        interaction.addItems(withTitles: ControlStripInteraction.allCases.map(\.title))
        interaction.target = self; interaction.action = #selector(changeInteraction)
        interaction.setAccessibilityIdentifier("stripInteraction")
        interaction.setAccessibilityLabel("Button interaction")
        interaction.toolTip = "Configure each interaction independently. Long Press uses this configuration's hold duration and does not also tap."
        longPressDuration.delegate = self
        longPressDuration.stringValue = String(config.longPressDuration)
        longPressDuration.alignment = .right
        longPressDuration.setAccessibilityIdentifier("stripLongPressDuration")
        longPressDuration.setAccessibilityLabel("Long press duration in seconds")
        longPressDuration.toolTip = "Hold duration in seconds (0.1–10). Saved independently for this configuration."
        longPressDuration.translatesAutoresizingMaskIntoConstraints = false
        longPressDuration.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let resetDuration = NSButton(title: "Default", target: self, action: #selector(resetLongPressDuration))
        resetDuration.setAccessibilityIdentifier("stripResetLongPressDuration")
        resetDuration.toolTip = "Restore 0.6 seconds."
        let durationRow = NSStackView(views: [longPressDuration, NSTextField(labelWithString: "seconds"), resetDuration])
        durationRow.alignment = .centerY; durationRow.spacing = 8
        action.addItems(withTitles: ControlStripAction.allCases.map(\.title))
        action.selectItem(at: ControlStripAction.allCases.firstIndex(of: config.action)!)
        action.target = self; action.action = #selector(changeAction)
        action.setAccessibilityIdentifier("stripAction")
        action.setAccessibilityLabel("Control Strip action")
        recorder.shortcut = config.keyboardShortcut
        recorder.onChange = { [weak self] in
            guard let self else { return }
            self.actionBinding.keyboardShortcut = self.recorder.shortcut
            self.save()
        }
        shortcutName.stringValue = config.shortcutName
        shortcutName.placeholderString = "Shortcut name or identifier"
        shortcutName.setAccessibilityLabel("Shortcut name or identifier")
        shortcutInput.addItems(withTitles: ControlStripShortcutInput.allCases.map(\.title))
        shortcutInput.selectItem(at: ControlStripShortcutInput.allCases.firstIndex(of: config.shortcutInput)!)
        shortcutInput.target = self; shortcutInput.action = #selector(changeInput)
        shortcutInput.setAccessibilityIdentifier("stripShortcutInput")
        shortcutInput.setAccessibilityLabel("Shortcut input")
        destination.stringValue = config.url
        destination.placeholderString = "https://example.com or an app URL scheme"
        destination.setAccessibilityLabel("URL to open")
        text.isRichText = false; text.allowsUndo = true
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.string = config.text; text.delegate = self
        text.setAccessibilityIdentifier("stripText")
        text.setAccessibilityLabel("Action text")
        text.isHorizontallyResizable = false; text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder; scroll.hasVerticalScroller = true
        scroll.documentView = text
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        feedback.textColor = .secondaryLabelColor
        feedback.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        feedback.setAccessibilityIdentifier("stripValidation")
        conditionFeedback.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        conditionFeedback.textColor = .secondaryLabelColor
        conditionFeedback.setAccessibilityIdentifier("stripRuleValidation")
        func section(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            return label
        }
        grid = NSGridView(views: [
            [editorTitle, NSGridCell.emptyContentView],
            [editorSummary, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Name:"), ruleName],
            [NSView(), enabled],
            [section("When all match"), NSGridCell.emptyContentView],
            [NSView(), bluetoothCondition],
            [NSTextField(labelWithString: "Device:"), deviceRow],
            [NSView(), mediaCondition],
            [NSView(), conditionFeedback],
            [section("Use this button"), NSGridCell.emptyContentView],
            [NSView(), configurationVisibility],
            [NSView(), hiddenExplanation],
            [NSTextField(labelWithString: "Symbol:"), symbolRow],
            [NSTextField(labelWithString: "Interaction:"), interaction],
            [NSTextField(labelWithString: "Hold for:"), durationRow],
            [NSTextField(labelWithString: "Action:"), action],
            [NSTextField(labelWithString: "Shortcut:"), recorder],
            [NSTextField(labelWithString: "Shortcut:"), shortcutName],
            [NSTextField(labelWithString: "Input:"), shortcutInput],
            [NSTextField(labelWithString: "Text:"), scroll],
            [NSTextField(labelWithString: "URL:"), destination],
            [NSView(), feedback]
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 72
        grid.column(at: 1).xPlacement = .fill
        grid.yPlacement = .center; grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 12; grid.columnSpacing = 12
        for row in [Row.heading, .summary, .conditionsHeading, .buttonHeading] {
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: row.rawValue, length: 1))
            grid.cell(atColumnIndex: 0, rowIndex: row.rawValue).xPlacement = .fill
            grid.row(at: row.rawValue).rowAlignment = .none
        }
        grid.row(at: Row.heading.rawValue).bottomPadding = -6
        grid.row(at: Row.summary.rawValue).bottomPadding = 6
        grid.row(at: Row.conditionsHeading.rawValue).topPadding = 8
        grid.row(at: Row.buttonHeading.rawValue).topPadding = 12
        grid.cell(atColumnIndex: 0, rowIndex: Row.text.rawValue).yPlacement = .top
        grid.row(at: Row.text.rawValue).rowAlignment = .none
        grid.row(at: Row.text.rawValue).yPlacement = .top
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSScrollView()
        container.hasVerticalScroller = true
        container.drawsBackground = false
        container.translatesAutoresizingMaskIntoConstraints = false
        let document = ControlStripSettingsDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        container.documentView = document
        // A persistent configuration list makes selection and priority visible.
        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.documentView = profiles
        listScroll.drawsBackground = false
        let listHeading = section("Configurations")
        let listHint = NSTextField(wrappingLabelWithString: "First matching rule wins, top to bottom.")
        listHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        listHint.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [removeRule, moveUp, moveDown])
        buttons.spacing = 6; buttons.alignment = .centerY
        let sidebar = NSView()
        let divider = NSBox(); divider.boxType = .separator
        let topDivider = NSBox(); topDivider.boxType = .separator
        let header = NSStackView(views: [visibility, automationStatus])
        header.orientation = .vertical; header.alignment = .leading; header.spacing = 6
        header.setContentHuggingPriority(.required, for: .vertical)
        for view in [listHeading, add, listHint, listScroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(view)
        }
        for view in [header, topDivider, sidebar, divider, container] {
            view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view)
        }
        document.addSubview(grid)
        let height = document.heightAnchor.constraint(equalTo: container.contentView.heightAnchor)
        height.priority = .defaultLow
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor),
            topDivider.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            topDivider.heightAnchor.constraint(equalToConstant: 1),
            sidebar.leadingAnchor.constraint(equalTo: leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            sidebar.bottomAnchor.constraint(equalTo: bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 236),
            listHeading.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 16),
            listHeading.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 18),
            add.topAnchor.constraint(equalTo: listHeading.bottomAnchor, constant: 12),
            add.leadingAnchor.constraint(equalTo: listHeading.leadingAnchor),
            listHint.leadingAnchor.constraint(equalTo: listHeading.leadingAnchor),
            listHint.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -16),
            listHint.topAnchor.constraint(equalTo: add.bottomAnchor, constant: 10),
            listScroll.topAnchor.constraint(equalTo: listHint.bottomAnchor, constant: 10),
            listScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            listScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -8),
            listScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            buttons.leadingAnchor.constraint(equalTo: listHeading.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -16),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: sidebar.topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            document.widthAnchor.constraint(equalTo: container.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: container.contentView.heightAnchor), height,
            grid.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -24)
        ])
        refreshProfiles()
        updateFields()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateFields() {
        let config = configuration
        let binding = actionBinding
        grid.row(at: Row.keyboard.rawValue).isHidden = binding.action != .keyboardShortcut
        grid.row(at: Row.shortcutName.rawValue).isHidden = binding.action != .runShortcut
        grid.row(at: Row.input.rawValue).isHidden = binding.action != .runShortcut
        grid.row(at: Row.text.rawValue).isHidden = !(binding.action == .pasteText || binding.action == .copyText ||
            (binding.action == .runShortcut && binding.shortcutInput == .text))
        grid.row(at: Row.url.rawValue).isHidden = binding.action != .openURL
        for row in [Row.keyboard, .shortcutName, .input, .text, .url] where !config.showsButton {
            grid.row(at: row.rawValue).isHidden = true
        }
        grid.row(at: Row.symbol.rawValue).isHidden = !config.showsButton
        grid.row(at: Row.action.rawValue).isHidden = !config.showsButton
        grid.row(at: Row.interaction.rawValue).isHidden = !config.showsButton
        grid.row(at: Row.duration.rawValue).isHidden = !config.showsButton || selectedInteraction != .longPress
        grid.row(at: Row.hiddenExplanation.rawValue).isHidden = config.showsButton
        for row in [Row.enabled, .ruleName, .conditionsHeading, .bluetooth, .media, .buttonHeading] { grid.row(at: row.rawValue).isHidden = selectedRuleIndex == nil }
        grid.row(at: Row.device.rawValue).isHidden = selectedRuleIndex.map { !store.controlStripAutomationRules[$0].bluetoothConnected } ?? true
        editorTitle.stringValue = selectedRuleIndex == nil ? "Default Button" : "Automation Rule"
        editorSummary.stringValue = selectedRuleIndex == nil ? "Used when no automation matches." : "Use this configuration while all selected conditions match."
        preview.image = NSImage(systemSymbolName: config.symbol, accessibilityDescription: nil)
        conditionFeedback.stringValue = selectedRuleIndex == nil ? "" : (conditionError ?? ruleValidation ?? "")
        grid.row(at: Row.conditionFeedback.rawValue).isHidden = conditionFeedback.stringValue.isEmpty
        feedback.stringValue = config.showsButton ? (symbolError ?? (selectedInteraction == .longPress ? durationError : nil) ?? binding.validationMessage ?? actionError ?? "") : ""
        grid.row(at: Row.feedback.rawValue).isHidden = feedback.stringValue.isEmpty
    }
    func showActionError(_ message: String?) { actionError = message; updateFields() }
    private func save() {
        actionError = nil; store.save(); updateFields(); updateProfileSummaries()
        showActiveAutomation(activeName, buttonVisible: activeButtonVisible, playbackUnavailable: playbackUnavailable)
    }
    @objc private func changeVisibility() {
        store.showControlStripButton = visibility.state == .on; save()
    }
    @objc private func changeConfigurationVisibility() {
        configuration.showsButton = configurationVisibility.state == .on
        save()
    }
    @objc private func resetSymbol() {
        symbol.stringValue = ControlStripConfiguration.defaultSymbol
        configuration.symbol = symbol.stringValue
        symbolError = nil; save()
    }
    @objc private func changeAction() {
        guard ControlStripAction.allCases.indices.contains(action.indexOfSelectedItem) else { return }
        actionBinding.action = ControlStripAction.allCases[action.indexOfSelectedItem]; save()
    }
    @objc private func changeInteraction() {
        guard ControlStripInteraction.allCases.indices.contains(interaction.indexOfSelectedItem) else { return }
        window?.makeFirstResponder(nil)
        selectedInteraction = ControlStripInteraction.allCases[interaction.indexOfSelectedItem]
        actionError = nil; durationError = nil; loadActionFields(); updateFields()
    }
    @objc private func resetLongPressDuration() {
        configuration.longPressDuration = ControlStripConfiguration.defaultLongPressDuration
        longPressDuration.stringValue = String(configuration.longPressDuration)
        durationError = nil; save()
    }
    @objc private func changeInput() {
        guard ControlStripShortcutInput.allCases.indices.contains(shortcutInput.indexOfSelectedItem) else { return }
        actionBinding.shortcutInput = ControlStripShortcutInput.allCases[shortcutInput.indexOfSelectedItem]; save()
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === symbol {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
                symbolError = "Enter a valid SF Symbol name."; updateFields(); return
            }
            symbolError = nil; configuration.symbol = name
        } else if field === longPressDuration {
            guard let value = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ControlStripConfiguration.isValidLongPressDuration(value) else {
                durationError = "Enter a duration from 0.1 to 10 seconds."; updateFields(); return
            }
            durationError = nil; configuration.longPressDuration = value
        } else if field === shortcutName { actionBinding.shortcutName = field.stringValue }
        else if field === destination { actionBinding.url = field.stringValue }
        else if field === ruleName, let index = selectedRuleIndex {
            store.controlStripAutomationRules[index].name = field.stringValue
        }
        else { return }
        save()
    }
    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === text else { return }
        actionBinding.text = text.string; save()
    }

    private var ruleValidation: String? {
        guard let index = selectedRuleIndex else { return nil }
        let rule = store.controlStripAutomationRules[index]
        if !rule.hasConditions { return "Select at least one condition. Selected conditions must all match." }
        return rule.bluetoothConnected && rule.deviceAddress.isEmpty ? "Choose a paired device using Refresh." : nil
    }
    private func refreshProfiles() {
        changingSelection = true
        profiles.reloadData()
        let row = selectedRuleIndex.map { $0 + 1 } ?? 0
        profiles.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        profiles.scrollRowToVisible(row)
        changingSelection = false
        removeRule.isEnabled = selectedRuleIndex != nil
        moveUp.isEnabled = (selectedRuleIndex ?? 0) > 0
        moveDown.isEnabled = selectedRuleIndex.map { $0 + 1 < store.controlStripAutomationRules.count } ?? false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { store.controlStripAutomationRules.count + 1 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("stripConfigurationRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? ControlStripConfigurationCell
            ?? ControlStripConfigurationCell()
        cell.identifier = identifier
        configure(cell, row: row)
        return cell
    }
    private func configure(_ cell: ControlStripConfigurationCell, row: Int) {
        if row == 0 {
            let config = store.controlStripConfiguration
            cell.update(title: "Default", summary: config.showsButton ? "When no rule matches" : "Fallback · Button hidden",
                        symbol: config.showsButton ? config.symbol : "eye.slash")
        } else if store.controlStripAutomationRules.indices.contains(row - 1) {
            let rule = store.controlStripAutomationRules[row - 1]
            var conditions: [String] = []
            if rule.bluetoothConnected { conditions.append(rule.deviceName.isEmpty ? "Choose device" : "\(rule.deviceName) connected") }
            if rule.mediaPlaying { conditions.append("Media playing") }
            let condition = conditions.isEmpty ? "No conditions" : conditions.joined(separator: " + ")
            let state = !rule.enabled ? "Off" : (rule.hasValidConditions ? "On" : "Needs setup")
            let visibility = rule.configuration.showsButton ? "" : " · Button hidden"
            cell.update(title: "\(row). \(rule.name.isEmpty ? "Automation Rule" : rule.name)",
                        summary: "\(state)\(visibility) · \(condition)", symbol: rule.configuration.showsButton ? rule.configuration.symbol : "eye.slash")
        }
    }
    private func updateProfileSummaries() {
        for row in 0..<numberOfRows(in: profiles) {
            if let cell = profiles.view(atColumn: 0, row: row, makeIfNecessary: false) as? ControlStripConfigurationCell {
                configure(cell, row: row)
            }
        }
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row > 0, store.controlStripAutomationRules.indices.contains(row - 1) else { return nil }
        let item = NSPasteboardItem()
        item.setString(store.controlStripAutomationRules[row - 1].id.uuidString, forType: Self.rulePasteboardType)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard info.draggingSource as? NSTableView === profiles, operation == .above,
              row >= 1, row <= numberOfRows(in: profiles),
              let raw = info.draggingPasteboard.string(forType: Self.rulePasteboardType), let id = UUID(uuidString: raw),
              store.controlStripAutomationRules.contains(where: { $0.id == id }) else { return [] }
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard self.tableView(tableView, validateDrop: info, proposedRow: row, proposedDropOperation: dropOperation) == .move,
              let raw = info.draggingPasteboard.string(forType: Self.rulePasteboardType), let id = UUID(uuidString: raw) else { return false }
        return moveRule(id: id, to: row - 1)
    }
    @discardableResult private func moveRule(id: UUID, to insertionIndex: Int) -> Bool {
        guard let source = store.controlStripAutomationRules.firstIndex(where: { $0.id == id }),
              (0...store.controlStripAutomationRules.count).contains(insertionIndex) else { return false }
        window?.makeFirstResponder(nil)
        let rule = store.controlStripAutomationRules.remove(at: source)
        store.controlStripAutomationRules.insert(rule, at: insertionIndex > source ? insertionIndex - 1 : insertionIndex)
        selectedRuleID = rule.id
        refreshProfiles(); loadConfiguration(); save()
        return true
    }
    private func loadConfiguration() {
        symbolError = nil; actionError = nil; conditionError = nil; durationError = nil
        let config = configuration
        configurationVisibility.state = config.showsButton ? .on : .off
        symbol.stringValue = config.symbol
        loadActionFields()
        if let index = selectedRuleIndex {
            enabled.state = store.controlStripAutomationRules[index].enabled ? .on : .off
            ruleName.stringValue = store.controlStripAutomationRules[index].name
            bluetoothCondition.state = store.controlStripAutomationRules[index].bluetoothConnected ? .on : .off
            mediaCondition.state = store.controlStripAutomationRules[index].mediaPlaying ? .on : .off
        }
        updateDeviceMenu(); updateFields()
    }
    private func loadActionFields() {
        let binding = actionBinding
        longPressDuration.stringValue = String(configuration.longPressDuration)
        interaction.selectItem(at: ControlStripInteraction.allCases.firstIndex(of: selectedInteraction)!)
        text.string = binding.text; recorder.shortcut = binding.keyboardShortcut
        shortcutName.stringValue = binding.shortcutName; destination.stringValue = binding.url
        action.selectItem(at: ControlStripAction.allCases.firstIndex(of: binding.action)!)
        shortcutInput.selectItem(at: ControlStripShortcutInput.allCases.firstIndex(of: binding.shortcutInput)!)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !changingSelection else { return }
        window?.makeFirstResponder(nil)
        let index = profiles.selectedRow - 1
        selectedRuleID = store.controlStripAutomationRules.indices.contains(index) ? store.controlStripAutomationRules[index].id : nil
        refreshProfiles(); loadConfiguration()
    }
    @objc private func addAutomation() {
        window?.makeFirstResponder(nil)
        var rule = ControlStripAutomationRule()
        rule.configuration = store.controlStripConfiguration
        rule.name = "Automation Rule \(store.controlStripAutomationRules.count + 1)"
        store.controlStripAutomationRules.append(rule); selectedRuleID = rule.id
        refreshProfiles(); loadConfiguration(); save()
    }
    @objc private func removeAutomation() {
        window?.makeFirstResponder(nil)
        guard let index = selectedRuleIndex else { return }
        store.controlStripAutomationRules.remove(at: index); selectedRuleID = nil
        refreshProfiles(); loadConfiguration(); save()
    }
    @objc private func moveAutomationUp() { moveAutomation(by: -1) }
    @objc private func moveAutomationDown() { moveAutomation(by: 1) }
    private func moveAutomation(by offset: Int) {
        window?.makeFirstResponder(nil)
        guard let index = selectedRuleIndex, store.controlStripAutomationRules.indices.contains(index + offset) else { return }
        store.controlStripAutomationRules.swapAt(index, index + offset)
        refreshProfiles(); save()
    }
    @objc private func changeAutomationEnabled() {
        guard let index = selectedRuleIndex else { return }
        store.controlStripAutomationRules[index].enabled = enabled.state == .on; save()
    }
    @objc private func changeConditions() {
        guard let index = selectedRuleIndex else { return }
        store.controlStripAutomationRules[index].bluetoothConnected = bluetoothCondition.state == .on
        store.controlStripAutomationRules[index].mediaPlaying = mediaCondition.state == .on
        conditionError = nil
        save()
    }
    @objc private func refreshDevices() {
        knownDevices = deviceReader(); updateDeviceMenu()
        if CBManager.authorization == .denied || CBManager.authorization == .restricted {
            conditionError = "Allow TouchBarEnhancer in Privacy & Security → Bluetooth to read connection status."
        } else if knownDevices.isEmpty { conditionError = "No paired devices found. Pair the device in macOS Bluetooth settings first." }
        else { conditionError = nil }
        updateFields()
    }
    private func updateDeviceMenu() {
        device.removeAllItems(); device.addItem(withTitle: "Choose Device…")
        for paired in knownDevices {
            let item = NSMenuItem(title: "\(paired.name) — \(paired.connected ? "Connected" : "Disconnected")", action: nil, keyEquivalent: "")
            item.representedObject = paired.address
            device.menu?.addItem(item)
        }
        guard let index = selectedRuleIndex else { return }
        let rule = store.controlStripAutomationRules[index]
        guard !rule.deviceAddress.isEmpty else { return }
        if let position = knownDevices.firstIndex(where: { $0.identifier == ControlStripBluetoothDevice.normalizedAddress(rule.deviceAddress) }) {
            device.selectItem(at: position + 1)
        } else {
            let item = NSMenuItem(title: "\(rule.deviceName.isEmpty ? "Saved Device" : rule.deviceName) — Saved", action: nil, keyEquivalent: "")
            item.representedObject = rule.deviceAddress; device.menu?.addItem(item); device.select(item)
        }
    }
    @objc private func changeDevice() {
        guard let index = selectedRuleIndex else { return }
        let address = device.selectedItem?.representedObject as? String ?? ""
        store.controlStripAutomationRules[index].deviceAddress = address
        store.controlStripAutomationRules[index].deviceName = knownDevices.first {
            $0.identifier == ControlStripBluetoothDevice.normalizedAddress(address)
        }?.name ?? store.controlStripAutomationRules[index].deviceName
        conditionError = nil
        save()
    }
    func showActiveAutomation(_ name: String?, buttonVisible: Bool = true, playbackUnavailable: Bool = false) {
        activeName = name; activeButtonVisible = buttonVisible; self.playbackUnavailable = playbackUnavailable
        var status = name.map { "Currently using: \($0.isEmpty ? "Automation Rule" : $0)" } ?? "Currently using: Default"
        if !buttonVisible { status += " · Button hidden" }
        if !store.showControlStripButton { status = "Control Strip button disabled" }
        if store.showControlStripButton && playbackUnavailable { status += " · Playback status unavailable" }
        let bluetoothUnavailable = store.showControlStripButton && store.controlStripAutomationRules.contains {
            $0.enabled && $0.hasValidConditions && $0.bluetoothConnected
        } && (CBManager.authorization == .denied || CBManager.authorization == .restricted)
        if bluetoothUnavailable { status += " · Allow Bluetooth access in Privacy & Security" }
        automationStatus.stringValue = status
    }
}

@MainActor
private final class ControlStripConfigurationCell: NSTableCellView {
    private let title = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let symbol = NSImageView()

    init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        title.textColor = .labelColor
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        for label in [title, summary] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        textField = title; imageView = symbol
        symbol.contentTintColor = .labelColor
        symbol.imageScaling = .scaleProportionallyDown
        let labels = NSStackView(views: [title, summary])
        labels.orientation = .vertical; labels.alignment = .leading; labels.spacing = 3
        for view in [symbol, labels] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            symbol.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 18), symbol.heightAnchor.constraint(equalToConstant: 20),
            labels.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.widthAnchor.constraint(equalTo: labels.widthAnchor),
            summary.widthAnchor.constraint(equalTo: labels.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(title: String, summary: String, symbol: String) {
        self.title.stringValue = title; self.summary.stringValue = summary
        self.symbol.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        toolTip = "\(title)\n\(summary)"
        setAccessibilityLabel("\(title), \(summary)")
    }
}

@MainActor
private final class ControlStripSettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Executes only an explicit tap. Shortcuts runs asynchronously without a shell
/// or an app activation; temporary input/error files belong to that invocation.
@MainActor
final class ControlStripActionRunner {
    var onError: ((String) -> Void)?
    var sendKeyboard: (KeyboardShortcut?, String) -> String? = { KeyboardShortcutSender.send($0, to: $1) }
    var pasteText: (String, String) -> String? = { QuickPhrasePaster.paste($0, into: $1) }
    var openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    // Injected by AppDelegate so native editor tests never control playback.
    var skipMedia: (_ forward: Bool) -> Bool = { _ in false }
    var targetBundleID: () -> String? = {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app.bundleIdentifier
    }
    private var jobs: [UUID: Process] = [:]
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func perform(_ configuration: ControlStripConfiguration, interaction: ControlStripInteraction = .tap, toggle: () -> Void) {
        guard configuration.showsButton else { return }
        let config = configuration.binding(for: interaction)
        if let message = config.validationMessage { onError?(message); return }
        switch config.action {
        case .none: return
        case .toggleEnhancement: toggle()
        case .pasteClipboard:
            guard !(pasteboard.pasteboardItems ?? []).isEmpty else { onError?("The clipboard is empty."); return }
            // Send Paste without rewriting the clipboard, preserving images/files.
            withTarget { sendKeyboard(.init(keyCode: 9, modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "V"), $0) }
        case .pasteText: withTarget { pasteText(config.text, $0) }
        case .copyText:
            pasteboard.clearContents()
            if !pasteboard.setString(config.text, forType: .string) { onError?("Could not copy the text to the clipboard.") }
        case .keyboardShortcut: withTarget { sendKeyboard(config.keyboardShortcut, $0) }
        case .runShortcut: runShortcut(config)
        case .openURL:
            if let url = URL(string: config.url), !openURL(url) { onError?("No application could open this URL.") }
        case .previousMedia, .nextMedia:
            if !skipMedia(config.action == .nextMedia) {
                onError?("The system could not accept the media command.")
            }
        }
    }

    private func withTarget(_ action: (String) -> String?) {
        guard let bundleID = targetBundleID() else {
            onError?("Focus the target app before using this action."); return
        }
        // The shared sender/paster also checks permission and foreground PID
        // immediately before posting events or modifying the clipboard.
        if let message = action(bundleID) { onError?(message) }
    }

    private func runShortcut(_ config: ControlStripActionBinding) {
        let input: String?
        switch config.shortcutInput {
        case .none: input = nil
        case .text: input = config.text
        case .clipboard:
            guard let value = pasteboard.string(forType: .string) else { onError?("The clipboard has no text to pass to the shortcut."); return }
            input = value
        }
        let id = UUID()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TouchBarEnhancer-Shortcut-\(id.uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            var inputPath: String?
            if let input {
                let file = directory.appendingPathComponent("input.txt")
                try Data(input.utf8).write(to: file, options: .atomic)
                inputPath = file.path
            }
            let errors = directory.appendingPathComponent("stderr.txt")
            FileManager.default.createFile(atPath: errors.path, contents: nil)
            let errorHandle = try FileHandle(forWritingTo: errors)
            defer { try? errorHandle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = config.shortcutArguments(inputPath: inputPath)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorHandle
            process.terminationHandler = { [weak self] finished in
                let status = finished.terminationStatus
                Task { @MainActor in
                    defer { try? FileManager.default.removeItem(at: directory) }
                    self?.jobs.removeValue(forKey: id)
                    guard status != 0 else { return }
                    let handle = try? FileHandle(forReadingFrom: errors)
                    defer { try? handle?.close() }
                    let data = (try? handle?.read(upToCount: 4096)) ?? Data()
                    let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    self?.onError?(message.isEmpty ? "The shortcut failed (exit \(status))." : message)
                }
            }
            jobs[id] = process
            do { try process.run() }
            catch { jobs.removeValue(forKey: id); throw error }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            onError?("Could not run the shortcut: \(error.localizedDescription)")
        }
    }
}
