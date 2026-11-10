import AppKit
import TouchBarBridge

// Exercise the real workspace activation path with isolated activation rules.
@main
@MainActor
struct BarSwitchingSmoke {
    static func main() {
        precondition(FileManager.default.changeCurrentDirectoryPath(
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path))
        TBPrepareForImmediateTransitions()
        let app = NSApplication.shared
        let suite = "TouchBarEnhancer.SwitchTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        store.autoPolicy = .selection
        store.selectedAppIDs = [LayoutApp.builtIn[0].bundleID]
        let delegate = AppDelegate(settings: store)
        app.delegate = delegate
        let targets = ["com.apple.finder", LayoutApp.builtIn[0].bundleID]
        var frame = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            app.windows.first { $0.title == "Applications" }?.close()
            Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if frame % 10 == 0, frame < 60 {
                        let id = targets[(frame / 10) % 2]
                        guard NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == id })?
                            .activate(options: []) == true else { fatalError("Required target app is not running: \(id)") }
                    }
                    if frame == 60 { store.paused = true; store.save() }
                    if frame == 65 { store.paused = false; store.save() }
                    if frame == 63 { precondition(delegate.enhancedAppBundleID == nil) }
                    if frame == 68 { precondition(delegate.enhancedAppBundleID == targets[1]) }
                    if frame < 60, frame % 10 == 7 {
                        let expected = (frame / 10) % 2 == 0 ? nil : targets[1]
                        precondition(delegate.enhancedAppBundleID == expected,
                            "Selection Mode did not switch between enhanced and native bars")
                        print("Selection state \(frame): \(delegate.enhancedAppBundleID ?? "Native")")
                        fflush(stdout)
                    }
                    frame += 1
                    if frame == 70 {
                        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                        print("Selection Mode checks passed: six selected/native app switches, pause and resume")
                        app.terminate(nil)
                    }
                }
            }
        }
        app.run()
    }
}
