import AppKit
import TouchBarBridge

/// Nonactivating fixture; the external harness captures the system-owned bar.
@main @MainActor
struct TextRegionWidthBarSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func near(_ value: CGFloat, _ expected: CGFloat) {
        precondition(abs(value - expected) <= 1, "Expected \(expected), got \(value)")
    }
    static func phase(_ index: Int, _ provider: AppBar, _ host: AppBarHost, foreground: pid_t?) {
        guard index < 8 else {
            _ = TBDismiss(host.bar)
            precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
            print("Text region width hardware checks passed: Fixed below 32, Hug, live content/style sizing, Auto reset, both orders, one component, unchanged buttons and 12pt gaps, no activation")
            fflush(stdout); NSApp.terminate(nil); return
        }
        let keys = index == 6 ? ["text"] : ([4, 5].contains(index) ? ["keyboard", "text"] : ["text", "keyboard"])
        let width: TextComponentWidth
        switch index {
        case 0, 4: width = .init(mode: .fixed, fixed: 20)
        case 5: width = .init()
        case 7: width = .init(mode: .fixed, fixed: 1_000_000)
        default: width = .init(mode: .hug)
        }
        let text = index == 2 || index == 3 ? "Text" : "I"
        let style = index == 3 ? TextComponentStyle(fontSize: 17, backgroundColor: "#363636") : TextComponentStyle()
        provider.configureText([TextComponentItem(text: text, style: style)])
        provider.configureComponentPresentations(["text": .init(layout: index == 3 ? .fill : .scrolling, textWidth: width),
            "keyboard": .init(layout: .fill)])
        provider.bar.defaultItemIdentifiers = keys.map(AppBar.itemID)
        host.display(provider); precondition(TBPresent(host.bar))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            var frames: [NSRect] = []
            for key in keys {
                let identifier = AppBar.itemID(key)
                let item = (host.bar.templateItems.first { $0.identifier == identifier }
                    ?? host.content.groupTouchBar.item(forIdentifier: identifier)) as! NSCustomTouchBarItem
                let region = (item.view as! TouchBarComponentView).content as! ScrollingComponentRegion
                precondition(region.window != nil && !region.isHiddenOrHasHiddenAncestor)
                region.layoutSubtreeIfNeeded()
                frames.append(region.convert(region.bounds, to: nil))
                if key == "text" {
                    if index == 5 { precondition(region.requestedWidth == nil) }
                    else if index == 7 { precondition(region.bounds.width < 700 && region.bounds.width > 600) }
                    else {
                        near(region.bounds.width, region.requestedWidth!)
                        if width.mode == .fixed { near(region.bounds.width, 20) }
                        if index == 1 || index == 6 { precondition(region.bounds.width < 32) }
                        if width.mode == .hug {
                            let label = descendants(region).compactMap { $0 as? NSTextField }.first { !$0.isHidden }!
                            near(region.bounds.width, ceil(label.fittingSize.width) + style.horizontalPadding * 2)
                        }
                    }
                } else {
                    precondition(region.requestedWidth == nil)
                    for label in descendants(region).compactMap({ $0 as? NSTextField }).filter({ !$0.isHidden }) {
                        precondition(label.font == .systemFont(ofSize: 15) && label.textColor == .white)
                        precondition(label.cell?.usesSingleLineMode == false && label.cell?.wraps == false)
                        precondition(label.attributedStringValue.attribute(.kern, at: 0, effectiveRange: nil) == nil)
                    }
                }
            }
            near(frames[0].minX, 0)
            if frames.count == 2 {
                near(frames[1].minX - frames[0].maxX, 12)
                if index == 5 { near(frames[0].width, frames[1].width) }
                else if index != 7 { precondition(frames[keys.first == "text" ? 1 : 0].width > 500) }
            }
            print("Text region phase \(index): \(keys), \(frames)")
            fflush(stdout); phase(index + 1, provider, host, foreground: foreground)
        }
    }
    static func main() {
        TBPrepareForImmediateTransitions()
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let provider = AppBar(app: LayoutApp.builtIn[1],
            keyboardButtons: .init(buttons: [KeyboardButton(title: "Find", symbol: "magnifyingglass"),
                KeyboardButton(title: "New", symbol: "plus")]), persistsLayout: false)
        let host = AppBarHost()
        phase(0, provider, host, foreground: foreground); app.run()
    }
}
