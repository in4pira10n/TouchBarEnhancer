#import "TouchBarBridge.h"
#import <objc/message.h>

void TBPrepareForImmediateTransitions(void) {
    // AppKit caches this switch on the first Touch Bar layout. Registration is
    // process-local: do not write a global preference or affect other apps'
    // native bars. A zero NSAnimationContext alone does not disable this path.
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        @"NSTouchBarContextAnimations": @NO
    }];
}

// Keep undocumented selectors isolated; never invoke a missing selector.
static SEL presentationSelector(void) {
    SEL modern = NSSelectorFromString(@"presentSystemModalTouchBar:placement:systemTrayItemIdentifier:");
    if ([NSTouchBar respondsToSelector:modern]) return modern;
    return NSSelectorFromString(@"presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:");
}

static SEL dismissalSelector(void) {
    SEL modern = NSSelectorFromString(@"dismissSystemModalTouchBar:");
    if ([NSTouchBar respondsToSelector:modern]) return modern;
    return NSSelectorFromString(@"dismissSystemModalFunctionBar:");
}

BOOL TBIsAvailable(void) {
    return [NSTouchBar respondsToSelector:presentationSelector()] &&
           [NSTouchBar respondsToSelector:dismissalSelector()];
}

BOOL TBPresent(NSTouchBar *bar) {
    if (!TBIsAvailable()) return NO;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0;
        context.allowsImplicitAnimation = NO;
        ((void (*)(id, SEL, id, NSInteger, id))objc_msgSend)(
            // Placement 0 preserves the system Control Strip; 1 uses full width.
            [NSTouchBar class], presentationSelector(), bar, 0, nil);
    } completionHandler:nil];
    return YES;
}

BOOL TBDismiss(NSTouchBar *bar) {
    SEL selector = dismissalSelector();
    if (![NSTouchBar respondsToSelector:selector]) return NO;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0;
        context.allowsImplicitAnimation = NO;
        ((void (*)(id, SEL, id))objc_msgSend)([NSTouchBar class], selector, bar);
    } completionHandler:nil];
    return YES;
}
