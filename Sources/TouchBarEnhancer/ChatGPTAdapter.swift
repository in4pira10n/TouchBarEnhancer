import AppKit
import ApplicationServices

enum ChatGPTCommand: String, CaseIterable {
    case newChat, temporaryChat, sidebar, previousItem, nextItem, terminalPanel, openTerminal

    var title: String {
        switch self {
        case .newChat: "New Chat"
        case .temporaryChat: "Temporary Chat"
        case .sidebar: "Sidebar"
        case .previousItem: "Previous Item"
        case .nextItem: "Next Item"
        case .terminalPanel: "Terminal Panel"
        case .openTerminal: "Open Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .newChat: "square.and.pencil"
        case .temporaryChat: "bubble.left.and.bubble.right"
        case .sidebar: "sidebar.left"
        case .previousItem: "chevron.up"
        case .nextItem: "chevron.down"
        case .terminalPanel, .openTerminal: "terminal"
        }
    }

    var detail: String {
        switch self {
        case .newChat: "Start a new chat."
        case .temporaryChat: "Start a new temporary chat, when available."
        case .sidebar: "Show or hide the sidebar."
        case .previousItem: "Select the previous sidebar item, including chats."
        case .nextItem: "Select the next sidebar item, including chats."
        case .terminalPanel: "Show or hide the bottom panel using Toggle Bottom Panel."
        case .openTerminal: "Open or focus the terminal using Open Terminal."
        }
    }

    var menuTitles: [String] {
        switch self {
        case .newChat: ["New Chat", "新建聊天", "新聊天"]
        case .temporaryChat: ["New Temporary Chat", "新建临时聊天", "新临时聊天"]
        case .sidebar: ["Toggle Sidebar", "切换侧边栏", "显示侧边栏", "隐藏侧边栏"]
        case .previousItem: ["Previous Sidebar Item", "上一个侧边栏项目"]
        case .nextItem: ["Next Sidebar Item", "下一个侧边栏项目"]
        case .terminalPanel: ["Toggle Bottom Panel", "切换底部面板"]
        case .openTerminal: ["Open Terminal", "打开终端"]
        }
    }
}

/// Reads only app menus. No key synthesis, chat contents, credentials or network API.
@MainActor
final class ChatGPTAdapter {
    struct MenuEntry {
        let title: String
        let enabled: Bool
        let element: AXUIElement
    }

    struct Snapshot {
        let trusted: Bool
        let running: Bool
        let entries: [MenuEntry]
        var sidebarVisible: Bool? = nil

        func entry(for command: ChatGPTCommand) -> MenuEntry? {
            entries.first { command.menuTitles.contains($0.title) }
        }

        var summary: String {
            if !trusted { return "Accessibility access needed" }
            if !running { return "ChatGPT is not running" }
            let count = ChatGPTCommand.allCases.filter { entry(for: $0) != nil }.count
            return count == 0 ? "App menus unavailable" : "Connected · \(count) menu actions found"
        }
    }

    let bundleID: String
    init(bundleID: String) { self.bundleID = bundleID }

