import AppKit
import TouchBarBridge

/// The same signed bundle runs this fixture; it does not edit system/user layouts.
@main @MainActor
struct ControlStripSmoke {
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        checkInteractions()
        checkDirectTouches()
        // Availability only: never skip the user's media while running checks.
        precondition(TBMediaSkipIsAvailable(), "System media transport API unavailable")
        precondition(TBControlStripIsAvailable(), "Control Strip API unavailable")
        let control = ControlStripButton()
        control.button.currentModifiers = { [] }
        precondition(!control.button.isBordered && (control.button.layer?.cornerRadius ?? 0) == 0)
        var count = 0
        control.onPress = { count += 1 }
        control.update(enabled: false, paused: false)
        precondition(!control.isRegistered)
        control.update(enabled: true, paused: false)
        precondition(control.isRegistered)
        precondition(control.button.longPressDuration == 0.6)
        print("Control Strip registered: \(control.item.identifier.rawValue)")
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            print("Control Strip view frame: \(control.button.frame), fitting: \(control.button.fittingSize), window: \(String(describing: control.button.window?.frame)), hidden: \(control.button.isHiddenOrHasHiddenAncestor)")
            precondition(abs(control.button.frame.height - 30) < 0.5 && abs(control.button.frame.minY) < 0.5,
                "Borderless alignment must stay inside the 30-point system tray slot")
            // Exercise the real NSButton target/action without sending input to another app.
            control.button.performClick(nil)
            precondition(count == 1)
            var interactions: [ControlStripInteraction] = []
            control.onInteraction = { interactions.append($0) }
            for (flags, expected) in [(NSEvent.ModifierFlags.option, ControlStripInteraction.optionTap), (.command, .commandTap), (.control, .controlTap)] {
                control.button.beginInteraction(modifiers: flags)
                _ = control.button.sendAction(control.button.action, to: control.button.target)
                control.button.endInteraction()
                precondition(interactions.last == expected)
            }
            control.button.beginInteraction(modifiers: [])
            control.button.recognizeLongPress()
            _ = control.button.sendAction(control.button.action, to: control.button.target)
            control.button.endInteraction()
            precondition(interactions == [.optionTap, .commandTap, .controlTap, .longPress])
            control.onInteraction = nil
            var custom = ControlStripConfiguration()
            custom.symbol = "play.fill"; custom.action = .pasteClipboard
            custom.longPressDuration = 1.3
            control.button.beginInteraction(modifiers: [])
            control.update(enabled: true, paused: true, configuration: custom)
            precondition(control.button.longPressDuration == 1.3)
            control.button.recognizeLongPress()
            _ = control.button.sendAction(control.button.action, to: control.button.target)
            control.button.endInteraction()
            precondition(count == 1, "Changing configuration must cancel an in-progress press")
            precondition(control.isRegistered && control.button.accessibilityLabel() == "Paste Clipboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { control.button.highlight(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { control.button.highlight(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                control.button.performClick(nil); precondition(count == 2)
                control.update(enabled: true, paused: true)
                precondition(control.button.accessibilityLabel() == "Resume TouchBarEnhancer")
                control.update(enabled: false, paused: false)
                precondition(!control.isRegistered)
                control.remove() // Repeated removal is harmless.
                precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
                precondition(!app.windows.contains { $0.styleMask.contains(.titled) && $0.isVisible })
                print("Control Strip checks passed: tap/modifier/long-press routing, direct-touch callbacks and hold timer, native mouse tracking, cancellation, guarded registration, target/action, state, unregister, no preferences or focus changes; physical touch still requires hardware input")
                fflush(stdout); app.terminate(nil)
            }
        }
        app.run()
    }

    static func checkInteractions() {
        precondition(ControlStripInteraction.click(modifiers: []) == .tap)
        precondition(ControlStripInteraction.click(modifiers: .option) == .optionTap)
        precondition(ControlStripInteraction.click(modifiers: .command) == .commandTap)
        precondition(ControlStripInteraction.click(modifiers: .control) == .controlTap)
        precondition(ControlStripInteraction.click(modifiers: [.command, .option]) == nil)
        precondition(ControlStripInteraction.click(modifiers: .shift) == nil)
        precondition(ControlStripInteraction.click(modifiers: .capsLock) == .tap)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
            styleMask: .borderless, backing: .buffered, defer: false)
        let button = ControlStripActionButton(title: "", target: nil, action: nil)
        button.currentModifiers = { [] }
        button.frame = NSRect(x: 0, y: 0, width: 55.5, height: 30)
        window.contentView!.addSubview(button)
        let target = InteractionTarget()
        button.target = target; button.action = #selector(InteractionTarget.pressed(_:))
        for (flags, expected) in [(NSEvent.ModifierFlags(), ControlStripInteraction.tap), (.option, .optionTap), (.command, .commandTap), (.control, .controlTap)] {
            button.beginInteraction(modifiers: flags)
            if expected != .tap { button.recognizeLongPress() }
            _ = button.sendAction(button.action, to: button.target)
            button.endInteraction()
            precondition(target.events.last == expected)
        }
        let beforeHold = target.events.count
        button.beginInteraction(modifiers: [])
        button.recognizeLongPress(); button.recognizeLongPress()
        _ = button.sendAction(button.action, to: button.target)
        button.endInteraction()
        precondition(target.events.count == beforeHold + 1 && target.events.last == .longPress)
        button.beginInteraction(modifiers: [])
        button.cancelInteraction(); button.recognizeLongPress()
        _ = button.sendAction(button.action, to: button.target)
        button.endInteraction()
        precondition(target.events.count == beforeHold + 1)
        button.beginInteraction(modifiers: [.command, .option])
        _ = button.sendAction(button.action, to: button.target)
        button.endInteraction()
        precondition(target.events.count == beforeHold + 1)

        // Exercise AppKit's actual tracking loop using events queued only inside
        // this fixture, never injected into the user's foreground application.
        func nativePress(modifiers: NSEvent.ModifierFlags, hold: Bool) {
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 15, y: 15),
                modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let release: @MainActor @Sendable () -> Void = {
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 15, y: 15),
                    modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
                NSApp.postEvent(up, atStart: true)
            }
            if hold {
                let releaseTimer = Timer(timeInterval: button.longPressDuration + 0.1, repeats: false) { _ in
                    MainActor.assumeIsolated { release() }
                }
                RunLoop.main.add(releaseTimer, forMode: .eventTracking)
            } else { release() }
            button.mouseDown(with: down)
        }
        for (flags, expected) in [(NSEvent.ModifierFlags(), ControlStripInteraction.tap), (.option, .optionTap), (.command, .commandTap), (.control, .controlTap)] {
            let before = target.events.count
            nativePress(modifiers: flags, hold: false)
            precondition(target.events.count == before + 1 && target.events.last == expected,
                "Native tracking must route exactly one \(expected) interaction; received \(Array(target.events.dropFirst(before)))")
        }
        let before = target.events.count
        nativePress(modifiers: [], hold: true)
        precondition(target.events.count == before + 1 && target.events.last == .longPress,
            "The real hold timer fires once and native mouse-up must not tap")
        precondition(!window.isVisible)
    }

    /// Exercise the direct-touch callbacks rather than substituting mouseDown.
    /// Immutable touch/event doubles avoid private event construction APIs.
    static func checkDirectTouches() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
            styleMask: .borderless, backing: .buffered, defer: false)
        let button = ControlStripActionButton(title: "", target: nil, action: nil)
        button.currentModifiers = { [] }
        button.frame = NSRect(x: 0, y: 0, width: 55.5, height: 30)
        window.contentView!.addSubview(button)
        let target = InteractionTarget()
        button.target = target; button.action = #selector(InteractionTarget.pressed(_:))
        let recognizers = button.gestureRecognizers.compactMap { $0 as? ControlStripTouchRecognizer }
        precondition(recognizers.count == 1 && recognizers[0].allowedTouchTypes == .direct)
        precondition(button.allowedTouchTypes == .direct)
        let recognizer = recognizers[0]
        func event(_ phase: NSTouch.Phase, x: CGFloat = 15,
                   flags: NSEvent.ModifierFlags = [], identity: String = "finger-1") -> NSEvent {
            DirectTouchEvent(touch: DirectTouch(identity: identity, phase: phase,
                location: NSPoint(x: x, y: 15)), modifiers: flags)
        }
        func settle() {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        for (flags, expected) in [(NSEvent.ModifierFlags(), ControlStripInteraction.tap),
                                  (.option, .optionTap), (.command, .commandTap), (.control, .controlTap)] {
            let before = target.events.count
            recognizer.touchesBegan(with: event(.began, flags: flags))
            precondition(button.isHighlighted)
            // Modifier state at release must not replace the press-down snapshot.
            recognizer.touchesEnded(with: event(.ended))
            precondition(!button.isHighlighted)
            settle()
            precondition(target.events.count == before + 1 && target.events.last == expected)
        }
        let beforeHold = target.events.count
        recognizer.touchesBegan(with: event(.began))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: button.longPressDuration + 0.1))
        precondition(target.events.count == beforeHold + 1 && target.events.last == .longPress,
            "Direct touch must start the actual hold timer without mouse tracking")
        recognizer.touchesEnded(with: event(.ended))
        settle()
        precondition(target.events.count == beforeHold + 1, "Long-press release must not fire Tap")
        recognizer.touchesBegan(with: event(.began, flags: .option))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: button.longPressDuration + 0.1))
        precondition(target.events.count == beforeHold + 1)
        recognizer.touchesEnded(with: event(.ended))
        settle()
        precondition(target.events.last == .optionTap)
        let beforeCancellation = target.events.count
        recognizer.touchesBegan(with: event(.began))
        recognizer.touchesMoved(with: event(.moved, x: -5))
        recognizer.touchesEnded(with: event(.ended))
        settle()
        precondition(!button.isHighlighted && target.events.count == beforeCancellation)
        recognizer.touchesBegan(with: event(.began))
        recognizer.touchesCancelled(with: event(.cancelled))
        settle()
        precondition(!button.isHighlighted && target.events.count == beforeCancellation)
        recognizer.touchesBegan(with: event(.began))
        button.cancelInteraction() // Live profile/visibility changes use this path.
        recognizer.touchesEnded(with: event(.ended))
        settle()
        precondition(target.events.count == beforeCancellation)
        recognizer.touchesBegan(with: event(.began))
        recognizer.touchesEnded(with: event(.ended, identity: "unrelated-finger"))
        precondition(target.events.count == beforeCancellation)
        recognizer.touchesEnded(with: event(.ended))
        settle()
        precondition(target.events.count == beforeCancellation + 1 && target.events.last == .tap)
        let beforeCustom = target.events.count
        button.longPressDuration = 0.9
        recognizer.touchesBegan(with: event(.began))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.7))
        precondition(target.events.count == beforeCustom, "A longer custom threshold must not fire at the default deadline")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        precondition(target.events.count == beforeCustom + 1 && target.events.last == .longPress)
        recognizer.touchesEnded(with: event(.ended)); settle()
        button.longPressDuration = 0.2
        recognizer.touchesBegan(with: event(.began))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        precondition(target.events.count == beforeCustom + 2 && target.events.last == .longPress)
        recognizer.touchesEnded(with: event(.ended)); settle()
        recognizer.touchesBegan(with: event(.began))
        button.longPressDuration = 0.6
        recognizer.touchesEnded(with: event(.ended)); settle()
        precondition(target.events.count == beforeCustom + 2, "Changing duration during a press cancels it")
        precondition(!window.isVisible)
    }
}

