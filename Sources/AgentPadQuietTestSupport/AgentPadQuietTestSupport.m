#import "AgentPadQuietTestSupport.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <crt_externs.h>
#import <dlfcn.h>
#import <stdatomic.h>

// DEBUG harnesses and XCTest processes use containment. A release application's
// loader never installs it; release XCTest is still mandatory quiet mode.
// Nothing changes the owner's audio settings, input or desktop configuration.
static atomic_bool APEnabled;
static BOOL APXCTestProcess;
static BOOL APObserving, APFinished;
static __weak NSWindow *APSelectedWindow;
static NSHashTable<NSWindow *> *APWindows;
static NSMutableArray<NSString *> *APFailures;
static NSMutableArray *APObservers;
static NSTimer *APTimer;
static NSUInteger APSamples, APWindowChecks, APActivationBlocks, APOrderRequests;
static NSUInteger APTabModelDispatches;
static NSUInteger APMenuModelDispatches;
static NSUInteger APRealFocusObservations;
static NSUInteger APFocusBlocks;
static atomic_ulong APSounds, APNotifications;
static unsigned long (*APInjectedSounds)(void), (*APInjectedNotifications)(void), (*APInjectedGlobalEvents)(void);
static BOOL APDispatching;
static NSUInteger APInitializingWindows;
static NSWindow *(*APRealKeyWindow)(id, SEL);
static NSWindow *(*APRealMainWindow)(id, SEL);

@interface APQuietMonitor : NSObject
@property NSEventMask mask;
@property(copy) NSEvent *(^handler)(NSEvent *);
@end
@implementation APQuietMonitor
@end
static NSMutableArray<APQuietMonitor *> *APMonitors;

static void APSwizzle(Class cls, SEL original, SEL replacement) {
    Method old = class_getInstanceMethod(cls, original), new = class_getInstanceMethod(cls, replacement);
    if (!old || !new) return;
    if (class_addMethod(cls, original, method_getImplementation(new), method_getTypeEncoding(new))) {
        class_replaceMethod(cls, replacement, method_getImplementation(old), method_getTypeEncoding(old));
    } else { method_exchangeImplementations(old, new); }
}

static void APSuppressLegacyNotification(Class cls, SEL selector) {
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    IMP original = method_getImplementation(method);
    IMP replacement = imp_implementationWithBlock(^(id receiver, id notification) {
        if (APEnabled) { APNotifications++; return; }
        ((void (*)(id, SEL, id))original)(receiver, selector, notification);
    });
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}

static NSRect APOffscreen(NSRect frame) {
    CGFloat right = 0, top = 0;
    for (NSScreen *screen in NSScreen.screens) {
        right = MAX(right, NSMaxX(screen.frame)); top = MAX(top, NSMaxY(screen.frame));
    }
    frame.origin = NSMakePoint(right + 4096, top + 4096);
    return frame;
}

static NSRect APContainedFrame(NSRect frame) {
    return APXCTestProcess ? frame : APOffscreen(frame);
}

static void APContainWindow(NSWindow *window) {
    window.alphaValue = 0;
    window.ignoresMouseEvents = YES;
    window.hasShadow = NO;
    window.animationBehavior = NSWindowAnimationBehaviorNone;
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenNone;
    if (!APXCTestProcess) [window setFrame:APOffscreen(window.frame) display:NO];
}

static void APBlockFocus(NSWindow *window, SEL selector) {
    APFocusBlocks++;
    if (getenv("AGENTPAD_QUIET_TRACE_FOCUS")) {
        fprintf(stderr, "QUIET BLOCK: %s class=%s window=%ld\n%s\n", sel_getName(selector),
                class_getName(window.class), (long)window.windowNumber,
                [NSThread.callStackSymbols componentsJoinedByString:@"\n"].UTF8String);
    }
}

static void APRecordFailure(NSString *failure) {
    if (![APFailures containsObject:failure]) {
        [APFailures addObject:failure];
        fprintf(stderr, "QUIET FAIL: %s\n", failure.UTF8String);
    }
}

