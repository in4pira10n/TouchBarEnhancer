import AppKit

@main @MainActor
struct SilentLaunchSmoke {
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    static func main() {
        let app = NSApplication.shared
        let suite = "TouchBarEnhancer.SilentLaunchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        precondition(store.launchSilently)
        store.paused = true // Test launch, without replacing the current app's bar.
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let delegate = AppDelegate(settings: store)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        // NSStatusBarWindow is intentionally visible for the menu bar icon.
        precondition(!app.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) },
            "Silent startup must create no visible settings or dialog window")
        precondition(!app.windows.contains { $0.title == "Applications" }, "Settings must be created lazily")
        let controller = SettingsWindowController(store: store)
        let window = controller.window!
        let general = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "general" }!
        precondition(app.sendAction(general.action!, to: general.target, from: general))
        window.contentView!.layoutSubtreeIfNeeded()
        let button = descendants(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == "Launch silently" }!
        precondition(button.state == .on)
        button.performClick(nil)
        precondition(!store.launchSilently && !SettingsStore(defaults: defaults).launchSilently)
        button.performClick(nil)
        precondition(store.launchSilently && SettingsStore(defaults: defaults).launchSilently)
        precondition(!window.isVisible)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
            "Silent startup and offscreen preferences checks must preserve focus")
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        print("Silent launch checks passed: default, no startup window, no activation, General checkbox, persisted opt-out and opt-in")
    }
}
