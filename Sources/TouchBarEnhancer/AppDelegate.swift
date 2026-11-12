import AppKit
import TouchBarBridge

/// Touch Bar buttons receive direct touches, not NSButtonCell's mouse loop.
/// Claim the stream on contact so AppKit's built-in click recognizer cannot
/// turn the release of an already handled hold into a second action.
@MainActor
final class ControlStripTouchRecognizer: NSGestureRecognizer {
    private var touchIdentity: (any NSObjectProtocol)?
    private var button: ControlStripActionButton? { view as? ControlStripActionButton }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = .direct
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowedTouchTypes = .direct
    }
    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        let touches = event.touches(matching: .began, in: view).filter { $0.type == .direct }
        guard !touches.isEmpty else { return }
        guard touchIdentity == nil, touches.count == 1, let touch = touches.first,
              let button, button.isEnabled, button.bounds.contains(touch.location(in: button)) else {
            cancelTouch()
            return
        }
        touchIdentity = touch.identity
        state = .began
        button.beginInteraction(modifiers: event.modifierFlags.union(button.currentModifiers()))
        button.highlight(true)
    }
    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        guard let touch = trackedTouch(in: event, phase: .moved), let button else { return }
        if !button.bounds.contains(touch.location(in: button)) { cancelTouch() }
    }
    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        guard let touch = trackedTouch(in: event, phase: .ended), let button else { return }
        if !button.bounds.contains(touch.location(in: button)) { button.cancelInteraction() }
        // sendAction suppresses taps after a long press or cancellation.
        _ = button.sendAction(button.action, to: button.target)
        button.highlight(false)
        state = .ended
    }
    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        if trackedTouch(in: event, phase: .cancelled) != nil { cancelTouch() }
    }
    private func trackedTouch(in event: NSEvent, phase: NSTouch.Phase) -> NSTouch? {
        guard let touchIdentity else { return nil }
        return event.touches(matching: phase, in: view).first {
            $0.type == .direct && touchIdentity.isEqual($0.identity)
        }
    }
    private func cancelTouch() {
        button?.cancelInteraction()
        button?.highlight(false)
        state = state == .possible ? .failed : .cancelled
    }
    override func reset() {
        if touchIdentity != nil {
            button?.highlight(false)
            button?.endInteraction()
        }
        touchIdentity = nil
        super.reset()
    }
    override func canBePrevented(by preventingGestureRecognizer: NSGestureRecognizer) -> Bool { false }
}

/// Preserve NSButton's native tracking loop and pressed feedback. The only timer
/// is a one-shot hold deadline, active while an unmodified press is held.
@MainActor
final class ControlStripActionCell: NSButtonCell {
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        isHighlighted = flag
        controlView.needsDisplay = true; controlView.displayIfNeeded()
    }
    override func trackMouse(with event: NSEvent, in cellFrame: NSRect, of controlView: NSView, untilMouseUp flag: Bool) -> Bool {
        guard let button = controlView as? ControlStripActionButton else {
            return super.trackMouse(with: event, in: cellFrame, of: controlView, untilMouseUp: flag)
        }
        button.beginInteraction(modifiers: event.modifierFlags.union(button.currentModifiers()))
        defer { button.endInteraction() }
        return super.trackMouse(with: event, in: cellFrame, of: controlView, untilMouseUp: flag)
    }
    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool { true }
    override func continueTracking(last lastPoint: NSPoint, current currentPoint: NSPoint, in controlView: NSView) -> Bool {
        if !controlView.bounds.contains(currentPoint) { (controlView as? ControlStripActionButton)?.cancelInteraction() }
        return true
    }
}

