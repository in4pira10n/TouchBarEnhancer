import AppKit

@main @MainActor
struct LyricsInteractionsSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.04)) }
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let clipboard = NSPasteboard.general.changeCount
        let suite = "TouchBarEnhancer.LyricsInteractions.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let settings = SettingsWindowController(store: store)
        let provider = AppBar(app: .enhancedBar, persistsLayout: false)
        var taps = 0, offsets: [Double] = []
        provider.onLyricsSearch = { taps += 1; settings.openLyricsSettings() }
        provider.onLyricsSeek = { offsets.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 30),
            styleMask: .borderless, backing: .buffered, defer: false)
        let item = provider.bar.item(forIdentifier: AppBar.itemID("lyrics")) as! NSCustomTouchBarItem
        item.view.frame = window.contentView!.bounds
        window.contentView!.addSubview(item.view); window.layoutIfNeeded()
        let surface = descendants(item.view).compactMap { $0 as? LyricsInteractionView }.first!
        let region = (item.view as! TouchBarComponentView).content
        precondition(surface.frame == region.bounds && surface.bounds.width > 100)
        precondition(surface.intrinsicContentSize.width == NSView.noIntrinsicMetric)
        let recognizer = surface.gestureRecognizers.first as! LyricsTouchRecognizer
        func event(_ phase: NSTouch.Phase, x: CGFloat = 50, y: CGFloat = 15, identity: String = "finger") -> NSEvent {
            LyricsTouchEvent(touches: [LyricsTouch(identity: identity, phase: phase, location: NSPoint(x: x, y: y))])
        }
        func gesture(_ start: CGFloat, _ end: CGFloat) {
            recognizer.touchesBegan(with: event(.began, x: start))
            recognizer.touchesMoved(with: event(.moved, x: end))
            recognizer.touchesEnded(with: event(.ended, x: end)); settle()
        }
        gesture(50, 52)
        precondition(taps == 1 && offsets.isEmpty && settings.window?.title == "Lyrics")
        precondition(settings.window?.isVisible == false && store.lastSettingsPane == "lyrics")
        gesture(50, 90); gesture(90, 50)
        precondition(taps == 1 && offsets == [5, -5])
        gesture(surface.bounds.maxX - 2, surface.bounds.maxX - 2)
        precondition(taps == 2, "The whole allocated region is tappable")
        recognizer.touchesBegan(with: event(.began))
        recognizer.touchesMoved(with: event(.moved, x: 90))
        recognizer.touchesEnded(with: event(.ended))
        settle(); precondition(taps == 2 && offsets.count == 2, "A swipe that returns is not a tap")
        recognizer.touchesBegan(with: event(.began))
        recognizer.touchesCancelled(with: event(.cancelled))
        recognizer.touchesEnded(with: event(.ended)); settle()
        recognizer.touchesBegan(with: event(.began))
        recognizer.touchesMoved(with: event(.moved, x: 90, y: 50))
        recognizer.touchesEnded(with: event(.ended, x: 90)); settle()
        precondition(taps == 2 && offsets.count == 2)
        recognizer.touchesBegan(with: event(.began))
        recognizer.touchesEnded(with: event(.ended, identity: "foreign"))
        precondition(taps == 2)
        recognizer.touchesEnded(with: event(.ended)); settle()
        precondition(taps == 3)
        recognizer.touchesBegan(with: event(.began))
        recognizer.touchesBegan(with: event(.began, identity: "second"))
        recognizer.touchesEnded(with: event(.ended)); settle()
        precondition(taps == 3)
        recognizer.touchesBegan(with: event(.began))
        provider.configureLyricsDisplay(.init(text: "Other track", detail: "Other track — Artist"))
        recognizer.touchesEnded(with: event(.ended)); settle()
        precondition(taps == 3, "A track change cancels the finger gesture")
        recognizer.touchesBegan(with: event(.began))
        provider.configureLyricsDisplay(.init(text: "Next line", detail: "Other track — Artist"))
        recognizer.touchesEnded(with: event(.ended)); settle()
        precondition(taps == 4, "A normal lyric line update retains the gesture")
        recognizer.touchesBegan(with: event(.began))
        surface.removeFromSuperview(); region.addSubview(surface)
        recognizer.touchesEnded(with: event(.ended)); settle()
        precondition(taps == 4)
        let mousePoint = surface.convert(NSPoint(x: 50, y: 15), to: nil)
        func mouse(_ type: NSEvent.EventType, dx: CGFloat = 0) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: mousePoint.x + dx, y: mousePoint.y),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1)!
        }
        surface.mouseDown(with: mouse(.leftMouseDown)); surface.mouseUp(with: mouse(.leftMouseUp))
        surface.mouseDown(with: mouse(.leftMouseDown)); surface.mouseDragged(with: mouse(.leftMouseDragged, dx: -30))
        surface.mouseUp(with: mouse(.leftMouseUp, dx: -30))
        precondition(taps == 5 && offsets == [5, -5, -5])
        precondition(surface.accessibilityPerformPress() && taps == 6)
        surface.isHidden = true
        gesture(50, 90)
        precondition(!surface.accessibilityPerformPress() && taps == 6 && offsets.count == 3)
        surface.isHidden = false
        let text = TextComponent(items: [.init(text: "Plain text")])
        precondition(!descendants(text.scroller.scrollRegion).contains { $0 is LyricsInteractionView })
        let other = NSTouchBar(); other.delegate = provider
        let otherItem = other.item(forIdentifier: AppBar.itemID("lyrics")) as! NSCustomTouchBarItem
        let otherSurface = descendants(otherItem.view).compactMap { $0 as? LyricsInteractionView }.first!
        precondition(otherSurface !== surface)
        let snapshot = LyricsPlayback(track: .init(title: "Fixture", artist: "Fixture", duration: 100),
            elapsed: 10, date: Date(), rate: 0, playing: false, source: "fixture")
        let result = LyricsSearchResult(lyrics: TimedLyrics(lrc: "[00:10]Ten\n[00:15]Fifteen\n[00:20]Twenty"), source: "Fixture")
        var seekTargets: [Double] = []
        let controller = LyricsController(search: { _ in result }, read: { $0(snapshot) },
            observe: { _ in nil }, setElapsed: { seekTargets.append($0); return true })
        controller.onChange = { provider.configureLyricsDisplay($0) }
        provider.onLyricsSeek = {
            precondition(recognizer.state == .ended, "Finish the gesture before seek callbacks can relayout it")
            controller.seek(by: $0)
        }
        controller.setEnabled(true); settle()
        gesture(50, 90); gesture(50, 90); gesture(90, 50)
        precondition(seekTargets == [15, 20, 15] && controller.display.text == "Fifteen",
            "Repeated direct gestures survive actual lyric rerendering and delayed player metadata")
        controller.setEnabled(false)
        precondition(!window.isVisible && settings.window?.isVisible == false)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground && NSPasteboard.general.changeCount == clipboard)
        print("Lyrics interaction checks passed: real recognizer callbacks, tap/right/left, repeat, full hit area, swipe/tap exclusion, cancellation, foreign/multiple fingers, live lines, detachment, mouse fallback, accessibility and offscreen search navigation; no playback/focus/clipboard effects")
    }
}

// Immutable event snapshots match AppKit's Sendable contract.
private final class LyricsTouch: NSTouch, @unchecked Sendable {
    let token: NSString
    let touchPhase: NSTouch.Phase
    let point: NSPoint
    init(identity: String, phase: NSTouch.Phase, location: NSPoint) {
        token = identity as NSString; touchPhase = phase; point = location; super.init()
    }
    override var identity: any NSObjectProtocol & NSCopying { token }
    override var type: NSTouch.TouchType { .direct }
    override var phase: NSTouch.Phase { touchPhase }
    override func location(in view: NSView?) -> NSPoint { point }
}
private final class LyricsTouchEvent: NSEvent, @unchecked Sendable {
    let values: Set<NSTouch>
    init(touches: Set<NSTouch>) { values = touches; super.init() }
    required init?(coder: NSCoder) { nil }
    override func touches(matching phase: NSTouch.Phase, in view: NSView?) -> Set<NSTouch> {
        values.filter { phase.contains($0.phase) }
    }
}
