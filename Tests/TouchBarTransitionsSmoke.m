#import "TouchBarBridge.h"
#import <objc/message.h>
#import <assert.h>

int main(void) {
    @autoreleasepool {
        TBPrepareForImmediateTransitions();
        [NSApplication sharedApplication];
        Class viewClass = NSClassFromString(@"NSTouchBarView");
        SEL setAllows = NSSelectorFromString(@"setAllowsTransitionAnimations:");
        SEL shouldAnimate = NSSelectorFromString(@"_shouldPerformTransitionAnimations");
        NSView *view = [[viewClass alloc] initWithFrame:NSMakeRect(0, 0, 684, 30)];
        assert(view && [view respondsToSelector:setAllows] && [view respondsToSelector:shouldAnimate]);
        ((void (*)(id, SEL, BOOL))objc_msgSend)(view, setAllows, YES);
        // Test the AppKit decision, not just our preference value. Even when the
        // view allows animations, context transitions must remain disabled.
        assert(!((BOOL (*)(id, SEL))objc_msgSend)(view, shouldAnimate));
        TBPrepareForImmediateTransitions();
        assert(!((BOOL (*)(id, SEL))objc_msgSend)(view, shouldAnimate));
        puts("AppKit Touch Bar context transitions disabled in this process");
    }
}
