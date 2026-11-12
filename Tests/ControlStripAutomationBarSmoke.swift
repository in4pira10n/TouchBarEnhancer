import AppKit
import TouchBarBridge

/// Mock conditions, real system-rendered tray item. Never runs configured actions.
@main @MainActor
struct ControlStripAutomationBarSmoke {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let control = ControlStripButton()
        var connected = false
        var playing = false
        let device = ControlStripBluetoothDevice(address: "AA:BB:CC:DD:EE:01", name: "Fixture AirPods", connected: true)
        var combined = ControlStripAutomationRule()
        combined.enabled = true; combined.mediaPlaying = true; combined.deviceAddress = device.address
        combined.configuration.symbol = "airpodspro"; combined.configuration.action = .pasteClipboard
        var media = ControlStripAutomationRule()
        media.enabled = true; media.bluetoothConnected = false; media.mediaPlaying = true
        media.configuration.symbol = "music.note"; media.configuration.action = .openURL
        media.configuration.url = "https://example.com"
        var playbackChanged: (@MainActor (Bool?) -> Void)?
        let monitor = ControlStripAutomationMonitor(readDevices: { connected ? [device] : [] }, readMedia: { $0(playing) },
            observeMedia: { changed in
                playbackChanged = changed
                return { playbackChanged = nil }
            })
        var defaultConfiguration = ControlStripConfiguration()
        var masterEnabled = true
        var effective = defaultConfiguration
        var taps: [ControlStripAction] = []
        control.onPress = { taps.append(effective.action) }
        func apply() {
            effective = monitor.activeRule?.configuration ?? defaultConfiguration
            control.update(enabled: masterEnabled, paused: false, configuration: effective)
        }
        monitor.onChange = { apply() }
        apply()
        monitor.configure(enabled: true, rules: [combined, media])
        func verify(_ symbol: String, action: ControlStripAction, stage: String) {
            precondition(effective.symbol == symbol && effective.action == action)
            precondition(control.isRegistered && control.button.window != nil)
            precondition(abs(control.button.frame.height - 30) < 0.5 && abs(control.button.frame.minY) < 0.5)
            let before = taps.count
            control.button.performClick(nil)
            precondition(taps.count == before + 1 && taps.last == action)
            print("Automation hardware stage: \(stage); frame: \(control.button.frame)")
            fflush(stdout)
        }
        func verifyHidden(_ stage: String) {
            precondition(!control.isRegistered && !control.button.isEnabled)
            let before = taps.count
            // Include a stale action delivery even though the native control is disabled.
            precondition(app.sendAction(control.button.action!, to: control.button.target, from: control.button))
            precondition(taps.count == before)
            print("Automation hardware stage: \(stage); button hidden; monitoring: \(monitor.isMonitoring)")
            fflush(stdout)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            verify(ControlStripConfiguration.defaultSymbol, action: .toggleEnhancement, stage: "Default")
            playing = true; playbackChanged?(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            verify("music.note", action: .openURL, stage: "Playing")
            connected = true; monitor.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            verify("airpodspro", action: .pasteClipboard, stage: "Connected AND Playing")
            combined.configuration.showsButton = false
            monitor.configure(enabled: true, rules: [combined, media])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            verifyHidden("Matching hidden rule takes priority over shown Playing")
            precondition(monitor.isMonitoring && monitor.activeRule?.id == combined.id)
            connected = false; monitor.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7.5) {
            verify("music.note", action: .openURL, stage: "Disconnected fallback to Playing")
            defaultConfiguration.showsButton = false
            playing = false; playbackChanged?(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            verifyHidden("Paused fallback to hidden Default")
            precondition(monitor.isMonitoring && monitor.activeRule == nil)
            playing = true; playbackChanged?(true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.5) {
            verify("music.note", action: .openURL, stage: "Playing reveals button over hidden Default")
            masterEnabled = false
            monitor.configure(enabled: false, rules: [combined, media]); apply()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            verifyHidden("Master off overrides shown rule")
            precondition(!monitor.isMonitoring)
            masterEnabled = true
            monitor.configure(enabled: true, rules: [combined, media]); apply()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 13.5) {
            verify("music.note", action: .openURL, stage: "Master on resumes matching rule")
            defaultConfiguration.showsButton = true
            playing = false; playbackChanged?(false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            verify(ControlStripConfiguration.defaultSymbol, action: .toggleEnhancement, stage: "Paused fallback to Default")
            monitor.onChange = nil; monitor.stop(); control.remove()
            precondition(!app.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) })
            print("Control Strip automation hardware checks passed: real tray geometry, hide/re-register, hidden priority, continued monitoring, default visibility, master switch, matching mock taps and no configured actions or settings writes")
            fflush(stdout); app.terminate(nil)
        }
        app.run()
    }
}
