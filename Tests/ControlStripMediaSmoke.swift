import AppKit
import TouchBarBridge
import Darwin

/// Read-only check of the real system source, without starting Music or playback.
@main @MainActor
struct ControlStripMediaSmoke {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if CommandLine.arguments.contains("--listen") {
            var count = 0
            let observer = TBObserveMediaPlaying { value in
                MainActor.assumeIsolated {
                    count += 1
                    print("System media event \(count): \(value.map { $0.boolValue ? "playing" : "paused" } ?? "source changed")")
                    fflush(stdout)
                }
            }
            precondition(observer != nil)
            print("Listening to system Now Playing events without polling or playback commands")
            fflush(stdout)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 45))
            TBStopObservingMediaPlaying(observer!)
            print("System event observation ended: \(count) events")
            return
        }
        var finished = false
        TBReadMediaPlaying { value in
            MainActor.assumeIsolated {
                precondition(Thread.isMainThread)
                precondition(value != nil, "System Now Playing API unavailable on this test machine")
                print("Read-only Now Playing state: \(value!.boolValue ? "playing" : "paused / idle")")
                finished = true
            }
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        precondition(finished, "System Now Playing query timed out")

        // Feed only this process's notification center: no real playback change,
        // media command, clipboard edit or cross-process notification is sent.
        let library = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL)!
        func name(_ symbol: String) -> String {
            let pointer = dlsym(library, symbol)!.assumingMemoryBound(to: NSString?.self)
            return pointer.pointee! as String
        }
        let playingName = Notification.Name(name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"))
        let sourceName = Notification.Name(name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"))
        let playingKey = name("kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey")
        var events: [Bool?] = []
        let observer = TBObserveMediaPlaying { value in
            MainActor.assumeIsolated {
                precondition(Thread.isMainThread)
                events.append(value?.boolValue)
            }
        }!
        var otherEvents = 0
        let other = TBObserveMediaPlaying { _ in MainActor.assumeIsolated { otherEvents += 1 } }!
        NotificationCenter.default.post(name: playingName, object: nil, userInfo: [playingKey: true])
        precondition(events.last! == true && otherEvents == 1)
        NotificationCenter.default.post(name: playingName, object: nil, userInfo: [playingKey: false])
        precondition(events.last! == false && otherEvents == 2)
        NotificationCenter.default.post(name: sourceName, object: nil)
        precondition(events.last! == nil && otherEvents == 3)
        TBStopObservingMediaPlaying(observer)
        TBStopObservingMediaPlaying(observer) // Cancellation is idempotent.
        let stoppedCount = events.count
        NotificationCenter.default.post(name: playingName, object: nil, userInfo: [playingKey: true])
        precondition(events.count == stoppedCount && otherEvents == 4, "Stopping one subscription must preserve the other")
        TBStopObservingMediaPlaying(other)
        NotificationCenter.default.post(name: playingName, object: nil, userInfo: [playingKey: false])
        precondition(otherEvents == 4)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        print("Control Strip media checks passed: real read-only state, system notification symbols, immediate playing/pause/source events, independent cancellation, main callbacks, no activation or playback changes")
    }
}
