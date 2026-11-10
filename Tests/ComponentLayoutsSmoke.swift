import AppKit

@main @MainActor
struct ComponentLayoutsSmoke {
    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory); application.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suite = "TouchBarEnhancer.ComponentLayouts.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        let app = LayoutApp.builtIn[0]
        let keys = ["chatgpt.chats", "phrases", "keyboard", "text"]
        store.chatShortcuts = [ChatShortcut(name: "Chat", slot: 1), ChatShortcut(name: "另一个聊天", slot: 2)]
        store.quickPhrasesByApp[app.bundleID] = [QuickPhrase(name: "Phrase", text: "One"), QuickPhrase(name: "Short", text: "Two")]
        store.keyboardButtons[app.bundleID] = .init(buttons: [KeyboardButton(title: "One"), KeyboardButton(title: "Two")], layout: .fill, alignment: .right)
        store.textComponents[app.bundleID] = [TextComponentItem(text: "Plain text"), TextComponentItem(text: "文字")]
        precondition(store.presentation(for: "keyboard", app: app.bundleID) == .init(layout: .fill, alignment: .right))
        let provider = AppBar(app: app, shortcuts: store.chatShortcuts, phrases: store.quickPhrasesByApp[app.bundleID]!,
            keyboardButtons: store.keyboardButtons[app.bundleID]!, textItems: store.textComponents[app.bundleID]!, persistsLayout: false)
        store.onChange = { provider.configureComponentPresentations(store.componentPresentations[app.bundleID] ?? [:]) }
        let editors: [NSView] = ShortcutCategoryEditor.Kind.allForTesting.map { ShortcutCategoryEditor(store: store, kind: $0, appBundleID: app.bundleID) }
            + [TextComponentEditor(store: store, appBundleID: app.bundleID)]
        for (index, key) in keys.enumerated() {
            let item = provider.bar.item(forIdentifier: AppBar.itemID(key)) as! NSCustomTouchBarItem
            let wrapper = item.view as! TouchBarComponentView
            let region = wrapper.content as! ScrollingComponentRegion
            let scrubber = descendants(region).compactMap { $0 as? NSScrubber }.first!
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = wrapper
            let layout = descendants(editors[index]).compactMap { $0 as? NSPopUpButton }.first {
                $0.accessibilityIdentifier() == (key == "keyboard" ? "keyboardLayout" : "componentLayout.\(key)")
            }!
            let alignment = descendants(editors[index]).compactMap { $0 as? NSPopUpButton }.first {
                $0.accessibilityIdentifier() == (key == "keyboard" ? "keyboardAlignment" : "componentAlignment.\(key)")
            }!
            for mode in ComponentLayout.allCases {
                layout.selectItem(withTitle: mode.rawValue); layout.sendAction(layout.action, to: layout.target)
                for align in ScrollingComponentAlignment.allCases {
                    alignment.selectItem(withTitle: align.rawValue); alignment.sendAction(alignment.action, to: alignment.target)
                    wrapper.layoutSubtreeIfNeeded(); region.layoutSubtreeIfNeeded()
                    let frames = (0..<scrubber.numberOfItems).map { scrubber.scrubberLayout.layoutAttributesForItem(at: $0)!.frame }
                    precondition(frames.count == 2)
                    precondition(abs(frames[1].minX - frames[0].maxX - 8) < 1)
                    if mode == .fill {
                        precondition(abs(frames[0].width - frames[1].width) < 1)
                        precondition(abs(scrubber.frame.width - region.bounds.width) < 1)
                        precondition(abs(frames[0].minX) < 1 && abs(frames[1].maxX - region.bounds.width) < 1)
                    } else {
                        let remaining = region.bounds.width - scrubber.frame.width
                        let expected: CGFloat = align == .left ? 0 : (align == .center ? remaining / 2 : remaining)
                        precondition(remaining > 0 && abs(scrubber.frame.minX - expected) < 1)
                    }
                    precondition(SettingsStore(defaults: defaults).presentation(for: key, app: app.bundleID) == .init(layout: mode, alignment: align))
                }
            }
            window.setContentSize(NSSize(width: 55, height: 30)); wrapper.layoutSubtreeIfNeeded()
            precondition(scrubber.bounds.width <= 55 && scrubber.bounds.width > 0)
            precondition(!window.isVisible)
        }
        let restored = SettingsStore(defaults: defaults)
        precondition(restored.componentPresentations[app.bundleID]?.count == 4)
        precondition(restored.componentPresentations["test.other-app"] == nil)
        precondition(restored.chatShortcuts == store.chatShortcuts && restored.quickPhrasesByApp == store.quickPhrasesByApp)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        print("Component layout checks passed: all four categories, native Settings actions, legacy keyboard fallback, per-app persistence, live fill/scrolling, three alignments, equal item widths, 8pt gaps, narrow viewports, no activation")
    }
}

private extension ShortcutCategoryEditor.Kind {
    static var allForTesting: [Self] { [.chats, .phrases, .keyboard] }
}
