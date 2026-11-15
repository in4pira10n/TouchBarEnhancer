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
// Normalized title/artist/album/duration/elapsed/timestamp/rate/playing/source.
// Read-only; no artwork, player activation, transport command or polling.
void TBReadNowPlaying(void (^ _Nonnull completion)(NSDictionary<NSString *, id> * _Nullable));
// Adds metadata/seek changes to playback/source observation. Stop with the same
// TBStopObservingMediaPlaying function; subscriptions have independent lifetimes.
id _Nullable TBObserveNowPlaying(void (^ _Nonnull changed)(NSNumber * _Nullable));
// Private system Now Playing transport; sends only on explicit user action.
BOOL TBMediaSkipIsAvailable(void);
// YES means the system accepted the command, not that the player changed track.
BOOL TBSkipMedia(BOOL forward);
BOOL TBMediaSeekIsAvailable(void);
// YES means dispatched, not acknowledged by the active player. Does not resume playback.
BOOL TBSeekMediaToTime(NSTimeInterval elapsed);
NS_ASSUME_NONNULL_END
