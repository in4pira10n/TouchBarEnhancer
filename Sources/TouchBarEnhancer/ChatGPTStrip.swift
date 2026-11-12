import AppKit

@MainActor
final class ChatSideButtonCell: NSButtonCell {
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        isHighlighted = flag
        controlView.needsDisplay = true
        controlView.displayIfNeeded()
    }
}

/// Keep NSButton's action and tracking, without its Touch Bar bezel's alignment overhang.
@MainActor
final class ChatSideButton: NSButton {
    static let normalBackground = NSColor(srgbRed: 54 / 255, green: 54 / 255, blue: 54 / 255, alpha: 1)
    static let pressedBackground = NSColor(srgbRed: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1)
    override class var cellClass: AnyClass? {
        get { ChatSideButtonCell.self }
        set { super.cellClass = newValue }
    }
    var fillsImageHeight = false
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
        displayIfNeeded()
    }
    override func draw(_ dirtyRect: NSRect) {
        let background = isHighlighted ? Self.pressedBackground : Self.normalBackground
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        guard let image else { return }
        let size = image.size
        let scale = bounds.height / max(size.height, 1)
        let fullHeightRect = NSRect(x: (bounds.width - size.width * scale) / 2,
                            y: (bounds.height - size.height * scale) / 2,
                            width: size.width * scale, height: size.height * scale)
        // Preserve the system image's intrinsic size, while drawing at full opacity even
        // when our system-modal bar belongs to a background application.
        let nativeRect = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                width: size.width, height: size.height)
        let target = fillsImageHeight ? fullHeightRect : nativeRect
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }
}

struct ChatShortcut: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var symbol: String = "message"
    var imageData: Data? = nil
    var color: String = "blue"
    var slot: Int = 1
    var displayModeOverride: ComponentDisplayMode?
    var fillWidth: ComponentItemWidth?
    var scrollingItem: ScrollingComponentItem {
        ScrollingComponentItem(title: name, symbol: symbol, imageData: imageData, background: .color(color),
            accessibilityLabel: "\(name), Control + \(slot)", toolTip: "\(name) · Control + \(slot)",
            displayModeOverride: displayModeOverride, fillWidth: fillWidth)
    }
    static let initial = (1...4).map { ChatShortcut(name: "Chat \($0)", color: ["blue", "teal", "orange", "orange"][$0 - 1], slot: $0) }
}

