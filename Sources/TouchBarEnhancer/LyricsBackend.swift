import Foundation
import CryptoKit
import os

// Inspired by LyricsX's provider → timed-document → current-line pipeline.
// Independent implementation; no LyricsX UI, player polling or LyricsKit dependency.
struct LyricsTrack: Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var album: String = ""
    var duration: Double?

    static func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    var cacheKey: String {
        let content = [Self.normalized(title), Self.normalized(artist), Self.normalized(album),
            duration.flatMap { $0.isFinite && $0 > 0 && $0 <= 86_400 ? String(Int($0.rounded())) : nil } ?? ""].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct TimedLyrics: Codable, Equatable, Sendable {
    struct Line: Codable, Equatable, Sendable { var time: Double; var text: String }
    var lines: [Line]

    init?(lrc: String) {
        guard lrc.utf8.count <= 1_000_000 else { return nil }
        let tags = try! NSRegularExpression(pattern: #"\[([^\]]+)\]"#)
        let inline = try! NSRegularExpression(pattern: #"<\d+:\d+(?:[.:]\d+)?>"#)
        var parsed: [(Double, String, Int)] = []
        var offset: Double = 0
        for row in lrc.replacingOccurrences(of: "\u{feff}", with: "").components(separatedBy: .newlines).prefix(20_000) {
            let range = NSRange(row.startIndex..., in: row)
            let matches = tags.matches(in: row, range: range)
            var times: [Double] = []
            var textStart = row.startIndex
            for match in matches {
                guard let tagRange = Range(match.range(at: 1), in: row), let fullRange = Range(match.range, in: row) else { continue }
                // Only leading tags are timestamps; bracketed text belongs to the lyric.
                guard row[textStart..<fullRange.lowerBound].trimmingCharacters(in: .whitespaces).isEmpty else { break }
                let tag = String(row[tagRange])
                if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7)), ms.isFinite, abs(ms) <= 600_000 {
                    offset = ms / 1000
                } else if let time = Self.timestamp(tag) { times.append(time) }
                else if !times.isEmpty { break }
                textStart = fullRange.upperBound
            }
            guard !times.isEmpty else { continue }
            let raw = String(row[textStart...])
            let text = inline.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            for time in times { parsed.append((time, String(text.prefix(2_000)), parsed.count)) }
            guard parsed.count <= 10_000 else { return nil }
        }
        guard parsed.contains(where: { !$0.1.isEmpty }) else { return nil }
        parsed.sort { $0.0 == $1.0 ? $0.2 < $1.2 : $0.0 < $1.0 }
        var result: [Line] = []
        for (time, text, _) in parsed {
            let adjusted = max(0, time - offset)
            if result.last?.time == adjusted {
                if !text.isEmpty, result.last?.text != text {
                    let previous = result.removeLast()
                    result.append(.init(time: adjusted, text: previous.text.isEmpty ? text : previous.text + " / " + text))
                }
            } else { result.append(.init(time: adjusted, text: text)) }
        }
        lines = result
    }

    private static func timestamp(_ value: String) -> Double? {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let minutes = Double(parts[0]), minutes.isFinite, minutes >= 0,
              let seconds = Double(parts[1]), seconds.isFinite, seconds >= 0, seconds < 60 else { return nil }
        var result = minutes * 60 + seconds
        if parts.count == 3 {
            // NetEase's legacy [mm:ss:fff] timestamps.
            guard !parts[1].contains("."), parts[2].allSatisfy(\.isNumber),
                  let fraction = Double("0." + parts[2]) else { return nil }
            result += fraction
        }
        return result.isFinite && result <= 86_400 ? result : nil
    }

    func position(at time: Double) -> (index: Int?, next: Double?) {
        guard time.isFinite else { return (nil, nil) }
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        return (low == 0 ? nil : low - 1, low < lines.count ? lines[low].time : nil)
    }
}

struct LyricsSearchResult: Codable, Equatable, Sendable {
    var lyrics: TimedLyrics?
    var source: String
    var instrumental = false
}

enum LyricsSearchError: Error { case unavailable, invalidResponse }

enum LyricsSource: String, Codable, CaseIterable, Sendable {
    case qqMusic = "QQ Music", netEase = "NetEase", lrclib = "LRCLIB"
}

struct LyricsSearchPreferences: Codable, Equatable, Sendable {
    var sources: [LyricsSource] = LyricsSource.allCases
    var fuzzyMatching = true
    var orderedSources: [LyricsSource] {
        var seen = Set<LyricsSource>()
        return (sources + LyricsSource.allCases).filter { seen.insert($0).inserted }
    }
}

/// Searches only public metadata. Session cookies/accounts/artwork are never used.
@MainActor
final class LyricsRepository {
    typealias Transport = @Sendable (URLRequest) async throws -> Data
    private struct CacheEntry: Codable {
        var track: LyricsTrack; var saved: Date; var result: LyricsSearchResult?
        var preferences: LyricsSearchPreferences?
    }
    struct Candidate: Sendable, Equatable {
        var track: LyricsTrack
        var id: String
        var lrc: String? = nil
        var instrumental = false
        var source = ""
        var identity: String { source + ":" + id }
    }
    private let directory: URL?
    private let transport: Transport
    private var memory: [String: CacheEntry] = [:]
    private(set) var preferences: LyricsSearchPreferences
    private var revision = UUID()
    var onSelectionChange: ((LyricsTrack) -> Void)?

    init(directory: URL? = nil, transport: Transport? = nil, preferences: LyricsSearchPreferences = .init()) {
        self.preferences = preferences
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("local.starfruit.TouchBarEnhancer/Lyrics-v1", isDirectory: true)
        if let transport { self.transport = transport }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 12
            config.httpCookieStorage = nil; config.urlCache = nil
            let session = URLSession(configuration: config)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), data.count <= 2_000_000 else {
                    throw LyricsSearchError.invalidResponse
                }
                return data
            }
        }
    }

    func search(_ track: LyricsTrack, refresh: Bool = false) async throws -> LyricsSearchResult? {
        try Task.checkCancellation()
        if let selected = selection(for: track) { return selected }
        if !refresh, let entry = cached(track) { return entry.result }
        let configuration = preferences, token = revision
        var discovered: [String: [Candidate]] = [:], failed = false
        // Prefer a strict match from any source before considering fuzzy ones.
        // Within each pass, the user's source priority is authoritative.
        for fuzzy in configuration.fuzzyMatching ? [false, true] : [false] {
            for source in configuration.orderedSources.map(\.rawValue) {
                try Task.checkCancellation()
                do {
                    let values: [Candidate]
                    if let known = discovered[source] { values = known }
                    else {
                        var found = try await candidates(source, track: track, titleOnly: track.artist.isEmpty)
                        if !track.artist.isEmpty && !found.contains(where: { Self.matchScore($0.track, for: track) != nil }) {
                            let broad = try await candidates(source, track: track, titleOnly: true)
                            var seen = Set(found.map(\.id))
                            found += broad.filter { seen.insert($0.id).inserted }
                        }
                        discovered[source] = found; values = found
                    }
                    if let result = try await matchingLyrics(values, source: source, track: track, fuzzy: fuzzy) {
                        try Task.checkCancellation()
                        if let chosen = selection(for: track) { return chosen }
                        if revision == token { save(.init(track: track, saved: Date(), result: result, preferences: configuration)) }
                        return result
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation(); failed = true; discovered[source] = [] }
            }
        }
        try Task.checkCancellation()
        if let chosen = selection(for: track) { return chosen }
        if failed { throw LyricsSearchError.unavailable }
        if revision == token { save(.init(track: track, saved: Date(), result: nil, preferences: configuration)) }
        return nil
    }

    @discardableResult func configure(_ value: LyricsSearchPreferences) -> Bool {
        guard preferences != value else { return false }
        preferences = value; revision = UUID(); return true
    }

    func searchCandidates(title: String, artist: String) async throws -> [Candidate] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return [] }
        let query = LyricsTrack(title: String(title.prefix(300)), artist: String(artist.prefix(300)))
        var results: [Candidate] = [], failures = 0
        for source in preferences.orderedSources.map(\.rawValue) {
            try Task.checkCancellation()
            do {
                var found = try await candidates(source, track: query, titleOnly: artist.isEmpty)
                if found.isEmpty && !artist.isEmpty { found = try await candidates(source, track: query, titleOnly: true) }
                found.sort { (Self.matchScore($0.track, for: query, fuzzy: true) ?? 0) > (Self.matchScore($1.track, for: query, fuzzy: true) ?? 0) }
                results += found.prefix(30).map { var item = $0; item.source = source; return item }
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); failures += 1 }
        }
        if results.isEmpty && failures > 0 { throw LyricsSearchError.unavailable }
        return results
    }

    func lyrics(for candidate: Candidate) async throws -> LyricsSearchResult {
        guard LyricsSource(rawValue: candidate.source) != nil,
              let result = try await fetch(candidate, source: candidate.source) else { throw LyricsSearchError.invalidResponse }
        return result
    }

    private func selectionKey(_ track: LyricsTrack) -> String {
        var identity = track; identity.duration = nil; return identity.cacheKey
    }
    func selection(for track: LyricsTrack) -> LyricsSearchResult? {
        guard let directory else { return nil }
        let file = directory.appendingPathComponent("Selections").appendingPathComponent(selectionKey(track) + ".json")
        guard let entry = load(file), selectionKey(entry.track) == selectionKey(track),
              let result = entry.result, Self.valid(result) else { return nil }
        return result
    }
    func select(_ result: LyricsSearchResult, for track: LyricsTrack) throws {
        guard Self.valid(result), let directory else { throw LyricsSearchError.invalidResponse }
        let folder = directory.appendingPathComponent("Selections", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(CacheEntry(track: track, saved: Date(), result: result))
            .write(to: folder.appendingPathComponent(selectionKey(track) + ".json"), options: .atomic)
        revision = UUID(); onSelectionChange?(track)
    }
    func removeSelection(for track: LyricsTrack) throws {
        guard let directory else { return }
        let file = directory.appendingPathComponent("Selections").appendingPathComponent(selectionKey(track) + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        memory[track.cacheKey] = nil
        let automatic = directory.appendingPathComponent(track.cacheKey + ".json")
        if FileManager.default.fileExists(atPath: automatic.path) { try FileManager.default.removeItem(at: automatic) }
        revision = UUID(); onSelectionChange?(track)
    }

    static func matchScore(_ candidate: LyricsTrack, for track: LyricsTrack, fuzzy: Bool = false) -> Double? {
        let title = LyricsTrack.normalized(track.title), otherTitle = LyricsTrack.normalized(candidate.title)
        let artist = LyricsTrack.normalized(track.artist), otherArtist = LyricsTrack.normalized(candidate.artist)
        let separators = try! NSRegularExpression(pattern: #"\s+(?:feat\.?|ft\.?)\s+|\s*&\s*|[,、;/]"#, options: .caseInsensitive)
        func performers(_ value: String) -> Set<String> {
            let separated = separators.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "\n")
            return Set(separated.components(separatedBy: "\n").flatMap { name in
                [LyricsTrack.normalized(name), LyricsTrack.normalized(name.applyingTransform(.toLatin, reverse: false) ?? name)]
            }.filter { !$0.isEmpty })
        }
        guard !title.isEmpty, !artist.isEmpty, !otherTitle.isEmpty, !otherArtist.isEmpty else { return nil }
        let artistMatches = artist == otherArtist || !performers(track.artist).isDisjoint(with: performers(candidate.artist))
        var score: Double
        if title == otherTitle && artistMatches { score = artist == otherArtist ? 100 : 85 }
        else {
            guard fuzzy, Self.versions(track.title) == Self.versions(candidate.title) else { return nil }
            if title == otherTitle { score = 55 }
            else {
                let left = Self.baseTitle(track.title), right = Self.baseTitle(candidate.title)
                guard left == right || Self.similar(left, right) else { return nil }
                score = artistMatches ? 75 : 40
            }
        }
        if let duration = track.duration, let other = candidate.duration, duration.isFinite, other.isFinite, duration > 0, other > 0 {
            let difference = abs(duration - other)
            guard difference <= max(8, duration * 0.04) else { return nil }
            score += max(0, 20 - difference)
        }
        if !track.album.isEmpty, LyricsTrack.normalized(track.album) == LyricsTrack.normalized(candidate.album) { score += 10 }
        return score
    }

    private static func versions(_ title: String) -> Set<String> {
        let expression = try! NSRegularExpression(pattern: #"\b(live|remix|instrumental|karaoke|acoustic|cover)\b|伴奏|翻唱|现场|現場|不插电"#, options: .caseInsensitive)
        return Set(expression.matches(in: title, range: NSRange(title.startIndex..., in: title)).compactMap {
            Range($0.range, in: title).map { String(title[$0]).lowercased() }
        })
    }
    private static func baseTitle(_ title: String) -> String {
        let expression = try! NSRegularExpression(pattern: #"\([^)]*\)|（[^）]*）|\[[^\]]*\]|\s+(?:feat\.?|ft\.?)\s+.*$"#, options: .caseInsensitive)
        return LyricsTrack.normalized(expression.stringByReplacingMatches(in: title, range: NSRange(title.startIndex..., in: title), withTemplate: ""))
    }
    private static func similar(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard min(a.count, b.count) >= 5, max(a.count, b.count) <= 200 else { return false }
        let limit = max(1, Int(Double(max(a.count, b.count)) * 0.12))
        guard abs(a.count - b.count) <= limit else { return false }
        var row = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var next = [i + 1]
            for (j, other) in b.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (character == other ? 0 : 1))) }
            row = next
        }
        return row[b.count] <= limit
    }

    private func request(_ host: String, _ path: String, _ query: [String: String], body: String? = nil) -> URLRequest {
        var url = URLComponents(); url.scheme = "https"; url.host = host; url.path = path
        url.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!, timeoutInterval: 8)
        request.setValue("TouchBarEnhancer (lyrics component)", forHTTPHeaderField: "User-Agent")
        request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        if let body {
            request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let data = try await transport(request); try Task.checkCancellation()
        guard data.count <= 2_000_000, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LyricsSearchError.invalidResponse
        }
        return value
    }
    private func candidates(_ source: String, track: LyricsTrack, titleOnly: Bool) async throws -> [Candidate] {
        let query = titleOnly ? track.title : track.title + " " + track.artist
        switch source {
        case "NetEase":
            let root = try await json(request("music.163.com", "/api/search/get", ["s": query, "type": "1", "limit": "10"]))
            guard (root["code"] as? Int) == 200, let result = root["result"] as? [String: Any] else { throw LyricsSearchError.invalidResponse }
            return (result["songs"] as? [[String: Any]] ?? []).compactMap { value in
                guard let id = value["id"] as? Int, let title = value["name"] as? String else { return nil }
                let artists = (value["artists"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
                return Candidate(track: .init(title: title, artist: artists, album: (value["album"] as? [String: Any])?["name"] as? String ?? "",
                    duration: (value["duration"] as? Double).map { $0 / 1000 }), id: String(id))
            }
        case "QQ Music":
            let root = try await json(request("c.y.qq.com", "/splcloud/fcgi-bin/smartbox_new.fcg", ["key": query, "format": "json"]))
            guard root["code"] as? Int == 0, let data = root["data"] as? [String: Any], let songs = data["song"] as? [String: Any] else { throw LyricsSearchError.invalidResponse }
            return (songs["itemlist"] as? [[String: Any]] ?? []).compactMap { value in
                guard let id = value["id"] as? String, id.allSatisfy(\.isNumber), !id.isEmpty,
                      let title = value["name"] as? String, let artist = value["singer"] as? String else { return nil }
                return Candidate(track: .init(title: title, artist: artist), id: id)
            }
        default:
            var parameters = ["track_name": track.title]
            if !titleOnly { parameters["artist_name"] = track.artist }
            let data = try await transport(request("lrclib.net", "/api/search", parameters))
            try Task.checkCancellation()
            guard data.count <= 2_000_000, let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw LyricsSearchError.invalidResponse }
            return rows.prefix(100).compactMap { value in
                guard let id = value["id"] as? Int, let title = value["trackName"] as? String, let artist = value["artistName"] as? String else { return nil }
                return Candidate(track: .init(title: title, artist: artist, album: value["albumName"] as? String ?? "", duration: value["duration"] as? Double),
                    id: String(id), lrc: value["syncedLyrics"] as? String, instrumental: value["instrumental"] as? Bool ?? false)
            }
        }
    }
    private func matchingLyrics(_ values: [Candidate], source: String, track: LyricsTrack, fuzzy: Bool) async throws -> LyricsSearchResult? {
        func rank(_ values: [Candidate]) -> [(Candidate, Double)] {
            values.compactMap { candidate in Self.matchScore(candidate.track, for: track, fuzzy: fuzzy).map { (candidate, $0) } }
                .sorted { $0.1 > $1.1 }
        }
        for (candidate, _) in rank(values).prefix(2) {
            try Task.checkCancellation()
            if let result = try await fetch(candidate, source: source) { return result }
        }
        return nil
    }

    private func fetch(_ candidate: Candidate, source: String) async throws -> LyricsSearchResult? {
        try Task.checkCancellation()
        var lrc = candidate.lrc
        if candidate.instrumental { return .init(lyrics: nil, source: source, instrumental: true) }
        if source == "NetEase" {
            let value = try await json(request("music.163.com", "/api/song/lyric", ["id": candidate.id, "lv": "-1", "kv": "-1", "tv": "-1"]))
            guard value["code"] as? Int == 200 else { throw LyricsSearchError.invalidResponse }
            lrc = (value["lrc"] as? [String: Any])?["lyric"] as? String
        } else if source == "QQ Music" {
            let data = try await transport(request("c.y.qq.com", "/qqmusic/fcgi-bin/lyric_download.fcg", [:],
                body: "musicid=\(candidate.id)&version=15&miniversion=82&lrctype=1"))
            try Task.checkCancellation()
            // Plain LRC response; no QRC decryption or credentials needed.
            lrc = Self.qqLyrics(data)
        }
        if let lrc, let parsed = TimedLyrics(lrc: lrc) {
            return .init(lyrics: parsed, source: source)
        }
        return nil
    }

    static func qqLyrics(_ data: Data) -> String? {
        guard data.count <= 1_000_000, let raw = String(data: data, encoding: .utf8) else { return nil }
        // QQ's legacy envelope can contain malformed tags such as
        // <miniversion="1" />. Parse only its well-formed lyric subtree.
        guard let start = raw.range(of: #"<lyric(?:\s|>)"#, options: .regularExpression),
              let end = raw.range(of: "</lyric>", range: start.upperBound..<raw.endIndex) else { return nil }
        let xml = String(raw[start.lowerBound..<end.upperBound])
        guard let document = try? XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]),
              let content = try? document.nodes(forXPath: "//lyric/content").first?.stringValue else { return nil }
        return content
    }

    private func cached(_ track: LyricsTrack) -> CacheEntry? {
        let key = track.cacheKey
        let file = directory?.appendingPathComponent(key + ".json")
        let entry = memory[key] ?? file.flatMap { load($0) }
        guard let entry, entry.track.cacheKey == key,
              entry.preferences == preferences,
              Date().timeIntervalSince(entry.saved) >= 0,
              Date().timeIntervalSince(entry.saved) < (entry.result == nil ? 3600 : 30 * 86_400),
              entry.result.map({ Self.valid($0) }) ?? true else { return nil }
        memory[key] = entry; return entry
    }
    private func load(_ file: URL) -> CacheEntry? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 3_000_000,
              let data = try? Data(contentsOf: file), data.count <= 3_000_000 else { return nil }
        return try? JSONDecoder().decode(CacheEntry.self, from: data)
    }
    private static func valid(_ result: LyricsSearchResult) -> Bool {
        result.instrumental || result.lyrics.map { lyrics in
            !lyrics.lines.isEmpty && lyrics.lines.count <= 10_000
                && lyrics.lines.allSatisfy { $0.time.isFinite && (0...86_400).contains($0.time) && $0.text.count <= 10_000 }
                && zip(lyrics.lines, lyrics.lines.dropFirst()).allSatisfy { $0.time < $1.time }
        } == true
    }
    private func save(_ entry: CacheEntry) {
        if memory.count >= 200 { memory.removeAll(keepingCapacity: true) }
        memory[entry.track.cacheKey] = entry
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent(entry.track.cacheKey + ".json"), options: .atomic)
            do {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                    .filter { $0.pathExtension == "json" && $0.deletingPathExtension().lastPathComponent.count == 64
                        && $0.deletingPathExtension().lastPathComponent.allSatisfy { $0.isHexDigit } }
                    .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                        > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
                for file in files.dropFirst(200) { try? FileManager.default.removeItem(at: file) }
            }
        } catch { /* Cache failure must not hide successfully downloaded lyrics. */ }
    }
}

