#import <AppKit/AppKit.h>

// Call before creating NSApplication / Touch Bar views. Process-local only.
void TBPrepareForImmediateTransitions(void);
BOOL TBIsAvailable(void);
BOOL TBPresent(NSTouchBar *bar);
BOOL TBDismiss(NSTouchBar *bar);