static void APSample(void) {
    if (!APEnabled || !NSThread.isMainThread || APInitializingWindows) return;
    APSamples++;
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (front.processIdentifier == getpid()) APRecordFailure(@"frontmostApplication became the test process");
    // NSWindow's base getters can delegate to a popover's parent and read a
    // fixture or selected-window getter. Application owners bypass that model.
    NSWindow *key = NSApp ? APRealKeyWindow(NSApp, @selector(keyWindow)) : nil;
    NSWindow *main = NSApp ? APRealMainWindow(NSApp, @selector(mainWindow)) : nil;
    if (key || main) {
        APRealFocusObservations++;
        APRecordFailure([NSString stringWithFormat:@"test application acquired real key/main ownership: key=%@/%ld main=%@/%ld",
                         key.class, (long)key.windowNumber, main.class, (long)main.windowNumber]);
    }
    NSMutableSet<NSWindow *> *windows = [NSMutableSet setWithArray:APWindows.allObjects];
    [windows addObjectsFromArray:NSApp.windows ?: @[]];
    NSArray<NSScreen *> *screens = NSScreen.screens;
    for (NSWindow *window in windows) {
        APWindowChecks++;
        if (getenv("AGENTPAD_QUIET_TRACE_FOCUS")) {
            BOOL (*windowKey)(id, SEL) = (BOOL (*)(id, SEL))class_getMethodImplementation(NSWindow.class, NSSelectorFromString(@"apq_isKeyWindow"));
            BOOL (*windowMain)(id, SEL) = (BOOL (*)(id, SEL))class_getMethodImplementation(NSWindow.class, NSSelectorFromString(@"apq_isMainWindow"));
            if (windowKey(window, @selector(isKeyWindow)) || windowMain(window, @selector(isMainWindow))) {
                fprintf(stderr, "QUIET FOCUS MODEL: class=%s window=%ld parent=%s; original-app-key=%ld original-app-main=%ld\n",
                        class_getName(window.class), (long)window.windowNumber, class_getName(window.parentWindow.class),
                        key ? (long)key.windowNumber : 0, main ? (long)main.windowNumber : 0);
            }
        }
        if (window.alphaValue != 0) APRecordFailure(@"test window lost zero alpha containment");
        if (!window.ignoresMouseEvents) APRecordFailure(@"test window can receive desktop mouse events");
        for (NSScreen *screen in screens) {
            if (NSIntersectsRect(window.frame, screen.frame) &&
                (!APXCTestProcess || (window.isVisible && window.alphaValue > 0))) {
                APRecordFailure([NSString stringWithFormat:@"uncontained window %ld intersects screen: %@", (long)window.windowNumber, NSStringFromRect(window.frame)]);
            }
        }
        if (window.styleMask & NSWindowStyleMaskFullScreen) APRecordFailure(@"test window entered fullscreen");
    }
}

static NSString *APSummary(void) {
    return [NSString stringWithFormat:@"QUIET %@: frontmostApplication checks=%lu test-app-frontmost=%@; window/screen checks=%lu intersections=%@; activation-blocks=%lu order-requests=%lu muted-sounds=%lu suppressed-notifications=%lu blocked-global-events=%lu firstResponder-tab-dispatches=%lu menu-action-dispatches=%lu os-key-main=%lu focus-blocks=%lu geometry=%@ routing-model=selected-window",
            APFailures.count ? @"FAIL" : @"PASS", (unsigned long)APSamples,
            [APFailures containsObject:@"frontmostApplication became the test process"] ? @"YES" : @"0",
            (unsigned long)APWindowChecks,
            [APFailures filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF CONTAINS 'intersects screen'"]].count ? @"YES" : @"0",
            (unsigned long)APActivationBlocks, (unsigned long)APOrderRequests,
            (unsigned long)(atomic_load(&APSounds) + (APInjectedSounds ? APInjectedSounds() : 0)), (unsigned long)(atomic_load(&APNotifications) + (APInjectedNotifications ? APInjectedNotifications() : 0)), (unsigned long)(APInjectedGlobalEvents ? APInjectedGlobalEvents() : 0), (unsigned long)APTabModelDispatches, (unsigned long)APMenuModelDispatches, (unsigned long)APRealFocusObservations, (unsigned long)APFocusBlocks, APXCTestProcess ? @"preserved-invisible" : @"offscreen-invisible"];
}

static void APExitSummary(void) {
    if (!APEnabled) return;
    @autoreleasepool {
        APSample();
        if (!APFinished || APFailures.count) fprintf(stderr, "%s\n", APSummary().UTF8String);
        // XCTest's exit status must not mask a containment failure.
        if (APFailures.count) _Exit(1);
    }
}

static void APObserve(void) {
    if (APObserving || !NSApp || !NSThread.isMainThread) return;
    APObserving = YES;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    [APObservers addObject:[workspace addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
        if (app.processIdentifier == getpid()) APRecordFailure(@"frontmostApplication became the test process");
        APSample();
    }]];
    for (NSNotificationName name in @[NSWindowDidMoveNotification, NSWindowDidResizeNotification, NSWindowDidBecomeKeyNotification,
                                     NSWindowDidBecomeMainNotification, NSWindowDidEnterFullScreenNotification]) {
        [APObservers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { APSample(); }]];
    }
    [APObservers addObject:[NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        // Reposition before subsequent test interactions when monitors change.
        for (NSWindow *window in APWindows.allObjects) APContainWindow(window);
        APSample();
    }]];
    APTimer = [NSTimer timerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer) { APSample(); }];
    [NSRunLoop.mainRunLoop addTimer:APTimer forMode:NSRunLoopCommonModes];
    APSample();
    fprintf(stderr, "QUIET START: policy=prohibited; alpha=0; ignoresMouseEvents=YES; geometry=%s; application-events; no-sounds-or-notifications; frontmost-pid=%d test-pid=%d\n",
            APXCTestProcess ? "preserved" : "offscreen", NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier, getpid());
}

