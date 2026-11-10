import AppKit

@main @MainActor
struct PerAppPhrasesSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory); application.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suite = "TouchBarEnhancer.PerAppPhrasesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstApp = LayoutApp.builtIn[0]
        let secondApp = LayoutApp.builtIn[1]
        let customApp = LayoutApp(bundleID: "test.previously-configured", name: "Previous App")
        let legacy = [QuickPhrase(name: "保留短语", symbol: "star", imageData: Data([1, 2, 3]), text: "Existing\nphrase")]
        let legacyData = try! JSONEncoder().encode(legacy)
        precondition(!String(data: legacyData, encoding: .utf8)!.contains("displayModeOverride"))
        defaults.set(legacyData, forKey: "quickPhrases")
        defaults.set(try! JSONEncoder().encode([customApp]), forKey: "layoutApps")
        defaults.set(try! JSONEncoder().encode([AppRule(bundleID: "test.rule", name: "Rule", mode: .native)]), forKey: "appRules")
        defaults.set(try! JSONEncoder().encode(["test.keyboard": KeyboardButtonsConfiguration()]), forKey: "keyboardButtons")
        defaults.set(try! JSONEncoder().encode(["test.display": ["phrases": ComponentDisplayMode.iconOnly]]), forKey: "componentDisplayModes")
        let store = SettingsStore(defaults: defaults)
        for id in [firstApp.bundleID, secondApp.bundleID, customApp.bundleID, "test.rule", "test.keyboard", "test.display"] {
            precondition(store.quickPhrasesByApp[id] == legacy, "Every known app gets a complete independent copy")
        }
        precondition(defaults.data(forKey: "quickPhrasesByApp") != nil)
        precondition(store.quickPhrasesByApp["test.new-app"] == nil)
        precondition(store.quickPhrasesByApp[firstApp.bundleID]![0].displayModeOverride == nil)
        // Legacy model payloads without the new optional field must decode intact.
        let chats = [ChatShortcut(name: "Existing Chat", slot: 3)]
        let buttons = [KeyboardButton(title: "Existing Button")]
        precondition(try! JSONDecoder().decode([ChatShortcut].self, from: JSONEncoder().encode(chats)) == chats)
        precondition(try! JSONDecoder().decode([KeyboardButton].self, from: JSONEncoder().encode(buttons)) == buttons)

        let first = AppBar(app: firstApp, phrases: store.quickPhrasesByApp[firstApp.bundleID]!, persistsLayout: false)
        let second = AppBar(app: secondApp, phrases: store.quickPhrasesByApp[secondApp.bundleID]!, persistsLayout: false)
        let firstItem = first.bar.item(forIdentifier: AppBar.itemID("phrases")) as! NSCustomTouchBarItem
        let secondItem = second.bar.item(forIdentifier: AppBar.itemID("phrases")) as! NSCustomTouchBarItem
        let firstScroller = descendants(firstItem.view).compactMap { $0 as? NSScrubber }.first!
        let secondScroller = descendants(secondItem.view).compactMap { $0 as? NSScrubber }.first!
        store.onChange = {
            first.configurePhrases(store.quickPhrasesByApp[firstApp.bundleID] ?? [])
            second.configurePhrases(store.quickPhrasesByApp[secondApp.bundleID] ?? [])
        }
        let editor = ShortcutCategoryEditor(store: store, kind: .phrases, appBundleID: firstApp.bundleID)
        let editingTable = descendants(editor).compactMap { $0 as? NSTableView }.first!
        let titleCell = editor.tableView(editingTable, viewFor: editingTable.tableColumns[0], row: 0)!
        let title = descendants(titleCell).compactMap { $0 as? ComponentInlineTextField }.first!
        let content = descendants(editor).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "phraseContent" }!
        title.stringValue = "Only the first app"
        content.string = "Independent content"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: title))
        editor.textDidChange(Notification(name: NSText.didChangeNotification, object: content))
        precondition(store.quickPhrasesByApp[firstApp.bundleID]![0].name == title.stringValue)
        precondition(store.quickPhrasesByApp[firstApp.bundleID]![0].text == content.string)
        precondition(store.quickPhrasesByApp[secondApp.bundleID] == legacy)
        let firstView = firstScroller.dataSource!.scrubber(firstScroller, viewForItemAt: 0)
        let secondView = secondScroller.dataSource!.scrubber(secondScroller, viewForItemAt: 0)
        precondition(descendants(firstView).compactMap { $0 as? NSTextField }.contains { $0.stringValue == title.stringValue })
        precondition(descendants(secondView).compactMap { $0 as? NSTextField }.contains { $0.stringValue == legacy[0].name })
        let add = descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Add Phrase" }!
        let delete = descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Delete Phrase" }!
        add.performClick(nil)
        precondition(firstScroller.numberOfItems == 2 && secondScroller.numberOfItems == 1)
        delete.performClick(nil); delete.performClick(nil)
        precondition(store.quickPhrasesByApp[firstApp.bundleID] == [] && firstScroller.numberOfItems == 0)
        precondition(store.quickPhrasesByApp[secondApp.bundleID] == legacy)
        let reloaded = SettingsStore(defaults: defaults)
        precondition(reloaded.quickPhrasesByApp[firstApp.bundleID] == [], "An intentionally empty list must stay empty")
        precondition(reloaded.quickPhrasesByApp[secondApp.bundleID] == legacy)
        reloaded.quickPhrasesByApp.removeValue(forKey: customApp.bundleID); reloaded.save()
        precondition(SettingsStore(defaults: defaults).quickPhrasesByApp[customApp.bundleID] == nil, "Do not reapply migration")
        precondition(defaults.data(forKey: "quickPhrases") == legacyData, "Keep the old key as an untouched backup")
        let newEditor = ShortcutCategoryEditor(store: reloaded, kind: .phrases, appBundleID: "test.new-app")
        let newTable = descendants(newEditor).compactMap { $0 as? NSTableView }.first!
        precondition(newTable.numberOfRows == 0)
        let newAdd = descendants(newEditor).compactMap { $0 as? NSButton }.first { $0.title == "Add Phrase" }!
        newAdd.performClick(nil)
        precondition(reloaded.quickPhrasesByApp["test.new-app"]?.count == 1)
        precondition(reloaded.quickPhrasesByApp[firstApp.bundleID] == [] && reloaded.quickPhrasesByApp[secondApp.bundleID] == legacy)
        // An existing new-format empty dictionary is also authoritative.
        defaults.set(try! JSONEncoder().encode([String: [QuickPhrase]]()), forKey: "quickPhrasesByApp")
        precondition(SettingsStore(defaults: defaults).quickPhrasesByApp.isEmpty)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        print("Per-app phrase checks passed: one-time migration, full data preservation, independent editing/add/delete/live views, empty and new app lists, legacy backup, no activation")
    }
}
