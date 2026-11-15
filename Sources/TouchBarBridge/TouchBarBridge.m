#import "TouchBarBridge.h"
#import <objc/message.h>
#import <dlfcn.h>

static void *mediaRemoteFramework(void) {
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL);
    });
    return framework;
}

typedef Boolean (*TBSendMediaCommand)(uint32_t, CFDictionaryRef);
static TBSendMediaCommand mediaCommandFunction(void) {
    void *framework = mediaRemoteFramework();
    return framework ? (TBSendMediaCommand)dlsym(framework, "MRMediaRemoteSendCommand") : NULL;
}

BOOL TBMediaSkipIsAvailable(void) { return mediaCommandFunction() != NULL; }

BOOL TBSkipMedia(BOOL forward) {
    TBSendMediaCommand function = mediaCommandFunction();
    if (!function) return NO;
    // MediaRemote transport command IDs: next track = 4, previous track = 5.
    return function(forward ? 4 : 5, NULL);
}

static NSString *mediaPlaybackPositionKey(void) {
    void *framework = mediaRemoteFramework();
    NSString * __unsafe_unretained *key = framework ? (NSString * __unsafe_unretained *)dlsym(framework, "kMRMediaRemoteOptionPlaybackPosition") : NULL;
    return key ? *key : nil;
}
BOOL TBMediaSeekIsAvailable(void) { return mediaCommandFunction() != NULL && mediaPlaybackPositionKey() != nil; }
BOOL TBSeekMediaToTime(NSTimeInterval elapsed) {
    TBSendMediaCommand function = mediaCommandFunction();
    NSString *key = mediaPlaybackPositionKey();
    if (!function || !key || !isfinite(elapsed) || elapsed < 0) return NO;
    // The same absolute-position command used by MRMediaRemoteSetElapsedTime,
    // but retain its dispatch result instead of the void wrapper's lost error.
    // Relative skip commands are disabled by some players, including Music.
    return function(24, (__bridge CFDictionaryRef)@{key: @(elapsed)});
}

void TBReadMediaPlaying(void (^completion)(NSNumber *)) {
    typedef void (*TBGetPlaying)(dispatch_queue_t, void (^)(Boolean));
    void *framework = mediaRemoteFramework();
    TBGetPlaying function = framework ? (TBGetPlaying)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!function) { completion(nil); return; }
        function(dispatch_get_main_queue(), ^(Boolean playing) { completion(@(playing)); });
    });
}

typedef void (*TBRegisterMediaNotifications)(dispatch_queue_t);
typedef void (*TBUnregisterMediaNotifications)(void);
static NSUInteger mediaObserverCount;

@interface TBMediaPlayingObservation : NSObject
@property(nonatomic, copy) void (^changed)(NSNumber *);
@property(nonatomic, strong) NSMutableArray *observers;
@property(nonatomic) BOOL registered;
- (void)invalidate;
@end