static NSView *APTabModelCurrentView(NSWindow *window) {
    if (APTabModelDispatches++ == 0) {
        fprintf(stderr, "QUIET NOT RUN: native key-window Tab traversal; checking product Tab dispatch via invisible firstResponder APIs\n");
    }
    NSResponder *responder = window.firstResponder;
    if ([responder isKindOfClass:NSTextView.class] && [(NSTextView *)responder isFieldEditor]) {
        id delegate = [(NSTextView *)responder delegate];
        if ([delegate isKindOfClass:NSView.class]) return delegate;
    }
    return [responder isKindOfClass:NSView.class] ? (NSView *)responder : nil;
}

static NSWindow *APVisibleSelectedWindow(void) {
    return APSelectedWindow.isVisible ? APSelectedWindow : nil;
}

static id APMenuTarget(NSMenuItem *item) {
    if (item.target) return [item.target respondsToSelector:item.action] ? item.target : nil;
    // Resolve the selected window's responder chain explicitly. AppKit's
    // application lookup can otherwise consult its actual (absent) key window.
    NSWindow *window = APVisibleSelectedWindow();
    NSResponder *responder = window.firstResponder;
    NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    while (responder && ![seen containsObject:responder]) {
        if ([responder respondsToSelector:item.action]) return responder;
        [seen addObject:responder]; responder = responder.nextResponder;
    }
    for (id candidate in @[window ?: NSNull.null, window.windowController ?: NSNull.null,
                           (id)NSApp.delegate ?: NSNull.null, NSApp]) {
        if ([candidate respondsToSelector:item.action]) return candidate;
    }
    return nil;
}

static BOOL APPerformMenuKey(NSMenu *menu, NSEvent *event) {
    if (event.type != NSEventTypeKeyDown) return NO;
    const NSEventModifierFlags mask = NSEventModifierFlagCommand | NSEventModifierFlagControl |
                                     NSEventModifierFlagOption | NSEventModifierFlagShift;
    NSString *characters = event.charactersIgnoringModifiers ?: @"";
    [menu update];
    for (NSMenuItem *item in menu.itemArray.copy) {
        if (item.hidden && !item.allowsKeyEquivalentWhenHidden) continue;
        if (!item.enabled) continue;
        if (item.submenu && APPerformMenuKey(item.submenu, event)) return YES;
        if (!item.action || !item.keyEquivalent.length) continue;
        NSEventModifierFlags expected = item.keyEquivalentModifierMask & mask;
        NSString *key = item.keyEquivalent;
        // AppKit treats an uppercase letter key equivalent as requiring Shift.
        if (![key.lowercaseString isEqualToString:key.uppercaseString] && [key isEqualToString:key.uppercaseString]) {
            expected |= NSEventModifierFlagShift;
        }
        if (expected != (event.modifierFlags & mask) || ![key.lowercaseString isEqualToString:characters.lowercaseString]) continue;
        id target = APMenuTarget(item);
        if (!target) continue;
        if ([target respondsToSelector:@selector(validateMenuItem:)] && ![(id<NSMenuItemValidation>)target validateMenuItem:item]) continue;
        if ([target respondsToSelector:@selector(validateUserInterfaceItem:)] &&
            ![(id<NSUserInterfaceValidations>)target validateUserInterfaceItem:item]) continue;
        if (APMenuModelDispatches++ == 0) {
            fprintf(stderr, "QUIET NOT RUN: native OS shortcut dispatch; checking installed menu key/modifiers, validation and action via the selected-window responder model\n");
        }
        return [NSApp sendAction:item.action to:target from:item];
    }
    return NO;
}

@interface NSMenu (APQuiet)
@end
@implementation NSMenu (APQuiet)
- (BOOL)apq_performKeyEquivalent:(NSEvent *)event {
    return APEnabled ? APPerformMenuKey(self, event) : [self apq_performKeyEquivalent:event];
}
@end

