import AppKit
import ApplicationServices

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
    var keyLabel: String

    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return (flags.contains(.control) ? "⌃" : "")
            + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "")
            + (flags.contains(.command) ? "⌘" : "") + keyLabel
    }

    static let modifierMask: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
    static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    init(keyCode: UInt16, modifiers: UInt, keyLabel: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        guard !Self.modifierKeyCodes.contains(event.keyCode) else { return nil }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            76: "⌤", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            123: "←", 124: "→", 125: "↓", 126: "↑", 122: "F1", 120: "F2", 99: "F3",
            118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16",
            64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        guard let label = special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(), !label.isEmpty else { return nil }
        self.init(keyCode: event.keyCode,
            modifiers: event.modifierFlags.intersection(Self.modifierMask).rawValue, keyLabel: label)
    }
}

struct KeyboardButton: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var symbol = "keyboard"
    var imageData: Data?
    var color = ""
    var shortcut: KeyboardShortcut?
    var description = ""
    var displayModeOverride: ComponentDisplayMode?
    var fillWidth: ComponentItemWidth?

    var scrollingItem: ScrollingComponentItem {
        let key = shortcut?.display ?? "No shortcut"
        let detail = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let background = color.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollingComponentItem(title: title, symbol: symbol, imageData: imageData,
            background: background.isEmpty || background.uppercased() == "#363636" ? .standard : .color(background),
            accessibilityLabel: "\(title), \(key)",
            toolTip: detail.isEmpty ? "\(title) · \(key)" : "\(detail) · \(key)", displayModeOverride: displayModeOverride, fillWidth: fillWidth)
    }

    var displayShortcut: ChatShortcut {
        ChatShortcut(id: id, name: title, symbol: symbol, imageData: imageData, color: color,
            displayModeOverride: displayModeOverride, fillWidth: fillWidth)
    }
}

struct KeyboardButtonsConfiguration: Codable, Equatable {
    typealias Layout = ComponentLayout
    var buttons: [KeyboardButton] = []
    var layout: Layout = .scrolling
    var alignment: ScrollingComponentAlignment = .left
}

/// Captures only while this Settings control is the first responder. No event tap.
@MainActor
final class KeyboardShortcutRecorder: NSButton {
    var shortcut: KeyboardShortcut? { didSet { updateTitle() } }
    private(set) var isRecording = false
    var onChange: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self; action = #selector(beginRecording)
        setAccessibilityLabel("Record keyboard shortcut")
        toolTip = "Click and press a shortcut. Escape cancels; Delete clears."
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func updateTitle() { title = isRecording ? "Press Shortcut…" : shortcut?.display ?? "Record Shortcut…" }
    @objc private func beginRecording() {
        guard window?.makeFirstResponder(self) == true else { return }
        isRecording = true; updateTitle()
    }
    override func resignFirstResponder() -> Bool {
        isRecording = false; updateTitle()
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 && modifiers.isEmpty { finish(); return }
        if event.keyCode == 51 && modifiers.isEmpty { shortcut = nil; finish(); onChange?(); return }
        guard let captured = KeyboardShortcut(event: event) else { return }
        shortcut = captured; finish(); onChange?()
    }
    private func finish() { isRecording = false; updateTitle() }
}

@MainActor
enum KeyboardShortcutSender {
    static func events(for shortcut: KeyboardShortcut) -> (CGEvent, CGEvent)? {
        guard shortcut.keyCode <= 127, !KeyboardShortcut.modifierKeyCodes.contains(shortcut.keyCode),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) else { return nil }
        let flags = CGEventFlags(rawValue: UInt64(shortcut.modifiers & KeyboardShortcut.modifierMask.rawValue))
        down.flags = flags; up.flags = flags
        return (down, up)
    }

    static func send(_ shortcut: KeyboardShortcut?, to bundleID: String) -> String? {
        guard let shortcut else { return "Record a shortcut for this button first." }
        guard AXIsProcessTrusted() else { return "Allow TouchBarEnhancer in Accessibility first." }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return "Bring the target app to the front before using this shortcut."
        }
        guard let (down, up) = events(for: shortcut) else { return "This shortcut cannot be sent." }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            return "The active app changed. Try again."
        }
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
        return nil
    }
}

@MainActor
final class KeyboardButtonsComponent {
    let scroller = ShortcutScroller(label: "Keyboard Shortcuts", alignsContent: true)
    var region: ScrollingComponentRegion { scroller.scrollRegion }
    private var configuration: KeyboardButtonsConfiguration?
    private let targetBundleID: String
    var onError: ((String) -> Void)?
    var onSelect: ((KeyboardButton) -> Void)?

    init(targetBundleID: String, configuration: KeyboardButtonsConfiguration) {
        self.targetBundleID = targetBundleID
        scroller.onSelect = { [weak self] index in self?.select(index) }
        configure(configuration)
    }

    func configure(_ configuration: KeyboardButtonsConfiguration) {
        guard self.configuration != configuration else { return }
        self.configuration = configuration
        scroller.fillsAvailableWidth = configuration.layout == .fill
        scroller.alignment = configuration.alignment
        scroller.configure(configuration.buttons.map(\.scrollingItem))
    }
    private func select(_ index: Int) {
        guard let buttons = configuration?.buttons, buttons.indices.contains(index) else { return }
        let button = buttons[index]
        if let onSelect { onSelect(button); return }
        if let error = KeyboardShortcutSender.send(button.shortcut, to: targetBundleID) { onError?(error) }
    }
}
