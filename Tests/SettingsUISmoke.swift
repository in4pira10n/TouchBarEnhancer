import AppKit

/// Renders only our own offscreen views; never presents windows or captures the screen.
@main @MainActor
struct SettingsUISmoke {
    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    static func render(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        view.window?.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: view.bounds).fill()
            view.displayIgnoringOpacity(view.bounds, in: context)
            NSGraphicsContext.restoreGraphicsState()
        }
        try! bitmap.representation(using: .png, properties: [:])!.write(
            to: URL(fileURLWithPath: ".build/settings-ui/\(name).png"))
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let suite = "TouchBarEnhancer.SettingsUITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try! FileManager.default.createDirectory(atPath: ".build/settings-ui", withIntermediateDirectories: true)
        let store = SettingsStore(defaults: defaults)
        store.chatShortcuts = [ChatShortcut(name: "Project", color: "blue", slot: 1),
            ChatShortcut(name: "设计讨论", color: "teal", slot: 2)]
        store.quickPhrasesByApp[LayoutApp.chatGPTBundleID] = [QuickPhrase(name: "Explain", text: "Please explain this in more detail.")]
        store.rules = [AppRule(bundleID: "com.openai.chat", name: "ChatGPT", mode: .auto),
            AppRule(bundleID: "com.apple.Safari", name: "Safari", mode: .native)]
        store.save()
        let controller = SettingsWindowController(store: store)
        let window = controller.window!
        controller.update(status: "")
        render(window.contentView!, "applications")
        let general = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "general" }!
        let windowTop = window.frame.maxY
        precondition(app.sendAction(general.action!, to: general.target, from: general))
        precondition(abs(window.frame.maxY - windowTop) < 0.5, "Pane resizing must preserve the window top edge")
        render(window.contentView!, "general")
        for id in ["apps", "applications", "general"] {
            let item = window.toolbar!.items.first { $0.itemIdentifier.rawValue == id }!
            precondition(app.sendAction(item.action!, to: item.target, from: item))
            window.contentView!.layoutSubtreeIfNeeded()
            precondition(abs(window.frame.maxY - windowTop) < 0.5)
        }
        precondition(!window.isVisible)
        precondition(window.styleMask.contains(.resizable))
        let appsItem = window.toolbar!.items.first { $0.itemIdentifier.rawValue == "apps" }!
        precondition(app.sendAction(appsItem.action!, to: appsItem.target, from: appsItem))
        window.setContentSize(NSSize(width: 1100, height: 740))
        window.layoutIfNeeded()
        precondition(window.contentView!.bounds.width == 1100)
        render(window.contentView!, "apps-resized")
        precondition(window.contentMinSize.width >= 760 && window.contentMinSize.height >= 520)

        let pane = AppsPane(store: store, chatGPTConnectionReader: {
            ChatGPTAdapter.Snapshot(trusted: false, running: true, entries: [])
        })
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false)
        host.contentView = pane
        store.onChange = { [weak pane] in pane?.refresh() }
        render(pane, "apps-chatgpt")
        let allCategories = descendants(pane).compactMap { $0 as? ShortcutCategoryEditor }
        precondition(allCategories.contains { $0.kind == .keyboard })
        let categories = allCategories.filter { $0.kind != .keyboard }
        precondition(categories.count == 2)
        precondition(!descendants(pane).compactMap { $0 as? NSButton }.contains { $0.title.hasPrefix("Save ") })
        var fieldOrigins: [CGFloat] = []
        for category in categories {
            if category.kind == .phrases {
                let title = descendants(category).compactMap { $0 as? NSButton }.first { $0.title == "Quick Phrases" }!
                title.performClick(nil)
            }
            pane.layoutSubtreeIfNeeded()
            let table = descendants(category).compactMap { $0 as? NSTableView }.first!
            let titleCell = table.view(atColumn: 0, row: 0, makeIfNecessary: true)!
            let fields = descendants(category).compactMap { $0 as? NSTextField }
            let name = descendants(titleCell).compactMap { $0 as? ComponentInlineTextField }.first!
            let symbol = fields.first { $0.placeholderString == (category.kind == .chats ? "bubble.left" : "text.bubble") }!
            let error = fields.first { $0.accessibilityIdentifier() == "shortcutValidation" }!
            let grid = descendants(category).compactMap { $0 as? NSGridView }.first { $0.numberOfRows > 3 }!
            let initial = name.stringValue
            name.stringValue = ""
            category.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
            precondition(error.stringValue == "Enter a title." && !grid.row(at: grid.numberOfRows - 1).isHidden)
            precondition(category.kind == .chats ? store.chatShortcuts[0].name == initial : store.quickPhrasesByApp[LayoutApp.chatGPTBundleID]![0].name == initial)
            name.stringValue = "Updated \(initial)"
            category.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: name))
            precondition(error.stringValue.isEmpty && grid.row(at: grid.numberOfRows - 1).isHidden)
            precondition(category.kind == .chats ? SettingsStore(defaults: defaults).chatShortcuts[0].name == name.stringValue
                : SettingsStore(defaults: defaults).quickPhrasesByApp[LayoutApp.chatGPTBundleID]![0].name == name.stringValue)
            let goodSymbol = symbol.stringValue
            symbol.stringValue = "invalid.symbol.for.testing"
            category.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: symbol))
            precondition(!error.stringValue.isEmpty)
            symbol.stringValue = goodSymbol
            category.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: symbol))
            precondition(error.stringValue.isEmpty)
            if category.kind == .chats {
                let color = fields.first { $0.placeholderString == "blue or #0088FF" }!
                let goodColor = color.stringValue
                color.stringValue = "invalid color"
                category.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: color))
                precondition(!error.stringValue.isEmpty && store.chatShortcuts[0].color == goodColor)
                color.stringValue = goodColor
                category.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: color))
            } else {
                let text = descendants(category).compactMap { $0 as? NSTextView }.first!
                text.string = "Updated content\n第二行"
                category.textDidChange(Notification(name: NSText.didChangeNotification, object: text))
                precondition(SettingsStore(defaults: defaults).quickPhrasesByApp[LayoutApp.chatGPTBundleID]![0].text == text.string)
            }
            pane.layoutSubtreeIfNeeded()
            let symbolFrame = symbol.convert(symbol.bounds, to: pane)
            precondition(symbolFrame.width > 200 && !symbol.hasAmbiguousLayout)
            let liveTitle = table.view(atColumn: 0, row: 0, makeIfNecessary: true)!
            precondition(descendants(liveTitle).compactMap { $0 as? ComponentInlineTextField }.allSatisfy { $0.bounds.width > 60 })
            fieldOrigins.append(symbolFrame.minX)
        }
        precondition(abs(fieldOrigins[0] - fieldOrigins[1]) < 0.5, "Categories must share form alignment")
        let detailScroll = pane.subviews.compactMap { $0 as? NSScrollView }.first!
        render(detailScroll.documentView!, "apps-expanded")
        categories[1].scrollToVisible(categories[1].bounds)
        render(pane, "apps-phrases")
        let text = descendants(categories[1]).compactMap { $0 as? NSTextView }.first!
        precondition(text.bounds.height >= 90 && text.bounds.width > 200)
        host.appearance = NSAppearance(named: .aqua)
        render(pane, "apps-phrases-light")
        let chatTable = descendants(categories[0]).compactMap { $0 as? NSTableView }.first!
        let chatCell = chatTable.view(atColumn: 0, row: 0, makeIfNecessary: true)!
        let chatName = descendants(chatCell).compactMap { $0 as? ComponentInlineTextField }.first!
        chatName.scrollToVisible(chatName.bounds)
        precondition(host.makeFirstResponder(chatName))
        let fieldEditor = chatName.currentEditor() as! NSTextView
        fieldEditor.selectAll(nil)
        fieldEditor.insertText("Live focus update", replacementRange: fieldEditor.selectedRange())
        precondition(store.chatShortcuts[0].name == "Live focus update")
        precondition(host.firstResponder === fieldEditor && chatName.currentEditor() === fieldEditor,
            "Immediate saving must preserve the active field editor")
        host.endEditing(for: nil)
        let sidebar = descendants(pane).compactMap { $0 as? NSTableView }.first {
            $0.dataSource === pane
        }!
        sidebar.selectRowIndexes([1], byExtendingSelection: false)
        render(pane, "apps-generic")
        precondition(!host.isVisible && !window.isVisible)
        precondition(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        print("Settings UI checks passed: no Save buttons, live persistence, inline validation, aligned forms, phrase content, field editor focus, offscreen renders, no activation")
    }
}
