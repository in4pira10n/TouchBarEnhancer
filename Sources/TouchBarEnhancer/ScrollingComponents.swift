import AppKit

enum ScrollingComponentAlignment: String, Codable, CaseIterable {
    case left = "Left", center = "Center", right = "Right"
}

enum ComponentLayout: String, Codable, CaseIterable { case scrolling = "Scrolling", fill = "Fill" }

struct ComponentPresentation: Codable, Equatable {
    var layout: ComponentLayout = .scrolling
    var alignment: ScrollingComponentAlignment = .left
    var textWidth: TextComponentWidth?
}

/// Per-entry sizing in Fill; values remain saved while the component scrolls.
struct ComponentItemWidth: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case relative = "Relative", fixed = "Fixed", hug = "Hug" }
    var mode: Mode = .relative
    var relative: Double = 12
    var fixed: Double = 75

    static func valid(_ value: Double) -> Bool { value.isFinite && value > 0 && value <= 1_000_000 }

    /// Fixed/Hug retain their widths on overflow; the native scroller handles it.
    static func allocate(_ policies: [Self], naturalWidths: [CGFloat], available: CGFloat) -> [CGFloat] {
        precondition(policies.count == naturalWidths.count)
        var widths = zip(policies, naturalWidths).map { policy, natural -> CGFloat in
            switch policy.mode {
            case .relative: return 0
            case .fixed: return CGFloat(valid(policy.fixed) ? policy.fixed : 75)
            case .hug: return max(1, natural)
            }
        }
        let indices = policies.indices.filter { policies[$0].mode == .relative }
        let weights = indices.map { valid(policies[$0].relative) ? policies[$0].relative : 12 }
        let total = weights.reduce(0, +)
        let gaps = CGFloat(max(0, policies.count - 1)) * ScrollingComponentStyle.itemSpacing
        let remaining = max(0, available - gaps - widths.reduce(0, +))
        for (index, weight) in zip(indices, weights) {
            widths[index] = max(1, remaining * CGFloat(weight / total))
        }
        return widths
    }
}

/// A presentation preference for an entire component, never an individual item.
enum ComponentDisplayMode: String, Codable, CaseIterable {
    case iconOnly = "Icon Only", iconAndText = "Icon + Text"
}

/// Shared metrics for every scrolling Touch Bar component. All values are points.
enum ScrollingComponentStyle {
    static let height: CGFloat = 30
    static let fontSize: CGFloat = 15
    static let iconTitleSpacing: CGFloat = 6
    static let horizontalPadding: CGFloat = 16
    static let itemSpacing: CGFloat = 8
    // Edges belong to the bar layout. Never add a margin around a scrolling
    // component; item padding and spacing remain independent below.
    static let regionInset: CGFloat = 0
    static let minimumWidth: CGFloat = 32
    static let preferredWidth: CGFloat = 518
    static let cornerRadius: CGFloat = 6
}

/// AppKit separates Touch Bar items by 8 pt. Add the remaining 4 pt at
/// component boundaries, independently of a button's content and item spacing.
@MainActor
final class TouchBarComponentView: NSView {
    let content: NSView
    var onHierarchyChange: (() -> Void)?
    var leadingSpacing: CGFloat {
        didSet {
            guard oldValue != leadingSpacing else { return }
            leadingConstraint.constant = leadingSpacing
            invalidateIntrinsicContentSize()
        }
    }
    private var leadingConstraint: NSLayoutConstraint!

    init(content: NSView, leadingSpacing: CGFloat) {
        self.content = content
        self.leadingSpacing = leadingSpacing
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        leadingConstraint = content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leadingSpacing)
        setContentHuggingPriority((content as? ScrollingComponentRegion)?.requestedWidth == nil ? .init(1) : .required, for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
        NSLayoutConstraint.activate([
            leadingConstraint,
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); onHierarchyChange?() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); onHierarchyChange?() }
    override func layout() { super.layout(); onHierarchyChange?() }

    override var intrinsicContentSize: NSSize {
        let intrinsic = content.intrinsicContentSize
        let width = intrinsic.width == NSView.noIntrinsicMetric ? content.fittingSize.width : intrinsic.width
        return NSSize(width: width + leadingSpacing, height: ScrollingComponentStyle.height)
    }
}

/// Presentation only: the owning adapter supplies the action separately.
struct ScrollingComponentItem: Equatable {
    var title: String
    var symbol: String
    var imageData: Data?
    var background: Background = .standard
    var accessibilityLabel: String
    var toolTip: String
    var displayModeOverride: ComponentDisplayMode?
    var textStyle: TextComponentStyle?
    var fillWidth: ComponentItemWidth?

    enum Background: Equatable {
        case standard
        case color(String)
        case none
    }
}