@interface NSApplication (APQuiet)
@end
@implementation NSApplication (APQuiet)
+ (NSApplication *)apq_sharedApplication {
    NSApplication *app = [self apq_sharedApplication];
    if (APEnabled) APObserve();
    return app;
}
- (BOOL)apq_setActivationPolicy:(NSApplicationActivationPolicy)policy {
    return [self apq_setActivationPolicy:APEnabled ? NSApplicationActivationPolicyProhibited : policy];
}
- (void)apq_activateIgnoringOtherApps:(BOOL)flag {
    if (APEnabled) { APActivationBlocks++; APSample(); return; }
    [self apq_activateIgnoringOtherApps:flag];
}
- (void)apq_activate {
    if (APEnabled) { APActivationBlocks++; APSample(); return; }
    [self apq_activate];
}
- (NSWindow *)apq_keyWindow { return APEnabled ? APVisibleSelectedWindow() : [self apq_keyWindow]; }
- (NSWindow *)apq_mainWindow { return APEnabled ? APVisibleSelectedWindow() : [self apq_mainWindow]; }
- (NSInteger)apq_requestUserAttention:(NSRequestUserAttentionType)type {
    if (APEnabled) { APNotifications++; return 0; }
    return [self apq_requestUserAttention:type];
}
- (void)apq_sendEvent:(NSEvent *)event {
    if (APEnabled) {
        // AppKit also delivers internal events to completion/tooltip windows.
        // Receiving an event does not make such a window the routing owner.
        // Only explicit harness selection/send or a key-window request does.
        // Local monitors belong to application dispatch, before any window
        // subclass can consume sendEvent without invoking NSWindow's method.
        BOOL wasDispatching = APDispatching;
        APDispatching = YES;
        @try {
            NSEvent *next = event;
            for (APQuietMonitor *monitor in [(NSArray *)APMonitors.copy reverseObjectEnumerator]) {
                if (next && (monitor.mask & NSEventMaskFromType(next.type))) next = monitor.handler(next);
            }
            if (next && [NSApp.mainMenu performKeyEquivalent:next]) next = nil;
            if (next) [(next.window ?: APSelectedWindow) sendEvent:next];
        } @finally { APDispatching = wasDispatching; APSample(); }
        return;
    }
    [self apq_sendEvent:event];
}
- (NSModalResponse)apq_runModalForWindow:(NSWindow *)window {
    if (APEnabled) { APNotifications++; return NSModalResponseCancel; }
    return [self apq_runModalForWindow:window];
}
- (BOOL)apq_presentError:(NSError *)error {
    if (APEnabled) { APNotifications++; return NO; }
    return [self apq_presentError:error];
}
- (void)apq_setPresentationOptions:(NSApplicationPresentationOptions)options {
    [self apq_setPresentationOptions:APEnabled ? NSApplicationPresentationDefault : options];
}
@end

@interface NSRunningApplication (APQuiet)
@end

@interface NSView (APQuiet)
@end
@implementation NSView (APQuiet)
- (BOOL)apq_enterFullScreenMode:(NSScreen *)screen withOptions:(NSDictionary *)options {
    if (APEnabled) { fprintf(stderr, "QUIET NOT RUN: real fullscreen requires a visible view\n"); return NO; }
    return [self apq_enterFullScreenMode:screen withOptions:options];
}
@end
@implementation NSRunningApplication (APQuiet)
- (BOOL)apq_activateWithOptions:(NSApplicationActivationOptions)options {
    if (APEnabled) { APActivationBlocks++; return NO; }
    return [self apq_activateWithOptions:options];
}
- (BOOL)apq_activateFromApplication:(NSRunningApplication *)application options:(NSApplicationActivationOptions)options {
    if (APEnabled) { APActivationBlocks++; return NO; }
    return [self apq_activateFromApplication:application options:options];
}
@end

