import AppKit

/// Real AppKit views and Settings actions, kept offscreen with isolated data.
@main @MainActor
struct ComponentDisplaySmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func scroller(_ provider: AppBar, _ bar: NSTouchBar, _ key: String) -> NSScrubber {
        let item = bar.item(forIdentifier: AppBar.itemID(key)) as! NSCustomTouchBarItem
        return descendants(item.view).compactMap { $0 as? NSScrubber }.first!
    }
    static func label(_ scrubber: NSScrubber) -> NSTextField {
        let item = scrubber.dataSource!.scrubber(scrubber, viewForItemAt: 0)
        return descendants(item).compactMap { $0 as? NSTextField }.first!
    }
    static func render(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: view.bounds).fill()
            view.displayIgnoringOpacity(view.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
        }
        try! bitmap.representation(using: .png, properties: [:])!.write(to:
            URL(fileURLWithPath: ".build/component-display/\(name).png"))
    }
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory); application.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suite = "TouchBarEnhancer.ComponentDisplayTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try! FileManager.default.createDirectory(atPath: ".build/component-display", withIntermediateDirectories: true)
        let store = SettingsStore(defaults: defaults)
        precondition(store.componentDisplayModes.isEmpty, "Older preferences retain Icon + Text")
        let app = LayoutApp.builtIn[0]
        let safari = LayoutApp.builtIn[1]
        store.quickPhrasesByApp[app.bundleID] = [QuickPhrase(name: "Explain 详细说明", text: "Keep the complete phrase.")]
        store.quickPhrasesByApp[safari.bundleID] = [QuickPhrase(name: "Safari Phrase", text: "Safari only.")]
        store.keyboardButtons[app.bundleID] = .init(buttons: [KeyboardButton(title: "Find", color: "purple",
            shortcut: .init(keyCode: 3, modifiers: NSEvent.ModifierFlags.command.rawValue, keyLabel: "F"))])
        let originalChats = store.chatShortcuts
        let originalPhrases = store.quickPhrasesByApp[app.bundleID]!
        let originalPhraseConfigurations = store.quickPhrasesByApp
        let originalKeys = store.keyboardButtons
        let provider = AppBar(app: app, shortcuts: store.chatShortcuts, phrases: originalPhrases,
            keyboardButtons: store.keyboardButtons[app.bundleID]!, persistsLayout: false)
        let otherProvider = AppBar(app: safari, phrases: store.quickPhrasesByApp[safari.bundleID]!, persistsLayout: false)
        let secondBar = NSTouchBar()
        secondBar.delegate = provider
        secondBar.defaultItemIdentifiers = ["chatgpt.chats", "phrases", "keyboard"].map(AppBar.itemID)
        let keys = ["chatgpt.chats", "phrases", "keyboard"]
        let originals = keys.map { scroller(provider, provider.bar, $0) }
        let separate = keys.map { scroller(provider, secondBar, $0) }
        let other = scroller(otherProvider, otherProvider.bar, "phrases")
        for index in keys.indices {
            precondition(originals[index] !== separate[index])
            precondition(!label(originals[index]).isHidden && !label(separate[index]).isHidden)
        }
        store.onChange = {
            provider.configureChats(store.chatShortcuts)
            provider.configurePhrases(store.quickPhrasesByApp[app.bundleID] ?? [])
            provider.configureKeyboardButtons(store.keyboardButtons[app.bundleID] ?? .init())
            provider.configureComponentDisplayModes(store.componentDisplayModes[app.bundleID] ?? [:])
            otherProvider.configureComponentDisplayModes(store.componentDisplayModes[safari.bundleID] ?? [:])
        }
        let pane = ChatGPTPane(store: store, app: app, connectionReader: {
            .init(trusted: false, running: false, entries: [])
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 1500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let document = NSView()
        window.contentView = document
        pane.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(pane)
        NSLayoutConstraint.activate([pane.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: document.trailingAnchor), pane.topAnchor.constraint(equalTo: document.topAnchor)])
        let categories = descendants(pane).compactMap { $0 as? ShortcutCategoryEditor }
        precondition(categories.count == 3)
        for (index, key) in keys.enumerated() {
            let control = descendants(pane).compactMap { $0 as? NSSegmentedControl }.first {
                $0.accessibilityIdentifier() == "componentDisplayMode.\(key)"
            }!
            precondition(control.segmentCount == 2 && control.selectedSegment == 1)
            precondition(control.label(forSegment: 0) == "Icon Only" && control.label(forSegment: 1) == "Icon + Text")
            control.selectedSegment = 0; precondition(control.sendAction(control.action, to: control.target))
            precondition(store.componentDisplayModes[app.bundleID]?[key] == .iconOnly)
            precondition(SettingsStore(defaults: defaults).componentDisplayModes == store.componentDisplayModes)
            for peer in keys.indices {
                precondition(label(originals[peer]).isHidden == (peer <= index))
                precondition(label(separate[peer]).isHidden == (peer <= index))
            }
            precondition(!label(other).isHidden, "Another app has independent presentation")
        }
        for category in categories where category.kind != .chats {
            descendants(category).compactMap { $0 as? NSButton }.first { $0.title == category.kind.title }!.performClick(nil)
        }
        render(categories.first { $0.kind == .chats }!, "chats-editor")
        render(categories.first { $0.kind == .keyboard }!, "keyboard-editor")
        precondition(store.chatShortcuts == originalChats && store.quickPhrasesByApp == originalPhraseConfigurations && store.keyboardButtons == originalKeys)
        let recreated = AppBar(app: app, phrases: originalPhrases, keyboardButtons: store.keyboardButtons[app.bundleID]!,
            componentDisplayModes: SettingsStore(defaults: defaults).componentDisplayModes[app.bundleID]!, persistsLayout: false)
        for key in keys { precondition(label(scroller(recreated, recreated.bar, key)).isHidden) }
        // Returning to text mode changes neither other components nor other apps.
        let chatToggle = descendants(pane).compactMap { $0 as? NSSegmentedControl }.first {
            $0.accessibilityIdentifier() == "componentDisplayMode.chatgpt.chats"
        }!
        chatToggle.selectedSegment = 1; chatToggle.sendAction(chatToggle.action, to: chatToggle.target)
        precondition(!label(originals[0]).isHidden && label(originals[1]).isHidden && label(originals[2]).isHidden)
        let generic = AppsPane(store: store)
        let appList = descendants(generic).compactMap { $0 as? NSTableView }.first { $0.dataSource === generic }!
        let safariIndex = store.configurableApps.firstIndex(of: safari)!
        appList.selectRowIndexes([safariIndex], byExtendingSelection: false)
        let genericToggle = descendants(generic).compactMap { $0 as? NSSegmentedControl }.first {
            $0.accessibilityIdentifier() == "componentDisplayMode.phrases"
        }!
        genericToggle.selectedSegment = 0; genericToggle.sendAction(genericToggle.action, to: genericToggle.target)
        precondition(store.componentDisplayModes[safari.bundleID]?["phrases"] == .iconOnly && label(other).isHidden)

        for (index, key) in keys.enumerated() {
            let category = categories.first { $0.kind.componentKey == key }!
            let componentToggle = descendants(category).compactMap { $0 as? NSSegmentedControl }.first!
            let itemToggle = descendants(category).compactMap { $0 as? NSPopUpButton }.first {
                $0.accessibilityIdentifier() == "itemDisplayMode"
            }!
            precondition(itemToggle.itemTitles == ["Follow Component", "Always Icon Only", "Always Icon + Text"])
            precondition(itemToggle.indexOfSelectedItem == 0)
            componentToggle.selectedSegment = 0; componentToggle.sendAction(componentToggle.action, to: componentToggle.target)
            precondition(label(originals[index]).isHidden && label(separate[index]).isHidden)
            itemToggle.selectItem(at: 2); itemToggle.sendAction(itemToggle.action, to: itemToggle.target)
            precondition(!label(originals[index]).isHidden && !label(separate[index]).isHidden)
            let restored = SettingsStore(defaults: defaults)
            let savedOverride: ComponentDisplayMode? = switch category.kind {
            case .chats: restored.chatShortcuts[0].displayModeOverride
            case .phrases: restored.quickPhrasesByApp[app.bundleID]![0].displayModeOverride
            case .keyboard: restored.keyboardButtons[app.bundleID]!.buttons[0].displayModeOverride
            }
            precondition(savedOverride == .iconAndText)
            let fresh = AppBar(app: app, shortcuts: restored.chatShortcuts, phrases: restored.quickPhrasesByApp[app.bundleID]!,
                keyboardButtons: restored.keyboardButtons[app.bundleID]!,
                componentDisplayModes: restored.componentDisplayModes[app.bundleID]!, persistsLayout: false)
            precondition(!label(scroller(fresh, fresh.bar, key)).isHidden)
            componentToggle.selectedSegment = 1; componentToggle.sendAction(componentToggle.action, to: componentToggle.target)
            itemToggle.selectItem(at: 1); itemToggle.sendAction(itemToggle.action, to: itemToggle.target)
            precondition(label(originals[index]).isHidden && label(separate[index]).isHidden)
            componentToggle.selectedSegment = 0; componentToggle.sendAction(componentToggle.action, to: componentToggle.target)
            componentToggle.selectedSegment = 1; componentToggle.sendAction(componentToggle.action, to: componentToggle.target)
            precondition(label(originals[index]).isHidden && label(separate[index]).isHidden,
                "Forced icon-only ignores the component’s text setting")
            itemToggle.selectItem(at: 0); itemToggle.sendAction(itemToggle.action, to: itemToggle.target)
            precondition(!label(originals[index]).isHidden && !label(separate[index]).isHidden)
        }
        precondition(store.chatShortcuts == originalChats && store.quickPhrasesByApp == originalPhraseConfigurations && store.keyboardButtons == originalKeys)
        render(categories.first { $0.kind == .phrases }!, "phrases-item-display")

        // Size measurement, view reuse and the two render modes must agree.
        for title in ["A", "一个很长的聊天名称和说明", "🧑‍💻 Design " + String(repeating: "Long", count: 30)] {
            let item = ScrollingComponentItem(title: title, symbol: "star.fill", accessibilityLabel: title, toolTip: title)
            let compact = ScrollingComponentItemView.width(for: item, displayMode: .iconOnly)
            precondition(compact < ScrollingComponentItemView.width(for: item))
            let view = ScrollingComponentItemView(frame: NSRect(x: 0, y: 0, width: compact, height: 30))
            let itemWindow = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            itemWindow.contentView = view
            view.configure(item, displayMode: .iconOnly); view.layoutSubtreeIfNeeded()
            let icon = descendants(view).compactMap { $0 as? NSImageView }.first!
            let text = descendants(view).compactMap { $0 as? NSTextField }.first!
            let iconFrame = icon.superview!.convert(icon.alignmentRect(forFrame: icon.frame), to: view)
            precondition(abs(iconFrame.midX - view.bounds.midX) < 0.5 && abs(iconFrame.midY - 15) < 0.5)
            precondition(text.isHidden && text.stringValue == title && view.toolTip == title && view.accessibilityLabel() == title)
            view.configure(item)
            precondition(!text.isHidden, "Reused scrubber items must restore text")
            precondition(!itemWindow.isVisible)
        }
        let aligned = ShortcutScroller(label: "Display test", alignsContent: true)
        aligned.configure([originalPhrases[0].scrollingItem])
        let barWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 30),
            styleMask: [.borderless], backing: .buffered, defer: false)
        barWindow.contentView = aligned.scrollRegion
        for mode in ComponentDisplayMode.allCases {
            aligned.displayMode = mode
            for alignment in ScrollingComponentAlignment.allCases {
                aligned.alignment = alignment; aligned.scrollRegion.layoutSubtreeIfNeeded()
                let width = ScrollingComponentItemView.width(for: originalPhrases[0].scrollingItem, displayMode: mode)
                let expected = alignment == .left ? 0 : (300 - width) / (alignment == .center ? 2 : 1)
                precondition(abs(aligned.scrubber.frame.minX - expected) < 0.5 && abs(aligned.scrubber.frame.width - width) < 0.5)
            }
            aligned.fillsAvailableWidth = true; aligned.scrollRegion.layoutSubtreeIfNeeded()
            precondition(abs(aligned.scrubber.scrubberLayout.layoutAttributesForItem(at: 0)!.frame.width - 300) < 0.5)
            aligned.fillsAvailableWidth = false
        }
        for parentMode in ComponentDisplayMode.allCases {
            for override in [nil, ComponentDisplayMode.iconOnly, .iconAndText] {
                let item = ScrollingComponentItem(title: "Long individual item 设计", symbol: "star.fill",
                    accessibilityLabel: "Full title", toolTip: "Description", displayModeOverride: override)
                let effective = override ?? parentMode
                let expected = ScrollingComponentItemView.width(for: item, displayMode: effective)
                aligned.displayMode = parentMode; aligned.configure([item])
                aligned.scrollRegion.layoutSubtreeIfNeeded()
                precondition(abs(aligned.scrubber.frame.width - expected) < 0.5)
                precondition(label(aligned.scrubber).isHidden == (effective == .iconOnly))
                aligned.fillsAvailableWidth = true; aligned.scrollRegion.layoutSubtreeIfNeeded()
                precondition(abs(aligned.scrubber.scrubberLayout.layoutAttributesForItem(at: 0)!.frame.width - 300) < 0.5)
                precondition(label(aligned.scrubber).isHidden == (effective == .iconOnly))
                aligned.fillsAvailableWidth = false
            }
        }
        precondition(!window.isVisible && !barWindow.isVisible)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        print("Component display checks passed: legacy defaults, per-app/component/item persistence, forced override precedence and reset, live multi-context updates, generic app wiring, content preservation, view reuse, icon centering, compact widths, scrolling alignment, fill layout, no activation")
    }
}
