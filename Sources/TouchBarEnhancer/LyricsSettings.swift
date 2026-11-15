import AppKit

extension Notification.Name {
    static let openLyricsSettings = Notification.Name("local.starfruit.TouchBarEnhancer.openLyricsSettings")
}

/// Owns explicit search/preview work. Playback observation has the pane's lifetime.
@MainActor
final class LyricsSearchModel {
    let repository: LyricsRepository
    var onChange: (() -> Void)?
    var title = "" { didSet { queryEdited = true; autofillOnNextRead = false } }
    var artist = "" { didSet { queryEdited = true; autofillOnNextRead = false } }
    private var queryEdited = false, autofillOnNextRead = false
    private(set) var currentTrack: LyricsTrack?
    private(set) var targetTrack: LyricsTrack?
    private(set) var candidates: [LyricsRepository.Candidate] = []
    private(set) var selectedID: String?
    private(set) var preview: LyricsSearchResult?
    private(set) var status = ""
    private(set) var searching = false
    private(set) var active = false
    private let read: (@escaping @MainActor (LyricsPlayback?) -> Void) -> Void
    private let observe: (@escaping @MainActor () -> Void) -> (() -> Void)?
    private var unsubscribe: (() -> Void)?
    private var searchTask: Task<Void, Never>?, previewTask: Task<Void, Never>?
    private var request = UUID(), previewRequest = UUID(), readRequest = UUID()

    init(repository: LyricsRepository,
         read: @escaping (@escaping @MainActor (LyricsPlayback?) -> Void) -> Void = { $0(nil) },
         observe: @escaping (@escaping @MainActor () -> Void) -> (() -> Void)? = { _ in nil }) {
        self.repository = repository; self.read = read; self.observe = observe
    }
    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if value {
            autofillOnNextRead = true
            unsubscribe = observe { [weak self] in self?.readTrack() }
            readTrack()
        } else {
            unsubscribe?(); unsubscribe = nil; readRequest = UUID()
            cancel(); status = ""; onChange?()
        }
    }
    private func readTrack() {
        let id = UUID(); readRequest = id
        read { [weak self] state in
            guard let self, self.active, self.readRequest == id else { return }
            self.currentTrack = state?.track
            if let track = state?.track, self.autofillOnNextRead || !self.queryEdited {
                self.title = track.title; self.artist = track.artist
                self.queryEdited = false; self.autofillOnNextRead = false
            }
            self.onChange?()
        }
    }
    func cancel() {
        request = UUID(); previewRequest = UUID()
        if previewTask != nil && preview == nil { selectedID = nil }
        searchTask?.cancel(); searchTask = nil; previewTask?.cancel(); previewTask = nil; searching = false
    }
    func search() {
        cancel()
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Enter a song title."; onChange?(); return }
        targetTrack = currentTrack ?? LyricsTrack(title: title, artist: artist)
        candidates = []; selectedID = nil; preview = nil; searching = true; status = "Searching…"; onChange?()
        let id = request, queryTitle = title, queryArtist = artist, duration = targetTrack?.duration
        searchTask = Task { [weak self, repository] in
            do {
                let found = try await repository.searchCandidates(title: queryTitle, artist: queryArtist, duration: duration)
                guard !Task.isCancelled, let self, self.request == id else { return }
                self.candidates = found; self.searching = false; self.searchTask = nil
                self.status = found.isEmpty ? "No results. Try a shorter title or another artist name." : "\(found.count) results"
                self.onChange?()
                let query = LyricsTrack(title: queryTitle, artist: queryArtist, duration: duration)
                if let recommended = found.first, LyricsRepository.matchScore(recommended.track, for: query) != nil
                    || LyricsRepository.durationDifference(recommended.track, for: query) != nil
                        && LyricsRepository.matchScore(recommended.track, for: query, fuzzy: true) != nil {
                    self.selectCandidate(recommended.identity)
                }
            } catch {
                guard !Task.isCancelled, let self, self.request == id else { return }
                self.searching = false; self.searchTask = nil; self.status = "Search failed. Check your connection and try again."; self.onChange?()
            }
        }
    }
    func selectCandidate(_ identity: String?) {
        guard selectedID != identity else { return }
        previewTask?.cancel(); previewRequest = UUID(); selectedID = identity; preview = nil
        guard let candidate = candidates.first(where: { $0.identity == identity }) else { onChange?(); return }
        status = "Loading preview…"; onChange?()
        let id = previewRequest
        previewTask = Task { [weak self, repository] in
            do {
                let result = try await repository.lyrics(for: candidate)
                guard !Task.isCancelled, let self, self.previewRequest == id else { return }
                self.preview = result; self.previewTask = nil; self.status = result.instrumental ? "Instrumental" : "Preview ready"
                self.onChange?()
            } catch {
                guard !Task.isCancelled, let self, self.previewRequest == id else { return }
                self.previewTask = nil; self.status = "Timed lyrics are unavailable for this result."; self.onChange?()
            }
        }
    }
    func useSelection() {
        guard let preview, let targetTrack else { return }
        do { try repository.select(preview, for: targetTrack); status = "Saved for this song. Lyrics updated." }
        catch { status = "Could not save lyrics to the local cache." }
        onChange?()
    }
    func restoreAutomatic() {
        guard let track = targetTrack ?? currentTrack else { return }
        do { try repository.removeSelection(for: track); status = "Automatic matching restored." }
        catch { status = "Could not remove this song’s cached selection." }
        onChange?()
    }
}