@interface NSWindow (APQuiet)
@end
@implementation NSWindow (APQuiet)
- (instancetype)apq_initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)defer {
    if (APEnabled) APInitializingWindows++;
    NSWindow *window = [self apq_initWithContentRect:APEnabled ? APContainedFrame(rect) : rect styleMask:style backing:backing defer:defer];
    if (APEnabled) {
        // AppKit may cascade a newly initialized, still-unordered window onto
        // the main screen despite its requested rect. Contain it before it is
        // returned to the caller (orderWindow is independently guarded).
        APContainWindow(window);
        [APWindows addObject:window];
        APInitializingWindows--; APSample();
    }
    return window;
}
- (instancetype)apq_initWithContentRect:(NSRect)rect styleMask:(NSWindowStyleMask)style backing:(NSBackingStoreType)backing defer:(BOOL)defer screen:(NSScreen *)screen {
    if (APEnabled) APInitializingWindows++;
    NSWindow *window = [self apq_initWithContentRect:APEnabled ? APContainedFrame(rect) : rect styleMask:style backing:backing defer:defer screen:screen];
    if (APEnabled) {
        APContainWindow(window);
        [APWindows addObject:window];
        APInitializingWindows--; APSample();
    }
    return window;
}
- (void)apq_setFrame:(NSRect)frame display:(BOOL)display {
    [self apq_setFrame:APEnabled ? APContainedFrame(frame) : frame display:display];
    if (APEnabled) APSample();
}
- (void)apq_setFrame:(NSRect)frame display:(BOOL)display animate:(BOOL)animate {
    [self apq_setFrame:APEnabled ? APContainedFrame(frame) : frame display:display animate:APEnabled ? NO : animate];
    if (APEnabled) APSample();
}
- (void)apq_setFrameOrigin:(NSPoint)point {
    [self apq_setFrameOrigin:APEnabled && !APXCTestProcess ? APOffscreen(self.frame).origin : point];
    if (APEnabled) APSample();
}
- (void)apq_setFrameTopLeftPoint:(NSPoint)point {
    if (APEnabled && !APXCTestProcess) { [self setFrame:APOffscreen(self.frame) display:NO]; return; }
    [self apq_setFrameTopLeftPoint:point];
}
- (NSRect)apq_constrainFrameRect:(NSRect)rect toScreen:(NSScreen *)screen {
    return APEnabled ? APContainedFrame(rect) : [self apq_constrainFrameRect:rect toScreen:screen];
}
- (void)apq_center {
    if (APEnabled && !APXCTestProcess) { [self setFrame:APOffscreen(self.frame) display:NO]; return; }
    [self apq_center];
}
- (void)apq_setAlphaValue:(CGFloat)alpha { [self apq_setAlphaValue:APEnabled ? 0 : alpha]; }
- (void)apq_setIgnoresMouseEvents:(BOOL)ignores { [self apq_setIgnoresMouseEvents:APEnabled ? YES : ignores]; }
- (void)apq_setHasShadow:(BOOL)shadow { [self apq_setHasShadow:APEnabled ? NO : shadow]; }
- (void)apq_setAnimationBehavior:(NSWindowAnimationBehavior)behavior {
    [self apq_setAnimationBehavior:APEnabled ? NSWindowAnimationBehaviorNone : behavior];
}
- (void)apq_setCollectionBehavior:(NSWindowCollectionBehavior)behavior {
    [self apq_setCollectionBehavior:APEnabled ? (NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenNone | NSWindowCollectionBehaviorFullScreenDisallowsTiling) : behavior];
}
- (void)apq_orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)other {
    if (APEnabled) { APOrderRequests++; APContainWindow(self); }
    [self apq_orderWindow:place relativeTo:other];
    if (APEnabled) APSample();
}
- (void)apq_orderFrontRegardless {
    if (APEnabled) { [self orderWindow:NSWindowAbove relativeTo:0]; return; }
    [self apq_orderFrontRegardless];
}
- (void)apq_makeKeyAndOrderFront:(id)sender {
    if (APEnabled) { APQuietSelectWindow(self); [self orderWindow:NSWindowAbove relativeTo:0]; return; }
    [self apq_makeKeyAndOrderFront:sender];
}
- (void)apq_makeKeyWindow { if (APEnabled) { APQuietSelectWindow(self); return; } [self apq_makeKeyWindow]; }
- (void)apq_makeMainWindow { if (APEnabled) { APQuietSelectWindow(self); return; } [self apq_makeMainWindow]; }
- (void)apq_becomeKeyWindow { if (APEnabled) { APBlockFocus(self, @selector(becomeKeyWindow)); return; } [self apq_becomeKeyWindow]; }
- (void)apq_becomeMainWindow { if (APEnabled) { APBlockFocus(self, @selector(becomeMainWindow)); return; } [self apq_becomeMainWindow]; }
- (BOOL)apq_canBecomeKeyWindow { return APEnabled ? NO : [self apq_canBecomeKeyWindow]; }
- (BOOL)apq_canBecomeMainWindow { return APEnabled ? NO : [self apq_canBecomeMainWindow]; }
- (BOOL)apq_isKeyWindow { return APEnabled ? self == APVisibleSelectedWindow() : [self apq_isKeyWindow]; }
- (BOOL)apq_isMainWindow { return APEnabled ? self == APVisibleSelectedWindow() : [self apq_isMainWindow]; }
- (void)apq_toggleFullScreen:(id)sender {
    if (APEnabled) { fprintf(stderr, "QUIET NOT RUN: real fullscreen requires a visible window\n"); return; }
    [self apq_toggleFullScreen:sender];
}
- (void)apq_selectNextKeyView:(id)sender {
    if (!APEnabled) { [self apq_selectNextKeyView:sender]; return; }
    // Invoke the real responder API only when product code requests traversal.
    // A no-op product Tab handler never reaches this adapter. This deliberately
    // proves dispatch and the invisible focus model, not OS key-window traversal.
    NSView *current = APTabModelCurrentView(self);
    if (current) [self selectKeyViewFollowingView:current];
}
- (void)apq_selectPreviousKeyView:(id)sender {
    if (!APEnabled) { [self apq_selectPreviousKeyView:sender]; return; }
    NSView *current = APTabModelCurrentView(self);
    if (current) [self selectKeyViewPrecedingView:current];
}
- (void)apq_sendEvent:(NSEvent *)event {
    if (!APEnabled || APDispatching) { [self apq_sendEvent:event]; return; }
    [NSApp sendEvent:event];
}
@end