struct LyricsPlayback: Equatable, Sendable {
    var track: LyricsTrack
    var elapsed: Double?
    var date: Date
    var rate: Double
    var playing: Bool
    var source: String = ""

    func position(at now: Date) -> Double? {
        guard let elapsed, elapsed.isFinite, elapsed >= 0 else { return nil }
        let advance = playing && rate.isFinite && rate > 0 ? max(0, now.timeIntervalSince(date)) * rate : 0
        let value = elapsed + advance
        return track.duration.flatMap { $0.isFinite && $0 > 0 ? min(value, $0) : nil } ?? value
    }
}

extension LyricsPlayback {
    init?(nowPlaying values: [String: Any]?) {
        guard let values, let title = values["title"] as? String, let artist = values["artist"] as? String else { return nil }
        let playing = (values["playing"] as? NSNumber)?.boolValue ?? false
        self.init(track: .init(title: title, artist: artist, album: values["album"] as? String ?? "",
            duration: (values["duration"] as? NSNumber)?.doubleValue), elapsed: (values["elapsed"] as? NSNumber)?.doubleValue,
            date: values["timestamp"] as? Date ?? Date(), rate: (values["rate"] as? NSNumber)?.doubleValue ?? (playing ? 1 : 0),
            playing: playing, source: values["source"] as? String ?? "")
        if playing && (!rate.isFinite || rate <= 0) { rate = 1 }
    }
}

