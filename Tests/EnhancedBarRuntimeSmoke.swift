import AppKit
import TouchBarBridge

/// Same signed bundle, isolated preferences/layouts and no input or playback actions.
@main @MainActor
struct EnhancedBarRuntimeSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func near(_ actual: CGFloat, _ expected: CGFloat) {
        precondition(abs(actual - expected) < 1, "Expected \(expected), got \(actual)")
    }
    static func main() {
        TBPrepareForImmediateTransitions()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication!
        let bundleID = foreground.bundleIdentifier!
        let clipboard = NSPasteboard.general.changeCount
        let domain = "TouchBarEnhancer.EnhancedRuntime.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        let store = SettingsStore(defaults: defaults)
        store.paused = false; store.showControlStripButton = false
        store.rules = [.init(bundleID: bundleID, name: foreground.localizedName ?? "Foreground", mode: .native)]
        let lyrics = LyricsController(search: { _ in preconditionFailure("Runtime policy fixture must not search user media") },
            read: { $0(nil) }, observe: { _ in {} })
        let delegate = AppDelegate(settings: store, persistsLayouts: false, lyricsController: lyrics)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        precondition(delegate.enhancedAppBundleID == nil)
        precondition(!lyrics.enabled)
        // Real tray button, but fixture-owned action and conditions only.
        let strip = ControlStripButton()
        var config = ControlStripConfiguration()
        config.action = .showEnhancedBar
        strip.update(enabled: true, paused: false, configuration: config)
        let runner = ControlStripActionRunner()
        runner.toggleEnhancedBar = { delegate.toggleEnhancedBar() }
        strip.onInteraction = { interaction in runner.perform(config, interaction: interaction) { preconditionFailure() } }
        func tap() { strip.button.performClick(nil) }
        func stage(_ label: String) { print("Enhanced Bar runtime: \(label)"); fflush(stdout) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            precondition(strip.isRegistered && strip.button.window != nil)
            tap()
            precondition(delegate.enhancedBarVisible && delegate.enhancedAppBundleID == LayoutApp.enhancedBar.bundleID)
            precondition(lyrics.enabled, "Only an actually shown Lyrics component should observe media")
            stage("native to shared bar")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            tap()
            precondition(!delegate.enhancedBarVisible && delegate.enhancedAppBundleID == nil)
            precondition(!lyrics.enabled)
            store.rules[0].mode = .enabled; store.save()
            precondition(delegate.enhancedAppBundleID == bundleID)
            tap()
            precondition(delegate.enhancedAppBundleID == LayoutApp.enhancedBar.bundleID)
            // Re-evaluate app policy without activating another user's app.
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification,
                object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: foreground])
            precondition(delegate.enhancedAppBundleID == LayoutApp.enhancedBar.bundleID)
            store.lyricsComponents[LayoutApp.enhancedBar.bundleID] = .init(fillWidth: .init(mode: .hug))
            store.save()
            precondition(delegate.enhancedBarVisible)
            stage("app bar to shared, survives policy re-evaluation and live edits")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            tap()
            precondition(!delegate.enhancedBarVisible && delegate.enhancedAppBundleID == bundleID)
            store.paused = true; store.save()
            precondition(delegate.enhancedAppBundleID == nil)
            tap(); precondition(delegate.enhancedBarVisible && store.paused)
            tap(); precondition(delegate.enhancedAppBundleID == nil && store.paused)
            tap()
            precondition(app.sendAction(NSSelectorFromString("hideBar"), to: delegate, from: nil))
            precondition(!delegate.enhancedBarVisible && delegate.enhancedAppBundleID == nil)
            tap()
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            precondition(!delegate.enhancedBarVisible && delegate.enhancedAppBundleID == nil)
            precondition(!lyrics.enabled, "Hiding or sleeping must stop lyrics")
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
            stage("close restores app policy; Pause, Hide and sleep preserved")
        }
        let provider = AppBar(app: .enhancedBar,
            keyboardButtons: .init(buttons: [.init(title: "One"), .init(title: "Two")]), persistsLayout: false)
        let host = AppBarHost()
        func layout(_ phase: Int) {
            let keys = phase == 0 ? ["lyrics"] : ["lyrics", "keyboard"]
            provider.bar.defaultItemIdentifiers = keys.map(AppBar.itemID)
            provider.configureComponentPresentations([
                "lyrics": .init(alignment: .center, textWidth: phase == 2 ? .init(mode: .fixed, fixed: 24) : .init()),
                "keyboard": .init(layout: .fill)
            ])
            host.display(provider); precondition(TBPresent(host.bar))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                var frames: [NSRect] = []
                for key in keys {
                    let id = AppBar.itemID(key)
                    let item = (host.bar.templateItems.first { $0.identifier == id }
                        ?? host.content.groupTouchBar.item(forIdentifier: id)) as! NSCustomTouchBarItem
                    let region = (item.view as! TouchBarComponentView).content as! ScrollingComponentRegion
                    precondition(region.window != nil && !region.isHiddenOrHasHiddenAncestor)
                    region.layoutSubtreeIfNeeded()
                    frames.append(region.convert(region.bounds, to: nil))
                    if key == "lyrics" {
                        let scrubber = descendants(region).compactMap { $0 as? NSScrubber }.first!
                        if phase != 2 { near(scrubber.frame.midX, region.bounds.midX) }
                        precondition(scrubber.numberOfItems == 1)
                    }
                }
                near(frames[0].minX, 0)
                if phase == 0 {
                    let leading = host.bar.templateItems.first { $0.identifier == AppBar.itemID("lyrics") } as! NSCustomTouchBarItem
                    // AppKit may reserve a trailing native item margin around
                    // the replacement slot. Measure the real presentation.
                    let margin = leading.view.window!.frame.width - frames[0].width
                    precondition((0...16).contains(margin))
                }
                if phase == 1 { near(frames[0].width, frames[1].width) }
                if phase == 2 { near(frames[0].width, 24); precondition(frames[1].width > 100) }
                if frames.count > 1 { near(frames[1].minX - frames[0].maxX, 12) }
                stage("layout \(phase), frames \(frames)")
                if phase < 2 { layout(phase + 1) }
                else {
                    _ = TBDismiss(host.bar); strip.remove()
                    defaults.removePersistentDomain(forName: domain)
                    precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground.processIdentifier)
                    precondition(NSPasteboard.general.changeCount == clipboard)
                    precondition(!app.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) })
                    print("Enhanced Bar runtime checks passed: real tray toggle, native/app restoration, policy re-evaluation, pause/hide/sleep, Lyrics centering, equal peers, compact widths and no input or activation")
                    fflush(stdout); app.terminate(nil)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { layout(0) }
        app.run()
    }
}