@MainActor
enum ChatColor {
    static func resolve(_ text: String) -> NSColor? {
        let names: [String: NSColor] = ["blue": .systemBlue, "teal": .systemTeal, "cyan": .systemCyan,
            "orange": .systemOrange, "red": .systemRed, "green": .systemGreen, "yellow": .systemYellow,
            "purple": .systemPurple, "pink": .systemPink, "indigo": .systemIndigo, "gray": .systemGray,
            "grey": .systemGray, "brown": .systemBrown, "black": .black, "white": .white]
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let color = names[value] { return color }
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((number >> 16) & 255) / 255,
                       green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
    }
    static func hex(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#0088FF" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}

@MainActor
final class ChatGPTStrip: NSObject, NSScrubberDataSource, NSScrubberFlowLayoutDelegate {
    static let sideControlWidth: CGFloat = 75
    static let chatViewportWidth: CGFloat = 510
    static let blockGap: CGFloat = 12

    let sidebar = ChatSideButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")!, target: nil, action: nil)
    let terminal = ChatSideButton(title: "", target: nil, action: nil)
    let sidebarContainer = NSView()
    let terminalContainer = NSView()
    private let sidebarBackground = NSView()
    private let terminalBackground = NSView()
    let scroller = ShortcutScroller(label: "Chat Shortcuts")
    var scrubber: NSScrubber { scroller.scrubber }
    var scrollRegion: ScrollingComponentRegion { scroller.scrollRegion }
    private var shortcuts: [ChatShortcut] = []
    private let adapter: ChatGPTAdapter
    var onSelectSlot: ((Int) -> Void)?
    var onToggleSidebar: (() -> Void)?
    var onToggleTerminal: (() -> Void)?

    init(adapter: ChatGPTAdapter, shortcuts: [ChatShortcut]) {
        self.adapter = adapter
        super.init()
        configureSideControl(sidebar, in: sidebarContainer, background: sidebarBackground)
        let sidebarConfiguration = NSImage.SymbolConfiguration(pointSize: 19, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        sidebar.image = sidebar.image?.withSymbolConfiguration(sidebarConfiguration)
        sidebar.target = self; sidebar.action = #selector(toggleSidebar)
        sidebar.setAccessibilityLabel("Toggle Sidebar")
        terminal.image = Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent("Images/chatgpt.terminal.png")) }
            ?? NSImage(contentsOfFile: "Resources/Images/chatgpt.terminal.png")
        terminal.imagePosition = .imageOnly
        terminal.fillsImageHeight = true
        terminal.imageScaling = .scaleProportionallyDown
        configureSideControl(terminal, in: terminalContainer, background: terminalBackground)
        terminal.target = self; terminal.action = #selector(toggleTerminal)
        terminal.setAccessibilityLabel("Toggle Terminal Panel")
        scroller.onSelect = { [weak self] index in
            guard let self else { return }
            self.scrubber(self.scrubber, didSelectItemAt: index)
        }
        configure(shortcuts)
    }

    private func configureSideControl(_ button: NSButton, in container: NSView, background: NSView) {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(background)
        container.addSubview(button)
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.backgroundColor = ChatSideButton.normalBackground.cgColor
        background.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.contentTintColor = .white
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.sideControlWidth),
            container.heightAnchor.constraint(equalToConstant: 30),
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    func configure(_ shortcuts: [ChatShortcut]) {
        guard self.shortcuts != shortcuts else { return }
        self.shortcuts = shortcuts
        scroller.configure(shortcuts.map(\.scrollingItem))
    }
    func numberOfItems(for scrubber: NSScrubber) -> Int { shortcuts.count }
    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        scroller.scrubber(scrubber, viewForItemAt: index)
    }
    nonisolated func scrubber(_ scrubber: NSScrubber, layout: NSScrubberFlowLayout, sizeForItemAt index: Int) -> NSSize {
        MainActor.assumeIsolated {
            scroller.scrubber(scrubber, layout: layout, sizeForItemAt: index)
        }
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt selectedIndex: Int) {
        guard shortcuts.indices.contains(selectedIndex) else { return }
        let slot = shortcuts[selectedIndex].slot
        if let onSelectSlot { onSelectSlot(slot) }
        else { adapter.selectChat(slot: slot) { Self.report($0) } }
        scrubber.selectedIndex = -1
    }
    func update(_ state: ChatGPTAdapter.Snapshot) {
        sidebar.toolTip = state.entry(for: .sidebar)?.enabled == true ? "Toggle Sidebar" : "Toggle Sidebar · \(state.summary)"
        terminal.toolTip = state.entry(for: .terminalPanel)?.enabled == true ? "Toggle Terminal Panel" : "Toggle Terminal Panel · \(state.summary)"
        sidebar.state = state.sidebarVisible == true ? .on : .off
        if let visible = state.sidebarVisible {
            sidebar.toolTip = visible ? "Hide Sidebar" : "Show Sidebar"
        }
    }
    @objc private func toggleSidebar() {
        if let onToggleSidebar { onToggleSidebar(); return }
        adapter.perform(.sidebar) { Self.report($0) }
    }
    @objc private func toggleTerminal() {
        if let onToggleTerminal { onToggleTerminal(); return }
        adapter.perform(.terminalPanel) { Self.report($0) }
    }
    private static func report(_ error: String?) {
        guard let error else { return }
        let alert = NSAlert(); alert.messageText = "ChatGPT Control Unavailable"; alert.informativeText = error
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}
