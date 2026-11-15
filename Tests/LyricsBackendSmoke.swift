import Foundation

@MainActor
private final class FixtureClock {
    var now = Date(timeIntervalSince1970: 1_000)
    var pending: [UUID: (Date, @MainActor () -> Void)] = [:]
    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID(); pending[id] = (now.addingTimeInterval(delay), action)
        return { [weak self] in self?.pending[id] = nil }
    }
    func advance(_ duration: Double) {
        let target = now.addingTimeInterval(duration)
        var iterations = 0
        while let first = pending.min(by: { $0.value.0 < $1.value.0 }), first.value.0 <= target {
            iterations += 1; precondition(iterations < 100, "Unexpected repeating work")
            now = first.value.0; pending[first.key] = nil; first.value.1()
        }
        now = target
    }
}

private actor FixtureNetwork {
    enum Mode { case found, missing, outage, wrongVersion, alias, strictLater }
    var mode: Mode = .found
    var calls: [URLRequest] = []
    func setMode(_ mode: Mode) { self.mode = mode }
    func count() -> Int { calls.count }
    func data(_ request: URLRequest) throws -> Data {
        calls.append(request)
        if mode == .outage { throw URLError(.notConnectedToInternet) }
        let host = request.url!.host!, path = request.url!.path
        precondition(request.url!.scheme == "https")
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
        let value: String
        if host == "lrclib.net" {
            if mode == .missing { value = "[]" }
            else if mode == .wrongVersion {
                value = #"[{"id":1,"trackName":"A Song","artistName":"Artist","duration":500,"syncedLyrics":"[00:00]Wrong version"}]"#
            } else { value = #"[{"id":1,"trackName":"A Song","artistName":"Artist","albumName":"Album","duration":100,"syncedLyrics":"[00:00]Opening\n[00:05]Second\n[00:10]\n[00:15]Ending"}]"# }
        } else if host == "music.163.com" && path == "/api/search/get" {
            value = mode == .missing || mode == .wrongVersion ? #"{"code":200,"result":{"songs":[]}}"#
                : #"{"code":200,"result":{"songs":[{"id":2,"name":"A Song","artists":[{"name":"Artist"}],"album":{"name":"Other"},"duration":100000}]}}"#
        } else if host == "music.163.com" {
            value = #"{"code":200,"lrc":{"lyric":"[00:00]Opening\n[00:05]Second"}}"#
        } else if path.contains("smartbox") {
            value = mode == .missing || mode == .wrongVersion ? #"{"code":0,"data":{"song":{"itemlist":[]}}}"#
                : #"{"code":0,"data":{"song":{"itemlist":[{"id":"3","name":"A Song","singer":"Artist"}]}}}"#
        } else {
            precondition(request.httpMethod == "POST" && String(data: request.httpBody!, encoding: .utf8)!.contains("lrctype=1"))
            value = "<!--<root><lyric><content><![CDATA[[00:00]Opening\n[00:05]Second]]></content></lyric></root>-->"
        }
        var output = value
        if mode == .alias || (mode == .strictLater && host != "lrclib.net") {
            output = output.replacingOccurrences(of: "Artist", with: "Alias")
        }
        return Data(output.utf8)
    }
}

@main @MainActor
struct LyricsBackendSmoke {
    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 { if condition() { return }; await Task.yield() }
        precondition(condition(), "Async result did not settle")
    }
    static func main() async throws {
        if CommandLine.arguments.contains("--live") {
            let repository = LyricsRepository(directory: URL(fileURLWithPath: ".build/lyrics-live-cache"))
            for track in [LyricsTrack(title: "Yellow", artist: "Coldplay", album: "Parachutes", duration: 269),
                          LyricsTrack(title: "晴天", artist: "周杰伦", album: "叶惠美", duration: 269),
                          LyricsTrack(title: "答案", artist: "Yang Kun & Amber Kuo"),
                          LyricsTrack(title: "爱的供养", artist: "Mini Yang")] {
                let result = try await repository.search(track, refresh: true)
                precondition(result?.lyrics?.lines.isEmpty == false || result?.instrumental == true, "Live providers returned no timed lyrics")
                print("Live lyrics source: \(result!.source), timed lines: \(result!.lyrics?.lines.count ?? 0)")
            }
            for (source, host, track) in [
                ("QQ Music", "c.y.qq.com", LyricsTrack(title: "一首暖暖的", artist: "刘人语")),
                ("NetEase", "music.163.com", LyricsTrack(title: "Yellow", artist: "Coldplay"))
            ] {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.timeoutIntervalForRequest = 8
                let session = URLSession(configuration: configuration)
                let isolated = LyricsRepository(directory: URL(fileURLWithPath: ".build/lyrics-live-cache/\(source)"), transport: { request in
                    guard request.url?.host == host else { throw LyricsSearchError.unavailable }
                    let (data, response) = try await session.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw LyricsSearchError.invalidResponse }
                    return data
                })
                let found = try await isolated.search(track, refresh: true)
                precondition(found?.source == source && found?.lyrics?.lines.isEmpty == false, "Individual live source returned no lyrics")
                print("Individual live provider: \(source), timed lines: \(found!.lyrics!.lines.count)")
                session.invalidateAndCancel()
            }
            print("Live lyrics provider checks passed; no user media was read or changed")
            return
        }
        let lrc = TimedLyrics(lrc: "\u{feff}[ti:Example]\r\n[offset:500]\r\n[00:02.50][00:05:000]Hello <00:02.60>world\r\n[00:03.00]\r\n[00:05.00]Translation\r\n[99:99.00]Bad\r\n[00:07.000]End")!
        precondition(lrc.lines.map(\.time) == [2, 2.5, 4.5, 6.5])
        precondition(lrc.lines[0].text == "Hello world" && lrc.lines[1].text.isEmpty)
        precondition(lrc.lines[2].text == "Hello world / Translation")
        precondition(lrc.position(at: 1).index == nil && lrc.position(at: 1).next == 2)
        precondition(lrc.position(at: 2).index == 0 && lrc.position(at: 100).next == nil)
        precondition(TimedLyrics(lrc: "No timestamps") == nil && TimedLyrics(lrc: "[00:00]\n[00:01]") == nil)
        precondition(TimedLyrics(lrc: "[offset:-500]\n[00:01]Later")!.lines[0].time == 1.5)
        precondition(TimedLyrics(lrc: "[00:01]A [chorus]")!.lines[0].text == "A [chorus]")
        precondition(LyricsRepository.qqLyrics(Data("<!--<root><lyric><content><![CDATA[[00:00]A & B]]></content></lyric></root>-->".utf8)) == "[00:00]A & B")
        precondition(LyricsRepository.qqLyrics(Data("<!--<root><cmd><miniversion=\"1\" /><lyric musicid=\"123\"><content><![CDATA[[00:00]A & B]]></content></lyric></cmd></root>-->".utf8)) == "[00:00]A & B")
        let track = LyricsTrack(title: "A Song", artist: "Artist", album: "Album", duration: 100)
        precondition(track.cacheKey == LyricsTrack(title: "a song", artist: "ARTIST", album: "Album", duration: 100).cacheKey)
        precondition(LyricsRepository.matchScore(.init(title: "A Song (Live)", artist: "Artist", duration: 100), for: track) == nil)
        precondition(LyricsRepository.matchScore(.init(title: "A Song", artist: "Cover Artist", duration: 500), for: track) == nil)
        precondition(LyricsRepository.matchScore(.init(title: "A Song", artist: "Cover Artist", duration: 100), for: track) == nil)
        precondition(LyricsRepository.matchScore(.init(title: "答案", artist: "杨坤, 郭采洁"), for: .init(title: "答案", artist: "Yang Kun & Amber Kuo")) != nil)
        precondition(!LyricsTrack(title: "Long", artist: "Artist", duration: .greatestFiniteMagnitude).cacheKey.isEmpty)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TouchBarEnhancer-LyricsTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let network = FixtureNetwork()
        let transport: LyricsRepository.Transport = { try await network.data($0) }
        let preferences = LyricsSearchPreferences(sources: [.lrclib, .netEase, .qqMusic])
        let repository = LyricsRepository(directory: folder, transport: transport, preferences: preferences)
        let result = try await repository.search(track)!
        precondition(result.source == "LRCLIB" && result.lyrics!.lines.count == 4)
        let calls = await network.count()
        precondition(calls == 1)
        let cached = try await repository.search(track)
        precondition(cached == result)
        let disk = LyricsRepository(directory: folder, transport: transport, preferences: preferences)
        let reloaded = try await disk.search(track)
        precondition(reloaded == result)
        let afterCache = await network.count(); precondition(afterCache == calls)
        let cacheFile = folder.appendingPathComponent(track.cacheKey + ".json")
        var corrupt = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheFile)) as! [String: Any]
        corrupt["result"] = ["source": "Fixture", "instrumental": false,
            "lyrics": ["lines": [["time": 5, "text": "Wrong"], ["time": 1, "text": "Order"]]]]
        try JSONSerialization.data(withJSONObject: corrupt).write(to: cacheFile)
        let repaired = try await LyricsRepository(directory: folder, transport: transport, preferences: preferences).search(track)
        precondition(repaired == result, "Reject malformed cached timelines and fetch again")
        await network.setMode(.missing)
        let miss = LyricsTrack(title: "Missing", artist: "Artist")
        let firstMiss = try await repository.search(miss); precondition(firstMiss == nil)
        let afterMiss = await network.count()
        let secondMiss = try await repository.search(miss); precondition(secondMiss == nil)
        let afterSecondMiss = await network.count(); precondition(afterSecondMiss == afterMiss)
        await network.setMode(.outage)
        let failed = LyricsTrack(title: "Offline", artist: "Artist")
        do { _ = try await repository.search(failed); preconditionFailure("Outage is not a successful miss") } catch LyricsSearchError.unavailable { }
        let failedCount = await network.count()
        do { _ = try await repository.search(failed); preconditionFailure() } catch LyricsSearchError.unavailable { }
        let retriedCount = await network.count(); precondition(retriedCount > failedCount, "Outages must not create negative cache entries")
        await network.setMode(.wrongVersion)
        let wrongVersion = try await repository.search(track, refresh: true); precondition(wrongVersion == nil)

        precondition(LyricsSearchPreferences(sources: [.lrclib, .lrclib]).orderedSources == [.lrclib, .qqMusic, .netEase])
        precondition(LyricsRepository.matchScore(.init(title: "爱的供养", artist: "杨幂"), for: .init(title: "爱的供养", artist: "Mini Yang"), fuzzy: true) != nil)
        precondition(LyricsRepository.matchScore(.init(title: "爱的供养 (Live)", artist: "杨幂"), for: .init(title: "爱的供养", artist: "Mini Yang"), fuzzy: true) == nil)
        precondition(LyricsRepository.matchScore(.init(title: "A Song", artist: "Alias", duration: 500), for: track, fuzzy: true) == nil)
        precondition(LyricsRepository.matchScore(.init(title: "Different", artist: "Artist"), for: track, fuzzy: true) == nil)
        await network.setMode(.found)
        repository.configure(.init())
        let priority = try await repository.search(track); precondition(priority?.source == "QQ Music", "Changing order invalidates automatic cache")
        repository.configure(preferences)
        let reordered = try await repository.search(track); precondition(reordered?.source == "LRCLIB")
        await network.setMode(.strictLater)
        repository.configure(.init())
        let strict = try await repository.search(track, refresh: true)
        precondition(strict?.source == "LRCLIB", "Exact match outranks earlier fuzzy alias")
        await network.setMode(.alias)
        let alias = try await repository.search(track, refresh: true); precondition(alias?.source == "QQ Music")
        repository.configure(.init(fuzzyMatching: false))
        let disabled = try await repository.search(track, refresh: true); precondition(disabled == nil)
        repository.configure(.init())
        let candidates = try await repository.searchCandidates(title: track.title, artist: track.artist)
        precondition(candidates.count == 3 && Set(candidates.map(\.identity)).count == 3)
        let chosen = try await repository.lyrics(for: candidates[1])
        precondition(chosen.source == "NetEase")
        var selectionChanges = 0; repository.onSelectionChange = { _ in selectionChanges += 1 }
        try repository.select(chosen, for: track)
        await network.setMode(.outage)
        let offline = LyricsRepository(directory: folder, transport: transport)
        var partialTrack = track; partialTrack.duration = nil
        let savedChoice = try await offline.search(partialTrack, refresh: true)
        precondition(savedChoice == chosen && selectionChanges == 1, "Manual choice survives relaunch, outage and missing duration")
        repository.configure(preferences)
        let stillChosen = try await repository.search(track); precondition(stillChosen == chosen)
        let another = LyricsTrack(title: "Another", artist: "Artist")
        try repository.select(result, for: another)
        try repository.removeSelection(for: track)
        precondition(repository.selection(for: track) == nil && repository.selection(for: another) == result && selectionChanges == 3)
        await network.setMode(.found)
        let restoredAutomatic = try await repository.search(track)
        precondition(restoredAutomatic?.source == "LRCLIB")

        let clock = FixtureClock()
        var events: (@MainActor (Bool?) -> Void)?
        var reads: [@MainActor (LyricsPlayback?) -> Void] = []
        var readCount = 0, subscriptions = 0, cancellations = 0, searches = 0
        let controller = LyricsController(search: { _ in searches += 1; return result }, read: { readCount += 1; reads.append($0) },
            observe: { events = $0; subscriptions += 1; return { events = nil; cancellations += 1 } },
            now: { clock.now }, schedule: { clock.schedule($0, $1) })
        controller.setEnabled(true)
        precondition(readCount == 1 && subscriptions == 1)
        reads.removeFirst()(.init(track: track, elapsed: 0, date: clock.now, rate: 1, playing: true))
        await settle { controller.display.text == "Opening" }
        precondition(searches == 1 && clock.pending.count == 1)
        clock.advance(5); precondition(controller.display.text == "Second" && readCount == 1)
        events?(false)
        precondition(clock.pending.count == 1) // Read timeout only; no lyric boundary while paused.
        reads.removeFirst()(.init(track: track, elapsed: 5, date: clock.now, rate: 0, playing: false))
        precondition(clock.pending.isEmpty)
        clock.advance(20); precondition(controller.display.text == "Second" && readCount == 2)
        events?(nil)
        reads.removeFirst()(.init(track: track, elapsed: 0, date: clock.now, rate: 2, playing: true))
        precondition(controller.display.text == "Opening" && searches == 1)
        clock.advance(2.5); precondition(controller.display.text == "Second")
        clock.advance(2.5); precondition(controller.display.text == "♪")
        clock.advance(2.5); precondition(controller.display.text == "Ending" && clock.pending.isEmpty)
        events?(nil); let stale = reads.removeFirst(), oldEvent = events
        controller.setEnabled(false)
        stale(.init(track: track, elapsed: 0, date: clock.now, rate: 1, playing: true)); oldEvent?(true)
        precondition(!controller.enabled && clock.pending.isEmpty && controller.display == .init() && cancellations == 1 && readCount == 4)
        controller.setEnabled(true); precondition(subscriptions == 2)
        clock.advance(3); precondition(clock.pending.isEmpty && controller.display == .init())
        reads.removeFirst()(.init(track: track, elapsed: 0, date: clock.now, rate: 1, playing: true))
        precondition(controller.display == .init(), "Timed-out callback must be ignored")
        controller.setEnabled(false)

        // Deliberately uncancellable searches arriving out of order.
        var searchesByTitle: [String: CheckedContinuation<LyricsSearchResult?, any Error>] = [:]
        var nextState = LyricsPlayback(track: track, elapsed: 0, date: clock.now, rate: 1, playing: true)
        let races = LyricsController(search: { track in try await withCheckedThrowingContinuation { searchesByTitle[track.title] = $0 } },
            read: { $0(nextState) }, observe: { events = $0; return { events = nil } }, now: { clock.now }, schedule: { clock.schedule($0, $1) })
        races.setEnabled(true); await settle { searchesByTitle["A Song"] != nil }
        nextState.track.title = "New Song"; events?(nil)
        await settle { searchesByTitle["New Song"] != nil }
        searchesByTitle.removeValue(forKey: "New Song")!.resume(returning: result)
        await settle { races.display.text == "Opening" }
        searchesByTitle.removeValue(forKey: "A Song")!.resume(returning: nil)
        for _ in 0..<10 { await Task.yield() }
        precondition(races.display.text == "Opening" && races.display.detail.contains("New Song"))
        races.setEnabled(false)

        // Incomplete resume/artwork snapshots must not clear a known song's
        // position, re-search it, or undo the notification's immediate pause.
        var partialState = LyricsPlayback(track: track, elapsed: 0, date: clock.now, rate: 1, playing: true)
        var partialSearches = 0
        let partial = LyricsController(search: { _ in partialSearches += 1; return result },
            read: { $0(partialState) }, observe: { events = $0; return { events = nil } },
            now: { clock.now }, schedule: { clock.schedule($0, $1) })
        partial.setEnabled(true); await settle { partial.display.text == "Opening" }
        clock.advance(5); precondition(partial.display.text == "Second")
        partialState.track.album = ""; partialState.track.duration = nil; partialState.elapsed = nil
        events?(false) // Deliberately stale read still says playing.
        precondition(clock.pending.isEmpty && partial.display.text == "Second")
        clock.advance(20); precondition(partial.display.text == "Second" && partialSearches == 1)
        partialState.playing = false; partialState.rate = 0
        events?(true)
        clock.advance(5); precondition(partial.display.text == "♪" && partialSearches == 1)
        partial.setEnabled(false)
        checkSeeking()
        checkDelayedSeekMetadata()
        checkMissingPositionAfterSeek()
        print("Lyrics backend checks passed: timestamp parsing/offsets/gaps, provider ranking and mismatch rejection, isolated disk/negative cache, HTTPS, outage retry, pause/seek/rate, next-line deadlines without media polling, read timeouts, stale callbacks and out-of-order cancellation")
    }

    static func checkSeeking() {
        let clock = FixtureClock()
        var reads: [@MainActor (LyricsPlayback?) -> Void] = []
        var event: (@MainActor (Bool?) -> Void)?
        var requests: [Double] = [], errors: [String] = []
        var available = true
        var state = LyricsPlayback(track: .init(title: "Song", artist: "Artist", duration: 100),
            elapsed: 10, date: clock.now, rate: 1, playing: true, source: "test.player")
        let controller = LyricsController(search: { _ in nil }, read: { reads.append($0) },
            observe: { event = $0; return { event = nil } }, now: { clock.now },
            schedule: { clock.schedule($0, $1) }, setElapsed: { requests.append($0); return available })
        controller.onSeekError = { errors.append($0) }
        controller.setEnabled(true); reads.removeFirst()(state)
        controller.seek(by: 5)
        clock.advance(1); reads.removeFirst()(state)
        precondition(requests == [16] && errors.isEmpty)
        state.playing = false; state.rate = 0; state.elapsed = 2
        event?(false); reads.removeFirst()(state)
        controller.seek(by: -5); reads.removeFirst()(state)
        precondition(requests.last == 0 && !state.playing, "Rewind clamps at zero without resuming")
        state.elapsed = 99
        controller.seek(by: 5); reads.removeFirst()(state)
        precondition(requests.last == 100)
        state.elapsed = 20
        controller.seek(by: 5); controller.seek(by: 5)
        precondition(reads.count == 1, "Pending swipes accumulate with one read")
        reads.removeFirst()(state); precondition(requests.last == 30)
        controller.seek(by: 5); controller.seek(by: -5)
        let count = requests.count
        reads.removeFirst()(state); precondition(requests.count == count)
        available = false
        controller.seek(by: 5); reads.removeFirst()(state)
        precondition(errors.last == "System media seeking is unavailable.")
        available = true
        let beforePartialRead = requests.count
        state.elapsed = nil
        controller.seek(by: 5); reads.removeFirst()(state)
        precondition(requests.count == beforePartialRead + 1 && requests.last == 35,
            "A partial read must reuse the same media's last accepted target")
        let unavailableCount = requests.count
        state.elapsed = 20
        controller.seek(by: 5)
        var other = state; other.source = "different.player"
        reads.removeFirst()(other)
        precondition(requests.count == unavailableCount && errors.last!.contains("media changed"))
        controller.seek(by: 5)
        let stale = reads.removeFirst()
        event?(nil); other.track.title = "Other Song"; reads.removeFirst()(other)
        stale(state); precondition(requests.count == unavailableCount)
        controller.seek(by: 5)
        let timedOut = reads.removeFirst()
        clock.advance(3); timedOut(other)
        precondition(requests.count == unavailableCount && errors.last!.contains("timed out"))
        controller.seek(by: 5); let hidden = reads.removeFirst()
        controller.setEnabled(false); hidden(other)
        precondition(requests.count == unavailableCount && clock.pending.isEmpty)
        controller.seek(by: .nan); controller.seek(by: .infinity); controller.seek(by: 0)
        precondition(reads.isEmpty)
        print("Lyrics seek checks passed: fresh/extrapolated position, pause, bounds, accumulated swipes, missing transport/position, source/track changes, timeout and hidden/stale cancellation; mock transport only")
    }

    static func checkDelayedSeekMetadata() {
        let clock = FixtureClock()
        var reads: [@MainActor (LyricsPlayback?) -> Void] = []
        var event: (@MainActor (Bool?) -> Void)?
        var requests: [Double] = []
        var available = true
        var state = LyricsPlayback(track: .init(title: "Song", artist: "Artist", duration: 100),
            elapsed: 10, date: clock.now, rate: 0, playing: false, source: "test.player")
        let controller = LyricsController(search: { _ in nil }, read: { reads.append($0) },
            observe: { event = $0; return { event = nil } }, now: { clock.now },
            schedule: { clock.schedule($0, $1) }, setElapsed: { requests.append($0); return available })
        controller.setEnabled(true); reads.removeFirst()(state)
        func swipe(_ offset: Double) { controller.seek(by: offset); reads.removeFirst()(state) }
        swipe(5); swipe(5); swipe(-5)
        precondition(requests == [15, 20, 15], "Repeated swipes must accumulate while MediaRemote repeats the pre-seek snapshot")
        event?(nil); reads.removeFirst()(state)
        swipe(-5)
        precondition(requests.last == 10, "A delayed metadata notification must not undo the pending target")
        available = false; swipe(5)
        available = true; swipe(5)
        precondition(requests.last == 15, "Rejected dispatches must not advance the pending target")
        state.elapsed = 60; state.date = clock.now.addingTimeInterval(0.1)
        swipe(5)
        precondition(requests.last == 65, "An external seek supersedes our pending target")
        state.elapsed = 65; state.date = clock.now.addingTimeInterval(0.2)
        event?(nil); reads.removeFirst()(state)
        swipe(5); precondition(requests.last == 70, "Acknowledged positions become authoritative")
        clock.advance(3)
        precondition(reads.count == 1, "One bounded reconciliation read after the last seek, without polling")
        reads.removeFirst()(state)
        swipe(5); precondition(requests.last == 70, "Expired targets must not override actual player position")
        var other = state; other.track.title = "Other Song"
        event?(nil); reads.removeFirst()(other)
        state = other; swipe(5)
        precondition(requests.last == 70, "A track change clears the previous song's pending target")
        controller.setEnabled(false)
        precondition(clock.pending.isEmpty)
        state.elapsed = 10; state.date = clock.now; state.playing = true; state.rate = 1
        controller.setEnabled(true); reads.removeFirst()(state)
        swipe(5); clock.advance(1); swipe(5)
        precondition(requests.last == 21, "Playing swipes include elapsed wall time and the preceding seek")
        event?(false); reads.removeFirst()(state)
        clock.advance(1); swipe(-5)
        precondition(requests.last == 16, "Pause notification freezes the pending anchor without resuming")
        controller.setEnabled(false)
        precondition(clock.pending.isEmpty)
        print("Lyrics delayed seek checks passed: repeated/opposite swipes, stale notifications, rejected dispatch, external seek, acknowledgement, bounded reconciliation and track change; mock transport only")
    }

    static func checkMissingPositionAfterSeek() {
        let clock = FixtureClock()
        var state = LyricsPlayback(track: .init(title: "Song", artist: "Artist", duration: 30),
            elapsed: nil, date: clock.now, rate: 1, playing: true, source: "test.player")
        var event: (@MainActor (Bool?) -> Void)?
        var requests: [Double] = [], errors: [String] = []
        var available = true
        let controller = LyricsController(search: { _ in nil }, read: { $0(state) },
            observe: { event = $0; return { event = nil } }, now: { clock.now },
            schedule: { clock.schedule($0, $1) }, setElapsed: { target in
                guard available else { return false }
                requests.append(target)
                // Observed on hardware: same song/source remains, but position
                // is absent in subsequent MediaRemote reads after the first seek.
                state.elapsed = nil; state.track.duration = nil
                return true
            })
        controller.onSeekError = { errors.append($0) }
        controller.setEnabled(true)
        controller.seek(by: 5)
        precondition(requests.isEmpty && errors == ["Playback position is unavailable."],
            "Never invent a position before the player has supplied a valid timeline")
        errors.removeAll()
        state.elapsed = 10; event?(nil)
        controller.seek(by: 5)
        clock.advance(0.5); event?(nil)
        controller.seek(by: 5)
        clock.advance(0.5); state.elapsed = -1
        controller.seek(by: 5)
        clock.advance(0.5); state.elapsed = .nan
        controller.seek(by: -5)
        precondition(requests == [15, 20.5, 26, 21.5] && errors.isEmpty,
            "Missing/invalid position after a seek must reuse the same media's known timeline for every swipe")
        available = false; controller.seek(by: 5)
        precondition(errors.last == "System media seeking is unavailable.")
        available = true; controller.seek(by: 5)
        precondition(requests.last == 26.5, "Rejected seeks must not advance the cached position")
        controller.seek(by: 5)
        precondition(requests.last == 30, "Missing duration must retain the same track's known bound")
        state.playing = false; state.rate = 0; event?(false)
        clock.advance(4) // Includes the one reconciliation read; still no position.
        controller.seek(by: -5)
        precondition(requests.last == 25, "A paused timeline survives a partial reconciliation without resuming")
        var count = requests.count
        state.source = "other.player"; event?(nil)
        controller.seek(by: 5)
        precondition(requests.count == count && errors.last == "Playback position is unavailable.",
            "Never borrow a missing position from another source")
        state.elapsed = 5; state.track.duration = 30; event?(nil)
        controller.seek(by: 5); precondition(requests.last == 10)
        count = requests.count
        state.track.title = "Another Song"; event?(nil)
        controller.seek(by: 5)
        precondition(requests.count == count, "Never borrow a missing position from another song")
        controller.setEnabled(false)
        precondition(clock.pending.isEmpty)
        print("Lyrics missing-position regression passed: repeated real-world partial snapshots, invalid position, elapsed wall time, pause, rejection, duration clamp, reconciliation, source/song isolation; mock transport only")
    }
}
