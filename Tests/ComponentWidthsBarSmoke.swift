import AppKit
import TouchBarBridge

/// Signed, nonactivating hardware fixture with no edits to the user's preferences.
@main @MainActor
struct ComponentWidthsBarSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func near(_ actual: CGFloat, _ expected: CGFloat) {
        precondition(abs(actual - expected) < 1, "Expected \(expected), got \(actual)")
    }
    static func buttons(_ phase: Int) -> [KeyboardButton] {
        let policies: [ComponentItemWidth]
        switch phase {
        case 0: policies = [.init(relative: 6), .init(relative: 6), .init(relative: 12)]
        case 4: policies = [.init(mode: .fixed, fixed: 760), .init(mode: .hug), .init()]
        default: policies = [.init(mode: .fixed, fixed: 90), .init(mode: .hug), .init()]
        }
        return zip(["Fixed / 6", "Hug / 6", "Relative / 12"], policies).map {
            KeyboardButton(title: $0.0, fillWidth: $0.1)
        }
    }
    static func phase(_ index: Int, _ provider: AppBar, _ host: AppBarHost, foreground: pid_t?) {
        guard index < 6 else {
            _ = TBDismiss(host.bar)
            precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
            print("Component width hardware checks passed: proportional, fixed, hug, mixed peers, scrolling ignores policies, overflow, live updates, 8/12pt gaps, no activation")
            fflush(stdout); NSApp.terminate(nil); return
        }
        let keys = index == 2 ? ["keyboard", "text"] : ["keyboard"]
        let mode: ComponentLayout = index == 3 ? .scrolling : .fill
        let configured = buttons(index)
        provider.configureKeyboardButtons(.init(buttons: configured))
        provider.configureComponentPresentations(Dictionary(uniqueKeysWithValues: keys.map { ($0, ComponentPresentation(layout: mode)) }))
        provider.bar.defaultItemIdentifiers = keys.map(AppBar.itemID)
        host.display(provider); precondition(TBPresent(host.bar))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var regions: [NSRect] = []
            for key in keys {
                let id = AppBar.itemID(key)
                let item = (host.bar.templateItems.first { $0.identifier == id }
                    ?? host.content.groupTouchBar.item(forIdentifier: id)) as! NSCustomTouchBarItem
                let region = (item.view as! TouchBarComponentView).content as! ScrollingComponentRegion
                precondition(region.window != nil && !region.isHiddenOrHasHiddenAncestor)
                region.layoutSubtreeIfNeeded(); regions.append(region.convert(region.bounds, to: nil))
                let scrubber = descendants(region).compactMap { $0 as? NSScrubber }.first!
                let frames = (0..<scrubber.numberOfItems).map { scrubber.scrubberLayout.layoutAttributesForItem(at: $0)!.frame }
                for pair in zip(frames, frames.dropFirst()) { near(pair.1.minX - pair.0.maxX, 8) }
                if key == "keyboard" {
                    if index == 0 {
                        near(frames[0].width, frames[1].width); near(frames[2].width, frames[0].width * 2)
                    } else if mode == .scrolling {
                        for (frame, button) in zip(frames, configured) { near(frame.width, ScrollingComponentItemView.width(for: button.scrollingItem)) }
                    } else {
                        near(frames[0].width, index == 4 ? 760 : 90)
                        near(frames[1].width, ScrollingComponentItemView.width(for: configured[1].scrollingItem))
                        if index == 4 { precondition(frames.last!.maxX > region.bounds.width && frames[2].width >= 1) }
                        else { near(frames.last!.maxX, region.bounds.width) }
                    }
                } else {
                    let naturalLabel = descendants(scrubber).compactMap { $0 as? NSTextField }.first { !$0.isHidden }!
                    // Text Hug uses the actual native presentation metrics.
                    precondition(frames[0].width >= naturalLabel.fittingSize.width - 4)
                    near(frames.last!.maxX, region.bounds.width)
                }
                print("Width phase \(index), \(key): \(frames)")
            }
            near(regions[0].minX, 0)
            if regions.count == 2 {
                near(regions[0].width, regions[1].width)
                near(regions[1].minX - regions[0].maxX, 12)
            }
            fflush(stdout); phase(index + 1, provider, host, foreground: foreground)
        }
    }
    static func main() {
        TBPrepareForImmediateTransitions()
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let provider = AppBar(app: LayoutApp.builtIn[0],
            textItems: [TextComponentItem(text: "Hug Text", fillWidth: .init(mode: .hug)), TextComponentItem(text: "Relative Text")], persistsLayout: false)
        let host = AppBarHost()
        phase(0, provider, host, foreground: foreground); app.run()
    }
}
