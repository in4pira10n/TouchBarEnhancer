import AppKit

/// Routes a private pasteboard through the native table drop callbacks.
@MainActor
private final class ControlStripRuleDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(source: NSTableView, pasteboard: NSPasteboard) {
        draggingSource = source; draggingPasteboard = pasteboard
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@main @MainActor
struct ControlStripSettingsSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func render(_ view: NSView, name: String) {
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill()
            view.displayIgnoringOpacity(view.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
        }
        try! bitmap.representation(using: .png, properties: [:])!.write(to:
            URL(fileURLWithPath: ".build/settings-ui/control-strip-\(name).png"))
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let clipboardCount = NSPasteboard.general.changeCount
        let suite = "TouchBarEnhancer.ControlStripSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        precondition(store.controlStripConfiguration == .init() && store.showControlStripButton)
        precondition(try! JSONDecoder().decode(ControlStripConfiguration.self, from: Data("{}".utf8)) == .init())
        precondition(store.controlStripConfiguration.longPressDuration == 0.6)
        for raw in ["0", "-1", "100"] {
            let legacy = try! JSONDecoder().decode(ControlStripConfiguration.self,
                from: Data("{\"longPressDuration\":\(raw)}".utf8))
            precondition(legacy.longPressDuration == 0.6)
        }
        let hiddenConfig = try! JSONDecoder().decode(ControlStripConfiguration.self,
            from: Data("{\"showsButton\":false,\"action\":\"runShortcut\"}".utf8))
        precondition(!hiddenConfig.showsButton && hiddenConfig.validationMessage == nil)
        precondition(try! JSONDecoder().decode(ControlStripConfiguration.self,
            from: JSONEncoder().encode(hiddenConfig)) == hiddenConfig)
        let controller = SettingsWindowController(store: store)
        let window = controller.window!
        let item = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "controlStrip" }!
        let top = window.frame.maxY
        precondition(app.sendAction(item.action!, to: item.target, from: item))
        precondition(abs(window.frame.maxY - top) < 0.5)
        let pane = window.contentView!.subviews.first as! ControlStripSettingsPane
        func field(_ identifier: String) -> NSTextField {
            descendants(pane).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == identifier }!
        }
        let symbol = field("stripSymbol")
        symbol.stringValue = "star.fill"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: symbol))
        precondition(SettingsStore(defaults: defaults).controlStripConfiguration.symbol == "star.fill")
        symbol.stringValue = "not.a.real.symbol.123"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: symbol))
        precondition(store.controlStripConfiguration.symbol == "star.fill")
        precondition(!field("stripValidation").stringValue.isEmpty)
        descendants(pane).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "stripResetSymbol" }!.performClick(nil)
        precondition(symbol.stringValue == ControlStripConfiguration.defaultSymbol)

        let popup = descendants(pane).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "stripAction" }!
        let input = descendants(pane).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "stripShortcutInput" }!
        let text = descendants(pane).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "stripText" }!
        func choose(_ action: ControlStripAction) {
            popup.selectItem(at: ControlStripAction.allCases.firstIndex(of: action)!)
            precondition(app.sendAction(popup.action!, to: popup.target, from: popup))
            pane.layoutSubtreeIfNeeded()
            precondition(store.controlStripConfiguration.action == action)
        }
        choose(.pasteText)
        precondition(!text.isHiddenOrHasHiddenAncestor)
        text.string = "First line\n第二行 🧪"
        pane.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
        precondition(SettingsStore(defaults: defaults).controlStripConfiguration.text == text.string)
        precondition(!text.isRichText && text.allowsUndo)
        pane.layoutSubtreeIfNeeded()
        let popupRect = pane.convert(popup.bounds, from: popup)
        let textRect = pane.convert(text.enclosingScrollView!.bounds, from: text.enclosingScrollView!)
        precondition(popupRect.minY - textRect.maxY < 24, "A scroll view must not inherit the grid's baseline spacing")
        render(window.contentView!, name: "paste-text")
        choose(.runShortcut)
        let name = field("stripShortcutName")
        name.stringValue = "My Shortcut \"中文\" $(untouched)"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
        input.selectItem(at: ControlStripShortcutInput.allCases.firstIndex(of: .text)!)
        precondition(app.sendAction(input.action!, to: input.target, from: input))
        precondition(!text.isHiddenOrHasHiddenAncestor && !name.isHiddenOrHasHiddenAncestor)
        precondition(store.controlStripConfiguration.validationMessage == nil)
        precondition(store.controlStripConfiguration.shortcutArguments(inputPath: "/tmp/a b/input.txt") ==
            ["run", "--input-path", "/tmp/a b/input.txt", "--", name.stringValue])
        render(window.contentView!, name: "shortcut")
        // A live edit must keep the actual field editor attached for selection/paste.
        name.selectText(nil)
        if let editor = name.currentEditor() {
            name.stringValue += " edited"
            pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
            precondition(name.currentEditor() === editor && window.firstResponder === editor)
        } else { preconditionFailure("Native name field must retain its field editor") }
        window.makeFirstResponder(nil)
        choose(.keyboardShortcut)
        let recorder = descendants(pane).compactMap { $0 as? KeyboardShortcutRecorder }.first!
        let binding = KeyboardShortcut(keyCode: 36, modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "↩")
        recorder.shortcut = binding; recorder.onChange?()
        precondition(SettingsStore(defaults: defaults).controlStripConfiguration.keyboardShortcut == binding)
        render(window.contentView!, name: "keyboard")
        choose(.openURL)
        let url = field("stripURL")
        url.stringValue = "https://example.com/path?q=test"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: url))
        precondition(store.controlStripConfiguration.validationMessage == nil)
        for mode in ControlStripAction.allCases { choose(mode) }
        for mode in [ControlStripAction.previousMedia, .nextMedia] {
            choose(mode)
            precondition(SettingsStore(defaults: defaults).controlStripConfiguration.action == mode)
            precondition(text.isHiddenOrHasHiddenAncestor && name.isHiddenOrHasHiddenAncestor &&
                url.isHiddenOrHasHiddenAncestor && recorder.isHiddenOrHasHiddenAncestor,
                "System media actions need no text, URL, shortcut or keyboard configuration")
        }
        render(window.contentView!, name: "next-media")
        let restored = SettingsStore(defaults: defaults).controlStripConfiguration
        precondition(restored.text == text.string && restored.keyboardShortcut == binding && restored.shortcutName == name.stringValue)
        choose(.toggleEnhancement)
        let interaction = descendants(pane).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "stripInteraction" }!
        func chooseInteraction(_ gesture: ControlStripInteraction) {
            window.makeFirstResponder(nil)
            interaction.selectItem(at: ControlStripInteraction.allCases.firstIndex(of: gesture)!)
            precondition(app.sendAction(interaction.action!, to: interaction.target, from: interaction))
        }
        let duration = field("stripLongPressDuration")
        precondition(duration.isHiddenOrHasHiddenAncestor)
        chooseInteraction(.longPress)
        precondition(!duration.isHiddenOrHasHiddenAncestor && duration.doubleValue == 0.6)
        duration.selectText(nil)
        let durationEditor = duration.currentEditor()
        duration.stringValue = "1.2"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: duration))
        precondition(SettingsStore(defaults: defaults).controlStripConfiguration.longPressDuration == 1.2)
        precondition(durationEditor != nil && duration.currentEditor() === durationEditor)
        for invalid in ["", "0", "-1", "nan", "inf", "11", "abc"] {
            duration.stringValue = invalid
            pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: duration))
            precondition(SettingsStore(defaults: defaults).controlStripConfiguration.longPressDuration == 1.2)
            precondition(!field("stripValidation").stringValue.isEmpty)
        }
        window.makeFirstResponder(nil)
        descendants(pane).compactMap { $0 as? NSButton }.first {
            $0.accessibilityIdentifier() == "stripResetLongPressDuration"
        }!.performClick(nil)
        precondition(duration.doubleValue == 0.6 && store.controlStripConfiguration.longPressDuration == 0.6)
        render(window.contentView!, name: "long-press-duration")
        chooseInteraction(.tap)
        precondition(duration.isHiddenOrHasHiddenAncestor)
        let savedTap = store.controlStripConfiguration.binding(for: .tap)
        for gesture in ControlStripInteraction.allCases where gesture != .tap {
            precondition(store.controlStripConfiguration.binding(for: gesture).action == .none,
                "Legacy configurations must not gain unexpected actions")
            chooseInteraction(gesture)
            precondition(popup.indexOfSelectedItem == ControlStripAction.allCases.firstIndex(of: .none))
            popup.selectItem(at: ControlStripAction.allCases.firstIndex(of: .copyText)!)
            precondition(app.sendAction(popup.action!, to: popup.target, from: popup))
            text.string = gesture.rawValue + " 独立动作"
            pane.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
            precondition(store.controlStripConfiguration.binding(for: gesture).text == text.string)
            precondition(store.controlStripConfiguration.binding(for: .tap) == savedTap)
        }
        render(window.contentView!, name: "interaction-actions")
        for gesture in ControlStripInteraction.allCases where gesture != .tap {
            chooseInteraction(gesture)
            precondition(text.string == gesture.rawValue + " 独立动作")
        }
        precondition(SettingsStore(defaults: defaults).controlStripConfiguration == store.controlStripConfiguration)
        precondition(try! JSONDecoder().decode(ControlStripConfiguration.self,
            from: JSONEncoder().encode(store.controlStripConfiguration)) == store.controlStripConfiguration)
        chooseInteraction(.tap)
        precondition(popup.indexOfSelectedItem == ControlStripAction.allCases.firstIndex(of: savedTap.action))
        render(window.contentView!, name: "toggle")
        window.setContentSize(NSSize(width: 1000, height: 640)); window.layoutIfNeeded()
        render(window.contentView!, name: "resized")
        precondition(window.styleMask.contains(.resizable) && !window.isVisible)
        checkAutomations(store: store, defaults: defaults, pane: pane, window: window)
        // Every profile retains its own hold duration across selection/reload.
        let profiles = descendants(pane).compactMap { $0 as? NSTableView }.first {
            $0.accessibilityIdentifier() == "stripProfile"
        }!
        var durationRule = ControlStripAutomationRule()
        durationRule.configuration.longPressDuration = 1.4
        store.controlStripAutomationRules.append(durationRule)
        // Refresh the pane's model-backed table without altering any user data.
        profiles.reloadData()
        profiles.selectRowIndexes(IndexSet(integer: store.controlStripAutomationRules.count), byExtendingSelection: false)
        chooseInteraction(.longPress)
        precondition(duration.doubleValue == 1.4)
        duration.stringValue = "0.9"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: duration))
        precondition(store.controlStripAutomationRules.last!.configuration.longPressDuration == 0.9)
        precondition(SettingsStore(defaults: defaults).controlStripAutomationRules.last!.configuration.longPressDuration == 0.9)
        profiles.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        precondition(duration.doubleValue == 0.6 && store.controlStripConfiguration.longPressDuration == 0.6)

        // Dispatch tests use a private pasteboard and mock event/URL effects.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let runner = ControlStripActionRunner(pasteboard: board)
        var mediaCommands: [Bool] = []
        runner.skipMedia = { mediaCommands.append($0); return true }
        var failure: String?
        runner.onError = { failure = $0 }
        var toggles = 0
        runner.perform(.init()) { toggles += 1 }
        precondition(toggles == 1)
        var config = ControlStripConfiguration()
        config.action = .copyText; config.text = "Clipboard 🧪\nSecond line"
        runner.perform(config) { preconditionFailure() }
        precondition(board.string(forType: .string) == config.text)
        var events: [(KeyboardShortcut?, String)] = []
        var pastes: [(String, String)] = []
        runner.targetBundleID = { "test.frontmost" }
        runner.sendKeyboard = { events.append(($0, $1)); return nil }
        runner.pasteText = { pastes.append(($0, $1)); return nil }
        let beforePaste = board.changeCount
        config.action = .pasteClipboard
        runner.perform(config) { preconditionFailure() }
        precondition(events.last?.0?.keyCode == 9 && events.last?.1 == "test.frontmost" && board.changeCount == beforePaste)
        config.action = .pasteText
        runner.perform(config) { preconditionFailure() }
        precondition(pastes.last?.0 == config.text && pastes.last?.1 == "test.frontmost")
        config.action = .keyboardShortcut; config.keyboardShortcut = binding
        runner.perform(config) { preconditionFailure() }
        precondition(events.last?.0 == binding)
        config.action = .openURL; config.url = "test-app://open?value=1"
        var opened: URL?
        runner.openURL = { opened = $0; return true }
        runner.perform(config) { preconditionFailure() }
        precondition(opened?.absoluteString == config.url)
        config.url = "invalid"
        runner.perform(config) { preconditionFailure() }
        precondition(failure != nil)
        failure = nil
        config.action = .runShortcut; config.shortcutName = ""
        runner.perform(config) { preconditionFailure() }
        precondition(failure != nil) // Must not launch Shortcuts for incomplete settings.
        failure = nil
        runner.targetBundleID = { nil }
        let beforeMediaClipboard = board.changeCount
        let beforeMediaKeys = events.count
        for gesture in ControlStripInteraction.allCases {
            for action in [ControlStripAction.previousMedia, .nextMedia] {
                var mediaConfig = ControlStripConfiguration()
                var mediaBinding = ControlStripActionBinding()
                mediaBinding.action = action
                mediaConfig.setBinding(mediaBinding, for: gesture)
                precondition(try! JSONDecoder().decode(ControlStripConfiguration.self,
                    from: JSONEncoder().encode(mediaConfig)) == mediaConfig)
                runner.perform(mediaConfig, interaction: gesture) { preconditionFailure() }
                precondition(mediaCommands.last == (action == .nextMedia) && failure == nil)
            }
        }
        precondition(mediaCommands == Array(repeating: [false, true], count: ControlStripInteraction.allCases.count).flatMap { $0 })
        precondition(board.changeCount == beforeMediaClipboard && events.count == beforeMediaKeys,
            "Media transport must not depend on foreground input or touch the clipboard")
        runner.skipMedia = { _ in false }
        config.action = .nextMedia
        runner.perform(config) { preconditionFailure() }
        precondition(failure == "The system could not accept the media command.")
        failure = nil
        runner.skipMedia = { mediaCommands.append($0); return true }
        config.action = .pasteText
        let oldPastes = pastes.count
        runner.perform(config) { preconditionFailure() }
        precondition(failure != nil && pastes.count == oldPastes)
        // A hidden configuration cannot dispatch even a stale/programmatic tap.
        failure = nil
        var interactionConfig = ControlStripConfiguration()
        interactionConfig.action = .copyText; interactionConfig.text = "tap action"
        for gesture in ControlStripInteraction.allCases where gesture != .tap {
            var binding = ControlStripActionBinding()
            binding.action = .copyText; binding.text = gesture.rawValue
            interactionConfig.setBinding(binding, for: gesture)
            runner.perform(interactionConfig, interaction: gesture) { preconditionFailure() }
            precondition(board.string(forType: .string) == gesture.rawValue)
        }
        runner.perform(interactionConfig) { preconditionFailure() }
        precondition(board.string(forType: .string) == "tap action")
        var invalidAlternate = ControlStripActionBinding()
        invalidAlternate.action = .keyboardShortcut
        interactionConfig.setBinding(invalidAlternate, for: .optionTap)
        runner.perform(interactionConfig, interaction: .optionTap) { preconditionFailure() }
        precondition(failure != nil)
        failure = nil
        runner.perform(interactionConfig) { preconditionFailure() }
        precondition(failure == nil, "An invalid alternate action must not block a valid tap")
        let hiddenClipboardCount = board.changeCount
        let hiddenEvents = events.count, hiddenPastes = pastes.count, hiddenToggles = toggles
        let hiddenMediaCommands = mediaCommands.count
        opened = nil
        for action in ControlStripAction.allCases {
            config.showsButton = false; config.action = action
            runner.perform(config) { toggles += 1 }
        }
        precondition(board.changeCount == hiddenClipboardCount && events.count == hiddenEvents &&
            pastes.count == hiddenPastes && toggles == hiddenToggles && opened == nil && failure == nil &&
            mediaCommands.count == hiddenMediaCommands)
        precondition(NSPasteboard.general.changeCount == clipboardCount)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        print("Control Strip settings checks passed: legacy defaults, persistence, live native editor, validation, all action forms, safe dispatch, isolated clipboard, shortcut arguments, resize and no activation")
    }

    static func checkAutomations(store: SettingsStore, defaults: UserDefaults, pane: ControlStripSettingsPane, window: NSWindow) {
        let airpods = ControlStripBluetoothDevice(address: "AA-BB-CC-DD-EE-01", name: "AirPods", connected: true)
        let second = ControlStripBluetoothDevice(address: "AA:BB:CC:DD:EE:02", name: "AirPods", connected: false)
        var combined = ControlStripAutomationRule()
        combined.enabled = true; combined.deviceAddress = airpods.address
        combined.mediaPlaying = true; combined.name = "AirPods + Playing"
        combined.configuration.symbol = "airpodspro"
        var playing = ControlStripAutomationRule()
        playing.enabled = true; playing.bluetoothConnected = false; playing.mediaPlaying = true
        playing.name = "Playing"; playing.configuration.symbol = "music.note"
        precondition(combined.matches([airpods], mediaIsPlaying: true))
        precondition(!combined.matches([airpods], mediaIsPlaying: false))
        precondition(!combined.matches([airpods], mediaIsPlaying: nil))
        precondition(!combined.matches([second], mediaIsPlaying: true), "Names do not identify Bluetooth devices")
        precondition(ControlStripAutomationRule.active(in: [combined, playing], devices: [airpods], mediaIsPlaying: true)?.id == combined.id)
        precondition(ControlStripAutomationRule.active(in: [playing, combined], devices: [airpods], mediaIsPlaying: true)?.id == playing.id)
        let legacy = try! JSONDecoder().decode(ControlStripAutomationRule.self, from: Data("{\"enabled\":true,\"deviceAddress\":\"AA:BB:CC:DD:EE:01\"}".utf8))
        precondition(legacy.bluetoothConnected && !legacy.mediaPlaying && legacy.matches([airpods], mediaIsPlaying: nil))
        var invalid = playing
        invalid.mediaPlaying = false
        precondition(!invalid.matches([], mediaIsPlaying: true) && !invalid.hasValidConditions)

        var deviceReads = 0, mediaReads = 0
        var connected = [airpods]
        var isPlaying: Bool? = true
        let monitor = ControlStripAutomationMonitor(readDevices: { deviceReads += 1; return connected },
            readMedia: { mediaReads += 1; $0(isPlaying) })
        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.configure(enabled: true, rules: [])
        monitor.configure(enabled: false, rules: [combined, playing])
        precondition(!monitor.isMonitoring && deviceReads == 0 && mediaReads == 0)
        monitor.configure(enabled: true, rules: [combined, playing])
        precondition(monitor.activeRule?.id == combined.id, "Already connected and playing must match at startup")
        var hiddenRule = combined
        hiddenRule.configuration.showsButton = false
        monitor.configure(enabled: true, rules: [hiddenRule, playing])
        precondition(monitor.isMonitoring && monitor.activeRule?.id == hiddenRule.id &&
            monitor.activeRule?.configuration.showsButton == false,
            "A hidden rule still wins priority and keeps condition monitoring active")
        connected = []; monitor.refresh()
        precondition(monitor.activeRule?.id == playing.id)
        isPlaying = false; monitor.refresh()
        precondition(monitor.activeRule == nil, "Pause must restore Default")
        isPlaying = true; monitor.refresh()
        precondition(monitor.activeRule?.id == playing.id)
        isPlaying = nil; monitor.refresh()
        precondition(monitor.activeRule == nil && monitor.mediaIsPlaying == nil, "Unknown must not match Playing")
        monitor.stop()
        let beforeBT = deviceReads
        isPlaying = true
        monitor.configure(enabled: true, rules: [playing])
        precondition(monitor.activeRule?.id == playing.id && deviceReads == beforeBT, "Media-only must not read Bluetooth")
        monitor.stop()
        let beforeMedia = mediaReads
        connected = [airpods]
        monitor.configure(enabled: true, rules: [legacy])
        precondition(monitor.activeRule?.id == legacy.id && mediaReads == beforeMedia)
        monitor.configure(enabled: true, rules: [invalid])
        precondition(!monitor.isMonitoring && monitor.activeRule == nil && changes > 0)

        var replies: [@MainActor (Bool?) -> Void] = []
        let asynchronous = ControlStripAutomationMonitor(readDevices: { preconditionFailure("No Bluetooth needed") },
            readMedia: { replies.append($0) })
        asynchronous.configure(enabled: true, rules: [playing])
        precondition(replies.count == 1)
        asynchronous.refresh()
        precondition(replies.count == 1, "Do not stack pending queries")
        asynchronous.stop(); replies[0](true)
        precondition(asynchronous.activeRule == nil)
        asynchronous.configure(enabled: true, rules: [playing]); replies[1](true)
        precondition(asynchronous.activeRule?.id == playing.id)
        asynchronous.refresh()
        var updated = playing; updated.configuration.symbol = "pause.fill"
        asynchronous.configure(enabled: true, rules: [updated])
        replies[2](false) // Outdated result must not override the new configuration.
        precondition(asynchronous.activeRule?.configuration.symbol == "pause.fill")
        replies[3](nil)
        precondition(asynchronous.activeRule == nil)
        asynchronous.stop()

        // Playback changes are push events. No media timer, even for a hidden
        // winning rule; stale queries and stopped observation events are ignored.
        var mediaCallbacks: [@MainActor (Bool?) -> Void] = []
        var mediaQueries: [@MainActor (Bool?) -> Void] = []
        var observationStarts = 0, observationStops = 0
        let pushed = ControlStripAutomationMonitor(readDevices: { [] },
            readMedia: { mediaQueries.append($0) }, observeMedia: { changed in
                observationStarts += 1; mediaCallbacks.append(changed)
                return { observationStops += 1 }
            })
        var hiddenPlaying = playing
        hiddenPlaying.configuration.showsButton = false
        pushed.configure(enabled: true, rules: [hiddenPlaying])
        precondition(pushed.isMonitoring && !pushed.isPollingBluetooth && observationStarts == 1 && mediaQueries.count == 1)
        mediaCallbacks[0](true)
        precondition(pushed.activeRule?.id == hiddenPlaying.id && mediaQueries.count == 1,
            "The system playing event applies immediately, without another query or timer")
        mediaQueries[0](false)
        precondition(pushed.activeRule?.id == hiddenPlaying.id, "An older query cannot overwrite a newer playback event")
        mediaCallbacks[0](false)
        precondition(pushed.activeRule == nil && mediaQueries.count == 1)
        mediaCallbacks[0](true)
        precondition(pushed.activeRule?.configuration.showsButton == false && observationStarts == 1)
        mediaCallbacks[0](nil)
        precondition(mediaQueries.count == 2 && pushed.activeRule?.id == hiddenPlaying.id,
            "A source change performs one fresh read without flickering to Default before the reply")
        mediaQueries[1](true)
        precondition(pushed.activeRule?.id == hiddenPlaying.id)
        pushed.configure(enabled: true, rules: [combined, hiddenPlaying])
        precondition(pushed.isPollingBluetooth && observationStarts == 1, "Bluetooth polling must not replace the media subscription")
        pushed.configure(enabled: true, rules: [legacy])
        precondition(pushed.isPollingBluetooth && observationStops == 1)
        let readsAfterMediaDisabled = mediaQueries.count
        mediaCallbacks[0](true)
        precondition(mediaQueries.count == readsAfterMediaDisabled && pushed.mediaIsPlaying == nil)
        pushed.configure(enabled: true, rules: [hiddenPlaying])
        precondition(!pushed.isPollingBluetooth && observationStarts == 2)
        mediaCallbacks[0](true)
        precondition(pushed.activeRule == nil, "A previous subscription cannot update a restarted monitor")
        mediaCallbacks[1](true)
        precondition(pushed.activeRule?.id == hiddenPlaying.id)
        pushed.configure(enabled: false, rules: [hiddenPlaying])
        precondition(!pushed.isMonitoring && !pushed.isPollingBluetooth && observationStops == 2)
        mediaCallbacks[1](true)
        precondition(pushed.activeRule == nil)

        func control<T: NSView>(_ identifier: String, as type: T.Type) -> T {
            descendants(pane).compactMap { $0 as? T }.first { $0.accessibilityIdentifier() == identifier }!
        }
        func click(_ title: String) {
            let button = descendants(pane).compactMap { $0 as? NSButton }.first { $0.title == title }!
            precondition(NSApp.sendAction(button.action!, to: button.target, from: button))
        }
        func choose(_ popup: NSPopUpButton, _ index: Int) {
            window.makeFirstResponder(nil)
            popup.selectItem(at: index)
            precondition(NSApp.sendAction(popup.action!, to: popup.target, from: popup))
        }
        func select(_ table: NSTableView, _ row: Int) {
            window.makeFirstResponder(nil)
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            pane.layoutSubtreeIfNeeded()
        }
        let original = store.controlStripConfiguration
        let profiles = control("stripProfile", as: NSTableView.self)
        let showButton = control("stripConfigurationVisible", as: NSButton.self)
        let master = control("stripMasterEnabled", as: NSButton.self)
        precondition(showButton.state == .on && master.state == .on)
        showButton.performClick(nil)
        precondition(!store.controlStripConfiguration.showsButton && store.showControlStripButton)
        precondition(control("stripSymbol", as: NSTextField.self).isHiddenOrHasHiddenAncestor)
        precondition(control("stripAction", as: NSPopUpButton.self).isHiddenOrHasHiddenAncestor)
        precondition(!SettingsStore(defaults: defaults).controlStripConfiguration.showsButton)
        pane.showActiveAutomation(nil, buttonVisible: false)
        render(window.contentView!, name: "default-hidden")
        showButton.performClick(nil)
        precondition(store.controlStripConfiguration == original &&
            !control("stripSymbol", as: NSTextField.self).isHiddenOrHasHiddenAncestor)
        master.performClick(nil)
        precondition(!SettingsStore(defaults: defaults).showControlStripButton && showButton.state == .on)
        precondition(control("stripAutomationStatus", as: NSTextField.self).stringValue == "Control Strip button disabled")
        master.performClick(nil)
        pane.showActiveAutomation(nil)
        precondition(profiles.numberOfRows == 1 && profiles.selectedRow == 0)
        precondition(!descendants(pane).contains { $0 is NSPopUpButton && $0.accessibilityIdentifier() == "stripProfile" })
        precondition(control("stripEditorTitle", as: NSTextField.self).stringValue == "Default Button")
        pane.layoutSubtreeIfNeeded()
        precondition(profiles.enclosingScrollView!.bounds.height > 150, "The configuration list must have a usable viewport")
        let statusFrame = pane.convert(control("stripAutomationStatus", as: NSTextField.self).bounds,
            from: control("stripAutomationStatus", as: NSTextField.self))
        precondition(pane.bounds.maxY - statusFrame.maxY < 70, "Live status belongs in the compact top header")
        let devices = control("stripDevice", as: NSPopUpButton.self)
        let bluetooth = control("stripBluetoothCondition", as: NSButton.self)
        let media = control("stripMediaCondition", as: NSButton.self)
        let enabled = control("stripRuleEnabled", as: NSButton.self)
        var refreshes = 0
        pane.deviceReader = { refreshes += 1; return [airpods, second] }
        click("Add Rule")
        precondition(profiles.numberOfRows == 2 && profiles.selectedRow == 1)
        let firstID = store.controlStripAutomationRules[0].id
        precondition(!store.controlStripAutomationRules[0].enabled && refreshes == 0)
        click("Refresh"); choose(devices, 1)
        enabled.performClick(nil); media.performClick(nil)
        precondition(store.controlStripAutomationRules[0].deviceAddress == airpods.address && store.controlStripAutomationRules[0].enabled)
        precondition(store.controlStripAutomationRules[0].bluetoothConnected && store.controlStripAutomationRules[0].mediaPlaying)
        let symbol = control("stripSymbol", as: NSTextField.self)
        symbol.stringValue = "music.note"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: symbol))
        precondition(store.controlStripConfiguration == original && store.controlStripAutomationRules[0].configuration.symbol == "music.note")
        let name = control("stripRuleName", as: NSTextField.self)
        name.selectText(nil)
        let editor = name.currentEditor()!
        name.stringValue = "AirPods + Music 播放"
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
        precondition(name.currentEditor() === editor && window.firstResponder === editor)
        window.makeFirstResponder(nil)
        let ruleConfig = store.controlStripAutomationRules[0].configuration
        showButton.performClick(nil)
        precondition(!store.controlStripAutomationRules[0].configuration.showsButton &&
            store.controlStripConfiguration == original && !media.isHiddenOrHasHiddenAncestor)
        precondition(symbol.isHiddenOrHasHiddenAncestor)
        pane.showActiveAutomation(name.stringValue, buttonVisible: false)
        render(window.contentView!, name: "automation-hidden")
        select(profiles, 0)
        precondition(showButton.state == .on && !symbol.isHiddenOrHasHiddenAncestor)
        precondition(control("stripAutomationStatus", as: NSTextField.self).stringValue.contains("Button hidden"),
            "Editor selection must not override the actual active visibility")
        select(profiles, 1)
        precondition(showButton.state == .off && symbol.isHiddenOrHasHiddenAncestor)
        showButton.performClick(nil)
        precondition(store.controlStripAutomationRules[0].configuration == ruleConfig && !symbol.isHiddenOrHasHiddenAncestor)
        precondition(control("stripAutomationStatus", as: NSTextField.self).stringValue.contains("Button hidden"),
            "Saving an edit must preserve the actual visibility until runtime reports it")
        pane.showActiveAutomation(name.stringValue)
        render(window.contentView!, name: "automation-combined")
        window.setContentSize(NSSize(width: 820, height: 560)); window.layoutIfNeeded()
        render(window.contentView!, name: "automation-compact")
        for view in [profiles, devices, bluetooth, media] as [NSView] {
            let rect = pane.convert(view.bounds, from: view)
            precondition(rect.minX >= 0 && rect.maxX <= pane.bounds.maxX + 1, "Native controls must fit the minimum pane width")
        }
        bluetooth.performClick(nil)
        precondition(devices.isHiddenOrHasHiddenAncestor && store.controlStripAutomationRules[0].deviceAddress == airpods.address)
        render(window.contentView!, name: "automation-playing")
        media.performClick(nil)
        precondition(!control("stripRuleValidation", as: NSTextField.self).stringValue.isEmpty)
        media.performClick(nil)
        showButton.performClick(nil)
        click("Add Rule")
        let secondID = store.controlStripAutomationRules[1].id
        precondition(secondID != firstID && store.controlStripAutomationRules[1].configuration == original,
            "New rules start with Default, independent of the selected rule")
        precondition(control("stripAutomationStatus", as: NSTextField.self).stringValue.contains("AirPods + Music"),
            "Selecting an inactive rule must not change the displayed active configuration")
        click("↑")
        precondition(store.controlStripAutomationRules.map(\.id) == [secondID, firstID] && profiles.selectedRow == 1)
        precondition(pane.tableView(profiles, pasteboardWriterForRow: 0) == nil, "Default cannot be dragged")
        precondition(pane.tableView(profiles, pasteboardWriterForRow: 2) != nil)
        let dragBoard = NSPasteboard.withUniqueName()
        defer { dragBoard.releaseGlobally() }
        precondition(dragBoard.writeObjects([pane.tableView(profiles, pasteboardWriterForRow: 2)!]))
        let drag = ControlStripRuleDrag(source: profiles, pasteboard: dragBoard)
        precondition(pane.tableView(profiles, validateDrop: drag, proposedRow: 0, proposedDropOperation: .above).isEmpty)
        precondition(pane.tableView(profiles, validateDrop: drag, proposedRow: 1, proposedDropOperation: .on).isEmpty)
        let foreign = ControlStripRuleDrag(source: NSTableView(), pasteboard: dragBoard)
        precondition(pane.tableView(profiles, validateDrop: foreign, proposedRow: 1, proposedDropOperation: .above).isEmpty)
        precondition(pane.tableView(profiles, validateDrop: drag, proposedRow: 1, proposedDropOperation: .above) == .move)
        precondition(pane.tableView(profiles, acceptDrop: drag, row: 1, dropOperation: .above))
        precondition(store.controlStripAutomationRules.map(\.id) == [firstID, secondID] && profiles.selectedRow == 1)
        precondition(pane.tableView(profiles, acceptDrop: drag, row: 3, dropOperation: .above))
        precondition(store.controlStripAutomationRules.map(\.id) == [secondID, firstID] && profiles.selectedRow == 2)
        select(profiles, 0)
        precondition(control("stripEditorTitle", as: NSTextField.self).stringValue == "Default Button" && enabled.isHiddenOrHasHiddenAncestor)
        select(profiles, 2)
        precondition(symbol.stringValue == "music.note" && media.state == .on && bluetooth.state == .off)
        precondition(showButton.state == .off && !store.controlStripAutomationRules[1].configuration.showsButton,
            "Visibility follows the stable rule through reorder and selection")
        name.stringValue = String(repeating: "Long rule 中文 ", count: 12)
        pane.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
        pane.layoutSubtreeIfNeeded()
        render(window.contentView!, name: "automation-long-name")
        for appearance in [NSAppearance.Name.darkAqua, .aqua] {
            window.appearance = NSAppearance(named: appearance)
            render(window.contentView!, name: appearance == .darkAqua ? "automation-dark" : "automation-light")
        }
        let roundtrip = try! JSONDecoder().decode([ControlStripAutomationRule].self,
            from: JSONEncoder().encode(store.controlStripAutomationRules))
        precondition(roundtrip == store.controlStripAutomationRules)
        precondition(SettingsStore(defaults: defaults).controlStripAutomationRules == roundtrip)
        click("Remove")
        precondition(store.controlStripAutomationRules.map(\.id) == [secondID] && profiles.selectedRow == 0)
        precondition(store.controlStripConfiguration == original && symbol.stringValue == original.symbol)
        select(profiles, 1); click("Remove")
        precondition(store.controlStripAutomationRules.isEmpty)
        pane.showActiveAutomation(nil)
        render(window.contentView!, name: "default-empty")
        print("Control Strip automation checks passed: playback / Bluetooth / AND, hidden-rule priority and continued monitoring, independent visibility, master switch, default restoration, live rule editor, reordering and persistence")
    }
}
