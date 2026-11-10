import AppKit

/// Keep system-modal presentation alive while replacing only its nested app layout.
@MainActor
final class AppBarHost: NSObject {
    let bar = NSTouchBar()
    let content = NSGroupTouchBarItem(identifier: .init("local.starfruit.TouchBarEnhancer.host.content"))
    private let escape = NSCustomTouchBarItem(identifier: AppBar.itemID("escape"))
    private weak var displayedProvider: AppBar?
    private var displayedIdentifiers: [NSTouchBarItem.Identifier] = []
    private var componentViews: [TouchBarComponentView] = []
    private var sizingConstraints: [NSLayoutConstraint] = []

    override init() {
        super.init()
        let spacer = NSView()
        spacer.widthAnchor.constraint(equalToConstant: 1).isActive = true
        escape.view = spacer
        bar.templateItems = [content, escape]
        bar.defaultItemIdentifiers = [content.identifier, .flexibleSpace]
        bar.escapeKeyReplacementItemIdentifier = escape.identifier
        NotificationCenter.default.addObserver(self, selector: #selector(sizeScrollingComponents),
            name: NSWindow.didResizeNotification, object: nil)
    }

    func display(_ provider: AppBar) {
        let identifiers = provider.bar.itemIdentifiers.filter { provider.bar.customizationAllowedItemIdentifiers.contains($0) }
        guard displayedProvider !== provider || displayedIdentifiers != identifiers else { return }
        NSLayoutConstraint.deactivate(sizingConstraints)
        sizingConstraints.removeAll()
        componentViews.removeAll()
        displayedProvider = provider
        displayedIdentifiers = identifiers
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            let body = NSTouchBar()
            body.defaultItemIdentifiers = identifiers
            body.delegate = provider
            // Respect the user's order. Whichever control leads the layout
            // occupies the replacement slot, without an invisible Escape gap.
            if let first = identifiers.first, first != .flexibleSpace,
               let leading = provider.touchBar(body, makeItemForIdentifier: first) {
                body.defaultItemIdentifiers.removeFirst()
                bar.templateItems = [content, leading]
                bar.escapeKeyReplacementItemIdentifier = first
            } else {
                bar.templateItems = [content, escape]
                bar.escapeKeyReplacementItemIdentifier = escape.identifier
            }
            bar.defaultItemIdentifiers = body.defaultItemIdentifiers.isEmpty ? [] : [content.identifier]
            content.groupTouchBar = body
            componentViews = identifiers.compactMap { identifier in
                let item = bar.templateItems.first { $0.identifier == identifier }
                    ?? body.item(forIdentifier: identifier)
                return (item as? NSCustomTouchBarItem)?.view as? TouchBarComponentView
            }
            for component in componentViews {
                (component.content as? ScrollingComponentRegion)?.onWindowChange = { [weak self] in
                    DispatchQueue.main.async { self?.sizeScrollingComponents() }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.sizeScrollingComponents() }
        }
    }

    @objc private func sizeScrollingComponents() {
        let regions = componentViews.compactMap { $0.content as? ScrollingComponentRegion }
        guard let first = regions.first, let window = first.window,
              regions.allSatisfy({ $0.window === window }),
              componentViews.allSatisfy({ $0.window === window }) else { return }
        NSLayoutConstraint.deactivate(sizingConstraints)
        sizingConstraints = regions.dropFirst().map { $0.widthAnchor.constraint(equalTo: first.widthAnchor) }
        if !displayedIdentifiers.contains(.flexibleSpace) {
            let fixed = componentViews.reduce(CGFloat.zero) { total, view in
                total + view.leadingSpacing + (view.content is ScrollingComponentRegion ? 0 : view.content.fittingSize.width)
            }
            let nativeGaps = CGFloat(max(0, componentViews.count - 1)) * 8
            let count = CGFloat(regions.count)
            // The system owns the presentation window's width. Constraining its
            // content root would let Auto Layout enlarge the root past that area.
            let scale = max(1, window.backingScaleFactor)
            // AppKit rounds item frames to backing pixels. Rounding three equal
            // widths upward can overflow the bar and hide its final component.
            let availableWidth = (window.frame.width - fixed - nativeGaps) / count
            let width = max(ShortcutScroller.minimumWidth, floor(availableWidth * scale) / scale)
            regions.forEach { $0.preferredWidth = width }
            sizingConstraints = regions.map { $0.widthAnchor.constraint(equalToConstant: width) }
        }
        // AppKit otherwise expands the last scrubber and may detach another
        // item. Keep these equal sizes exact after clamping to the minimum.
        sizingConstraints.forEach { $0.priority = .required }
        NSLayoutConstraint.activate(sizingConstraints)
    }
}

