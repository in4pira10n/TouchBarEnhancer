import AppKit

@main @MainActor
struct NativeCustomizationSmoke {
    static func main() {
        _ = NSApplication.shared
        let domain = "TouchBarEnhancer.NativeCustomizationTests.\(UUID().uuidString)"
        // Negative control: reproduce the previous bug through the same native
        // drop path. This prevents a test that passes merely by setting IDs.
        let old = AppBar(app: LayoutApp.builtIn[0], persistsLayout: false)
        old.bar.customizationIdentifier = .init("\(domain).negative")
        old.bar.defaultItemIdentifiers = [AppBar.itemID("chatgpt.chats")]
        for suffix in ["chatgpt.chats", "phrases"] {
            let view = (old.bar.item(forIdentifier: AppBar.itemID(suffix)) as! NSCustomTouchBarItem).view as! TouchBarComponentView
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let oldDrop = NativeCustomizationDrop(old.bar, AppBar.itemID("phrases").rawValue, 590)
        precondition(oldDrop.count == 1, "Negative control must reproduce replacement: \(oldDrop)")
        print("Negative control reproduced replacement")
        for (index, scenario) in [["chatgpt.chats"], ["phrases"],
                ["chatgpt.sidebar", "chatgpt.chats", "chatgpt.terminal"],
                ["chatgpt.sidebar", "phrases", "chatgpt.terminal"]].enumerated() {
            let initial = scenario.contains("chatgpt.chats") ? "chatgpt.chats" : "phrases"
            let added = initial == "phrases" ? "chatgpt.chats" : "phrases"
            let provider = AppBar(app: LayoutApp.builtIn[0],
                phrases: [QuickPhrase(name: "Test", text: "Test")], persistsLayout: false)
            let bar = provider.bar
            bar.customizationIdentifier = .init("\(domain).\(index)")
            bar.defaultItemIdentifiers = scenario.map(AppBar.itemID)
            for suffix in [initial, added] {
                let item = bar.item(forIdentifier: AppBar.itemID(suffix))!
                let minimum = NativeCustomizationMinimum(item)
                precondition(minimum.width <= 36, "Native minimum must stay compressible: \(suffix): \(minimum)")
            }
            // Actual cursor-enter / cursor-move / mouse-up path, without
            // opening the system overlay or assigning a combined default list.
            let identifiers = NativeCustomizationDrop(bar, AppBar.itemID(added).rawValue, 590)
            precondition(identifiers.count == scenario.count + 1 && Set(identifiers) == Set((scenario + [added]).map { AppBar.itemID($0).rawValue }),
                "Native drop must retain both independent components: \(identifiers)")
            print("Native drop \(initial) + \(added): \(identifiers)")
            // Verify actual native layout using the resulting order.
            bar.defaultItemIdentifiers = identifiers.map { NSTouchBarItem.Identifier($0) }
            let frames = NativeCustomizationFrames(bar).map(\.rectValue)
            print("Native frames: \(frames)")
            precondition(frames.count == identifiers.count && frames.allSatisfy { $0.width >= 32 })
            let scrollingWidths = zip(identifiers, frames).enumerated().compactMap { position, pair -> CGFloat? in
                guard [initial, added].map({ AppBar.itemID($0).rawValue }).contains(pair.0) else { return nil }
                return pair.1.width - (position == 0 ? 0 : 4)
            }
            precondition(scrollingWidths.count == 2 && abs(scrollingWidths[0] - scrollingWidths[1]) <= 1.01,
                "Content widths must be equal: \(frames)")
        }
        for layout in KeyboardButtonsConfiguration.Layout.allCases {
            for mode in ComponentDisplayMode.allCases {
                for (index, scenario) in [["phrases"], ["keyboard"], ["chatgpt.chats"],
                        ["phrases", "chatgpt.chats"]].enumerated() {
                    let added = scenario.contains("keyboard") ? "phrases" : "keyboard"
                    let config = KeyboardButtonsConfiguration(buttons: [KeyboardButton(title: "A", displayModeOverride: .iconAndText,
                        fillWidth: .init(mode: .fixed, fixed: 850)),
                        KeyboardButton(title: "B", displayModeOverride: .iconOnly, fillWidth: .init(mode: .hug)),
                        KeyboardButton(title: "C", fillWidth: .init(relative: 6))], layout: layout)
                    let provider = AppBar(app: LayoutApp.builtIn[0],
                        phrases: [QuickPhrase(name: "Test", text: "Test")], keyboardButtons: config,
                        componentDisplayModes: ["chatgpt.chats": mode, "phrases": mode, "keyboard": mode], persistsLayout: false)
                    let bar = provider.bar
                    bar.customizationIdentifier = .init("\(domain).keyboard.\(layout.rawValue).\(mode.rawValue).\(index)")
                    bar.defaultItemIdentifiers = scenario.map(AppBar.itemID)
                    let minimum = NativeCustomizationMinimum(bar.item(forIdentifier: AppBar.itemID("keyboard"))!)
                    precondition(minimum.width <= 36, "Keyboard native minimum: \(minimum)")
                    let inserted = NativeCustomizationDrop(bar, AppBar.itemID(added).rawValue, 590)
                    precondition(Set(inserted) == Set((scenario + [added]).map { AppBar.itemID($0).rawValue }),
                        "Keyboard native insertion must retain every region: \(inserted)")
                    bar.defaultItemIdentifiers = inserted.map { .init($0) }
                    let frames = NativeCustomizationFrames(bar).map(\.rectValue)
                    let widths = frames.enumerated().map { $0.element.width - ($0.offset == 0 ? 0 : 4) }
                    precondition(widths.allSatisfy { abs($0 - widths[0]) <= 1.01 }, "Peer widths \(layout.rawValue), \(scenario): \(widths)")
                    print("Keyboard native drop \(layout.rawValue), \(mode.rawValue), \(scenario): \(inserted), widths \(widths)")
                }
            }
        }
        for mode in ComponentLayout.allCases {
            for (index, pair) in [["text", "phrases"], ["phrases", "text"], ["text", "chatgpt.chats"], ["keyboard", "text"]].enumerated() {
                let provider = AppBar(app: LayoutApp.builtIn[0],
                    componentPresentations: Dictionary(uniqueKeysWithValues: pair.map { ($0, ComponentPresentation(layout: mode, alignment: .right)) }),
                    textItems: [TextComponentItem(text: String(repeating: "宽文字", count: 80), style: .init(fontSize: 40, tracking: 3),
                        fillWidth: .init(mode: .hug))], persistsLayout: false)
                let bar = provider.bar
                bar.customizationIdentifier = .init("\(domain).text.\(mode).\(index)")
                bar.defaultItemIdentifiers = [AppBar.itemID(pair[0])]
                for key in pair {
                    let minimum = NativeCustomizationMinimum(bar.item(forIdentifier: AppBar.itemID(key))!)
                    precondition(minimum.width <= 36, "\(key) minimum stays compressible with custom text: \(minimum)")
                }
                let ids = NativeCustomizationDrop(bar, AppBar.itemID(pair[1]).rawValue, 590)
                precondition(Set(ids) == Set(pair.map { AppBar.itemID($0).rawValue }))
                bar.defaultItemIdentifiers = ids.map { .init($0) }
                let frames = NativeCustomizationFrames(bar).map(\.rectValue)
                let sizes = ids.map { id -> String in
                    let view = (bar.item(forIdentifier: .init(id)) as! NSCustomTouchBarItem).view as! TouchBarComponentView
                    return "\(view.content.intrinsicContentSize)/\(view.fittingSize)/\(view.leadingSpacing)/\(NativeCustomizationSizes(bar.item(forIdentifier: .init(id))!).map(\.sizeValue))"
                }
                precondition(frames.count == 2 && abs(frames[0].width - (frames[1].width - 4)) <= 1.01,
                    "Text native peer widths: \(mode), \(pair), \(ids), \(frames), \(sizes)")
            }
        }
        for mode in ComponentLayout.allCases {
            for width in [TextComponentWidth(mode: .fixed, fixed: 20), TextComponentWidth(mode: .hug)] {
                for (index, pair) in [["text", "keyboard"], ["keyboard", "text"], ["text", "phrases"], ["text"]].enumerated() {
                    let provider = AppBar(app: LayoutApp.builtIn[0],
                        componentPresentations: ["text": .init(layout: mode, textWidth: width)],
                        textItems: [TextComponentItem(text: "I")], persistsLayout: false)
                    let bar = provider.bar
                    bar.customizationIdentifier = .init("\(domain).compact.\(mode).\(width.mode).\(index)")
                    bar.defaultItemIdentifiers = [AppBar.itemID(pair[0])]
                    let text = bar.item(forIdentifier: AppBar.itemID("text"))!
                    precondition(NativeCustomizationMinimum(text).width <= 5, "Compact Text minimum stays below 32")
                    if pair.count > 1 {
                        let ids = NativeCustomizationDrop(bar, AppBar.itemID(pair[1]).rawValue, 590)
                        precondition(Set(ids) == Set(pair.map { AppBar.itemID($0).rawValue }), "Compact Text native insertion: \(ids)")
                        bar.defaultItemIdentifiers = ids.map { .init($0) }
                    }
                    let frames = NativeCustomizationFrames(bar).map(\.rectValue)
                    let wrapper = (text as! NSCustomTouchBarItem).view as! TouchBarComponentView
                    let region = wrapper.content as! ScrollingComponentRegion
                    precondition(abs(region.bounds.width - region.requestedWidth!) <= 1,
                        "Compact Text \(width.mode): requested \(region.requestedWidth!), actual \(region.bounds.width), \(frames)")
                    precondition(region.bounds.width < 32)
                    precondition(abs(frames[0].minX) <= 1, "Compact layout stays leading-aligned: \(frames)")
                    if frames.count > 1 {
                        precondition(abs(frames[1].minX - frames[0].maxX - 8) <= 1, "Native wrapper gap: \(frames)")
                        precondition(frames[pair[0] == "text" ? 1 : 0].width > 600, "Adaptive peer uses released space: \(frames)")
                    }
                    print("Compact Text native \(mode), \(width.mode), \(pair): \(frames)")
                }
            }
        }
        print("Native customization checks passed")
    }
}