@interface NSEvent (APQuiet)
@end
@implementation NSEvent (APQuiet)
+ (id)apq_addLocalMonitorForEventsMatchingMask:(NSEventMask)mask handler:(NSEvent *(^)(NSEvent *))handler {
    if (!APEnabled) return [self apq_addLocalMonitorForEventsMatchingMask:mask handler:handler];
    APQuietMonitor *monitor = [APQuietMonitor new]; monitor.mask = mask; monitor.handler = handler;
    [APMonitors addObject:monitor]; return monitor;
}
+ (id)apq_addGlobalMonitorForEventsMatchingMask:(NSEventMask)mask handler:(void (^)(NSEvent *))handler {
    if (!APEnabled) return [self apq_addGlobalMonitorForEventsMatchingMask:mask handler:handler];
    return [APQuietMonitor new];
}
+ (void)apq_removeMonitor:(id)monitor {
    if ([monitor isKindOfClass:APQuietMonitor.class]) { [APMonitors removeObjectIdenticalTo:monitor]; return; }
    [self apq_removeMonitor:monitor];
}
@end

@interface NSSound (APQuiet)
@end
@implementation NSSound (APQuiet)
- (BOOL)apq_play { if (APEnabled) { APSounds++; return NO; } return [self apq_play]; }
- (BOOL)apq_resume { if (APEnabled) { APSounds++; return NO; } return [self apq_resume]; }
@end
@interface AVAudioPlayer (APQuiet)
@end
@implementation AVAudioPlayer (APQuiet)
- (BOOL)apq_play { if (APEnabled) { APSounds++; return NO; } return [self apq_play]; }
- (BOOL)apq_playAtTime:(NSTimeInterval)time { if (APEnabled) { APSounds++; return NO; } return [self apq_playAtTime:time]; }
@end
@interface AVPlayer (APQuiet)
@end
@implementation AVPlayer (APQuiet)
- (void)apq_setMuted:(BOOL)muted { [self apq_setMuted:APEnabled ? YES : muted]; }
- (void)apq_setRate:(float)rate { if (APEnabled) self.muted = YES; [self apq_setRate:rate]; }
- (void)apq_play { if (APEnabled) self.muted = YES; [self apq_play]; }
@end
@interface NSAlert (APQuiet)
@end
@implementation NSAlert (APQuiet)
- (NSModalResponse)apq_runModal { if (APEnabled) { APNotifications++; return NSModalResponseCancel; } return [self apq_runModal]; }
- (void)apq_beginSheetModalForWindow:(NSWindow *)window completionHandler:(void (^)(NSModalResponse))handler {
    if (APEnabled) { APNotifications++; if (handler) handler(NSModalResponseCancel); return; }
    [self apq_beginSheetModalForWindow:window completionHandler:handler];
}
@end
@interface UNUserNotificationCenter (APQuiet)
@end
@implementation UNUserNotificationCenter (APQuiet)
- (void)apq_addNotificationRequest:(UNNotificationRequest *)request withCompletionHandler:(void (^)(NSError *))completion {
    if (APEnabled) { APNotifications++; if (completion) completion(nil); return; }
    [self apq_addNotificationRequest:request withCompletionHandler:completion];
}
- (void)apq_requestAuthorizationWithOptions:(UNAuthorizationOptions)options completionHandler:(void (^)(BOOL, NSError *))completion {
    if (APEnabled) { APNotifications++; completion(NO, nil); return; }
    [self apq_requestAuthorizationWithOptions:options completionHandler:completion];
}
@end

