import AppKit
import TouchBarBridge

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let settings: SettingsStore
    private var settingsWindow: SettingsWindowController?
    private var providers: [String: AppBar] = [:]
    private var presented: AppBar?
    private let barHost = AppBarHost()
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

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontAppChanged),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil)
        settings.onChange = { [weak self] in
            self?.hiddenForCurrentApp = false
            self?.settingsWindow?.refreshAppsIfNeeded()
            self?.applyRules()
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
        previewApp = nil
        settingsWindow?.window?.touchBar = nil
        settingsWindow?.window?.contentView?.touchBar = nil
        hiddenForCurrentApp = true
        dismissBar()
    }
    @objc private func showDiagnostics() {
        let alert = NSAlert()
        alert.messageText = "TouchBarEnhancer"
        alert.informativeText = "Private presentation API: \(TBIsAvailable() ? "available" : "unavailable")\nActive layout: \(previewApp?.name ?? presented?.app.name ?? "Native")\n\nApps previews use the window’s native Touch Bar. Other apps use system-modal presentation. Layouts are saved separately per app by AppKit."
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        clockTimer?.invalidate()
        dismissBar()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
