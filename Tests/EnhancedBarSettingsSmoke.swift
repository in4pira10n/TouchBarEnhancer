import AppKit

/// Offscreen editors and mock action dispatch; no media, input or tray effects.
@main @MainActor
struct EnhancedBarSettingsSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func select(_ popup: NSPopUpButton, _ title: String) {
        popup.selectItem(withTitle: title)
        precondition(popup.sendAction(popup.action, to: popup.target))
    }
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
            URL(fileURLWithPath: ".build/settings-ui/enhanced-\(name).png"))
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let clipboardCount = NSPasteboard.general.changeCount
        let domain = "TouchBarEnhancer.EnhancedBarTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = SettingsStore(defaults: defaults)
        let id = LayoutApp.enhancedBar.bundleID
        precondition(!store.configurableApps.contains(.enhancedBar))
        precondition(store.presentation(for: "lyrics", app: id).alignment == .center)
        precondition(store.presentation(for: "phrases", app: id).alignment == .left)
        let provider = AppBar(app: .enhancedBar, persistsLayout: false)
        precondition(!provider.usesChatGPTControls)
        precondition(provider.bar.defaultItemIdentifiers == [AppBar.itemID("lyrics")])
        precondition(provider.bar.customizationAllowedItemIdentifiers == ["phrases", "keyboard", "menu", "text", "lyrics"].map(AppBar.itemID) + [.flexibleSpace])
        let other = AppBar(app: .builtIn[1], persistsLayout: false)
        precondition(!other.bar.defaultItemIdentifiers.contains(AppBar.itemID("lyrics")))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let runner = ControlStripActionRunner(pasteboard: board)
        var toggles = 0
        runner.toggleEnhancedBar = { toggles += 1 }
        runner.sendKeyboard = { _, _ in preconditionFailure("Showing a bar must not send input") }
        runner.pasteText = { _, _ in preconditionFailure("Showing a bar must not paste") }
        runner.targetBundleID = { preconditionFailure("Showing a bar needs no foreground input target") }
        for interaction in ControlStripInteraction.allCases {
            var config = ControlStripConfiguration()
            var binding = ControlStripActionBinding()
            binding.action = .showEnhancedBar
            config.setBinding(binding, for: interaction)
            let restored = try! JSONDecoder().decode(ControlStripConfiguration.self, from: JSONEncoder().encode(config))
            let before = toggles
            runner.perform(restored, interaction: interaction) { preconditionFailure() }
            runner.perform(restored, interaction: interaction) { preconditionFailure() }
            precondition(toggles == before + 2)
            config.showsButton = false
            runner.perform(config, interaction: interaction) { preconditionFailure() }
            precondition(toggles == before + 2)
        }

        let controller = SettingsWindowController(store: store)
        let window = controller.window!
        var preview: LayoutApp?
        controller.onPreviewApp = { preview = $0 }
        func pane(_ key: String) {
            let item = window.toolbar!.items.first { $0.itemIdentifier.rawValue == key }!
            precondition(app.sendAction(item.action!, to: item.target, from: item))
            window.layoutIfNeeded()
        }
        pane("controlStrip")
        let strip = window.contentView!.subviews.first as! ControlStripSettingsPane
        let action = descendants(strip).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityIdentifier() == "stripAction" }!
        select(action, ControlStripAction.showEnhancedBar.title)
        let edit = descendants(strip).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "stripEditEnhancedBar" }!
        precondition(!edit.isHiddenOrHasHiddenAncestor && store.controlStripConfiguration.action == .showEnhancedBar)
        render(window.contentView!, name: "strip-action")
        edit.performClick(nil)
        precondition(window.title == "Enhanced Bar" && window.toolbar!.selectedItemIdentifier?.rawValue == "enhancedBar")
        precondition(preview == .enhancedBar)
        let editor = window.contentView!.subviews.first as! AppsPane
        let lyrics = descendants(editor).compactMap { $0 as? LyricsComponentEditor }.first!
        let title = descendants(lyrics).compactMap { $0 as? NSButton }.first { $0.title == "Lyrics" }!
        title.performClick(nil)
        let options = descendants(lyrics).compactMap { $0 as? NSPopUpButton }
        let layout = options.first { $0.accessibilityIdentifier() == "componentLayout.lyrics" }!
        let alignment = options.first { $0.accessibilityIdentifier() == "componentAlignment.lyrics" }!
        precondition(alignment.titleOfSelectedItem == "Center")
        let widthControl = descendants(lyrics).compactMap { $0 as? ComponentItemWidthControl }.first!
        precondition(widthControl.isHiddenOrHasHiddenAncestor)

        let item = provider.bar.item(forIdentifier: AppBar.itemID("lyrics")) as! NSCustomTouchBarItem
        let wrapper = item.view as! TouchBarComponentView
        let region = wrapper.content as! ScrollingComponentRegion
        let scrubber = descendants(region).compactMap { $0 as? NSScrubber }.first!
        let barWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        barWindow.contentView = wrapper
        store.onChange = {
            provider.configureLyrics(store.lyricsComponents[id] ?? .init())
            provider.configureComponentPresentations(store.componentPresentations[id] ?? [:])
        }
        func frame() -> NSRect {
            wrapper.layoutSubtreeIfNeeded(); region.layoutSubtreeIfNeeded(); scrubber.layoutSubtreeIfNeeded()
            return scrubber.scrubberLayout.layoutAttributesForItem(at: 0)!.frame
        }
        _ = frame()
        precondition(abs(scrubber.frame.midX - region.bounds.midX) < 1)
        let cell = scrubber.dataSource!.scrubber(scrubber, viewForItemAt: 0)
        let label = descendants(cell).compactMap { $0 as? NSTextField }.first!
        precondition(label.stringValue == LyricsComponent.placeholder && label.alignment == .center)
        for mode in ComponentLayout.allCases {
            select(layout, mode.rawValue)
            precondition(widthControl.isHiddenOrHasHiddenAncestor == (mode == .scrolling))
            if mode == .fill {
                let widthMode = descendants(widthControl).compactMap { $0 as? NSPopUpButton }.first!
                let value = descendants(widthControl).compactMap { $0 as? ComponentInlineTextField }.first!
                select(widthMode, "Fixed")
                value.stringValue = "96"; value.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: value))
                precondition(abs(frame().width - 96) < 1)
                for invalid in ["0", "-1", "nan", "inf", "1000001"] {
                    value.stringValue = invalid; value.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: value))
                    precondition(store.lyricsComponents[id]?.fillWidth?.fixed == 96)
                }
                select(widthMode, "Hug"); precondition(frame().width > 0 && frame().width < 600)
                select(widthMode, "Relative"); precondition(abs(frame().width - 600) < 1)
            } else {
                for align in ScrollingComponentAlignment.allCases {
                    select(alignment, align.rawValue); _ = frame()
                    let rest = region.bounds.width - scrubber.bounds.width
                    let expected: CGFloat = align == .left ? 0 : (align == .center ? rest / 2 : rest)
                    precondition(abs(scrubber.frame.minX - expected) < 1)
                }
            }
        }
        select(layout, "Scrolling"); select(alignment, "Center")
        let regionMode = options.first { $0.accessibilityIdentifier() == "lyricsComponentWidthMode" }!
        select(regionMode, "Hug"); _ = frame()
        precondition(region.requestedWidth != nil && region.requestedWidth! > 0)
        let hug = region.requestedWidth!
        select(regionMode, "Fixed")
        let regionValue = descendants(lyrics).compactMap { $0 as? ComponentInlineTextField }.first { $0.accessibilityIdentifier() == "lyricsComponentWidthValue" }!
        regionValue.stringValue = "20"; regionValue.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: regionValue))
        precondition(region.requestedWidth == 20 && hug != 20)
        select(layout, "Fill"); precondition(region.requestedWidth == 20)
        select(regionMode, "Auto"); precondition(region.requestedWidth == nil)
        select(layout, "Scrolling")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            render(window.contentView!, name: appearance.rawValue)
        }
        let restored = SettingsStore(defaults: defaults)
        precondition(restored.lyricsComponents == store.lyricsComponents)
        precondition(restored.presentation(for: "lyrics", app: id) == store.presentation(for: "lyrics", app: id))
        precondition(restored.lyricsComponents[LayoutApp.builtIn[0].bundleID] == nil)
        precondition(restored.lastSettingsPane == "enhancedBar")
        let restoredController = SettingsWindowController(store: restored)
        precondition(restoredController.window?.title == "Enhanced Bar")
        pane("apps"); precondition(preview?.isEnhancedBar == false)
        precondition(!descendants(editor).compactMap { $0 as? NSButton }.contains { $0.title.hasPrefix("Save ") })
        precondition(!window.isVisible && !barWindow.isVisible)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        precondition(NSPasteboard.general.changeCount == clipboardCount)
        print("Enhanced Bar settings checks passed: all gestures, isolated configuration, contextual navigation, remembered pane, Lyrics defaults, live layout/width, persistence and no external input")
    }
}
