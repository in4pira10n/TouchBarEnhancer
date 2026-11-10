import AppKit
import TouchBarBridge

/// Nonactivating hardware fixture. Screenshots belong to the external harness.
@main @MainActor
struct KeyboardBarLayoutSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static let layouts = [
        ["keyboard"], ["keyboard"], ["keyboard"],
        ["keyboard", "phrases"], ["phrases", "keyboard"],
        ["chatgpt.chats", "keyboard", "phrases"],
        ["keyboard"], ["keyboard"]
    ]
    static let buttons = [KeyboardButton(title: "Search", symbol: "magnifyingglass", displayModeOverride: .iconAndText),
        KeyboardButton(title: "New Tab", symbol: "plus", color: "blue", displayModeOverride: .iconOnly),
        KeyboardButton(title: "下一页", symbol: "arrow.right", color: "teal")]
    static let chats = [ChatShortcut(name: "Chat 1", slot: 1, displayModeOverride: .iconAndText),
        ChatShortcut(name: "Chat 2", color: "teal", slot: 2)]
    static let phrases = [QuickPhrase(name: "Quick Phrase", text: "Fixture", displayModeOverride: .iconAndText),
        QuickPhrase(name: "Icon Phrase", text: "Fixture 2", displayModeOverride: .iconOnly)]
    static let displayModes: [[String: ComponentDisplayMode]] = [
        [:], ["keyboard": .iconOnly], [:],
        ["keyboard": .iconOnly], ["phrases": .iconOnly],
        ["chatgpt.chats": .iconOnly, "keyboard": .iconOnly, "phrases": .iconOnly],
        ["keyboard": .iconOnly], ["keyboard": .iconOnly]
    ]

    static func check(_ index: Int, provider: AppBar, host: AppBarHost, foreground: pid_t?) {
        guard layouts.indices.contains(index) else {
            _ = TBDismiss(host.bar)
            precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
            print("Keyboard hardware layout checks passed: fill 1/2/3, component/item override precedence, live icon/text switching, peer widths, 8/12pt gaps, aligned scrolling, no activation")
            fflush(stdout)
            NSApp.terminate(nil)
            return
        }
        let suffixes = layouts[index]
        let count = index < 3 ? index + 1 : (index >= 6 ? 1 : 3)
        let configuration = KeyboardButtonsConfiguration(buttons: Array(buttons.prefix(count)),
            layout: index < 6 ? .fill : .scrolling, alignment: index == 6 ? .center : .right)
        provider.configureKeyboardButtons(configuration)
        provider.configureComponentDisplayModes(displayModes[index])
        provider.bar.defaultItemIdentifiers = suffixes.map(AppBar.itemID)
        host.display(provider)
        precondition(TBPresent(host.bar))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var frames: [NSRect] = []
            for suffix in suffixes {
                let id = AppBar.itemID(suffix)
                let item = (host.bar.templateItems.first { $0.identifier == id }
                    ?? host.content.groupTouchBar.item(forIdentifier: id)) as! NSCustomTouchBarItem
                let wrapper = item.view as! TouchBarComponentView
                let region = wrapper.content as! ScrollingComponentRegion
                precondition(region.window != nil && !region.isHiddenOrHasHiddenAncestor,
                    "Phase \(index), \(suffix): frame \(region.frame), window \(String(describing: region.window?.frame)), scale \(String(describing: region.window?.backingScaleFactor)), hidden \(region.isHiddenOrHasHiddenAncestor)")
                let frame = region.convert(region.bounds, to: nil)
                frames.append(frame)
                let scrubber = descendants(region).compactMap { $0 as? NSScrubber }.first!
                let mode = displayModes[index][suffix] ?? .iconAndText
                for entry in 0..<scrubber.numberOfItems {
                    let item = scrubber.dataSource!.scrubber(scrubber, viewForItemAt: entry)
                    let label = descendants(item).compactMap { $0 as? NSTextField }.first!
                    let override = suffix == "keyboard" ? buttons[entry].displayModeOverride
                        : (suffix == "phrases" ? phrases[entry].displayModeOverride : chats[entry].displayModeOverride)
                    precondition(label.isHidden == ((override ?? mode) == .iconOnly) && !label.stringValue.isEmpty)
                }
                if suffix == "keyboard" {
                    region.layoutSubtreeIfNeeded()
                    let items = (0..<count).map { scrubber.scrubberLayout.layoutAttributesForItem(at: $0)!.frame }
                    if configuration.layout == .fill {
                        let expected = (region.bounds.width - CGFloat(count - 1) * 8) / CGFloat(count)
                        precondition(items.allSatisfy { abs($0.width - expected) < 1 })
                        precondition(abs(items[0].minX) < 1 && abs(items.last!.maxX - region.bounds.width) < 1)
                        for pair in zip(items, items.dropFirst()) {
                            precondition(abs(pair.1.minX - pair.0.maxX - 8) < 1)
                        }
                    } else {
                        let natural = ScrollingComponentItemView.width(for: buttons[0].scrollingItem, displayMode: mode)
                        let expected = (region.bounds.width - natural) / (index == 6 ? 2 : 1)
                        precondition(abs(scrubber.frame.minX - expected) < 1)
                    }
                }
            }
            precondition(abs(frames[0].minX) < 1)
            precondition(frames.allSatisfy { abs($0.width - frames[0].width) < 1 })
            for pair in zip(frames, frames.dropFirst()) {
                precondition(abs(pair.1.minX - pair.0.maxX - 12) < 1)
            }
            print("Keyboard hardware phase \(index): \(suffixes), modes \(displayModes[index]), frames \(frames)")
            fflush(stdout)
            check(index + 1, provider: provider, host: host, foreground: foreground)
        }
    }

    static func main() {
        TBPrepareForImmediateTransitions()
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let provider = AppBar(app: LayoutApp.builtIn[0], shortcuts: chats, phrases: phrases,
            keyboardButtons: .init(buttons: buttons), persistsLayout: false)
        let host = AppBarHost()
        check(0, provider: provider, host: host, foreground: foreground)
        application.run()
    }
}