@MainActor
final class LyricsSettingsPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let model: LyricsSearchModel
    private let store: SettingsStore
    let sourcesTable = NSTableView(), resultsTable = NSTableView()
    private let titleField = NSTextField(), artistField = NSTextField()
    private let playing = NSTextField(labelWithString: "No song playing")
    private let target = NSTextField(labelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextView()
    private let searchButton = NSButton(title: "Search", target: nil, action: nil)
    private let useButton = NSButton(title: "Use Lyrics", target: nil, action: nil)
    private let restoreButton = NSButton(title: "Restore Automatic", target: nil, action: nil)
    private let fuzzy = NSButton(checkboxWithTitle: "Allow fuzzy matching", target: nil, action: nil)
    private static let dragType = NSPasteboard.PasteboardType("local.starfruit.TouchBarEnhancer.lyricsSource")
    private var rows: [String] = []

    init(store: SettingsStore, model: LyricsSearchModel) {
        self.store = store; self.model = model
        super.init(frame: .zero)
        setAccessibilityIdentifier("lyricsSettingsPane")
        let sourceColumn = NSTableColumn(identifier: .init("source")); sourceColumn.title = "Source"; sourcesTable.addTableColumn(sourceColumn)
        sourcesTable.headerView = nil; sourcesTable.rowHeight = 24
        sourcesTable.setAccessibilityIdentifier("lyricsSourceOrder")
        sourcesTable.registerForDraggedTypes([Self.dragType]); sourcesTable.setDraggingSourceOperationMask(.move, forLocal: true)
        let sourceScroll = tableScroll(sourcesTable)
        sourceScroll.heightAnchor.constraint(equalToConstant: 82).isActive = true
        fuzzy.state = store.lyricsSearch.fuzzyMatching ? .on : .off; fuzzy.target = self; fuzzy.action = #selector(changeFuzzy)
        fuzzy.toolTip = "After exact matches, prefer similar titles with the closest playing duration. Artist is optional when duration matches."
        let heading = NSTextField(labelWithString: "Search Order"); heading.font = .systemFont(ofSize: 13, weight: .semibold)
        sourcesTable.toolTip = "Drag to reorder sources. Exact matches first, then closest duration."
        titleField.placeholderString = "Song title"; titleField.setAccessibilityIdentifier("lyricsSearchTitle")
        artistField.placeholderString = "Artist (optional)"; artistField.setAccessibilityIdentifier("lyricsSearchArtist")
        for field in [titleField, artistField] { field.delegate = self; field.target = self; field.action = #selector(search) }
        searchButton.target = self; searchButton.action = #selector(search)
        useButton.target = self; useButton.action = #selector(useLyrics)
        restoreButton.target = self; restoreButton.action = #selector(restore)
        let searchRow = NSStackView(views: [titleField, artistField, searchButton]); searchRow.spacing = 8; searchRow.alignment = .centerY
        titleField.widthAnchor.constraint(equalTo: artistField.widthAnchor, multiplier: 1.2).isActive = true
        playing.lineBreakMode = .byTruncatingTail
        playing.textColor = .secondaryLabelColor
        for (key, name, width) in [("title", "Title", 230.0), ("artist", "Artist", 170.0), ("source", "Source", 100.0), ("duration", "Time", 65.0)] {
            let column = NSTableColumn(identifier: .init(key)); column.title = name; column.width = width; column.minWidth = key == "duration" ? 50 : 75
            resultsTable.addTableColumn(column)
        }
        resultsTable.setAccessibilityIdentifier("lyricsSearchResults"); resultsTable.rowHeight = 26
        let resultsScroll = tableScroll(resultsTable); resultsScroll.hasHorizontalScroller = true
        resultsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        preview.isEditable = false; preview.isSelectable = true; preview.font = .systemFont(ofSize: NSFont.systemFontSize)
        preview.textContainerInset = NSSize(width: 8, height: 8)
        preview.isVerticallyResizable = true; preview.isHorizontallyResizable = false
        preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        let previewScroll = NSScrollView(); previewScroll.documentView = preview; previewScroll.hasVerticalScroller = true; previewScroll.borderType = .bezelBorder
        previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        let bottom = NSStackView(views: [useButton, restoreButton]); bottom.spacing = 8
        target.font = .systemFont(ofSize: NSFont.smallSystemFontSize); target.textColor = .secondaryLabelColor; target.lineBreakMode = .byTruncatingTail
        feedback.font = .systemFont(ofSize: NSFont.smallSystemFontSize); feedback.textColor = .secondaryLabelColor
        let separator = NSBox(); separator.boxType = .separator; separator.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let stack = NSStackView(views: [heading, sourceScroll, fuzzy, separator, playing, searchRow, resultsScroll, previewScroll, target, bottom, feedback])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
        for view in [sourceScroll, separator, playing, searchRow, resultsScroll, previewScroll, target, feedback] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        model.onChange = { [weak self] in self?.refresh() }; refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func tableScroll(_ table: NSTableView) -> NSScrollView {
        table.delegate = self; table.dataSource = self; table.style = .inset; table.allowsMultipleSelection = false
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; return scroll
    }
    private func refresh() {
        if titleField.currentEditor() == nil { titleField.stringValue = model.title }
        if artistField.currentEditor() == nil { artistField.stringValue = model.artist }
        playing.stringValue = model.currentTrack.map { "\($0.title) — \($0.artist)" } ?? "No song playing"
        target.stringValue = model.targetTrack.map { "Save for: \($0.title) — \($0.artist)" } ?? ""
        target.isHidden = model.targetTrack == nil
        let ids = model.candidates.map(\.identity)
        if rows != ids { rows = ids; resultsTable.reloadData() }
        let selection = model.selectedID.flatMap { id in model.candidates.firstIndex { $0.identity == id } } ?? -1
        if resultsTable.selectedRow != selection {
            if selection < 0 { resultsTable.deselectAll(nil) }
            else { resultsTable.selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false) }
        }
        let previewText = model.preview.map { value in
            value.instrumental ? "Instrumental" : value.lyrics?.lines.map { String(format: "[%02d:%05.2f] %@", Int($0.time) / 60, $0.time.truncatingRemainder(dividingBy: 60), $0.text) }.joined(separator: "\n") ?? ""
        } ?? ""
        if preview.string != previewText { preview.string = previewText }
        searchButton.isEnabled = !model.searching
        useButton.isEnabled = model.preview != nil && model.targetTrack != nil
        restoreButton.isEnabled = (model.targetTrack ?? model.currentTrack).map { model.repository.selection(for: $0) != nil } ?? false
        restoreButton.isHidden = !restoreButton.isEnabled
        feedback.stringValue = model.status; feedback.isHidden = model.status.isEmpty
    }
    func controlTextDidChange(_ notification: Notification) {
        model.title = titleField.stringValue; model.artist = artistField.stringValue
    }
    @objc private func search() { model.title = titleField.stringValue; model.artist = artistField.stringValue; model.search() }
    @objc private func useLyrics() { model.useSelection() }
    @objc private func restore() { model.restoreAutomatic() }
    @objc private func changeFuzzy() {
        store.lyricsSearch.fuzzyMatching = fuzzy.state == .on; store.save(); model.repository.configure(store.lyricsSearch)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === sourcesTable ? store.lyricsSearch.orderedSources.count : model.candidates.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let value: String
        if tableView === sourcesTable { value = "\(row + 1).  \(store.lyricsSearch.orderedSources[row].rawValue)" }
        else {
            guard model.candidates.indices.contains(row) else { return nil }
            let item = model.candidates[row]
            switch tableColumn?.identifier.rawValue {
            case "artist": value = item.track.artist
            case "source": value = item.source
            case "duration": value = item.track.duration.flatMap { $0.isFinite && $0 > 0 && $0 < 86_400 ? String(format: "%d:%02d", Int($0) / 60, Int($0) % 60) : nil } ?? "—"
            default: value = item.track.title
            }
        }
        let field = NSTextField(labelWithString: value); field.lineBreakMode = .byTruncatingTail; field.toolTip = value
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard notification.object as? NSTableView === resultsTable else { return }
        let row = resultsTable.selectedRow
        model.selectCandidate(model.candidates.indices.contains(row) ? model.candidates[row].identity : nil)
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === sourcesTable, store.lyricsSearch.orderedSources.indices.contains(row) else { return nil }
        let item = NSPasteboardItem(); item.setString(store.lyricsSearch.orderedSources[row].rawValue, forType: Self.dragType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        tableView === sourcesTable && info.draggingSource as? NSTableView === sourcesTable && operation == .above && (0...numberOfRows(in: sourcesTable)).contains(row) ? .move : []
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation operation: NSTableView.DropOperation) -> Bool {
        guard self.tableView(tableView, validateDrop: info, proposedRow: row, proposedDropOperation: operation) == .move,
              let name = info.draggingPasteboard.string(forType: Self.dragType), let source = LyricsSource(rawValue: name) else { return false }
        return moveSource(source, to: row)
    }
    @discardableResult func moveSource(_ source: LyricsSource, to row: Int) -> Bool {
        var order = store.lyricsSearch.orderedSources
        guard (0...order.count).contains(row), let old = order.firstIndex(of: source) else { return false }
        order.remove(at: old); let destination = row > old ? row - 1 : row; order.insert(source, at: destination)
        store.lyricsSearch.sources = order; store.save(); model.repository.configure(store.lyricsSearch)
        sourcesTable.reloadData(); sourcesTable.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false); return true
    }
}
