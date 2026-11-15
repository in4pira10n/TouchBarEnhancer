import AppKit
import TouchBarBridge
import Darwin

/// Reads the current system player; never starts an app or changes playback.
@main @MainActor
struct LyricsMediaSmoke {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        precondition(!TBSeekMediaToTime(-1) && !TBSeekMediaToTime(.nan) && !TBSeekMediaToTime(.infinity),
            "Invalid positions must be rejected before sending a media command")
        print("System seek transport: \(TBMediaSeekIsAvailable() ? "available" : "unavailable") (availability/validation only; no seek sent)")
        var finished = false
        TBReadNowPlaying { values in
            let state = LyricsPlayback(nowPlaying: values)
            MainActor.assumeIsolated {
                precondition(Thread.isMainThread)
                if let state {
                    print("System track: \(state.track.title) — \(state.track.artist)")
                    print("Playback: \(state.playing ? "playing" : "paused"), position: \(state.position(at: Date()).map { String(format: "%.2f", $0) } ?? "unavailable"), source: \(state.source)")
                    precondition(state.date.timeIntervalSince1970.isFinite)
                } else { print("System player has no complete song metadata") }
                finished = true
            }
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        precondition(finished, "System Now Playing metadata query timed out")

        let library = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL)!
        func name(_ symbol: String) -> String {
            dlsym(library, symbol)!.assumingMemoryBound(to: NSString?.self).pointee! as String
        }
        let playing = Notification.Name(name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"))
        let source = Notification.Name(name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"))
        let info = Notification.Name(name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"))
        let key = name("kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey")
        var events: [Bool?] = [], otherEvents = 0
        let observer = TBObserveNowPlaying { value in MainActor.assumeIsolated { events.append(value?.boolValue) } }!
        let other = TBObserveMediaPlaying { _ in MainActor.assumeIsolated { otherEvents += 1 } }!
        NotificationCenter.default.post(name: info, object: nil)
        precondition(events.count == 1 && events.last! == nil && otherEvents == 0)
        NotificationCenter.default.post(name: playing, object: nil, userInfo: [key: false])
        precondition(events.last! == false && otherEvents == 1)
        NotificationCenter.default.post(name: source, object: nil)
        precondition(events.count == 3 && events.last! == nil && otherEvents == 2)
        TBStopObservingMediaPlaying(observer); TBStopObservingMediaPlaying(observer)
        NotificationCenter.default.post(name: info, object: nil)
        NotificationCenter.default.post(name: playing, object: nil, userInfo: [key: true])
        precondition(events.count == 3 && otherEvents == 3)
        TBStopObservingMediaPlaying(other)

        if CommandLine.arguments.contains("--live") {
            let repository = LyricsRepository(directory: URL(fileURLWithPath: ".build/lyrics-media-cache"))
            let controller = LyricsController(search: { try await repository.search($0, refresh: true) }, read: { completion in
                TBReadNowPlaying { values in
                    let state = LyricsPlayback(nowPlaying: values)
                    MainActor.assumeIsolated { completion(state) }
                }
            }, observe: { changed in
                guard let token = TBObserveNowPlaying({ value in MainActor.assumeIsolated { changed(value?.boolValue) } }) else { return nil }
                return { TBStopObservingMediaPlaying(token) }
            })
            var received = false
            controller.onChange = { display in
                print("Lyrics: \(display.text == "Searching lyrics…" || display.text == "Lyrics unavailable" || display.text == "No media playing" ? display.text : "current line (\(display.text.count) characters)") · \(display.detail)")
                fflush(stdout)
                if !["Searching lyrics…", "Lyrics unavailable", "No media playing"].contains(display.text) { received = true }
            }
            controller.setEnabled(true)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: CommandLine.arguments.contains("--listen") ? 45 : 18))
            controller.setEnabled(false)
            print("Real current-line result: \(received ? "available" : "unavailable for this track / system state")")
        }
        precondition(!app.isActive && !app.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) })
        print("Lyrics media checks passed: real read-only metadata, playing/source/position notifications, independent subscription cancellation, no activation or playback commands")
    }
}
