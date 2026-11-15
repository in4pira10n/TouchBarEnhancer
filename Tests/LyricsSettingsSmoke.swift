import AppKit

@MainActor
private final class LyricsSourceDrag: NSObject, NSDraggingInfo {
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

private actor LyricsSettingsNetwork {
    var pending: [CheckedContinuation<Void, Never>] = []
    func waiting() -> Bool { !pending.isEmpty }
    func release() { let old = pending; pending = []; for continuation in old { continuation.resume() } }
    func data(_ request: URLRequest) async throws -> Data {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        if components.host != "lrclib.net" {
            return Data((components.host == "music.163.com" ? #"{"code":200,"result":{"songs":[]}}"# : #"{"code":0,"data":{"song":{"itemlist":[]}}}"#).utf8)
        }
        let title = components.queryItems!.first { $0.name == "track_name" }!.value!
        if title == "Delayed" { await withCheckedContinuation { pending.append($0) } }
        return try JSONSerialization.data(withJSONObject: [["id": 1, "trackName": title, "artistName": "Artist",
            "duration": 123, "syncedLyrics": "[00:00]First line\n[00:05]Second line"]])
    }
}

@main @MainActor
struct LyricsSettingsSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<1_000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(1)) }
        precondition(predicate(), "Async operation did not settle")
    }
    static func main() async throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory); app.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let clipboard = NSPasteboard.general.changeCount
        let suite = "TouchBarEnhancer.LyricsSettingsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let store = SettingsStore(defaults: defaults)
        store.lyricsSearch.sources = [.lrclib, .qqMusic, .netEase]
        let network = LyricsSettingsNetwork()
        let repository = LyricsRepository(directory: folder, transport: { try await network.data($0) }, preferences: store.lyricsSearch)
        var state = LyricsPlayback(track: .init(title: "Original", artist: "Artist", album: "Album", duration: 123),
            elapsed: 0, date: Date(), rate: 1, playing: true)
        let original = state.track
        var event: (@MainActor () -> Void)?, reads = 0, cancels = 0, reloads = 0
        let model = LyricsSearchModel(repository: repository, read: { reads += 1; $0(state) },
            observe: { event = $0; return { cancels += 1; event = nil } })
        let controller = SettingsWindowController(store: store, lyricsModel: model)
        let window = controller.window!
        precondition(reads == 0 && !window.isVisible && !model.active)
        func pane(_ id: String) {
            let item = window.toolbar!.items.first { $0.itemIdentifier.rawValue == id }!
            precondition(app.sendAction(item.action!, to: item.target, from: item)); window.layoutIfNeeded()
        }
        pane("lyrics")
        precondition(reads == 0 && !model.active && window.contentMinSize == NSSize(width: 760, height: 650))
        let editor = window.contentView!.subviews.first as! LyricsSettingsPane
        store.onChange = { if repository.configure(store.lyricsSearch) { reloads += 1 } }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        precondition(board.writeObjects([editor.tableView(editor.sourcesTable, pasteboardWriterForRow: 2)!]))
        let drag = LyricsSourceDrag(source: editor.sourcesTable, pasteboard: board)
        precondition(editor.tableView(editor.sourcesTable, validateDrop: drag, proposedRow: 0, proposedDropOperation: .above) == .move)
        precondition(editor.tableView(editor.sourcesTable, acceptDrop: drag, row: 0, dropOperation: .above))
        precondition(store.lyricsSearch.orderedSources == [.netEase, .lrclib, .qqMusic] && reloads == 1)
        let foreign = LyricsSourceDrag(source: editor.resultsTable, pasteboard: board)
        precondition(editor.tableView(editor.sourcesTable, validateDrop: foreign, proposedRow: 0, proposedDropOperation: .above).isEmpty)
        precondition(!editor.tableView(editor.sourcesTable, acceptDrop: drag, row: 0, dropOperation: .on))
        let fuzzy = descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Allow fuzzy matching" }!
        fuzzy.performClick(nil); precondition(!store.lyricsSearch.fuzzyMatching && reloads == 2)
        fuzzy.performClick(nil); precondition(store.lyricsSearch.fuzzyMatching && reloads == 3)
        let reloaded = SettingsStore(defaults: defaults)
        precondition(reloaded.lyricsSearch == store.lyricsSearch && reloaded.lastSettingsPane == "lyrics")

        // Observation is tied to the pane; no player polling or search on typing.
        model.setActive(true); precondition(reads == 1 && model.title == "Original")
        let titleField = descendants(editor).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "lyricsSearchTitle" }!
        titleField.stringValue = "Alternate spelling"
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: titleField))
        let search = descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Search" }!
        search.performClick(nil)
        state.track = .init(title: "Next Song", artist: "Someone Else"); event?()
        try await settle { !model.searching }
        precondition(model.targetTrack == original && model.candidates.count == 1 && model.currentTrack == state.track)
        editor.resultsTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try await settle { model.preview != nil }
        let use = descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Use Lyrics" }!
        precondition(use.isEnabled); use.performClick(nil)
        precondition(repository.selection(for: original) != nil && repository.selection(for: state.track) == nil)
        let preview = descendants(editor).compactMap { $0 as? NSTextView }.first { !$0.isEditable }!
        precondition(preview.string.contains("Second line"))
        preview.setSelectedRange(NSRange(location: 0, length: 5)); event?()
        precondition(preview.selectedRange().length == 5, "Metadata event must not reset preview selection")
        let restore = descendants(editor).compactMap { $0 as? NSButton }.first { $0.title == "Restore Automatic" }!
        restore.performClick(nil); precondition(repository.selection(for: original) == nil)

        // A cancelled request deliberately completes after a newer search.
        model.title = "Delayed"; model.artist = "Artist"; model.search()
        for _ in 0..<1_000 { if await network.waiting() { break }; try await Task.sleep(for: .milliseconds(1)) }
        let waiting = await network.waiting(); precondition(waiting)
        model.title = "Fresh"; model.search(); try await settle { !model.searching }
        await network.release()
        for _ in 0..<10 { await Task.yield() }
        precondition(model.candidates.first?.track.title == "Fresh")
        model.selectCandidate(model.candidates.first?.identity); try await settle { model.preview != nil }
        let chosen = model.preview!
        let delayedTrack = LyricsTrack(title: "Delayed", artist: "Artist")
        let automatic = Task { try await repository.search(delayedTrack, refresh: true) }
        for _ in 0..<1_000 { if await network.waiting() { break }; try await Task.sleep(for: .milliseconds(1)) }
        try repository.select(chosen, for: delayedTrack)
        await network.release()
        let late = try await automatic.value
        precondition(late == chosen, "In-flight automatic result cannot overwrite an explicit selection")
        pane("general"); precondition(!model.active && event == nil && cancels == 1)
        let count = reads; controller.resumePreviewIfNeeded(); precondition(reads == count)
        pane("lyrics")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance); window.layoutIfNeeded()
            window.displayIfNeeded()
            let root = window.contentView!
            precondition(editor.sourcesTable.enclosingScrollView!.frame.height >= 80)
            precondition(editor.resultsTable.enclosingScrollView!.frame.height >= 120)
            for button in descendants(editor).compactMap({ $0 as? NSButton }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
                let rect = button.convert(button.bounds, to: root)
                precondition(root.bounds.insetBy(dx: -1, dy: -1).contains(rect), "Clipped button: \(button.title)")
            }
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.effectiveAppearance.performAsCurrentDrawingAppearance {
                let context = NSGraphicsContext(bitmapImageRep: bitmap)!
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
                NSColor.windowBackgroundColor.setFill(); NSBezierPath(rect: root.bounds).fill()
                root.displayIgnoringOpacity(root.bounds, in: context)
                NSGraphicsContext.restoreGraphicsState()
            }
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: ".build/settings-ui/lyrics-\(appearance.rawValue).png"))
        }
        precondition(!window.isVisible && NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        precondition(NSPasteboard.general.changeCount == clipboard)
        print("Lyrics settings checks passed: native source drag, fuzzy preference, immediate reload, query/preview/selection, stable song binding, offline cache, stale/cancelled searches, minimum layout and silent lifecycle")
    }
}
