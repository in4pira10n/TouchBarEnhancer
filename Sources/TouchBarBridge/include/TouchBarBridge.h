#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN

// Call before creating NSApplication / Touch Bar views. Process-local only.
void TBPrepareForImmediateTransitions(void);
BOOL TBIsAvailable(void);
BOOL TBPresent(NSTouchBar *bar);
BOOL TBDismiss(NSTouchBar *bar);
// Private Control Strip registration; does not edit the system's button layout.
BOOL TBControlStripIsAvailable(void);
BOOL TBControlStripRegister(NSTouchBarItem *item);
void TBControlStripUnregister(NSTouchBarItem *item);
// Private, read-only system Now Playing query; nil means unavailable.
// Completion is always delivered on the main queue. Does not start playback.
void TBReadMediaPlaying(void (^ _Nonnull completion)(NSNumber * _Nullable));
// Playback/source change notifications only; no polling. A nil event requests a
// fresh system query. Returns nil when this private API is unavailable.
id _Nullable TBObserveMediaPlaying(void (^ _Nonnull changed)(NSNumber * _Nullable));
void TBStopObservingMediaPlaying(id observation);
// Private system Now Playing transport; sends only on explicit user action.
BOOL TBMediaSkipIsAvailable(void);
// YES means the system accepted the command, not that the player changed track.
BOOL TBSkipMedia(BOOL forward);
NS_ASSUME_NONNULL_END