struct LayoutApp: Codable, Equatable {
    var bundleID: String
    var name: String

    static var chatGPTBundleID: String {
        Bundle(url: URL(fileURLWithPath: "/Applications/ChatGPT.app"))?.bundleIdentifier ?? "com.openai.chat"
    }
    var isChatGPT: Bool { [Self.chatGPTBundleID, "com.openai.chat"].contains(bundleID) }

    static var builtIn: [LayoutApp] { [
        LayoutApp(bundleID: chatGPTBundleID, name: "ChatGPT"),
        LayoutApp(bundleID: "com.apple.Safari", name: "Safari"),
        LayoutApp(bundleID: "com.apple.Music", name: "Music"),
        LayoutApp(bundleID: "com.apple.finder", name: "Finder")
    ] }
}

@MainActor
final class AppBar: NSObject, NSTouchBarDelegate {
    static let componentDescriptions = [
        ("Keyboard Shortcuts", "Custom shortcut buttons, scrolling or equal width."),
        ("Quick Phrases", "Scrollable phrases that paste into the focused input field."),
        ("Text", "Plain text with system typography and optional styling."),
        ("Space", "Keep controls separated as space changes.")
    ]

    let app: LayoutApp
    let bar = NSTouchBar()
    let usesChatGPTControls: Bool
    private let chatGPT: ChatGPTAdapter?
    private var lastChatStatusUpdate = Date.distantPast
    // A view can belong to only one Touch Bar. Preview and modal presentation
    // share configuration, but each bar owns its own controls.
    private let chatStrips = NSMapTable<NSTouchBar, ChatGPTStrip>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var activeChatStrips: [ChatGPTStrip] {
        chatStrips.objectEnumerator()?.allObjects as? [ChatGPTStrip] ?? []
    }
    private var latestChatGPTStatus: ChatGPTAdapter.Snapshot?
    private var layoutObservation: NSKeyValueObservation?
    private var previewComponents: [NSTouchBarItem.Identifier: TouchBarComponentView] = [:]
    private var previewWidthConstraints: [NSLayoutConstraint] = []
    private var previewWidthContext: [ObjectIdentifier] = []
    private var shortcuts: [ChatShortcut]
    private var phrases: [QuickPhrase]
    private var keyboardConfiguration: KeyboardButtonsConfiguration
    private var componentDisplayModes: [String: ComponentDisplayMode]
    private var componentPresentations: [String: ComponentPresentation]
    private var textItems: [TextComponentItem]
    private let textComponents = NSMapTable<NSTouchBar, TextComponent>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var activeTextComponents: [TextComponent] {
        textComponents.objectEnumerator()?.allObjects as? [TextComponent] ?? []
    }
    private let keyboardComponents = NSMapTable<NSTouchBar, KeyboardButtonsComponent>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var activeKeyboardComponents: [KeyboardButtonsComponent] {
        keyboardComponents.objectEnumerator()?.allObjects as? [KeyboardButtonsComponent] ?? []
    }
    private let phraseComponents = NSMapTable<NSTouchBar, QuickPhrasesComponent>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private var activePhraseComponents: [QuickPhrasesComponent] {
        phraseComponents.objectEnumerator()?.allObjects as? [QuickPhrasesComponent] ?? []
    }

    static func itemID(_ suffix: String) -> NSTouchBarItem.Identifier {
        .init("local.starfruit.TouchBarEnhancer.component.\(suffix)")
    }