@implementation TBMediaPlayingObservation
- (void)invalidate {
    self.changed = nil;
    for (id observer in self.observers) [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [self.observers removeAllObjects];
    if (self.registered) {
        self.registered = NO;
        if (--mediaObserverCount == 0) {
            TBUnregisterMediaNotifications unregister = (TBUnregisterMediaNotifications)dlsym(mediaRemoteFramework(), "MRMediaRemoteUnregisterForNowPlayingNotifications");
            if (unregister) unregister();
        }
    }
}
- (void)dealloc { [self invalidate]; }
@end

id TBObserveMediaPlaying(void (^changed)(NSNumber *)) {
    NSCAssert([NSThread isMainThread], @"Media observation must be owned on the main thread");
    void *framework = mediaRemoteFramework();
    if (!framework) return nil;
    TBRegisterMediaNotifications registration = (TBRegisterMediaNotifications)dlsym(framework, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!registration || !dlsym(framework, "MRMediaRemoteUnregisterForNowPlayingNotifications")) return nil;
    NSString * __unsafe_unretained *playingName = (NSString * __unsafe_unretained *)dlsym(framework, "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification");
    NSString * __unsafe_unretained *sourceName = (NSString * __unsafe_unretained *)dlsym(framework, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification");
    NSString * __unsafe_unretained *playingKey = (NSString * __unsafe_unretained *)dlsym(framework, "kMRMediaRemoteNowPlayingApplicationIsPlayingUserInfoKey");
    if (!playingName || !*playingName || !sourceName || !*sourceName) return nil;
    TBMediaPlayingObservation *observation = [TBMediaPlayingObservation new];
    observation.changed = changed;
    observation.observers = [NSMutableArray array];
    __weak TBMediaPlayingObservation *weakObservation = observation;
    for (NSString *name in @[*playingName, *sourceName]) {
        id token = [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            TBMediaPlayingObservation *owner = weakObservation;
            if (!owner.changed) return;
            id value = [note.name isEqualToString:*playingName] && playingKey && *playingKey ? note.userInfo[*playingKey] : nil;
            // Use the system's event value immediately. Source switches or an
            // incomplete notification trigger a single fresh read instead.
            owner.changed([value isKindOfClass:[NSNumber class]] ? value : nil);
        }];
        [observation.observers addObject:token];
    }
    observation.registered = YES;
    if (mediaObserverCount++ == 0) registration(dispatch_get_main_queue());
    return observation;
}

void TBStopObservingMediaPlaying(id observation) {
    NSCAssert([NSThread isMainThread], @"Media observation must be stopped on the main thread");
    if ([observation isKindOfClass:[TBMediaPlayingObservation class]]) [observation invalidate];
}

static id nowPlayingValue(NSDictionary *info, const char *symbol) {
    NSString * __unsafe_unretained *key = (NSString * __unsafe_unretained *)dlsym(mediaRemoteFramework(), symbol);
    return key && *key ? info[*key] : nil;
}

void TBReadNowPlaying(void (^completion)(NSDictionary<NSString *, id> *)) {
    typedef void (*TBGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
    typedef void (*TBGetPlaying)(dispatch_queue_t, void (^)(Boolean));
    typedef void (*TBGetPID)(dispatch_queue_t, void (^)(int));
    void *framework = mediaRemoteFramework();
    TBGetInfo getInfo = framework ? (TBGetInfo)dlsym(framework, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    TBGetPlaying getPlaying = framework ? (TBGetPlaying)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
    TBGetPID getPID = framework ? (TBGetPID)dlsym(framework, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!getInfo || !getPlaying) { completion(nil); return; }
        dispatch_group_t group = dispatch_group_create();
        __block NSDictionary *info;
        __block BOOL playing = NO;
        __block int pid = 0;
        dispatch_group_enter(group);
        getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef value) {
            info = [(__bridge NSDictionary *)value copy]; dispatch_group_leave(group);
        });
        dispatch_group_enter(group);
        getPlaying(dispatch_get_main_queue(), ^(Boolean value) { playing = value; dispatch_group_leave(group); });
        if (getPID) {
            dispatch_group_enter(group);
            getPID(dispatch_get_main_queue(), ^(int value) { pid = value; dispatch_group_leave(group); });
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            if (!info) { completion(nil); return; }
            NSMutableDictionary *result = [NSMutableDictionary dictionary];
            const char *symbols[] = {"kMRMediaRemoteNowPlayingInfoTitle", "kMRMediaRemoteNowPlayingInfoArtist",
                "kMRMediaRemoteNowPlayingInfoAlbum", "kMRMediaRemoteNowPlayingInfoDuration",
                "kMRMediaRemoteNowPlayingInfoElapsedTime", "kMRMediaRemoteNowPlayingInfoTimestamp",
                "kMRMediaRemoteNowPlayingInfoPlaybackRate"};
            NSArray *keys = @[@"title", @"artist", @"album", @"duration", @"elapsed", @"timestamp", @"rate"];
            for (NSUInteger i = 0; i < keys.count; i++) {
                id value = nowPlayingValue(info, symbols[i]);
                if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSDate class]]) {
                    result[keys[i]] = value;
                }
            }
            result[@"playing"] = @(playing);
            if (pid > 0) result[@"source"] = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier ?: @"";
            completion(result);
        });
    });
}

id TBObserveNowPlaying(void (^changed)(NSNumber *)) {
    TBMediaPlayingObservation *observation = TBObserveMediaPlaying(changed);
    if (!observation) return nil;
    NSString * __unsafe_unretained *name = (NSString * __unsafe_unretained *)dlsym(mediaRemoteFramework(), "kMRMediaRemoteNowPlayingInfoDidChangeNotification");
    if (!name || !*name) { [observation invalidate]; return nil; }
    __weak TBMediaPlayingObservation *weakObservation = observation;
    id token = [[NSNotificationCenter defaultCenter] addObserverForName:*name object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        TBMediaPlayingObservation *owner = weakObservation;
        if (owner.changed) owner.changed(nil);
    }];
    [observation.observers addObject:token];
    return observation;
}

typedef void (*TBSetControlStripPresence)(NSString *, BOOL);
static TBSetControlStripPresence presenceFunction(void) {
    static TBSetControlStripPresence function;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Keep the framework loaded for the lifetime of the function pointer.
        void *framework = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY | RTLD_LOCAL);
        if (framework) function = (TBSetControlStripPresence)dlsym(framework, "DFRElementSetControlStripPresenceForIdentifier");
    });
    return function;
}

BOOL TBControlStripIsAvailable(void) {
    return presenceFunction() != NULL &&
        [NSTouchBarItem respondsToSelector:NSSelectorFromString(@"addSystemTrayItem:")] &&
        [NSTouchBarItem respondsToSelector:NSSelectorFromString(@"removeSystemTrayItem:")];
}

BOOL TBControlStripRegister(NSTouchBarItem *item) {
    if (!TBControlStripIsAvailable()) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)([NSTouchBarItem class], NSSelectorFromString(@"addSystemTrayItem:"), item);
    presenceFunction()(item.identifier, YES);
    return YES;
}

void TBControlStripUnregister(NSTouchBarItem *item) {
    if (!TBControlStripIsAvailable()) return;
    presenceFunction()(item.identifier, NO);
    ((void (*)(id, SEL, id))objc_msgSend)([NSTouchBarItem class], NSSelectorFromString(@"removeSystemTrayItem:"), item);
}

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