    func snapshot() -> Snapshot {
        let running = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
        guard AXIsProcessTrusted() else { return Snapshot(trusted: false, running: running != nil, entries: []) }
        guard let running else { return Snapshot(trusted: true, running: false, entries: []) }
        let application = AXUIElementCreateApplication(running.processIdentifier)
        // Bound unresponsive-app IPC on the main thread. Never walk the document tree.
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let value = Self.attribute(application, kAXMenuBarAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return Snapshot(trusted: true, running: true, entries: [])
        }
        let menuBar = value as! AXUIElement
        var entries: [MenuEntry] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        // Skip the system Apple menu. Commands live in the app's top-level menus.
        for topLevel in Self.children(menuBar).dropFirst().prefix(12) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { break }
            guard let name = Self.attribute(topLevel, kAXTitleAttribute) as? String,
                  ["File", "View", "文件", "显示", "视图"].contains(name) else { continue }
            for menu in Self.children(topLevel).prefix(1) {
                for item in Self.children(menu).prefix(100) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    guard let title = Self.attribute(item, kAXTitleAttribute) as? String,
                          ChatGPTCommand.allCases.contains(where: { $0.menuTitles.contains(title) }) else { continue }
                    let enabled = Self.attribute(item, kAXEnabledAttribute) as? Bool ?? false
                    entries.append(MenuEntry(title: title, enabled: enabled, element: item))
                }
            }
        }
        var sidebarVisible: Bool?
        if let sidebar = entries.first(where: { ChatGPTCommand.sidebar.menuTitles.contains($0.title) }) {
            if let mark = Self.attribute(sidebar.element, "AXMenuItemMarkChar") as? String, !mark.isEmpty { sidebarVisible = true }
            if sidebar.title == "隐藏侧边栏" { sidebarVisible = true }
            if sidebar.title == "显示侧边栏" { sidebarVisible = false }
        }
        // Read explicit toggle button labels only; never guess visibility from our last click.
        if sidebarVisible == nil, let window = Self.attribute(application, kAXFocusedWindowAttribute),
           CFGetTypeID(window) == AXUIElementGetTypeID() {
            var pending: [(AXUIElement, Int)] = [(window as! AXUIElement, 0)]
            var visited = 0
            while let (element, depth) = pending.popLast(), visited < 150,
                  ProcessInfo.processInfo.systemUptime < deadline {
                visited += 1
                if Self.attribute(element, kAXRoleAttribute) as? String == kAXButtonRole {
                    let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                        .compactMap { Self.attribute(element, $0) as? String }
                    if labels.contains(where: { ["Hide sidebar", "Hide Sidebar", "隐藏侧边栏"].contains($0) }) { sidebarVisible = true; break }
                    if labels.contains(where: { ["Show sidebar", "Show Sidebar", "显示侧边栏"].contains($0) }) { sidebarVisible = false; break }
                }
                if depth < 8 { pending.append(contentsOf: Self.children(element).prefix(40).map { ($0, depth + 1) }) }
            }
        }
        return Snapshot(trusted: true, running: true, entries: entries, sidebarVisible: sidebarVisible)
    }

    func perform(_ command: ChatGPTCommand, completion: @escaping @MainActor (String?) -> Void) {
        guard AXIsProcessTrusted() else {
            completion("Enable TouchBarEnhancer in System Settings → Privacy & Security → Accessibility, then check the connection again.")
            return
        }
        guard let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            completion("Open ChatGPT, then try again.")
            return
        }
        guard !running.isTerminated else { completion("ChatGPT has quit."); return }
        if !running.isActive { _ = running.activate(options: []) }
        performWhenActive(command, attemptsRemaining: 8, completion: completion)
    }

    private func performWhenActive(_ command: ChatGPTCommand, attemptsRemaining: Int,
                                   completion: @escaping @MainActor (String?) -> Void) {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else {
            guard attemptsRemaining > 0 else { completion("Bring ChatGPT to the front, then try again."); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.performWhenActive(command, attemptsRemaining: attemptsRemaining - 1, completion: completion)
            }
            return
        }
        guard let entry = snapshot().entry(for: command) else {
            completion("\(command.title) is not available in this version or language of ChatGPT.")
            return
        }
        guard entry.enabled else { completion("\(command.title) is currently disabled in ChatGPT."); return }
        let result = AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
        completion(result == .success ? nil : "ChatGPT could not run \(command.title). Check the connection and try again.")
    }

    static func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func selectChat(slot: Int, completion: @escaping @MainActor (String?) -> Void) {
        guard (1...9).contains(slot) else { completion("Chat shortcuts support Control + 1–9."); return }
        guard AXIsProcessTrusted() else { completion("Allow TouchBarEnhancer in Accessibility first."); return }
        // Never send a shortcut to another foreground app or change focus during preview.
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else {
            completion("Bring ChatGPT to the front before using a chat shortcut."); return
        }
        let codes: [CGKeyCode] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: codes[slot - 1], keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: codes[slot - 1], keyDown: false) else {
            completion("Could not create the chat shortcut."); return
        }
        down.flags = .maskControl; up.flags = .maskControl
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        completion(nil)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
}