struct LyricsDisplay: Equatable {
    var text = "No media playing"
    var detail = "Play a song in an app that supports system Now Playing."
}

/// Observe once while visible; schedule only the next local lyric boundary.
@MainActor
final class LyricsController {
    typealias Cancel = () -> Void
    var onChange: ((LyricsDisplay) -> Void)?
    var onSeekError: ((String) -> Void)?
    private(set) var display = LyricsDisplay()
    private(set) var enabled = false
    private let search: (LyricsTrack) async throws -> LyricsSearchResult?
    private let read: (@escaping @MainActor (LyricsPlayback?) -> Void) -> Void
    private let observe: (@escaping @MainActor (Bool?) -> Void) -> Cancel?
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Cancel
    private let setElapsed: (TimeInterval) -> Bool
    private let seekLog = Logger(subsystem: "local.starfruit.TouchBarEnhancer", category: "LyricsSeek")
    private var seekTimeout: Cancel?
    private var pendingSeek: (id: UUID, expected: LyricsPlayback, offset: TimeInterval)?
    private struct SeekAnchor {
        var baseline: LyricsPlayback
        var target: LyricsPlayback
        var expires: Date
    }
    private var seekAnchor: SeekAnchor?
    private var seekReconcile: Cancel?
    private var unsubscribe: Cancel?
    private var boundary: Cancel?
    private var timeout: Cancel?
    private var searchTask: Task<Void, Never>?
    private var generation = UUID()
    private var readID = UUID()
    private var playback: LyricsPlayback?
    private var result: LyricsSearchResult?
    private var searchedKey: String?
    private var status = LyricsDisplay()

