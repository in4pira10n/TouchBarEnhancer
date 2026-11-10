#import "NativeCustomizationBridge.h"
#import <objc/message.h>

// Test-only SPI: exercise AppKit's real cursor/drop layout offscreen. None of
// these selectors are added to the production app or open an overlay window.
static id Get(id object, NSString *selector) {
    return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(selector));
}
static void Set(id object, NSString *selector, id value) {
    ((void (*)(id, SEL, id))objc_msgSend)(object, NSSelectorFromString(selector), value);
}

NSSize NativeCustomizationMinimum(NSTouchBarItem *item) {
    NSSize minimum, maximum, preferred;
    ((void (*)(id, SEL, NSSize *, NSSize *, NSSize *))objc_msgSend)(item,
        NSSelectorFromString(@"_itemViewMinSize:maxSize:preferredSize:"), &minimum, &maximum, &preferred);
    return minimum;
}

NSArray<NSValue *> *NativeCustomizationSizes(NSTouchBarItem *item) {
    NSSize minimum, maximum, preferred;
    ((void (*)(id, SEL, NSSize *, NSSize *, NSSize *))objc_msgSend)(item,
        NSSelectorFromString(@"_itemViewMinSize:maxSize:preferredSize:"), &minimum, &maximum, &preferred);
    return @[[NSValue valueWithSize:minimum], [NSValue valueWithSize:maximum], [NSValue valueWithSize:preferred]];
}

NSArray<NSString *> *NativeCustomizationDrop(NSTouchBar *bar, NSString *identifier, CGFloat x) {
    NSViewController *palette = [NSClassFromString(@"NSTouchBarCustomizationPaletteViewController") new];
    Set(palette, @"setTouchBars:", @[bar]);
    palette.view.frame = NSMakeRect(0, 0, 1004, 300);
    NSViewController *preview = [NSClassFromString(@"NSTouchBarCustomizationPreviewViewController") new];
    preview.view.frame = NSMakeRect(0, 0, 1004, 30);
    Set(preview, @"setApplicationItemTree:", Get(palette, @"itemTree"));
    ((void (*)(id, SEL, NSRect))objc_msgSend)(preview,
        NSSelectorFromString(@"setApplicationRect:"), NSMakeRect(0, 0, 685, 30));
    [preview.view layoutSubtreeIfNeeded];
    CGPoint point = CGPointMake(x, 15);
    ((CGPoint (*)(id, SEL, CGPoint, BOOL, id))objc_msgSend)(preview,
        NSSelectorFromString(@"cursorEnterAtPoint:mouseIsDown:withItem:"), point, YES, [bar itemForIdentifier:identifier]);
    [preview.view layoutSubtreeIfNeeded];
    ((CGPoint (*)(id, SEL, CGPoint, CGSize, BOOL))objc_msgSend)(preview,
        NSSelectorFromString(@"cursorMovedToPoint:withDelta:mouseIsDown:"), point, CGSizeZero, YES);
    ((CGPoint (*)(id, SEL, CGPoint))objc_msgSend)(preview,
        NSSelectorFromString(@"cursorMouseUpAtPoint:"), point);
    id tree = Get(preview, @"applicationItemTree");
    NSArray *nodes = Get(tree, @"leafNodes");
    NSMutableArray *identifiers = [NSMutableArray array];
    for (id node in nodes) [identifiers addObject:Get(node, @"itemIdentifier")];
    return identifiers;
}

NSArray<NSValue *> *NativeCustomizationFrames(NSTouchBar *bar) {
    NSViewController *live = [NSClassFromString(@"NSTouchBarViewController") new];
    Set(live, @"setTouchBars:", @[bar]);
    live.view.frame = NSMakeRect(0, 0, 685, 30);
    [live.view layoutSubtreeIfNeeded];
    // Components establish equal sibling widths once AppKit attaches their views.
    // Settle those native constraints before measuring the rendered geometry.
    [live.view layoutSubtreeIfNeeded];
    NSMutableArray *frames = [NSMutableArray array];
    for (NSString *identifier in bar.itemIdentifiers) {
        NSView *view = [[bar itemForIdentifier:identifier] view];
        [frames addObject:[NSValue valueWithRect:[view convertRect:view.bounds toView:live.view]]];
    }
    return frames;
}