@MainActor
final class ScrollingComponentRegion: NSView {
    var requestedWidth: CGFloat? {
        didSet {
            guard oldValue != requestedWidth else { return }
            minimumWidthConstraint?.constant = requestedWidth == nil ? ScrollingComponentStyle.minimumWidth : 1
            setContentHuggingPriority(requestedWidth == nil ? .init(1) : .required, for: .horizontal)
            (superview as? TouchBarComponentView)?.setContentHuggingPriority(requestedWidth == nil ? .init(1) : .required, for: .horizontal)
            invalidateIntrinsicContentSize()
            (superview as? TouchBarComponentView)?.invalidateIntrinsicContentSize()
            onWidthRequestChange?()
        }
    }
    var minimumWidthConstraint: NSLayoutConstraint?
    var onWidthRequestChange: (() -> Void)?
    var preferredWidth = ScrollingComponentStyle.preferredWidth {
        didSet {
            if oldValue != preferredWidth {
                invalidateIntrinsicContentSize()
                (superview as? TouchBarComponentView)?.invalidateIntrinsicContentSize()
            }
        }
    }
    var onWindowChange: (() -> Void)?
    var onMeasurementContextChange: (() -> Void)?
    var onLayout: ((NSRect) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); onMeasurementContextChange?(); onWindowChange?()
    }
    override func layout() { super.layout(); onLayout?(bounds) }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: requestedWidth ?? preferredWidth, height: ScrollingComponentStyle.height)
    }
}

/// NSScrubber owns interaction; items only render the shared icon/title layout.
@MainActor
final class ScrollingComponentItemView: NSScrubberItemView {
    private let background = NSView()
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let content = NSStackView()
    private var iconWidth: NSLayoutConstraint!
    private var leadingPadding: NSLayoutConstraint!
    private var trailingPadding: NSLayoutConstraint!
    private var textEdges: [NSLayoutConstraint] = []
    private var passiveText = false
    private var standardBackground = false
    private var baseBackground = NSColor.systemBlue

    override var isHighlighted: Bool { didSet { updateBackground() } }

