import AppKit

/// Offscreen drag session fixture; exercises the actual table data-source callbacks.
@MainActor
final class RowDragFixture: NSObject, NSDraggingInfo {
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
struct ListReorderingSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func main() {
        _ = NSApplication.shared
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suite = "TouchBarEnhancer.ReorderingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let widths: [ComponentItemWidth] = [.init(relative: 6), .init(mode: .fixed, fixed: 96), .init(mode: .hug)]
        store.chatShortcuts = [ChatShortcut(name: "First", color: "blue", slot: 2, displayModeOverride: .iconOnly, fillWidth: widths[0]),
            ChatShortcut(name: "第二个", color: "teal", slot: 7, fillWidth: widths[1]),
            ChatShortcut(name: "Third", color: "orange", slot: 9, fillWidth: widths[2])]
        let keyboardApp = LayoutApp.builtIn[0].bundleID
        store.quickPhrasesByApp[keyboardApp] = (1...3).map {
            QuickPhrase(name: "Phrase \($0)", text: "Content \($0)\n第二行", displayModeOverride: $0 == 1 ? .iconAndText : nil,
                fillWidth: widths[$0 - 1])
        }
        store.keyboardButtons[keyboardApp] = KeyboardButtonsConfiguration(buttons: (1...3).map {
            KeyboardButton(title: "Button \($0)", shortcut: .init(keyCode: UInt16($0), modifiers: NSEvent.ModifierFlags.command.rawValue,
                keyLabel: "\($0)"), description: "Action \($0)", displayModeOverride: $0 == 1 ? .iconOnly : nil, fillWidth: widths[$0 - 1])
        })
        let provider = AppBar(app: LayoutApp.builtIn[0], shortcuts: store.chatShortcuts,
            phrases: store.quickPhrasesByApp[keyboardApp]!, keyboardButtons: store.keyboardButtons[keyboardApp]!, persistsLayout: false)
        let chatView = (provider.bar.item(forIdentifier: AppBar.itemID("chatgpt.chats")) as! NSCustomTouchBarItem).view
        let phraseView = (provider.bar.item(forIdentifier: AppBar.itemID("phrases")) as! NSCustomTouchBarItem).view
        let chatScroller = descendants(chatView).compactMap { $0 as? NSScrubber }.first!
        let phraseScroller = descendants(phraseView).compactMap { $0 as? NSScrubber }.first!
        let keyboardView = (provider.bar.item(forIdentifier: AppBar.itemID("keyboard")) as! NSCustomTouchBarItem).view
        let keyboardScroller = descendants(keyboardView).compactMap { $0 as? NSScrubber }.first!
        var changes = 0
        store.onChange = {
            changes += 1
            provider.configureChats(store.chatShortcuts)
            provider.configurePhrases(store.quickPhrasesByApp[keyboardApp]!)
            provider.configureKeyboardButtons(store.keyboardButtons[keyboardApp]!)
        }
        for kind in [ShortcutCategoryEditor.Kind.chats, .phrases, .keyboard] {
            let editor = ShortcutCategoryEditor(store: store, kind: kind, appBundleID: keyboardApp)
            let table = descendants(editor).compactMap { $0 as? NSTableView }.first!
            precondition(!descendants(editor).compactMap { $0 as? NSTextField }.contains { !$0.isHidden && $0.stringValue == "SF Symbol" })
            let originalChats = store.chatShortcuts
            let originalPhrases = store.quickPhrasesByApp[keyboardApp]!
            let originalKeyboard = store.keyboardButtons[keyboardApp]!
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let writer = editor.tableView(table, pasteboardWriterForRow: 0)!
            precondition(pasteboard.writeObjects([writer]))
            let drag = RowDragFixture(source: table, pasteboard: pasteboard)
            precondition(editor.tableView(table, validateDrop: drag, proposedRow: 3, proposedDropOperation: .on) == .move)
            let before = changes
            precondition(editor.tableView(table, acceptDrop: drag, row: 3, dropOperation: .above))
            precondition(changes == before + 1 && table.selectedRow == 2)
            if kind == .chats {
                precondition(store.chatShortcuts == [originalChats[1], originalChats[2], originalChats[0]])
                precondition(store.quickPhrasesByApp[keyboardApp] == originalPhrases)
                precondition(SettingsStore(defaults: defaults).chatShortcuts == store.chatShortcuts)
            } else if kind == .phrases {
                precondition(store.quickPhrasesByApp[keyboardApp] == [originalPhrases[1], originalPhrases[2], originalPhrases[0]])
                precondition(store.chatShortcuts == originalChats)
                precondition(SettingsStore(defaults: defaults).quickPhrasesByApp == store.quickPhrasesByApp)
            } else {
                precondition(store.keyboardButtons[keyboardApp]!.buttons == [originalKeyboard.buttons[1], originalKeyboard.buttons[2], originalKeyboard.buttons[0]])
                precondition(SettingsStore(defaults: defaults).keyboardButtons[keyboardApp] == store.keyboardButtons[keyboardApp])
            }
            let scroller = kind == .chats ? chatScroller : (kind == .phrases ? phraseScroller : keyboardScroller)
            let first = scroller.dataSource!.scrubber(scroller, viewForItemAt: 0)
            precondition(descendants(first).compactMap { $0 as? NSTextField }.contains {
                $0.stringValue == (kind == .chats ? originalChats[1].name : (kind == .phrases ? originalPhrases[1].name : originalKeyboard.buttons[1].title))
            }, "Active Touch Bar must update immediately after reordering")
            // Same stable ID still resolves correctly after its row changes.
            precondition(editor.tableView(table, validateDrop: drag, proposedRow: 0, proposedDropOperation: .above) == .move)
            precondition(editor.tableView(table, acceptDrop: drag, row: 0, dropOperation: .above))
            precondition(table.selectedRow == 0)
            precondition(store.chatShortcuts == originalChats && store.quickPhrasesByApp[keyboardApp] == originalPhrases)
            precondition(store.keyboardButtons[keyboardApp] == originalKeyboard)
            let titleCell = editor.tableView(table, viewFor: table.tableColumns[0], row: table.selectedRow)!
            let nameField = descendants(titleCell).compactMap { $0 as? NSTextField }.first {
                $0.placeholderString == (kind == .chats ? "Chat name" : (kind == .phrases ? "Phrase title" : "Button title"))
            }!
            precondition(nameField.stringValue == (kind == .chats ? originalChats[0].name : (kind == .phrases ? originalPhrases[0].name : originalKeyboard.buttons[0].title)))
            precondition(editor.tableView(table, validateDrop: drag, proposedRow: 1, proposedDropOperation: .above).isEmpty)
            precondition(!editor.tableView(table, acceptDrop: drag, row: 1, dropOperation: .above))
            precondition(!editor.tableView(table, acceptDrop: drag, row: -1, dropOperation: .above))
            precondition(!editor.tableView(table, acceptDrop: drag, row: 4, dropOperation: .above))
            precondition(!editor.tableView(table, acceptDrop: drag, row: 2, dropOperation: .on))
            let foreignDrag = RowDragFixture(source: NSTableView(), pasteboard: pasteboard)
            precondition(editor.tableView(table, validateDrop: foreignDrag, proposedRow: 2, proposedDropOperation: .above).isEmpty)
            precondition(!editor.tableView(table, acceptDrop: foreignDrag, row: 2, dropOperation: .above))
            switch kind {
            case .chats: store.chatShortcuts.removeFirst()
            case .phrases: store.quickPhrasesByApp[keyboardApp]!.removeFirst()
            case .keyboard: store.keyboardButtons[keyboardApp]!.buttons.removeFirst()
            }
            precondition(!editor.tableView(table, acceptDrop: drag, row: 2, dropOperation: .above), "Reject deleted drag IDs")
            store.chatShortcuts = originalChats; store.quickPhrasesByApp[keyboardApp] = originalPhrases
            store.keyboardButtons[keyboardApp] = originalKeyboard
            print("\(kind.title) reordering checks passed")
        }
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        print("List reordering checks passed: native callbacks, both directions, selection, stable IDs, data and shortcuts, persistence, live bar updates, invalid drops, no window activation")
    }
}
