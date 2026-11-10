#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
NSSize NativeCustomizationMinimum(NSTouchBarItem *item);
NSArray<NSValue *> *NativeCustomizationSizes(NSTouchBarItem *item);
NSArray<NSString *> *NativeCustomizationDrop(NSTouchBar *bar, NSString *identifier, CGFloat x);
NSArray<NSValue *> *NativeCustomizationFrames(NSTouchBar *bar);
NS_ASSUME_NONNULL_END