    private func updateBackground() {
        let pressed = isHighlighted && !passiveText
        background.alphaValue = standardBackground ? 1 : (pressed ? 0.65 : 1)
        background.layer?.backgroundColor = (standardBackground && pressed
            ? ChatSideButton.pressedBackground : baseBackground).cgColor
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        background.wantsLayer = true
        background.layer?.cornerRadius = ScrollingComponentStyle.cornerRadius
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background, positioned: .below, relativeTo: nil)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .white
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconWidth = icon.widthAnchor.constraint(equalToConstant: ScrollingComponentStyle.fontSize)
        NSLayoutConstraint.activate([
            iconWidth,
            icon.heightAnchor.constraint(equalToConstant: ScrollingComponentStyle.height)
        ])
        title.font = .systemFont(ofSize: ScrollingComponentStyle.fontSize)
        title.textColor = .white
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = ScrollingComponentStyle.iconTitleSpacing
        content.addArrangedSubview(icon)
        content.addArrangedSubview(title)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        leadingPadding = content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: ScrollingComponentStyle.horizontalPadding)
        trailingPadding = content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -ScrollingComponentStyle.horizontalPadding)
        leadingPadding.priority = .defaultHigh; trailingPadding.priority = .defaultHigh
        NSLayoutConstraint.activate([leadingPadding, trailingPadding])
        textEdges = [content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor)]
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ item: ScrollingComponentItem, displayMode: ComponentDisplayMode = .iconAndText) {
        let displayMode = item.displayModeOverride ?? displayMode
        let isText = item.textStyle != nil
        passiveText = isText
        icon.isHidden = isText
        background.isHidden = isText && item.textStyle?.backgroundColor == nil
        let textPadding = item.textStyle?.horizontalPadding ?? 0
        textEdges[0].constant = textPadding; textEdges[1].constant = -textPadding
        if isText { NSLayoutConstraint.activate(textEdges) }
        else { NSLayoutConstraint.deactivate(textEdges) }
        Self.configureLabel(title, for: item)
        title.isHidden = !isText && displayMode == .iconOnly
        content.spacing = isText || displayMode == .iconOnly ? 0 : ScrollingComponentStyle.iconTitleSpacing
        icon.image = Self.image(for: item)
        iconWidth.constant = Self.iconWidth(for: item)
        switch item.background {
        case .standard:
            standardBackground = true
            baseBackground = ChatSideButton.normalBackground
        case .color(let value):
            standardBackground = false
            baseBackground = ChatColor.resolve(value) ?? .systemBlue
        case .none:
            standardBackground = false
            baseBackground = .clear
        }
        leadingPadding.constant = isText ? textPadding : ScrollingComponentStyle.horizontalPadding
        trailingPadding.constant = isText ? -textPadding : -ScrollingComponentStyle.horizontalPadding
        updateBackground()
        setAccessibilityLabel(item.accessibilityLabel)
        toolTip = item.toolTip
    }

    static func width(for item: ScrollingComponentItem, displayMode: ComponentDisplayMode = .iconAndText,
                      measurementLabel: NSTextField? = nil) -> CGFloat {
        let label = measurementLabel ?? NSTextField(labelWithString: "")
        configureLabel(label, for: item)
        if let style = item.textStyle {
            return max(1, ceil(label.fittingSize.width + 2 * style.horizontalPadding))
        }
        let displayMode = item.displayModeOverride ?? displayMode
        if displayMode == .iconOnly {
            return ceil(iconWidth(for: item) + 2 * ScrollingComponentStyle.horizontalPadding)
        }
        return ceil(label.fittingSize.width + iconWidth(for: item)
            + ScrollingComponentStyle.iconTitleSpacing + 2 * ScrollingComponentStyle.horizontalPadding)
    }

    private static func configureLabel(_ label: NSTextField, for item: ScrollingComponentItem) {
        if let style = item.textStyle {
            label.font = style.font
            label.attributedStringValue = style.attributedString(item.title)
            label.alignment = style.textAlignment
            label.lineBreakMode = style.lineBreakMode
            label.maximumNumberOfLines = 1
            label.cell?.usesSingleLineMode = true
        } else {
            // Assigning stringValue also discards a recycled Text item's rich
            // attributes. Button titles use the native plain-text label path.
            label.stringValue = item.title
            label.font = .systemFont(ofSize: ScrollingComponentStyle.fontSize)
            label.textColor = .white
            label.alignment = .natural
            label.lineBreakMode = .byTruncatingTail
            // Retain the original native button label metrics. The rich Text
            // path's single-line cell mode changes its vertical drawing metrics.
            label.maximumNumberOfLines = 0
            label.cell?.usesSingleLineMode = false
        }
        label.cell?.wraps = false
        label.cell?.isScrollable = false
    }

    private static func image(for item: ScrollingComponentItem) -> NSImage? {
        if let image = item.imageData.flatMap(NSImage.init(data:)) { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: ScrollingComponentStyle.fontSize, weight: .regular)
            .applying(.init(paletteColors: [.white]))
        return NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
    private static func iconWidth(for item: ScrollingComponentItem) -> CGFloat {
        item.imageData == nil ? (image(for: item)?.size.width ?? ScrollingComponentStyle.fontSize) : ScrollingComponentStyle.height
    }
}

/// Reusable entry point: configure presentation items and handle taps by index.
@MainActor
final class ShortcutScroller: NSObject, NSScrubberDataSource, NSScrubberFlowLayoutDelegate {
    static let minimumWidth = ScrollingComponentStyle.minimumWidth
    let scrubber = NSScrubber(frame: NSRect(x: 0, y: 0, width: 460, height: ScrollingComponentStyle.height))
    let scrollRegion = ScrollingComponentRegion()
    private(set) var items: [ScrollingComponentItem] = []
    var onSelect: ((Int) -> Void)?
    var onNaturalWidthChange: (() -> Void)?
    var naturalContentWidth: CGFloat {
        items.reduce(CGFloat.zero) { $0 + naturalWidth(for: $1) }
            + CGFloat(max(0, items.count - 1)) * ScrollingComponentStyle.itemSpacing
    }
    var displayMode: ComponentDisplayMode = .iconAndText {
        didSet { if oldValue != displayMode { reloadPresentation() } }
    }
    var alignment: ScrollingComponentAlignment = .left { didSet { updateAlignment() } }
    var fillsAvailableWidth = false {
        didSet {
            guard oldValue != fillsAvailableWidth else { return }
            fillWidths = nil
            scrubber.scrubberLayout.invalidateLayout()
            updateAlignment()
        }
    }
    private let alignsContent: Bool
    private let measurementLabel = NSTextField(labelWithString: "")
    private var fillWidths: (viewport: CGFloat, values: [CGFloat])?

