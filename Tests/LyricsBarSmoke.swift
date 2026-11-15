import AppKit
import TouchBarBridge

/// Synthetic lyrics in the signed production bundle. No real player or requests.
@main @MainActor
struct LyricsBarSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func main() {
        TBPrepareForImmediateTransitions()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory); app.finishLaunching()
        let provider = AppBar(app: .enhancedBar,
            keyboardButtons: .init(buttons: [.init(title: "One"), .init(title: "Two")]), persistsLayout: false)
        provider.bar.defaultItemIdentifiers = ["lyrics", "keyboard"].map(AppBar.itemID)
        provider.configureComponentPresentations(["lyrics": .init(alignment: .center), "keyboard": .init(layout: .fill)])
        let canonical = provider.bar.item(forIdentifier: AppBar.itemID("lyrics")) as! NSCustomTouchBarItem
        let host = AppBarHost(); host.display(provider)
        precondition(TBPresent(host.bar))
        let item = host.bar.templateItems.first { $0.identifier == AppBar.itemID("lyrics") } as! NSCustomTouchBarItem
        let region = (item.view as! TouchBarComponentView).content as! ScrollingComponentRegion
        let interaction = descendants(region).compactMap { $0 as? LyricsInteractionView }.first!
        var searchTaps = 0, seekOffsets: [TimeInterval] = []
        provider.onLyricsSearch = { searchTaps += 1 }
        provider.onLyricsSeek = { seekOffsets.append($0) }
        precondition(item.view !== canonical.view, "Canonical and modal views must be independent")
        var state = LyricsPlayback(track: .init(title: "Fixture", artist: "Fixture", duration: 30),
            elapsed: 0, date: Date(), rate: 0, playing: false, source: "fixture")
        var event: (@MainActor (Bool?) -> Void)?
        var searches = 0, reads = 0, cancelled = 0
        let result = LyricsSearchResult(lyrics: TimedLyrics(lrc: "[00:00]A short line\n[00:05]这句歌词与Swift2026一起显示\n[00:10]"), source: "Fixture")
        let controller = LyricsController(search: { _ in searches += 1; return result },
            read: { reads += 1; $0(state) }, observe: { event = $0; return { event = nil; cancelled += 1 } })
        controller.onChange = { provider.configureLyricsDisplay($0) }
        controller.setEnabled(true)
        var autoWidth: CGFloat = 0, shortWidth: CGFloat = 0
        func label(_ view: NSView) -> NSTextField {
            descendants(view).compactMap { $0 as? NSTextField }.first { $0.stringValue == controller.display.text }!
        }
        func check(_ text: String) {
            region.layoutSubtreeIfNeeded()
            precondition(controller.display.text == text && label(region).stringValue == text)
            precondition(region.window != nil && !region.isHiddenOrHasHiddenAncestor)
            precondition(interaction.frame == region.bounds, "Hit surface must cover the allocated native lyric region")
            precondition(region.hitTest(NSPoint(x: region.frame.midX, y: region.frame.midY)) === interaction,
                "The native hit target must be lyrics interaction, not the passive text scrubber")
            precondition(item.view === host.bar.templateItems.first { $0.identifier == item.identifier }?.view)
            precondition(label(canonical.view).stringValue == text)
            precondition(!app.isActive && !app.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            check("A short line")
            precondition(interaction.accessibilityPerformPress() && searchTaps == 1)
            interaction.begin(at: NSPoint(x: 50, y: 15)); interaction.end(at: NSPoint(x: 90, y: 15))
            interaction.begin(at: NSPoint(x: 90, y: 15)); interaction.end(at: NSPoint(x: 50, y: 15))
            precondition(searchTaps == 1 && seekOffsets == [5, -5], "Native routing uses mock effects only")
            autoWidth = region.frame.width
            let keyItem = host.content.groupTouchBar.item(forIdentifier: AppBar.itemID("keyboard")) as! NSCustomTouchBarItem
            let keyRegion = (keyItem.view as! TouchBarComponentView).content as! ScrollingComponentRegion
            precondition(abs(autoWidth - keyRegion.frame.width) < 1)
            precondition(abs(keyRegion.convert(keyRegion.bounds, to: nil).minX - region.convert(region.bounds, to: nil).maxX - 12) < 1)
            state.elapsed = 5; event?(nil)
            provider.configureLyrics(.init(style: .init(fontSize: 18, color: "orange", tracking: 2,
                alignment: .center, truncation: .tail)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            check("这句歌词与Swift2026一起显示")
            let attributes = label(region).attributedStringValue.attributes(at: 0, effectiveRange: nil)
            precondition((attributes[.font] as! NSFont).pointSize == 18 && attributes[.kern] as? Double == 2)
            precondition(label(region).attributedStringValue.attribute(.kern, at: 4, effectiveRange: nil) as? Double == 6.5,
                "Native lyric measurement and drawing must include the quarter-em Pangu boundary")
            precondition(abs(region.frame.width - autoWidth) < 1 && searches == 1)
            provider.configureComponentPresentations(["lyrics": .init(alignment: .center, textWidth: .init(mode: .hug)), "keyboard": .init(layout: .fill)])
            state.elapsed = 0; event?(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            check("A short line")
            shortWidth = region.frame.width
            precondition(shortWidth < autoWidth && shortWidth > 1)
            state.elapsed = 5; event?(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            check("这句歌词与Swift2026一起显示")
            precondition(region.frame.width > shortWidth && searches == 1)
            precondition(region.requestedWidth != nil)
            provider.configureComponentPresentations(["lyrics": .init(layout: .fill, textWidth: .init(mode: .fixed, fixed: 100)), "keyboard": .init(layout: .fill)])
            provider.configureLyrics(.init(fillWidth: .init(mode: .relative, relative: 12),
                style: .init(fontSize: 18, color: "orange", tracking: 2, alignment: .center, truncation: .tail)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            check("这句歌词与Swift2026一起显示")
            precondition(abs(region.frame.width - 100) < 1)
            state.elapsed = 10; event?(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            check("♪")
            precondition(searches == 1 && reads == 5)
            controller.setEnabled(false)
            precondition(cancelled == 1 && event == nil)
            _ = TBDismiss(host.bar)
            print("Lyrics bar checks passed: independent canonical/modal live typography and current lines/gap, equal peers, 12pt boundary, live Hug growth and Fixed/Fill preservation, no real media/input/network")
            fflush(stdout); app.terminate(nil)
        }
        app.run()
    }
}