    init(app: LayoutApp, chatGPTControlsEnabled: Bool = true, shortcuts: [ChatShortcut] = ChatShortcut.initial,
         phrases: [QuickPhrase] = [], keyboardButtons: KeyboardButtonsConfiguration = .init(),
         componentDisplayModes: [String: ComponentDisplayMode] = [:],
         componentPresentations: [String: ComponentPresentation] = [:],
         textItems: [TextComponentItem] = TextComponentItem.initial, persistsLayout: Bool = true) {
        self.app = app
        self.shortcuts = shortcuts
        self.phrases = phrases
        self.keyboardConfiguration = keyboardButtons
        self.componentDisplayModes = componentDisplayModes
        self.componentPresentations = componentPresentations
        self.textItems = textItems
        usesChatGPTControls = app.isChatGPT && chatGPTControlsEnabled
        chatGPT = app.isChatGPT && chatGPTControlsEnabled ? ChatGPTAdapter(bundleID: app.bundleID) : nil
        super.init()
        bar.delegate = self
        // Keep the original generic layout intact when opting into the dedicated adapter.
        bar.customizationIdentifier = persistsLayout ? .init(usesChatGPTControls
            ? "local.starfruit.TouchBarEnhancer.layout.chatgpt.v3.\(app.bundleID)"
            : "local.starfruit.TouchBarEnhancer.layout.v1.\(app.bundleID)") : nil
        // Normal app controls don't need a replacement Escape slot. The modal
        // host handles its own close-button replacement separately.
        bar.escapeKeyReplacementItemIdentifier = nil
        bar.defaultItemIdentifiers = [Self.itemID("phrases"), .flexibleSpace]
        bar.customizationAllowedItemIdentifiers = [Self.itemID("phrases"), Self.itemID("keyboard"), Self.itemID("text"), .flexibleSpace]
        if usesChatGPTControls {
            bar.escapeKeyReplacementItemIdentifier = nil
            bar.defaultItemIdentifiers = [Self.itemID("chatgpt.sidebar"), Self.itemID("chatgpt.chats"), Self.itemID("chatgpt.terminal")]
            bar.customizationAllowedItemIdentifiers = bar.defaultItemIdentifiers + [Self.itemID("phrases"), Self.itemID("keyboard"), Self.itemID("text"), .flexibleSpace]
        }
        layoutObservation = bar.observe(\.itemIdentifiers, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refreshPreviewSpacing() }
        }
    }

    static func chatID(_ command: ChatGPTCommand) -> NSTouchBarItem.Identifier {
        itemID("chatgpt.\(command.rawValue)")
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        if identifier == Self.itemID("text") {
            let component: TextComponent
            if let existing = textComponents.object(forKey: touchBar) { component = existing }
            else {
                component = TextComponent(items: textItems)
                component.scroller.configurePresentation(presentation(for: "text"))
                textComponents.setObject(component, forKey: touchBar)
            }
            item.customizationLabel = "Text"
            component.scroller.scrollRegion.preferredWidth = scrollingPreferredWidth
            item.view = wrapped(component.scroller.scrollRegion, identifier: identifier, in: touchBar)
            return item
        }
        if identifier == Self.itemID("keyboard") {
            let component: KeyboardButtonsComponent
            if let existing = keyboardComponents.object(forKey: touchBar) { component = existing }
            else {
                component = KeyboardButtonsComponent(targetBundleID: app.bundleID, configuration: keyboardConfiguration)
                component.scroller.displayMode = componentDisplayModes["keyboard"] ?? .iconAndText
                component.scroller.configurePresentation(presentation(for: "keyboard"))
                component.onError = { error in
                    let alert = NSAlert(); alert.messageText = "Keyboard Shortcut Unavailable"; alert.informativeText = error
                    NSApp.activate(ignoringOtherApps: true); alert.runModal()
                }
                keyboardComponents.setObject(component, forKey: touchBar)
            }
            item.customizationLabel = "Keyboard Shortcuts"
            component.region.preferredWidth = scrollingPreferredWidth
            item.view = wrapped(component.region, identifier: identifier, in: touchBar)
            return item
        }
        if identifier == Self.itemID("phrases") {
            let component: QuickPhrasesComponent
            if let existing = phraseComponents.object(forKey: touchBar) { component = existing }
            else {
                component = QuickPhrasesComponent(targetBundleID: app.bundleID, phrases: phrases)
                component.scroller.displayMode = componentDisplayModes["phrases"] ?? .iconAndText
                component.scroller.configurePresentation(presentation(for: "phrases"))
                component.onError = { error in
                    let alert = NSAlert(); alert.messageText = "Quick Phrase Unavailable"; alert.informativeText = error
                    NSApp.activate(ignoringOtherApps: true); alert.runModal()
                }
                phraseComponents.setObject(component, forKey: touchBar)
            }
            item.customizationLabel = "Quick Phrases"
            component.scroller.scrollRegion.preferredWidth = scrollingPreferredWidth
            item.view = wrapped(component.scroller.scrollRegion, identifier: identifier, in: touchBar)
            return item
        }
        if ["chatgpt.sidebar", "chatgpt.chats", "chatgpt.terminal"].map({ Self.itemID($0) }).contains(identifier), let chatGPT {
            let strip: ChatGPTStrip
            if let existing = chatStrips.object(forKey: touchBar) {
                strip = existing
            } else {
                strip = ChatGPTStrip(adapter: chatGPT, shortcuts: shortcuts)
                strip.scroller.displayMode = componentDisplayModes["chatgpt.chats"] ?? .iconAndText
                strip.scroller.configurePresentation(presentation(for: "chatgpt.chats"))
                chatStrips.setObject(strip, forKey: touchBar)
                if let latestChatGPTStatus { strip.update(latestChatGPTStatus) }
            }
            switch identifier {
            case Self.itemID("chatgpt.sidebar"): item.customizationLabel = "Sidebar"; item.view = strip.sidebarContainer
            case Self.itemID("chatgpt.terminal"): item.customizationLabel = "Terminal"; item.view = strip.terminalContainer
            default: item.customizationLabel = "Chat Shortcuts"; item.view = strip.scrollRegion
            }
            strip.scrollRegion.preferredWidth = scrollingPreferredWidth
            item.view = wrapped(item.view, identifier: identifier, in: touchBar)
            return item
        }
        // Retired demo identifiers may still be present in saved AppKit layouts.
        // Returning nil prevents them from resurfacing without resetting valid controls.
        guard identifier == Self.itemID("escape") else { return nil }
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        item.view = view
        return item
    }

    private func wrapped(_ view: NSView, identifier: NSTouchBarItem.Identifier, in touchBar: NSTouchBar) -> TouchBarComponentView {
        let index = bar.itemIdentifiers.firstIndex(of: identifier) ?? 0
        let wrapper = TouchBarComponentView(content: view, leadingSpacing: index == 0 ? 0 : 4)
        if touchBar === bar {
            previewComponents[identifier] = wrapper
            wrapper.onHierarchyChange = { [weak self] in self?.refreshPreviewWidths() }
        }
        return wrapper
    }

    private func refreshPreviewSpacing() {
        for (identifier, view) in previewComponents {
            let index = bar.itemIdentifiers.firstIndex(of: identifier) ?? 0
            view.leadingSpacing = index == 0 ? 0 : 4
        }
        _ = scrollingPreferredWidth
        refreshPreviewWidths()
    }

    private func refreshPreviewWidths() {
        let wrappers = bar.itemIdentifiers.compactMap { previewComponents[$0] }.filter { $0.content is ScrollingComponentRegion }
        var ancestor = wrappers.first?.superview
        while let candidate = ancestor, !wrappers.allSatisfy({ $0.isDescendant(of: candidate) }) { ancestor = candidate.superview }
        guard wrappers.count > 1, let ancestor else {
            if !previewWidthConstraints.isEmpty { NSLayoutConstraint.deactivate(previewWidthConstraints) }
            previewWidthConstraints.removeAll(); previewWidthContext.removeAll(); return
        }
        let context = [ObjectIdentifier(ancestor)] + wrappers.map(ObjectIdentifier.init)
        guard previewWidthContext != context else { return }
        NSLayoutConstraint.deactivate(previewWidthConstraints)
        previewWidthContext = context
        let first = wrappers[0].content
        previewWidthConstraints = wrappers.dropFirst().map { $0.content.widthAnchor.constraint(equalTo: first.widthAnchor) }
        NSLayoutConstraint.activate(previewWidthConstraints)
    }

    private var scrollingPreferredWidth: CGFloat {
        let scrollingIDs = [Self.itemID("phrases"), Self.itemID("chatgpt.chats"), Self.itemID("keyboard"), Self.itemID("text")]
        let count = max(1, bar.itemIdentifiers.filter { scrollingIDs.contains($0) }.count)
        let boundaries = max(0, bar.itemIdentifiers.filter { $0 != .flexibleSpace }.count - 1)
        let width = max(ShortcutScroller.minimumWidth,
            (ScrollingComponentStyle.preferredWidth - CGFloat(count - 1) * ChatGPTStrip.blockGap
                - CGFloat(boundaries) * 4) / CGFloat(count))
        activeChatStrips.forEach { $0.scrollRegion.preferredWidth = width }
        activePhraseComponents.forEach { $0.scroller.scrollRegion.preferredWidth = width }
        activeKeyboardComponents.forEach { $0.region.preferredWidth = width }
        activeTextComponents.forEach { $0.scroller.scrollRegion.preferredWidth = width }
        return width
    }

    func updateChatGPTStatus(force: Bool = false) {
        guard let chatGPT, force || Date().timeIntervalSince(lastChatStatusUpdate) >= 2 else { return }
        lastChatStatusUpdate = Date()
        let state = chatGPT.snapshot()
        applyChatGPTStatus(state)
    }

    func applyChatGPTStatus(_ state: ChatGPTAdapter.Snapshot) {
        latestChatGPTStatus = state
        activeChatStrips.forEach { $0.update(state) }
    }

    func configureChats(_ shortcuts: [ChatShortcut]) {
        self.shortcuts = shortcuts
        activeChatStrips.forEach { $0.configure(shortcuts) }
    }

    func configurePhrases(_ phrases: [QuickPhrase]) {
        guard self.phrases != phrases else { return }
        self.phrases = phrases
        activePhraseComponents.forEach { $0.configure(phrases) }
    }

    func configureKeyboardButtons(_ configuration: KeyboardButtonsConfiguration) {
        guard keyboardConfiguration != configuration else { return }
        keyboardConfiguration = configuration
        activeKeyboardComponents.forEach { $0.configure(configuration) }
        activeKeyboardComponents.forEach { $0.scroller.configurePresentation(presentation(for: "keyboard")) }
    }

    func configureComponentDisplayModes(_ modes: [String: ComponentDisplayMode]) {
        guard componentDisplayModes != modes else { return }
        componentDisplayModes = modes
        activeChatStrips.forEach { $0.scroller.displayMode = modes["chatgpt.chats"] ?? .iconAndText }
        activePhraseComponents.forEach { $0.scroller.displayMode = modes["phrases"] ?? .iconAndText }
        activeKeyboardComponents.forEach { $0.scroller.displayMode = modes["keyboard"] ?? .iconAndText }
    }

    private func presentation(for key: String) -> ComponentPresentation {
        componentPresentations[key] ?? (key == "keyboard"
            ? ComponentPresentation(layout: keyboardConfiguration.layout, alignment: keyboardConfiguration.alignment) : .init())
    }

    func configureComponentPresentations(_ values: [String: ComponentPresentation]) {
        guard componentPresentations != values else { return }
        componentPresentations = values
        activeChatStrips.forEach { $0.scroller.configurePresentation(presentation(for: "chatgpt.chats")) }
        activePhraseComponents.forEach { $0.scroller.configurePresentation(presentation(for: "phrases")) }
        activeKeyboardComponents.forEach { $0.scroller.configurePresentation(presentation(for: "keyboard")) }
        activeTextComponents.forEach { $0.scroller.configurePresentation(presentation(for: "text")) }
    }

    func configureText(_ items: [TextComponentItem]) {
        guard textItems != items else { return }
        textItems = items
        activeTextComponents.forEach { $0.configure(items) }
    }

}