    init(label: String, alignsContent: Bool = true) {
        self.alignsContent = alignsContent
        super.init()
        let layout = NSScrubberFlowLayout()
        layout.itemSpacing = ScrollingComponentStyle.itemSpacing
        scrubber.scrubberLayout = layout
        scrubber.mode = .free
        scrubber.isContinuous = false
        scrubber.showsAdditionalContentIndicators = true
        scrubber.selectionOverlayStyle = nil
        scrubber.selectionBackgroundStyle = nil
        scrubber.dataSource = self
        scrubber.delegate = self
        scrubber.register(ScrollingComponentItemView.self, forItemIdentifier: .init("scrollingItem"))
        scrubber.setAccessibilityLabel(label)
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrollRegion.setContentHuggingPriority(.init(1), for: .horizontal)
        // AppKit measures customization drop targets at fittingSize priority
        // (50). A resistance above that makes the preferred width the minimum,
        // so adding a second scroller evicts the first instead of shrinking it.
        scrollRegion.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        scrollRegion.addSubview(scrubber)
        // Native Touch Bar typography can measure differently after attachment.
        // Keep a hidden measuring label in this presentation's actual context.
        measurementLabel.isHidden = true
        scrollRegion.addSubview(measurementLabel)
        scrollRegion.onMeasurementContextChange = { [weak self] in self?.reloadPresentation() }
        let minimum = scrollRegion.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth)
        scrollRegion.minimumWidthConstraint = minimum
        NSLayoutConstraint.activate([scrollRegion.heightAnchor.constraint(equalToConstant: ScrollingComponentStyle.height), minimum])
        if alignsContent {
            // Position a short list inside its viewport without making its natural
            // content width an Auto Layout limit on the customizable component.
            scrollRegion.onLayout = { [weak self] bounds in self?.layoutScrubber(in: bounds) }
        } else {
            NSLayoutConstraint.activate([
                scrubber.leadingAnchor.constraint(equalTo: scrollRegion.leadingAnchor),
                scrubber.trailingAnchor.constraint(equalTo: scrollRegion.trailingAnchor),
                scrubber.centerYAnchor.constraint(equalTo: scrollRegion.centerYAnchor),
                scrubber.heightAnchor.constraint(equalToConstant: ScrollingComponentStyle.height)
            ])
        }
    }
    func configurePresentation(_ presentation: ComponentPresentation) {
        fillsAvailableWidth = presentation.layout == .fill
        alignment = presentation.alignment
    }
    private func updateAlignment() {
        guard alignsContent else { return }
        scrollRegion.needsLayout = true
    }
    private func layoutScrubber(in bounds: NSRect) {
        let contentWidth = items.reduce(CGFloat.zero) { $0 + naturalWidth(for: $1) }
            + CGFloat(max(0, items.count - 1)) * ScrollingComponentStyle.itemSpacing
        let width = fillsAvailableWidth ? bounds.width : min(bounds.width, max(1, contentWidth))
        let x: CGFloat
        switch fillsAvailableWidth ? .left : alignment {
        case .left: x = 0
        case .center: x = (bounds.width - width) / 2
        case .right: x = bounds.width - width
        }
        let changedWidth = scrubber.frame.width != width
        scrubber.frame = NSRect(x: x, y: 0, width: width, height: ScrollingComponentStyle.height)
        if changedWidth { scrubber.scrubberLayout.invalidateLayout() }
    }
    func configure(_ items: [ScrollingComponentItem]) {
        guard self.items != items else { return }
        self.items = items
        reloadPresentation()
    }
    private func reloadPresentation() {
        fillWidths = nil
        updateAlignment()
        scrubber.reloadData()
        scrubber.scrubberLayout.invalidateLayout()
        onNaturalWidthChange?()
        scrubber.selectedIndex = -1
    }
    func numberOfItems(for scrubber: NSScrubber) -> Int { items.count }
    private func naturalWidth(for item: ScrollingComponentItem) -> CGFloat {
        ScrollingComponentItemView.width(for: item, displayMode: displayMode,
            measurementLabel: item.textStyle == nil ? nil : measurementLabel)
    }
    private func fillItemWidths() -> [CGFloat] {
        if let fillWidths, fillWidths.viewport == scrubber.bounds.width { return fillWidths.values }
        let widths = ComponentItemWidth.allocate(items.map { $0.fillWidth ?? .init() },
            naturalWidths: items.map { naturalWidth(for: $0) }, available: scrubber.bounds.width)
        fillWidths = (scrubber.bounds.width, widths)
        return widths
    }
    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = scrubber.makeItem(withIdentifier: .init("scrollingItem"), owner: self) as! ScrollingComponentItemView
        view.configure(items[index], displayMode: displayMode)
        return view
    }
    nonisolated func scrubber(_ scrubber: NSScrubber, layout: NSScrubberFlowLayout, sizeForItemAt index: Int) -> NSSize {
        MainActor.assumeIsolated {
            let width = fillsAvailableWidth
                ? fillItemWidths()[index]
                : naturalWidth(for: items[index])
            return NSSize(width: width, height: ScrollingComponentStyle.height)
        }
    }
    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        guard items.indices.contains(index) else { return }
        onSelect?(index)
        scrubber.selectedIndex = -1
    }
}
