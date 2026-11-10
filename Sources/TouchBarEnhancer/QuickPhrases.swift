import AppKit
import ApplicationServices

struct QuickPhrase: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var symbol = "text.bubble"
    var imageData: Data?
    var text: String
    var displayModeOverride: ComponentDisplayMode?

    var scrollingItem: ScrollingComponentItem {
        ScrollingComponentItem(title: name, symbol: symbol, imageData: imageData, background: .standard,
            accessibilityLabel: "Paste \(name)", toolTip: "Paste \(name)", displayModeOverride: displayModeOverride)
    }

    var displayShortcut: ChatShortcut {
        ChatShortcut(id: id, name: name, symbol: symbol, imageData: imageData, color: "#363636",
            displayModeOverride: displayModeOverride)
    }
}

/// Universal component: no ChatGPT adapter or app-specific commands required.
/// Each app has its own phrase data; each Touch Bar owns its own presentation.
@MainActor
final class QuickPhrasesComponent {
    let scroller = ShortcutScroller(label: "Quick Phrases")
    private var phrases: [QuickPhrase] = []
    var onError: ((String) -> Void)?

    init(targetBundleID: String, phrases: [QuickPhrase]) {
        scroller.onSelect = { [weak self] index in
            guard let self, self.phrases.indices.contains(index) else { return }
            if let error = QuickPhrasePaster.paste(self.phrases[index].text, into: targetBundleID) {
                self.onError?(error)
            }
        }
        configure(phrases)
    }

    func configure(_ phrases: [QuickPhrase]) {
        self.phrases = phrases
        scroller.configure(phrases.map(\.scrollingItem))
    }
}

/// Pastes into the frontmost app without activating it or sending Return.
@MainActor
enum QuickPhrasePaster {
    static func paste(_ text: String, into bundleID: String) -> String? {
        guard !text.isEmpty else { return "Enter some text for this phrase first." }
        guard AXIsProcessTrusted() else { return "Allow TouchBarEnhancer in Accessibility first." }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return "Bring the target app to the front and focus an input field before pasting."
        }
        return postPaste(text, to: app.processIdentifier)
    }

    // Route the standard Paste command to the existing first responder. Web
    // editors and custom controls need not expose AXFocusedUIElement/AXEditable.
    // The caller validates the target app; recheck its PID before any side effect.
    static func postPaste(_ text: String, to processID: pid_t) -> String? {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false) else {
            return "Could not create the Paste shortcut."
        }
        guard !text.isEmpty, NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
            return "The active app changed. Focus the input field and try again."
        }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return "Could not copy the phrase to the clipboard." }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(processID)
        up.postToPid(processID)
        return nil
    }
}