void APQuietInstall(void) {
#if !DEBUG
    if (!APXCTestProcess) return;
#endif
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bool (*loaded)(void) = dlsym(RTLD_DEFAULT, "APQuietInterposerLoaded");
        if (!loaded || !loaded()) {
            fprintf(stderr, "QUIET FAIL: launch with DYLD_INSERT_LIBRARIES=path/to/libAgentPadQuietInterposer.dylib (build product AgentPadQuietInterposer)\n"); _Exit(1);
        }
        APInjectedSounds = dlsym(RTLD_DEFAULT, "APQuietInterposedSoundCount");
        APInjectedNotifications = dlsym(RTLD_DEFAULT, "APQuietInterposedNotificationCount");
        APInjectedGlobalEvents = dlsym(RTLD_DEFAULT, "APQuietInterposedGlobalEventCount");
        APWindows = [NSHashTable weakObjectsHashTable]; APFailures = [NSMutableArray new];
        APObservers = [NSMutableArray new]; APMonitors = [NSMutableArray new];
        APRealKeyWindow = (NSWindow *(*)(id, SEL))class_getMethodImplementation(NSApplication.class, @selector(keyWindow));
        APRealMainWindow = (NSWindow *(*)(id, SEL))class_getMethodImplementation(NSApplication.class, @selector(mainWindow));
#define HOOK(C, S, R) APSwizzle(C.class, @selector(S), @selector(R))
#define CLASSHOOK(C, S, R) APSwizzle(object_getClass(C.class), @selector(S), @selector(R))
        CLASSHOOK(NSApplication, sharedApplication, apq_sharedApplication);
        HOOK(NSApplication, setActivationPolicy:, apq_setActivationPolicy:);
        HOOK(NSApplication, activateIgnoringOtherApps:, apq_activateIgnoringOtherApps:);
        HOOK(NSApplication, activate, apq_activate);
        HOOK(NSApplication, keyWindow, apq_keyWindow); HOOK(NSApplication, mainWindow, apq_mainWindow);
        HOOK(NSApplication, requestUserAttention:, apq_requestUserAttention:);
        HOOK(NSApplication, sendEvent:, apq_sendEvent:); HOOK(NSApplication, runModalForWindow:, apq_runModalForWindow:);
        HOOK(NSApplication, presentError:, apq_presentError:); HOOK(NSApplication, setPresentationOptions:, apq_setPresentationOptions:);
        HOOK(NSMenu, performKeyEquivalent:, apq_performKeyEquivalent:);
        HOOK(NSRunningApplication, activateWithOptions:, apq_activateWithOptions:);
        HOOK(NSRunningApplication, activateFromApplication:options:, apq_activateFromApplication:options:);
        HOOK(NSWindow, initWithContentRect:styleMask:backing:defer:, apq_initWithContentRect:styleMask:backing:defer:);
        HOOK(NSWindow, initWithContentRect:styleMask:backing:defer:screen:, apq_initWithContentRect:styleMask:backing:defer:screen:);
        HOOK(NSWindow, setFrame:display:, apq_setFrame:display:); HOOK(NSWindow, setFrame:display:animate:, apq_setFrame:display:animate:);
        HOOK(NSWindow, setFrameOrigin:, apq_setFrameOrigin:); HOOK(NSWindow, setFrameTopLeftPoint:, apq_setFrameTopLeftPoint:);
        HOOK(NSWindow, constrainFrameRect:toScreen:, apq_constrainFrameRect:toScreen:); HOOK(NSWindow, center, apq_center);
        HOOK(NSWindow, setAlphaValue:, apq_setAlphaValue:); HOOK(NSWindow, setIgnoresMouseEvents:, apq_setIgnoresMouseEvents:);
        HOOK(NSWindow, setHasShadow:, apq_setHasShadow:);
        HOOK(NSWindow, setAnimationBehavior:, apq_setAnimationBehavior:);
        HOOK(NSWindow, setCollectionBehavior:, apq_setCollectionBehavior:);
        HOOK(NSWindow, orderWindow:relativeTo:, apq_orderWindow:relativeTo:); HOOK(NSWindow, orderFrontRegardless, apq_orderFrontRegardless);
        HOOK(NSWindow, makeKeyAndOrderFront:, apq_makeKeyAndOrderFront:); HOOK(NSWindow, makeKeyWindow, apq_makeKeyWindow);
        HOOK(NSWindow, makeMainWindow, apq_makeMainWindow); HOOK(NSWindow, canBecomeKeyWindow, apq_canBecomeKeyWindow);
        HOOK(NSWindow, becomeKeyWindow, apq_becomeKeyWindow); HOOK(NSWindow, becomeMainWindow, apq_becomeMainWindow);
        HOOK(NSWindow, canBecomeMainWindow, apq_canBecomeMainWindow); HOOK(NSWindow, toggleFullScreen:, apq_toggleFullScreen:);
        // This is only routing eligibility. Actual OS ownership is sampled
        // through the saved base IMPs above, never through these model getters.
        HOOK(NSWindow, isKeyWindow, apq_isKeyWindow); HOOK(NSWindow, isMainWindow, apq_isMainWindow);
        HOOK(NSWindow, selectNextKeyView:, apq_selectNextKeyView:); HOOK(NSWindow, selectPreviousKeyView:, apq_selectPreviousKeyView:);
        HOOK(NSWindow, sendEvent:, apq_sendEvent:);
        HOOK(NSView, enterFullScreenMode:withOptions:, apq_enterFullScreenMode:withOptions:);
        CLASSHOOK(NSEvent, addLocalMonitorForEventsMatchingMask:handler:, apq_addLocalMonitorForEventsMatchingMask:handler:);
        CLASSHOOK(NSEvent, addGlobalMonitorForEventsMatchingMask:handler:, apq_addGlobalMonitorForEventsMatchingMask:handler:);
        CLASSHOOK(NSEvent, removeMonitor:, apq_removeMonitor:);
        HOOK(NSSound, play, apq_play); HOOK(NSSound, resume, apq_resume);
        HOOK(AVAudioPlayer, play, apq_play); HOOK(AVAudioPlayer, playAtTime:, apq_playAtTime:);
        HOOK(AVPlayer, setMuted:, apq_setMuted:); HOOK(AVPlayer, setRate:, apq_setRate:); HOOK(AVPlayer, play, apq_play);
        HOOK(NSAlert, runModal, apq_runModal); HOOK(NSAlert, beginSheetModalForWindow:completionHandler:, apq_beginSheetModalForWindow:completionHandler:);
        HOOK(UNUserNotificationCenter, addNotificationRequest:withCompletionHandler:, apq_addNotificationRequest:withCompletionHandler:);
        HOOK(UNUserNotificationCenter, requestAuthorizationWithOptions:completionHandler:, apq_requestAuthorizationWithOptions:completionHandler:);
        APSuppressLegacyNotification(NSClassFromString(@"NSUserNotificationCenter"), NSSelectorFromString(@"deliverNotification:"));
        APSuppressLegacyNotification(NSClassFromString(@"NSUserNotificationCenter"), NSSelectorFromString(@"scheduleNotification:"));
#undef HOOK
#undef CLASSHOOK
        atexit(APExitSummary);
    });
}

