import AppKit

@main
@MainActor
struct AppsCustomizationSmoke {
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    static func capture(_ filename: String, arguments: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = arguments + [".build/visual-checks/\(filename).png"]
        try! task.run()
        task.waitUntilExit()
        precondition(task.terminationStatus == 0)
    }

    static func main() {
        try! FileManager.default.createDirectory(atPath: ".build/visual-checks", withIntermediateDirectories: true)
        let suite = "TouchBarEnhancer.CustomizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        let app = NSApplication.shared
        let delegate = AppDelegate(settings: store)
        app.delegate = delegate
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let window = app.windows.first { $0.title == "Applications" }!
            let appsItem = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "apps" }!
            window.toolbar?.selectedItemIdentifier = appsItem.itemIdentifier
            app.sendAction(appsItem.action!, to: appsItem.target, from: appsItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                capture("apps-settings", arguments: ["-x", "-l\(window.windowNumber)"])
                capture("apps-preview", arguments: ["-b", "-x"])
                let button = descendants(window.contentView!).compactMap { $0 as? NSButton }
                    .first { $0.title == "Customize Touch Bar…" }!
                button.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    capture("native-palette", arguments: ["-x", "-m"])
                    let paletteWindows = app.windows.filter { $0.isVisible && $0 !== window }
                    for palette in paletteWindows where NSStringFromClass(type(of: palette)) == "NSTouchBarCustomizationPaletteOverlayWindow" {
                        capture("native-palette-active", arguments: ["-x", "-l\(palette.windowNumber)"])
                    }
                    print("Visible auxiliary windows:", paletteWindows.map { ($0.title, NSStringFromClass(type(of: $0))) })
                    NSApp.toggleTouchBarCustomizationPalette(nil)
                    let applications = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "applications" }!
                    window.toolbar?.selectedItemIdentifier = applications.itemIdentifier
                    app.sendAction(applications.action!, to: applications.target, from: applications)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        capture("apps-preview-ended", arguments: ["-b", "-x"])
                        window.close()
                        defaults.removePersistentDomain(forName: suite)
                        print("Apps preview and native customization smoke completed")
                        app.terminate(nil)
                    }
                }
            }
        }
        app.run()
    }
}
