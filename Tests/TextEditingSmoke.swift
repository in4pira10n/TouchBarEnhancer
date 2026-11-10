import AppKit

@main
@MainActor
struct TextEditingSmoke {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appRoot = NSMenuItem()
        appRoot.submenu = NSMenu(title: "TouchBarEnhancer")
        mainMenu.addItem(appRoot)
        let root = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        root.submenu = ApplicationMenus.editMenu()
        mainMenu.addItem(root)
        app.mainMenu = mainMenu
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            checkEditing(app: app, mainMenu: mainMenu)
            app.terminate(nil)
        }
        app.run()
    }

    static func checkEditing(app: NSApplication, mainMenu: NSMenu) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let field = NSTextField(frame: NSRect(x: 20, y: 30, width: 260, height: 24))
        field.stringValue = "Original chat"
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        precondition(window.makeFirstResponder(field))
        let editor = field.currentEditor() as! NSTextView
        editor.allowsUndo = true
        // In unattended sessions key-window activation may be denied. Exercise
        // menu shortcuts with the field editor supplied explicitly as the target.
        for item in mainMenu.items.first(where: { $0.title == "Edit" })!.submenu!.items where !item.isSeparatorItem {
            item.target = ["Undo", "Redo"].contains(item.title) ? editor.undoManager : editor
        }
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            let items = saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(items)
            window.orderOut(nil)
        }
        func key(_ character: String, shift: Bool = false) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shift ? [.command, .shift] : [.command], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0)!
            precondition(mainMenu.performKeyEquivalent(with: event), "Unhandled shortcut: \(character)")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        key("a")
        precondition(editor.selectedRange() == NSRange(location: 0, length: 13))
        key("c")
        precondition(pasteboard.string(forType: .string) == "Original chat", "Clipboard: \(String(describing: pasteboard.string(forType: .string))); selection: \(editor.selectedRange()); key: \(window.isKeyWindow); responder: \(String(describing: window.firstResponder))")
        pasteboard.clearContents()
        pasteboard.setString("Pasted chat", forType: .string)
        key("v")
        precondition(editor.string == "Pasted chat")
        key("a")
        key("x")
        precondition(editor.string.isEmpty)
        precondition(pasteboard.string(forType: .string) == "Pasted chat")
        key("v")
        precondition(editor.string == "Pasted chat")
        print("Text editing menu checks passed: select all, copy, paste, cut (explicit editor target)")
    }
}
