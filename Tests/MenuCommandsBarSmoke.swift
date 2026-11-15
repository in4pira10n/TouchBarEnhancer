import AppKit
import ApplicationServices
import TouchBarBridge

/// Signed, nonactivating fixture. Reads real menus but never executes them.
@main @MainActor
struct MenuCommandsBarSmoke {
    static let buttons: [KeyboardButton] = [
        .init(title: "Sidebar", symbol: "sidebar.left", fillWidth: .init(relative: 6),
              menuCommand: .init(title: "Show Sidebar", parentPath: "View")),
        .init(title: "Export…", symbol: "square.and.arrow.up", color: "blue", fillWidth: .init(relative: 12),
              menuCommand: .init(title: "Export…", parentPath: "File")),
        .init(title: "文档", symbol: "doc", fillWidth: .init(mode: .fixed, fixed: 70),
              menuCommand: .init(title: "文档", parentPath: "File → Recent"))]
    static let layouts = [["menu"], ["menu", "keyboard"], ["keyboard", "menu"], ["menu", "phrases"]]
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func check(_ phase: Int, provider: AppBar, host: AppBarHost, foreground: pid_t?) {
        guard layouts.indices.contains(phase) else {
            _ = TBDismiss(host.bar)
            precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
            print("Menu commands hardware checks passed: real menu read, shared button rendering, mixed widths, peer allocation, 8/12pt gaps, icon/text overrides, scrolling alignment, no activation or menu execution")
            fflush(stdout); NSApp.terminate(nil); return
        }
        let configuration = KeyboardButtonsConfiguration(buttons: buttons)
        provider.configureMenuButtons(configuration)
        provider.configureComponentPresentations(["menu": .init(layout: phase == 3 ? .scrolling : .fill, alignment: .right)])
        provider.configureComponentDisplayModes(["menu": phase == 2 ? .iconOnly : .iconAndText])
        provider.bar.defaultItemIdentifiers = layouts[phase].map(AppBar.itemID)
        host.display(provider)
        precondition(TBPresent(host.bar))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            var regions: [NSRect] = []
            for suffix in layouts[phase] {
                let id = AppBar.itemID(suffix)
                let item = (host.bar.templateItems.first { $0.identifier == id }
                    ?? host.content.groupTouchBar.item(forIdentifier: id)) as! NSCustomTouchBarItem
                let wrapper = item.view as! TouchBarComponentView
                let region = wrapper.content as! ScrollingComponentRegion
                precondition(region.window != nil && !region.isHiddenOrHasHiddenAncestor)
                region.layoutSubtreeIfNeeded()
                regions.append(region.convert(region.bounds, to: nil))
                if suffix == "menu" {
                    let scrubber = descendants(region).compactMap { $0 as? NSScrubber }.first!
                    let frames = (0..<buttons.count).map { scrubber.scrubberLayout.layoutAttributesForItem(at: $0)!.frame }
                    for pair in zip(frames, frames.dropFirst()) { precondition(abs(pair.1.minX - pair.0.maxX - 8) < 1) }
                    if phase < 3 {
                        let remaining = region.bounds.width - 70 - 16
                        precondition(abs(frames[0].width - remaining / 3) < 1)
                        precondition(abs(frames[1].width - remaining * 2 / 3) < 1)
                        precondition(abs(frames[2].width - 70) < 1)
                    }
                    for index in buttons.indices {
                        let view = scrubber.dataSource!.scrubber(scrubber, viewForItemAt: index)
                        let label = descendants(view).compactMap { $0 as? NSTextField }.first!
                        precondition(label.stringValue == buttons[index].title && label.isHidden == (phase == 2))
                    }
                }
            }
            precondition(abs(regions[0].minX) < 1)
            precondition(regions.allSatisfy { abs($0.width - regions[0].width) < 1 })
            for pair in zip(regions, regions.dropFirst()) { precondition(abs(pair.1.minX - pair.0.maxX - 12) < 1) }
            print("Menu commands hardware phase \(phase): \(regions)"); fflush(stdout)
            check(phase + 1, provider: provider, host: host, foreground: foreground)
        }
    }
    static func main() {
        TBPrepareForImmediateTransitions()
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if AXIsProcessTrusted(), let foreground {
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = MenuCommandSender.snapshot(pid: foreground)
            print("Read-only foreground menu snapshot: complete=\(snapshot.complete), entries=\(snapshot.entries.count), enabled=\(snapshot.entries.filter(\.enabled).count), elapsed=\(ProcessInfo.processInfo.systemUptime - start), error=\(snapshot.error ?? "none")")
            if snapshot.complete && snapshot.error == nil && !snapshot.entries.isEmpty {
                precondition(snapshot.entries.contains(where: \.enabled), "The live reader should retain enabled menu commands")
                let entry = snapshot.entries.first(where: \.enabled)!
                let path = Array(entry.path.dropLast())
                let targeted = MenuCommandSender.snapshot(pid: foreground, parentPath: path)
                let binding = MenuCommandBinding(title: entry.title, parentPath: path.joined(separator: " → "))
                guard case .success(let resolved) = MenuCommandSender.resolve(binding, in: targeted) else {
                    preconditionFailure("A real menu entry must resolve through its exact path")
                }
                precondition(resolved.path == entry.path)
            }
        }
        let provider = AppBar(app: LayoutApp.enhancedBar, phrases: [.init(name: "Quick Phrase", text: "Fixture")],
            keyboardButtons: .init(buttons: [.init(title: "Keyboard", symbol: "keyboard")]),
            menuButtons: .init(buttons: buttons), persistsLayout: false)
        let host = AppBarHost()
        check(0, provider: provider, host: host, foreground: foreground)
        application.run()
    }
}
