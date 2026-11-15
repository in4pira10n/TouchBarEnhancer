import AppKit
import ApplicationServices

/// The button title is independent of these exact, localized menu titles.
struct MenuCommandBinding: Codable, Equatable {
    var title = ""
    var parentPath = ""
    var alternateTitle = ""

    var path: [String] {
        parentPath.split(separator: "→", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    var display: String {
        title.isEmpty ? "No menu command" : ((parentPath.isEmpty ? [] : path) + [title]).joined(separator: " → ")
    }
    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (parentPath.isEmpty || path.allSatisfy { !$0.isEmpty })
            && title.count <= 512 && parentPath.count <= 2048 && alternateTitle.count <= 512
    }
}

@MainActor
enum MenuCommandSender {
    struct Entry {
        var path: [String]
        var enabled: Bool
        var element: AXUIElement?
        var title: String { path.last ?? "" }
    }
    struct Snapshot {
        var entries: [Entry] = []
        var complete = true
        var error: String?
    }
    struct Target: Equatable {
        var bundleID: String
        var pid: pid_t
    }
    /// Injected by regression checks: no user menu action is executed by tests.
    @MainActor struct Environment {
        var trusted: () -> Bool = { AXIsProcessTrusted() }
        var foreground: () -> Target? = {
            guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
            return Target(bundleID: id, pid: app.processIdentifier)
        }
        var read: (pid_t, [String]?) -> Snapshot = { snapshot(pid: $0, parentPath: $1) }
        var press: (Entry) -> Bool = { entry in
            guard let element = entry.element else { return false }
            AXUIElementSetMessagingTimeout(element, 0.25)
            return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
        }
    }

    static func resolve(_ binding: MenuCommandBinding, in snapshot: Snapshot) -> Result<Entry, CommandError> {
        guard binding.isValid else { return .failure(.init(message: "Enter an exact menu command name.")) }
        if let error = snapshot.error { return .failure(.init(message: error)) }
        // Never execute a partial search: an unseen duplicate may exist.
        guard snapshot.complete else { return .failure(.init(message: "The menu could not be fully read. Try again or specify a menu path.")) }
        let titles = [binding.title, binding.alternateTitle].filter { !$0.isEmpty }
        let matches = snapshot.entries.filter {
            titles.contains($0.title) && (binding.parentPath.isEmpty || Array($0.path.dropLast()) == binding.path)
        }
        guard !matches.isEmpty else { return .failure(.init(message: "Menu command “\(binding.title)” was not found. Check its exact name and language.")) }
        let enabled = matches.filter(\.enabled)
        guard !enabled.isEmpty else { return .failure(.init(message: "Menu command “\(binding.title)” is currently disabled.")) }
        // A disabled duplicate still requires disambiguation, except an explicit
        // pair of mutually exclusive Show/Hide titles in the same menu.
        let parents = Set(matches.map { Array($0.path.dropLast()) })
        guard enabled.count == 1, parents.count == 1,
              Set(matches.map(\.title)).count == matches.count else {
            return .failure(.init(message: "More than one menu command matches. Specify its full menu path."))
        }
        return .success(enabled[0])
    }
    struct CommandError: Error { var message: String }

    static func send(_ binding: MenuCommandBinding?, to bundleID: String,
                     environment: Environment = .init()) -> String? {
        guard let binding, binding.isValid else { return "Enter an exact menu command name for this button first." }
        guard environment.trusted() else { return "Allow TouchBarEnhancer in Accessibility first." }
        guard let target = environment.foreground(), target.bundleID == bundleID else {
            return "Bring the target app to the front before using this menu command."
        }
        switch resolve(binding, in: environment.read(target.pid, binding.parentPath.isEmpty ? nil : binding.path)) {
        case .failure(let error): return error.message
        case .success(let entry):
            guard environment.foreground() == target else { return "The active app changed. Try again." }
            return environment.press(entry) ? nil : "The app did not confirm the menu action. Check the app before trying again."
        }
    }

    /// Reads only menus, on demand; never opens menus or traverses documents.
    /// Search bounds make a stalled or unusually large accessibility tree fail closed.
    static func snapshot(pid: pid_t, parentPath: [String]? = nil) -> Snapshot {
        let app = AXUIElementCreateApplication(pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        var result = Snapshot()
        var visited = 0
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { result.complete = false; return nil }
            AXUIElementSetMessagingTimeout(element, 0.08)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if status == .cannotComplete || status == .invalidUIElement { result.complete = false }
            return status == .success ? value : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        }
        func walk(_ element: AXUIElement, path: [String], depth: Int, ancestorsEnabled: Bool) {
            guard depth < 24, visited < 1800, ProcessInfo.processInfo.systemUptime < deadline else {
                result.complete = false; return
            }
            visited += 1
            let role = attribute(element, kAXRoleAttribute) as? String
            let title = attribute(element, kAXTitleAttribute) as? String ?? ""
            let isItem = role == kAXMenuItemRole || role == kAXMenuBarItemRole
            let next = isItem && !title.isEmpty ? path + [title] : path
            if let parentPath, !next.isEmpty,
               !next.starts(with: parentPath), !parentPath.starts(with: next) { return }
            let enabled = ancestorsEnabled && (!isItem || (attribute(element, kAXEnabledAttribute) as? Bool ?? false))
            let nested = children(element)
            if role == kAXMenuItemRole, !title.isEmpty, nested.isEmpty {
                result.entries.append(.init(path: next, enabled: enabled, element: element))
            }
            for child in nested { walk(child, path: next, depth: depth + 1, ancestorsEnabled: enabled) }
        }
        guard let menuValue = attribute(app, kAXMenuBarAttribute), CFGetTypeID(menuValue) == AXUIElementGetTypeID() else {
            result.error = "The app’s menu bar is unavailable through Accessibility."; return result
        }
        let menuBar = menuValue as! AXUIElement
        // The first menu belongs to macOS (Apple), not the target app.
        for top in children(menuBar).dropFirst() { walk(top, path: [], depth: 0, ancestorsEnabled: true) }
        return result
    }
}