/// Use shared button colors with square corners inside the system's tray slot.
@MainActor
final class ControlStripActionButton: NSButton {
    // Direct Touch Bar events may omit hardware keyboard modifiers. Fixtures
    // inject an empty snapshot so the user's typing cannot alter queued input.
    var currentModifiers: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    var longPressDuration = ControlStripConfiguration.defaultLongPressDuration {
        didSet {
            if !ControlStripConfiguration.isValidLongPressDuration(longPressDuration) { longPressDuration = oldValue }
            if longPressDuration != oldValue { cancelInteraction() }
        }
    }
    private var holdTimer: Timer?
    private var trackingInteraction = false
    private var clickInteraction: ControlStripInteraction?
    private var consumedInteraction = false
    private(set) var deliveredInteraction: ControlStripInteraction?

    override class var cellClass: AnyClass? {
        get { ControlStripActionCell.self }
        set { super.cellClass = newValue }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installDirectTouchTracking()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installDirectTouchTracking()
    }
    private func installDirectTouchTracking() {
        allowedTouchTypes = .direct
        addGestureRecognizer(ControlStripTouchRecognizer(target: nil, action: nil))
    }
    func beginInteraction(modifiers: NSEvent.ModifierFlags) {
        endInteraction()
        trackingInteraction = true; consumedInteraction = false
        clickInteraction = ControlStripInteraction.click(modifiers: modifiers)
        guard isEnabled, clickInteraction == .tap else { return }
        let timer = Timer(timeInterval: longPressDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.recognizeLongPress() }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }
    func recognizeLongPress() {
        guard isEnabled, trackingInteraction, !consumedInteraction, clickInteraction == .tap else { return }
        consumedInteraction = true
        holdTimer?.invalidate(); holdTimer = nil
        _ = deliver(.longPress, action: action, target: target)
    }
    func cancelInteraction() {
        holdTimer?.invalidate(); holdTimer = nil
        // Retain the cancellation until the native tracking loop finishes, so a
        // late mouse-up after hide/configuration changes cannot become a tap.
        if trackingInteraction { consumedInteraction = true }
    }
    func endInteraction() {
        holdTimer?.invalidate(); holdTimer = nil
        trackingInteraction = false; consumedInteraction = false; clickInteraction = nil
    }
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard isEnabled else { return false }
        if trackingInteraction {
            guard !consumedInteraction, let clickInteraction else { return false }
            consumedInteraction = true
            holdTimer?.invalidate(); holdTimer = nil
            return deliver(clickInteraction, action: action, target: target)
        }
        return deliver(.tap, action: action, target: target)
    }
    private func deliver(_ interaction: ControlStripInteraction, action: Selector?, target: Any?) -> Bool {
        deliveredInteraction = interaction
        defer { deliveredInteraction = nil }
        return super.sendAction(action, to: target)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelInteraction() }
    }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
        displayIfNeeded()
    }
    override func draw(_ dirtyRect: NSRect) {
        let background = isHighlighted ? ChatSideButton.pressedBackground : ChatSideButton.normalBackground
        background.setFill()
        NSBezierPath(rect: bounds).fill()
        guard let image else { return }
        let size = image.size
        let scale = min(1, min(bounds.width / max(size.width, 1), bounds.height / max(size.height, 1)))
        let rect = NSRect(x: (bounds.width - size.width * scale) / 2,
            y: (bounds.height - size.height * scale) / 2, width: size.width * scale, height: size.height * scale)
        // Native NSButtonCell dims a borderless button in a background app.
        // Keep native tracking/action, but draw the symbol at full opacity.
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// A separate system-tray item, retained independently of the per-app bar.
@MainActor
final class ControlStripButton: NSObject {
    static let identifier = NSTouchBarItem.Identifier("local.starfruit.TouchBarEnhancer.controlstrip.toggle")
    let item = NSCustomTouchBarItem(identifier: identifier)
    let button: ControlStripActionButton
    private(set) var isRegistered = false
    var onPress: (() -> Void)?
    var onInteraction: ((ControlStripInteraction) -> Void)?
    private var configuration: ControlStripConfiguration?

    override init() {
        button = ControlStripActionButton(image: NSImage(systemSymbolName: ControlStripConfiguration.defaultSymbol, accessibilityDescription: "TouchBarEnhancer")!,
            target: nil, action: nil)
        super.init()
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.target = self; button.action = #selector(pressed)
        item.view = button
        item.customizationLabel = "TouchBarEnhancer"
        update(enabled: false, paused: false)
    }
    func update(enabled: Bool, paused: Bool, configuration: ControlStripConfiguration = .init()) {
        if self.configuration != configuration { button.cancelInteraction() }
        self.configuration = configuration
        button.longPressDuration = ControlStripConfiguration.isValidLongPressDuration(configuration.longPressDuration)
            ? configuration.longPressDuration : ControlStripConfiguration.defaultLongPressDuration
        let symbol = paused && configuration.action == .toggleEnhancement && configuration.symbol == ControlStripConfiguration.defaultSymbol
            ? "rectangle.slash" : configuration.symbol
        button.image = (NSImage(systemSymbolName: symbol, accessibilityDescription: "TouchBarEnhancer")
            ?? NSImage(systemSymbolName: ControlStripConfiguration.defaultSymbol, accessibilityDescription: "TouchBarEnhancer"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
                .applying(.init(paletteColors: [.white])))
        let action = configuration.action == .toggleEnhancement
            ? (paused ? "Resume TouchBarEnhancer" : "Pause TouchBarEnhancer") : configuration.action.title
        button.toolTip = ControlStripInteraction.allCases.compactMap { gesture -> String? in
            let binding = configuration.binding(for: gesture)
            guard binding.action != .none else { return nil }
            return "\(gesture.title): \(gesture == .tap ? action : binding.action.title)"
        }.joined(separator: "\n")
        button.setAccessibilityLabel(action)
        let visible = enabled && configuration.showsButton
        button.isEnabled = visible
        if visible && !isRegistered { isRegistered = TBControlStripRegister(item) }
        else if !visible { remove() }
    }
    func remove() {
        button.cancelInteraction()
        guard isRegistered else { return }
        TBControlStripUnregister(item); isRegistered = false
    }
    @objc private func pressed() {
        guard isRegistered else { return }
        if let onInteraction { onInteraction(button.deliveredInteraction ?? .tap) }
        else { onPress?() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings: SettingsStore
    private var settingsWindow: SettingsWindowController?
    private var providers: [String: AppBar] = [:]
    private var presented: AppBar?
    private let barHost = AppBarHost()
    private let controlStrip = ControlStripButton()
    private let controlStripActions = ControlStripActionRunner()
    private let controlStripAutomation = ControlStripAutomationMonitor(readMedia: { completion in
        TBReadMediaPlaying { value in
            MainActor.assumeIsolated { completion(value?.boolValue) }
        }
    }, observeMedia: { changed in
        guard let observation = TBObserveMediaPlaying({ value in
            MainActor.assumeIsolated { changed(value?.boolValue) }
        }) else { return nil }
        return { TBStopObservingMediaPlaying(observation) }
    })
    private var effectiveControlStripConfiguration = ControlStripConfiguration()
    private var previewApp: LayoutApp?
    private var hiddenForCurrentApp = false
    private var clockTimer: Timer?
    var enhancedAppBundleID: String? { presented?.app.bundleID }

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = true
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Customize Touch Bar…", action: #selector(NSApplication.toggleTouchBarCustomizationPalette(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Quit TouchBarEnhancer", action: #selector(quit), keyEquivalent: "q").target = self
        let root = NSMenuItem()
        root.submenu = appMenu
        mainMenu.addItem(root)
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editRoot.submenu = ApplicationMenus.editMenu()
        mainMenu.addItem(editRoot)
        NSApp.mainMenu = mainMenu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "TB"
        statusItem.button?.toolTip = "TouchBarEnhancer"
        let menu = NSMenu()
        addMenuItem("Settings…", action: #selector(openSettings), to: menu)
        menu.addItem(.separator())
        addMenuItem("Show Touch Bar", action: #selector(showBar), to: menu)
        addMenuItem("Hide and Restore System Bar", action: #selector(hideBar), to: menu)
        menu.addItem(.separator())
        addMenuItem("About and Diagnostics", action: #selector(showDiagnostics), to: menu)
        menu.addItem(.separator())
        addMenuItem("Quit TouchBarEnhancer", action: #selector(quit), to: menu)
        statusItem.menu = menu
        controlStripActions.skipMedia = { TBSkipMedia($0) }
        controlStrip.onInteraction = { [weak self] interaction in
            guard let self else { return }
            self.statusItem.button?.toolTip = "TouchBarEnhancer"
            self.settingsWindow?.showControlStripError(nil)
            self.controlStripActions.perform(self.effectiveControlStripConfiguration, interaction: interaction) {
                self.settings.paused.toggle()
                self.settings.save()
            }
        }
        controlStripActions.onError = { [weak self] message in
            self?.statusItem.button?.toolTip = message
            self?.settingsWindow?.showControlStripError(message)
            NSSound.beep()
        }
        controlStripAutomation.onChange = { [weak self] in self?.updateControlStrip() }
        configureControlStripAutomation()

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        settings.onChange = { [weak self] in
            guard let self else { return }
            self.configureControlStripAutomation()
            self.hiddenForCurrentApp = false
            self.settingsWindow?.refreshAppsIfNeeded()
            self.applyRules()
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let visible = NSApp.isActive && self.settingsWindow?.window?.isVisible == true
                    ? self.previewApp.flatMap { self.providers[$0.bundleID] } ?? self.presented
                    : self.presented
                visible?.updateChatGPTStatus()
            }
        }
        applyRules()
        if !settings.launchSilently { openSettings() }
    }

    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func configureControlStripAutomation() {
        controlStripAutomation.configure(enabled: settings.showControlStripButton, rules: settings.controlStripAutomationRules)
        updateControlStrip()
    }
    private func updateControlStrip() {
        // Commit the displayed symbol and the action for its next tap together.
        effectiveControlStripConfiguration = controlStripAutomation.activeRule?.configuration ?? settings.controlStripConfiguration
        controlStrip.update(enabled: settings.showControlStripButton, paused: settings.paused,
                            configuration: effectiveControlStripConfiguration)
        settingsWindow?.showControlStripAutomation(controlStripAutomation.activeRule?.name,
            buttonVisible: settings.showControlStripButton && effectiveControlStripConfiguration.showsButton,
            playbackUnavailable: controlStripAutomation.isMonitoring && controlStripAutomation.needsMedia && controlStripAutomation.mediaIsPlaying == nil)
    }

    private func provider(for app: LayoutApp) -> AppBar {
        if let cached = providers[app.bundleID],
           cached.usesChatGPTControls == (app.isChatGPT && settings.chatGPTControlsEnabled) {
            cached.configureChats(settings.chatShortcuts)
            cached.configurePhrases(settings.quickPhrasesByApp[app.bundleID] ?? [])
            cached.configureKeyboardButtons(settings.keyboardButtons[app.bundleID] ?? .init())
            cached.configureComponentDisplayModes(settings.componentDisplayModes[app.bundleID] ?? [:])
            cached.configureComponentPresentations(settings.componentPresentations[app.bundleID] ?? [:])
            cached.configureText(settings.textComponents[app.bundleID] ?? TextComponentItem.initial)
            return cached
        }
        let result = AppBar(app: app, chatGPTControlsEnabled: settings.chatGPTControlsEnabled,
                            shortcuts: settings.chatShortcuts, phrases: settings.quickPhrasesByApp[app.bundleID] ?? [],
                            keyboardButtons: settings.keyboardButtons[app.bundleID] ?? .init(),
                            componentDisplayModes: settings.componentDisplayModes[app.bundleID] ?? [:],
                            componentPresentations: settings.componentPresentations[app.bundleID] ?? [:],
                            textItems: settings.textComponents[app.bundleID] ?? TextComponentItem.initial)
        providers[app.bundleID] = result
        return result
    }

    @objc private func frontAppChanged(_ notification: Notification) {
        hiddenForCurrentApp = false
        applyRules()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let controller = SettingsWindowController(store: settings)
            controller.onPreviewApp = { [weak self] app in
                self?.previewApp = app
                self?.applyRules()
            }
            controller.onCustomizeApp = { [weak self] app in self?.customize(app) }
            settingsWindow = controller
        }
        updateControlStrip()
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.resumePreviewIfNeeded()
        applyRules()
    }

    private func customize(_ app: LayoutApp) {
        previewApp = app
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        applyRules()
        // Let AppKit publish the window's normal responder-chain bar before editing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.previewApp?.bundleID == app.bundleID,
                  self.settingsWindow?.window?.isVisible == true else { return }
            NSApp.toggleTouchBarCustomizationPalette(nil)
        }
    }

    private func applyRules() {
        guard statusItem != nil else { return }
        let app = NSWorkspace.shared.frontmostApplication
        if let previewApp, settingsWindow?.window?.isVisible == true, NSApp.isActive {
            dismissBar()
            let bar = provider(for: previewApp).bar
            settingsWindow?.window?.touchBar = bar
            settingsWindow?.window?.contentView?.touchBar = bar
            statusItem.button?.title = "TB ◇"
            settingsWindow?.update(status: "Preview · \(previewApp.name) · temporary; rules unchanged")
            return
        }
        settingsWindow?.window?.touchBar = nil
        settingsWindow?.window?.contentView?.touchBar = nil
        let id = app?.bundleIdentifier ?? ""
        let name = app?.localizedName ?? "Unknown App"
        let enabled = settings.shouldEnhance(id, manuallyHidden: hiddenForCurrentApp)
        if enabled {
            present(provider(for: LayoutApp(bundleID: id, name: name)))
        } else { dismissBar() }
        let mode = settings.mode(for: id)
        let autoReason = mode == .auto ? "Auto / \(settings.autoPolicy.rawValue)" : mode.rawValue
        let reason = settings.paused ? "Paused" : (hiddenForCurrentApp ? "Hidden" : autoReason)
        settingsWindow?.update(status: "\(name) · \(reason) → \(enabled ? "Custom Bar" : "Native Bar")")
    }

    private func present(_ provider: AppBar) {
        guard presented !== provider else { return }
        barHost.display(provider)
        // Changing apps must not dismiss the modal host and expose the native bar.
        if presented != nil || TBPresent(barHost.bar) { presented = provider }
        statusItem.button?.title = presented != nil ? "TB ●" : "TB !"
    }

    private func dismissBar() {
        if presented != nil { _ = TBDismiss(barHost.bar) }
        presented = nil
        statusItem.button?.title = "TB"
    }

    @objc private func showBar() { hiddenForCurrentApp = false; applyRules() }
    @objc private func hideBar() {
        previewApp = nil
        hiddenForCurrentApp = true
        applyRules()
    }
    @objc private func willSleep(_ notification: Notification) {
        controlStripAutomation.stop()
        previewApp = nil
        settingsWindow?.window?.touchBar = nil
        settingsWindow?.window?.contentView?.touchBar = nil
        hiddenForCurrentApp = true
        dismissBar()
    }
    @objc private func didWake(_ notification: Notification) {
        configureControlStripAutomation()
    }
    @objc private func showDiagnostics() {
        let alert = NSAlert()
        alert.messageText = "TouchBarEnhancer"
        alert.informativeText = "Private presentation API: \(TBIsAvailable() ? "available" : "unavailable")\nControl Strip API: \(TBControlStripIsAvailable() ? "available" : "unavailable")\nControl Strip item: \(controlStrip.isRegistered ? "registered" : "not registered")\nActive layout: \(previewApp?.name ?? presented?.app.name ?? "Native")\n\nApps previews use the window’s native Touch Bar. Other apps use system-modal presentation. Layouts are saved separately per app by AppKit."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        clockTimer?.invalidate()
        settings.onChange = nil
        controlStripAutomation.onChange = nil
        controlStripAutomation.stop()
        dismissBar()
        controlStrip.remove()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
