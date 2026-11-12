import AppKit
import Foundation

@main
struct SettingsSmoke {
    @MainActor static func main() {
        let suite = "TouchBarEnhancer.Tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        precondition(store.launchSilently, "New and existing installations must launch silently by default")
        precondition(store.showControlStripButton)
        store.showControlStripButton = false; store.save()
        precondition(!SettingsStore(defaults: defaults).showControlStripButton)
        store.showControlStripButton = true; store.save()
        precondition(SettingsStore(defaults: defaults).showControlStripButton)
        store.launchSilently = false
        store.save()
        precondition(!SettingsStore(defaults: defaults).launchSilently, "Explicit opt-out must persist")
        store.launchSilently = true
        store.save()
        precondition(SettingsStore(defaults: defaults).launchSilently)
        let id = "test.app"
        precondition(store.mode(for: id) == .auto)
        precondition(store.shouldEnhance(id, manuallyHidden: false))
        store.selectedAppIDs.insert(id)
        precondition(!store.shouldEnhance(id, manuallyHidden: false))
        store.autoPolicy = .selection
        precondition(store.shouldEnhance(id, manuallyHidden: false))
        store.selectedAppIDs.remove(id)
        precondition(!store.shouldEnhance(id, manuallyHidden: false))
        store.rules = [AppRule(bundleID: id, name: "Test", mode: .enabled)]
        precondition(store.shouldEnhance(id, manuallyHidden: false))
        precondition(!store.shouldEnhance(id, manuallyHidden: true))
        store.paused = true
        precondition(!store.shouldEnhance(id, manuallyHidden: false))
        store.save()
        let restored = SettingsStore(defaults: defaults)
        precondition(restored.paused && restored.mode(for: id) == .enabled)
        restored.paused = false
        restored.rules[0].mode = .native
        precondition(!restored.shouldEnhance(id, manuallyHidden: false))
        restored.rules.removeAll()
        precondition(restored.mode(for: id) == .auto)
        restored.save()
        let afterRemoval = SettingsStore(defaults: defaults)
        precondition(afterRemoval.rules.isEmpty && afterRemoval.mode(for: id) == .auto)
        precondition(afterRemoval.autoPolicy == .selection)
        precondition(!afterRemoval.shouldEnhance(id, manuallyHidden: false))
        afterRemoval.autoPolicy = .exclusion
        precondition(afterRemoval.shouldEnhance(id, manuallyHidden: false))
        afterRemoval.selectedAppIDs.insert(id)
        afterRemoval.save()
        let persisted = SettingsStore(defaults: defaults)
        precondition(persisted.autoPolicy == .exclusion && persisted.selectedAppIDs.contains(id))
        precondition(!persisted.shouldEnhance(id, manuallyHidden: false))

        // Legacy rules decode without new preferences and keep explicit overrides.
        defaults.removeObject(forKey: "autoPolicy")
        defaults.removeObject(forKey: "selectedAppIDs")
        defaults.set(try! JSONEncoder().encode([AppRule(bundleID: id, name: "Legacy", mode: .enabled)]), forKey: "appRules")
        let legacy = SettingsStore(defaults: defaults)
        precondition(legacy.selectedAppIDs.contains(id))
        precondition(legacy.shouldEnhance(id, manuallyHidden: false))
        legacy.layoutApps = [LayoutApp(bundleID: "test.layout", name: "Layout Only")]
        legacy.save()
        let layoutRestored = SettingsStore(defaults: defaults)
        precondition(layoutRestored.layoutApps == legacy.layoutApps)
        precondition(layoutRestored.rules.count == 1)
        let first = AppBar(app: LayoutApp(bundleID: "test.first", name: "First"))
        let second = AppBar(app: LayoutApp(bundleID: "test.second", name: "Second"))
        precondition(first.bar.customizationIdentifier != second.bar.customizationIdentifier)
        let host = AppBarHost()
        let presentedBar = host.bar
        precondition(host.bar.principalItemIdentifier == nil)
        host.display(first)
        precondition(host.content.groupTouchBar.delegate === first)
        precondition(host.bar.escapeKeyReplacementItemIdentifier == AppBar.itemID("phrases"))
        host.display(second)
        precondition(host.bar === presentedBar && host.content.groupTouchBar.delegate === second)
        host.display(first)
        precondition(host.content.groupTouchBar.delegate === first)
        for identifier in first.bar.customizationAllowedItemIdentifiers where identifier.rawValue.hasPrefix("local.starfruit") {
            precondition(first.touchBar(first.bar, makeItemForIdentifier: identifier) != nil)
        }
        let chat = LayoutApp(bundleID: LayoutApp.chatGPTBundleID, name: "ChatGPT")
        let dedicated = AppBar(app: chat)
        let generic = AppBar(app: chat, chatGPTControlsEnabled: false)
        precondition(dedicated.bar.principalItemIdentifier == nil)
        precondition(dedicated.usesChatGPTControls && !generic.usesChatGPTControls)
        precondition(dedicated.bar.customizationIdentifier != generic.bar.customizationIdentifier)
        precondition(generic.bar.customizationIdentifier == "local.starfruit.TouchBarEnhancer.layout.v1.\(chat.bundleID)")
        precondition(!dedicated.bar.defaultItemIdentifiers.contains(AppBar.itemID("counter")))
        precondition(dedicated.bar.defaultItemIdentifiers == ["sidebar", "chats", "terminal"].map { AppBar.itemID("chatgpt.\($0)") })
        let isolatedDedicated = AppBar(app: chat, persistsLayout: false)
        host.display(isolatedDedicated)
        precondition(host.bar.escapeKeyReplacementItemIdentifier == AppBar.itemID("chatgpt.sidebar"))
        precondition(host.content.groupTouchBar.defaultItemIdentifiers == ["chats", "terminal"].map { AppBar.itemID("chatgpt.\($0)") })
        precondition(host.content.groupTouchBar.item(forIdentifier: AppBar.itemID("chatgpt.terminal")) != nil)
        host.display(first)
        precondition(host.bar.escapeKeyReplacementItemIdentifier == AppBar.itemID("phrases"))
        precondition(host.content.groupTouchBar.delegate === first)
        let nativeChats = ChatGPTStrip(adapter: ChatGPTAdapter(bundleID: chat.bundleID), shortcuts: ChatShortcut.initial)
        precondition(nativeChats.scrubber.mode == .free && !nativeChats.scrubber.isContinuous)
        precondition(nativeChats.scrubber.selectionOverlayStyle == nil && nativeChats.scrubber.selectionBackgroundStyle == nil)
        precondition(nativeChats.scrubber.superview === nativeChats.scrollRegion)
        precondition(!nativeChats.scrollRegion.constraints.contains { $0.firstAttribute == .width && $0.relation == .equal && $0.priority == .required })
        let layoutHost = NSView(frame: NSRect(x: 0, y: 0, width: 684, height: 30))
        nativeChats.scrollRegion.translatesAutoresizingMaskIntoConstraints = false
        layoutHost.addSubview(nativeChats.scrollRegion)
        NSLayoutConstraint.activate([
            nativeChats.scrollRegion.leadingAnchor.constraint(equalTo: layoutHost.leadingAnchor),
            nativeChats.scrollRegion.trailingAnchor.constraint(equalTo: layoutHost.trailingAnchor),
            nativeChats.scrollRegion.topAnchor.constraint(equalTo: layoutHost.topAnchor),
            nativeChats.scrollRegion.bottomAnchor.constraint(equalTo: layoutHost.bottomAnchor)
        ])
        layoutHost.layoutSubtreeIfNeeded()
        precondition(nativeChats.scrollRegion.frame.width == 684)
        precondition(nativeChats.scrubber.frame.minX == 0 && nativeChats.scrubber.frame.width <= 684)
        precondition(nativeChats.sidebarContainer.constraints.contains { $0.firstAttribute == .width && $0.constant == 75 })
        precondition(nativeChats.sidebarContainer.constraints.contains { $0.firstAttribute == .height && $0.constant == 30 })
        precondition(nativeChats.terminalContainer.constraints.contains { $0.firstAttribute == .width && $0.constant == 75 })
        precondition(nativeChats.terminalContainer.constraints.contains { $0.firstAttribute == .height && $0.constant == 30 })
        precondition(2 * ChatGPTStrip.sideControlWidth + ChatGPTStrip.chatViewportWidth + 2 * ChatGPTStrip.blockGap == 684)
        precondition(nativeChats.numberOfItems(for: nativeChats.scrubber) == 4)
        var selectedSlot: Int?
        nativeChats.onSelectSlot = { selectedSlot = $0 }
        var sidebarToggles = 0
        var terminalToggles = 0
        nativeChats.onToggleSidebar = { sidebarToggles += 1 }
        nativeChats.onToggleTerminal = { terminalToggles += 1 }
        nativeChats.update(ChatGPTAdapter.Snapshot(trusted: false, running: false, entries: []))
        precondition(nativeChats.sidebar.isEnabled && nativeChats.terminal.isEnabled)
        nativeChats.sidebar.performClick(nil)
        nativeChats.terminal.performClick(nil)
        precondition(sidebarToggles == 1 && terminalToggles == 1)
        let chatItem = nativeChats.scrubber(nativeChats.scrubber, viewForItemAt: 2) as! ScrollingComponentItemView
        chatItem.isHighlighted = true
        chatItem.isHighlighted = false
        precondition(nativeChats.responds(to: NSSelectorFromString("scrubber:didSelectItemAtIndex:")))
        nativeChats.scrubber.delegate?.scrubber?(nativeChats.scrubber, didSelectItemAt: 2)
        precondition(selectedSlot == 3)
        precondition(nativeChats.scrubber.selectedIndex == -1)
        selectedSlot = nil
        nativeChats.scrubber(nativeChats.scrubber, didSelectItemAt: 2)
        precondition(selectedSlot == 3)
        nativeChats.scrubber(nativeChats.scrubber, didSelectItemAt: -1)
        precondition(selectedSlot == 3)
        precondition((nativeChats.scrubber.scrubberLayout as! NSScrubberFlowLayout).itemSpacing == NSStackView().spacing)
        nativeChats.configure([])
        precondition(nativeChats.numberOfItems(for: nativeChats.scrubber) == 0)
        for command in ChatGPTCommand.allCases {
            let id = AppBar.chatID(command)
            precondition(dedicated.bar.customizationAllowedItemIdentifiers.contains(id) == (command == .sidebar))
            if command != .sidebar { precondition(dedicated.touchBar(dedicated.bar, makeItemForIdentifier: id) == nil) }
            precondition(!generic.bar.customizationAllowedItemIdentifiers.contains(id))
        }
        precondition(ChatGPTCommand.terminalPanel.menuTitles.contains("Toggle Bottom Panel"))
        precondition(ChatGPTCommand.openTerminal.menuTitles.contains("Open Terminal"))
        precondition(layoutRestored.chatGPTControlsEnabled)
        layoutRestored.chatGPTControlsEnabled = false
        layoutRestored.save()
        precondition(!SettingsStore(defaults: defaults).chatGPTControlsEnabled)
        precondition(ChatColor.resolve("blue") == .systemBlue)
        precondition(ChatColor.resolve("#12ABEF") != nil)
        precondition(ChatColor.resolve("invalid color") == nil)
        let shortcut = ChatShortcut(name: "Custom", symbol: "star", imageData: Data([1, 2]), color: "#123456", slot: 9)
        layoutRestored.chatShortcuts = [shortcut]
        layoutRestored.save()
        precondition(SettingsStore(defaults: defaults).chatShortcuts == [shortcut])
        layoutRestored.chatShortcuts = []
        layoutRestored.save()
        precondition(SettingsStore(defaults: defaults).chatShortcuts.isEmpty)
        let phrase = QuickPhrase(name: "Explain", symbol: "text.bubble", text: "请详细解释。\nKeep line breaks.")
        layoutRestored.quickPhrasesByApp[chat.bundleID] = [phrase]
        layoutRestored.save()
        precondition(SettingsStore(defaults: defaults).quickPhrasesByApp[chat.bundleID] == [phrase])
        precondition(phrase.displayShortcut.color == "#363636")
        let phraseBar = AppBar(app: chat, phrases: [phrase], persistsLayout: false)
        precondition(phraseBar.bar.customizationAllowedItemIdentifiers == ["chatgpt.sidebar", "chatgpt.chats", "chatgpt.terminal", "phrases", "keyboard", "text"].map(AppBar.itemID) + [.flexibleSpace])
        for name in ["name", "open", "counter", "reset", "clock", "settings", "hide"] {
            precondition(phraseBar.touchBar(phraseBar.bar, makeItemForIdentifier: AppBar.itemID(name)) == nil)
        }
        let phraseWrapper = (phraseBar.touchBar(phraseBar.bar, makeItemForIdentifier: AppBar.itemID("phrases")) as! NSCustomTouchBarItem).view as! TouchBarComponentView
        let phraseView = phraseWrapper.content
        let phraseScrubber = phraseView.subviews.compactMap { $0 as? NSScrubber }.first!
        precondition(phraseScrubber.dataSource?.numberOfItems(for: phraseScrubber) == 1)
        phraseBar.configurePhrases([])
        precondition(phraseScrubber.dataSource?.numberOfItems(for: phraseScrubber) == 0)
        precondition(phraseView.constraints.contains { $0.firstAttribute == .width && $0.relation == .greaterThanOrEqual && $0.constant == 32 })
        layoutRestored.autoPolicy = .selection
        precondition(layoutRestored.configurableApps.map(\.bundleID) == layoutRestored.rules.map(\.bundleID))
        layoutRestored.rules.removeAll()
        precondition(layoutRestored.configurableApps.isEmpty)
        layoutRestored.autoPolicy = .exclusion
        precondition(!layoutRestored.configurableApps.isEmpty)
        print("Settings smoke checks passed")
    }
}
