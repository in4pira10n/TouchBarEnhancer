import AppKit
import TouchBarBridge

// Standalone integration check. Uses isolated preferences and does not edit user rules.
@main
@MainActor
struct VisualSmoke {
    static func findPolicyPopup(_ view: NSView) -> NSPopUpButton? {
        if let popup = view as? NSPopUpButton, popup.itemTitles.contains(AutoPolicy.exclusion.rawValue) { return popup }
        for child in view.subviews {
            if let result = findPolicyPopup(child) { return result }
        }
        return nil
    }
    static func capture(_ name: String, window: Int? = nil) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = window.map { ["-x", "-l\($0)", ".build/visual-checks/\(name).png"] }
            ?? ["-b", "-x", ".build/visual-checks/\(name).png"]
        try! task.run()
        task.waitUntilExit()
        precondition(task.terminationStatus == 0)
    }

    static func main() {
        try! FileManager.default.createDirectory(atPath: ".build/visual-checks", withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let suite = "TouchBarEnhancer.VisualTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        store.autoPolicy = .selection
        let id = NSWorkspace.shared.frontmostApplication!.bundleIdentifier!
        let bar = NSTouchBar()
        let item = NSCustomTouchBarItem(identifier: .init("test"))
        item.view = NSButton(title: "Lifecycle Test", target: nil, action: nil)
        bar.templateItems = [item]
        bar.defaultItemIdentifiers = [item.identifier]
        capture("native-before")
        store.rules = [AppRule(bundleID: id, name: "Test", mode: .enabled)]
        precondition(store.shouldEnhance(id, manuallyHidden: false))
        precondition(TBPresent(bar))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            capture("enabled")
            store.rules.removeAll()
            precondition(!store.shouldEnhance(id, manuallyHidden: false))
            precondition(TBDismiss(bar))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                capture("native-after-removal")
                store.rules = [
                    AppRule(bundleID: "com.apple.Safari", name: "Safari", mode: .auto),
                    AppRule(bundleID: "com.apple.finder", name: "Finder", mode: .native)
                ]
                store.selectedAppIDs.insert("com.apple.Safari")
                let controller = SettingsWindowController(store: store)
                controller.update(status: "Visual test · isolated settings")
                controller.showWindow(nil)
                app.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    capture("app-rows", window: controller.window!.windowNumber)
                    let popup = findPolicyPopup(controller.window!.contentView!)!
                    popup.selectItem(withTitle: AutoPolicy.exclusion.rawValue)
                    app.sendAction(popup.action!, to: popup.target, from: popup)
                    precondition(store.autoPolicy == .exclusion)
                    controller.window!.contentView!.layoutSubtreeIfNeeded()
                    capture("exclusion-mode", window: controller.window!.windowNumber)
                    controller.close()
                    defaults.removePersistentDomain(forName: suite)
                    print("Lifecycle and row-layout captures saved in .build/visual-checks")
                    app.stop(nil)
                }
            }
        }
        app.run()
    }
}