void APQuietStart(void) {
#if !DEBUG
    if (!APXCTestProcess) return;
#endif
    APQuietInstall(); APEnabled = YES;
    [NSApplication sharedApplication]; APObserve();
    for (NSWindow *window in NSApp.windows) { APContainWindow(window); [APWindows addObject:window]; }
    APSample();
}
void APQuietSelectWindow(NSWindow *window) {
    if (!APEnabled) APQuietStart();
    if (!APEnabled) return;
    APSelectedWindow = window; [APWindows addObject:window];
    APContainWindow(window);
    [window orderWindow:NSWindowBelow relativeTo:0]; APSample();
}
void APQuietSendEvent(NSEvent *event, NSWindow *window) {
    if (!APEnabled) APQuietStart();
    if (!APEnabled) return;
    APSelectedWindow = window; [APWindows addObject:window];
    [NSApp sendEvent:event]; APSample();
}
NSString *APQuietFailure(void) { APSample(); return APFailures.count ? [APFailures componentsJoinedByString:@"; "] : nil; }
NSString *APQuietFinish(void) { APSample(); APFinished = YES; return APSummary(); }
BOOL APQuietIsEnabled(void) { return APEnabled; }
NSUInteger APQuietMutedSoundCount(void) { return atomic_load(&APSounds) + (APInjectedSounds ? APInjectedSounds() : 0); }
BOOL APQuietWindowHasOSFocus(NSWindow *window) {
    if (!NSApp) return NO;
    return APRealKeyWindow && APRealMainWindow ?
        APRealKeyWindow(NSApp, @selector(keyWindow)) == window || APRealMainWindow(NSApp, @selector(mainWindow)) == window :
        NSApp.keyWindow == window || NSApp.mainWindow == window;
}

@interface APQuietLoader : NSObject
@end
@implementation APQuietLoader
+ (void)load {
    // C argument detection avoids constructing NSApplication during +load.
    APXCTestProcess = getenv("XCTestConfigurationFilePath") != NULL || getenv("XCTestBundlePath") != NULL;
    char **args = *_NSGetArgv();
    for (int i = 0; i < *_NSGetArgc(); i++) {
        if (strstr(args[i], ".xctest") || strstr(args[i], "/xctest")) APXCTestProcess = YES;
    }
    BOOL test = APXCTestProcess;
#if DEBUG
    test |= getenv("AGENTPAD_QUIET_TEST") != NULL;
    for (int i = 0; i < *_NSGetArgc(); i++) {
        if (strstr(args[i], "--self-check-") || strstr(args[i], "--screenshot")) test = YES;
    }
#endif
    if (test) { @autoreleasepool { APQuietInstall(); APEnabled = YES; } }
}
@end