    init(search: @escaping (LyricsTrack) async throws -> LyricsSearchResult?,
         read: @escaping (@escaping @MainActor (LyricsPlayback?) -> Void) -> Void,
         observe: @escaping (@escaping @MainActor (Bool?) -> Void) -> Cancel?,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Cancel = LyricsController.timer,
         setElapsed: @escaping (TimeInterval) -> Bool = { _ in false }) {
        self.search = search; self.read = read; self.observe = observe; self.now = now; self.schedule = schedule
        self.setElapsed = setElapsed
    }
    static func timer(_ delay: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Cancel {
        let timer = Timer(timeInterval: max(0.01, delay), repeats: false) { _ in MainActor.assumeIsolated { body() } }
        timer.tolerance = 0.02; RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value; generation = UUID()
        if value {
            let token = generation
            unsubscribe = observe { [weak self] playing in
                guard let self, self.enabled, self.generation == token else { return }
                if let playing, var state = self.playback {
                    state.elapsed = state.position(at: self.now()); state.date = self.now(); state.playing = playing
                    if playing && state.rate <= 0 { state.rate = 1 }
                    self.seekAnchor?.target = state
                    self.playback = state; self.render()
                }
                self.refresh(playingOverride: playing)
            }
            refresh()
        } else {
            cancelSeek()
            clearSeekAnchor()
            unsubscribe?(); unsubscribe = nil
            boundary?(); boundary = nil; timeout?(); timeout = nil
            readID = UUID(); searchTask?.cancel(); searchTask = nil
            playback = nil; result = nil; searchedKey = nil
            publish(.init())
        }
    }
    func refresh(playingOverride: Bool? = nil) {
        guard enabled else { return }
        readID = UUID(); let id = readID, token = generation
        timeout?()
        timeout = schedule(3) { [weak self] in
            guard let self, self.readID == id, self.generation == token else { return }
            self.readID = UUID(); self.accept(nil)
        }
        read { [weak self] state in
            guard let self, self.enabled, self.generation == token, self.readID == id else { return }
            self.readID = UUID(); self.timeout?(); self.timeout = nil
            var state = state
            if let playingOverride, state != nil {
                state!.playing = playingOverride
                if playingOverride && state!.rate <= 0 { state!.rate = 1 }
            }
            self.accept(state)
        }
    }
    func reload() {
        boundary?(); boundary = nil
        searchTask?.cancel(); searchTask = nil; searchedKey = nil; result = nil
        if enabled { refresh() }
    }
    private static func sameMedia(_ lhs: LyricsPlayback, _ rhs: LyricsPlayback) -> Bool {
        lhs.source == rhs.source &&
        LyricsTrack.normalized(lhs.track.title) == LyricsTrack.normalized(rhs.track.title) &&
        LyricsTrack.normalized(lhs.track.artist) == LyricsTrack.normalized(rhs.track.artist)
    }

    /// One fresh, bounded position read per gesture batch. No playback polling,
    /// key events or play/pause command; the active system player owns seeking.
    func seek(by offset: TimeInterval) {
        guard offset.isFinite, offset != 0 else { return }
        seekLog.notice("Swipe request: offset=\(offset, privacy: .public), enabled=\(self.enabled, privacy: .public), playback=\(self.playback != nil, privacy: .public)")
        guard enabled, let playback else { onSeekError?("Playback position is unavailable."); return }
        if let pendingSeek, Self.sameMedia(pendingSeek.expected, playback) {
            seekLog.notice("Seek queued behind pending position read")
            let sum = pendingSeek.offset + offset
            if sum.isFinite { self.pendingSeek?.offset = sum }
            return
        }
        cancelSeek()
        let id = UUID(), token = generation
        pendingSeek = (id, playback, offset)
        seekTimeout = schedule(3) { [weak self] in
            guard let self, self.pendingSeek?.id == id else { return }
            self.cancelSeek(); self.onSeekError?("Playback position request timed out.")
        }
        read { [weak self] state in
            if let self {
                self.seekLog.notice("Seek position read: state=\(state != nil, privacy: .public), enabled=\(self.enabled, privacy: .public), generation=\(self.generation == token, privacy: .public), pending=\(self.pendingSeek?.id == id, privacy: .public)")
                if let state, let current = self.playback, let pending = self.pendingSeek {
                    self.seekLog.notice("Seek identity: expected=\(Self.sameMedia(pending.expected, state), privacy: .public), current=\(Self.sameMedia(current, state), privacy: .public), position=\(state.elapsed ?? -1, privacy: .public)")
                }
            }
            guard let self, self.enabled, self.generation == token,
                  let pending = self.pendingSeek, pending.id == id else { return }
            self.cancelSeek()
            guard let state, let current = self.playback,
                  Self.sameMedia(pending.expected, state), Self.sameMedia(current, state) else {
                self.onSeekError?("The current media changed. Swipe again to seek."); return
            }
            let date = self.now()
            let resolved = self.resolvingPlayback(state, at: date)
            guard let position = resolved.position(at: date), position.isFinite else {
                self.onSeekError?("Playback position is unavailable."); return
            }
            var target = max(0, position + pending.offset)
            if let duration = resolved.track.duration, duration.isFinite, duration > 0 { target = min(target, duration) }
            guard target.isFinite, pending.offset != 0 else { return }
            guard self.setElapsed(target) else {
                self.seekLog.notice("Seek dispatch rejected: target=\(target, privacy: .public)")
                self.onSeekError?("System media seeking is unavailable."); return
            }
            self.seekLog.notice("Seek dispatched: reported=\(state.elapsed ?? -1, privacy: .public), resolved=\(position, privacy: .public), target=\(target, privacy: .public)")
            // A successful dispatch may precede the player's metadata update.
            // Reuse the target for an unchanged old snapshot or a missing position
            // from the same media. A valid new anchor/source/song takes authority.
            var anchor = resolved
            anchor.elapsed = target; anchor.date = date
            self.clearSeekAnchor()
            self.seekAnchor = SeekAnchor(baseline: state, target: anchor, expires: date.addingTimeInterval(3))
            self.playback = anchor; self.render()
            self.seekReconcile = self.schedule(3) { [weak self] in
                guard let self else { return }
                self.clearSeekAnchor()
                if self.enabled { self.refresh() }
            }
        }
    }
    private func cancelSeek() { pendingSeek = nil; seekTimeout?(); seekTimeout = nil }

    private func clearSeekAnchor() {
        seekAnchor = nil; seekReconcile?(); seekReconcile = nil
    }

    private func resolvingSeekAnchor(_ incoming: LyricsPlayback, at date: Date) -> LyricsPlayback {
        guard let anchor = seekAnchor else { return incoming }
        guard date < anchor.expires, Self.sameMedia(anchor.baseline, incoming) else {
            clearSeekAnchor(); return incoming
        }
        // A partial snapshot is not acknowledgement of a different position.
        // Keep the one-shot reconciliation and let the shared merge fill it in.
        guard let elapsed = incoming.elapsed, elapsed.isFinite, elapsed >= 0 else { return incoming }
        guard incoming.elapsed == anchor.baseline.elapsed, incoming.date == anchor.baseline.date else {
            clearSeekAnchor(); return incoming
        }
        var state = incoming
        state.elapsed = anchor.target.position(at: date); state.date = date
        return state
    }

    private func resolvingPlayback(_ incoming: LyricsPlayback, at date: Date) -> LyricsPlayback {
        var state = resolvingSeekAnchor(incoming, at: date)
        guard let previous = playback, Self.sameMedia(state, previous) else { return state }
        // MediaRemote can omit the elapsed position after seeking, as well as
        // during artwork/resume updates. Display and transport must share the
        // same known timeline, and must never borrow it from another song/player.
        if state.track.album.isEmpty { state.track.album = previous.track.album }
        if state.track.duration.map({ $0.isFinite && $0 > 0 }) != true {
            state.track.duration = previous.track.duration
        }
        if state.elapsed.map({ $0.isFinite && $0 >= 0 }) != true {
            state.elapsed = previous.position(at: date); state.date = date
        }
        return state
    }

    private func accept(_ incoming: LyricsPlayback?) {
        if incoming == nil { seekLog.notice("Metadata read returned no complete media") }
        if let pendingSeek, incoming.map({ Self.sameMedia(pendingSeek.expected, $0) }) != true { cancelSeek() }
        if incoming == nil { clearSeekAnchor() }
        let state = incoming.map { resolvingPlayback($0, at: now()) }
        playback = state
        guard let state, !state.track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !state.track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchTask?.cancel(); searchTask = nil; searchedKey = nil; result = nil
            status = .init(); render(); return
        }
        let key = state.track.cacheKey
        guard searchedKey != key else { render(); return }
        searchTask?.cancel(); result = nil; searchedKey = key
        status = .init(text: "Searching lyrics…", detail: "\(state.track.title) — \(state.track.artist)")
        render()
        let token = generation
        searchTask = Task { [weak self, search] in
            do {
                let found = try await search(state.track)
                guard !Task.isCancelled, let self, self.enabled, self.generation == token, self.searchedKey == key else { return }
                self.result = found
                self.status = .init(text: found == nil ? "Lyrics unavailable" : "♪", detail: found?.source ?? "No matching timed lyrics found.")
                self.searchTask = nil; self.render()
            } catch {
                guard !Task.isCancelled, let self, self.enabled, self.generation == token, self.searchedKey == key else { return }
                self.status = .init(text: "Lyrics unavailable", detail: "Lyrics search failed. Reopen this bar to retry.")
                self.searchTask = nil; self.render()
            }
        }
    }
    private func publish(_ value: LyricsDisplay) {
        guard display != value else { return }; display = value; onChange?(value)
    }
    private func render() {
        boundary?(); boundary = nil
        guard enabled, let playback else { publish(.init()); return }
        guard let result else { publish(status); return }
        let detail = "\(playback.track.title) — \(playback.track.artist) · \(result.source)"
        if result.instrumental { publish(.init(text: "Instrumental", detail: detail)); return }
        guard let lyrics = result.lyrics, let time = playback.position(at: now()) else {
            publish(.init(text: "Lyrics unavailable", detail: "Playback position is unavailable.")); return
        }
        let position = lyrics.position(at: time)
        let text = position.index.map { lyrics.lines[$0].text }.flatMap { $0.isEmpty ? nil : $0 } ?? "♪"
        publish(.init(text: text, detail: detail))
        if playback.playing, playback.rate > 0, playback.rate.isFinite, let next = position.next,
           playback.track.duration.map({ !$0.isFinite || $0 <= 0 || next <= $0 }) ?? true {
            let token = generation
            boundary = schedule(max(0.01, (next - time) / playback.rate)) { [weak self] in
                guard let self, self.enabled, self.generation == token else { return }
                self.render()
            }
        }
    }
}