// AppKit declares these event objects @unchecked Sendable. The doubles retain
// only immutable values, matching that contract without mutable shared state.
private final class DirectTouch: NSTouch, @unchecked Sendable {
    private let token: NSString
    private let touchPhase: NSTouch.Phase
    private let point: NSPoint
    init(identity: String, phase: NSTouch.Phase, location: NSPoint) {
        token = identity as NSString; touchPhase = phase; point = location
        super.init()
    }
    override var identity: any NSObjectProtocol & NSCopying { token }
    override var type: NSTouch.TouchType { .direct }
    override var phase: NSTouch.Phase { touchPhase }
    override func location(in view: NSView?) -> NSPoint { point }
}

private final class DirectTouchEvent: NSEvent, @unchecked Sendable {
    private let touch: NSTouch
    private let modifiers: NSEvent.ModifierFlags
    init(touch: NSTouch, modifiers: NSEvent.ModifierFlags) {
        self.touch = touch; self.modifiers = modifiers
        super.init()
    }
    required init?(coder: NSCoder) { nil }
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
    override func touches(matching phase: NSTouch.Phase, in view: NSView?) -> Set<NSTouch> {
        phase.contains(touch.phase) ? [touch] : []
    }
}

@MainActor
private final class InteractionTarget: NSObject {
    var events: [ControlStripInteraction] = []
    @objc func pressed(_ sender: ControlStripActionButton) { events.append(sender.deliveredInteraction!) }
}
