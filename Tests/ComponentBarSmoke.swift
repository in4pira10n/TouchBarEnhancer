import AppKit
import TouchBarBridge

/// Uses the installed signed bundle without activation; capture is external.
@main @MainActor
struct ComponentBarSmoke {
    static let layouts = [["phrases"], ["chatgpt.chats"], ["text"],
        ["phrases", "chatgpt.chats"], ["text", "keyboard"], ["chatgpt.chats", "text", "phrases"]]
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func phase(_ index: Int, _ provider: AppBar, _ host: AppBarHost, foreground: pid_t?) {
        guard layouts.indices.contains(index) else {
            _ = TBDismiss(host.bar)
            precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
            print("Component hardware checks passed: all categories, text defaults/custom typography, fill and scrolling alignment, equal peer widths, 8/12pt gaps, no activation")
            fflush(stdout); NSApp.terminate(nil); return
        }
        let keys = layouts[index]
        var presentations = Dictionary(uniqueKeysWithValues: keys.map { ($0, ComponentPresentation(layout: .fill)) })
        if index == 3 { presentations["phrases"] = .init(alignment: .right) }
        if index == 4 { presentations["text"] = .init(alignment: .center) }
        provider.configureComponentPresentations(presentations)
        provider.bar.defaultItemIdentifiers = keys.map(AppBar.itemID)
        host.display(provider); precondition(TBPresent(host.bar))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var frames: [NSRect] = []
            for key in keys {
                let id = AppBar.itemID(key)
                let item = (host.bar.templateItems.first { $0.identifier == id }
                    ?? host.content.groupTouchBar.item(forIdentifier: id)) as! NSCustomTouchBarItem
                let wrapper = item.view as! TouchBarComponentView
                let region = wrapper.content as! ScrollingComponentRegion
                precondition(region.window != nil && !region.isHiddenOrHasHiddenAncestor)
                region.layoutSubtreeIfNeeded()
                frames.append(region.convert(region.bounds, to: nil))
                let scrubber = descendants(region).compactMap { $0 as? NSScrubber }.first!
                let items = (0..<scrubber.numberOfItems).map { scrubber.scrubberLayout.layoutAttributesForItem(at: $0)!.frame }
                precondition(items.count >= 2)
                if presentations[key]!.layout == .fill {
                    let expected = (region.bounds.width - CGFloat(items.count - 1) * 8) / CGFloat(items.count)
                    precondition(items.allSatisfy { abs($0.width - expected) < 1 })
                    precondition(abs(items[0].minX) < 1 && abs(items.last!.maxX - region.bounds.width) < 1)
                }
                for pair in zip(items, items.dropFirst()) { precondition(abs(pair.1.minX - pair.0.maxX - 8) < 1) }
                let labels = descendants(scrubber).compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
                precondition(!labels.isEmpty)
                for label in labels {
                    precondition(label.cell?.wraps == false)
                    if key != "text" {
                        precondition(label.maximumNumberOfLines == 0 && label.cell?.usesSingleLineMode == false)
                        precondition(label.lineBreakMode == .byTruncatingTail)
                        precondition(label.bounds.height <= 22, "Button wrapped: \(label.stringValue), \(label.frame)")
                    } else if presentations[key]!.layout == .scrolling {
                        precondition(label.frame.width >= label.fittingSize.width, "Text clipped: \(label.stringValue), \(label.frame), fitting \(label.fittingSize)")
                    }
                }
                if key == "text" {
                    let textItem = scrubber.dataSource!.scrubber(scrubber, viewForItemAt: 0)
                    precondition(descendants(textItem).compactMap { $0 as? NSImageView }.allSatisfy(\.isHidden))
                    precondition(descendants(textItem).compactMap { $0 as? NSTextField }.allSatisfy { !$0.isHidden })
                }
            }
            precondition(abs(frames[0].minX) < 1)
            precondition(frames.allSatisfy { abs($0.width - frames[0].width) < 1 })
            for pair in zip(frames, frames.dropFirst()) { precondition(abs(pair.1.minX - pair.0.maxX - 12) < 1) }
            print("Component hardware phase \(index): \(keys), \(frames)"); fflush(stdout)
            phase(index + 1, provider, host, foreground: foreground)
        }
    }
    static func main() {
        TBPrepareForImmediateTransitions()
        let application = NSApplication.shared; application.setActivationPolicy(.accessory)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let provider = AppBar(app: LayoutApp.builtIn[0],
            shortcuts: [ChatShortcut(name: "Chat One", slot: 1), ChatShortcut(name: "Chat Two", color: "teal", slot: 2)],
            phrases: [QuickPhrase(name: "Explain", text: "Test"), QuickPhrase(name: "Summarize", text: "Test")],
            keyboardButtons: .init(buttons: [KeyboardButton(title: "Find", symbol: "magnifyingglass"), KeyboardButton(title: "New", symbol: "plus")]),
            textItems: [TextComponentItem(text: "Native Text"),
                TextComponentItem(text: "Styled Text", style: .init(fontSize: 17, color: "orange", tracking: 1, backgroundColor: "#363636"))], persistsLayout: false)
        let host = AppBarHost()
        phase(0, provider, host, foreground: foreground); application.run()
    }
}
