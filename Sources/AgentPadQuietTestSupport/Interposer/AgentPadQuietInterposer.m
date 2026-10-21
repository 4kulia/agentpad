#import "AgentPadQuietInterposer.h"
#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <stdatomic.h>

// A separately inserted image is necessary: dyld does not apply interposition
// tuples in the main executable. This library has no shipped-app dependency.
// Quiet harnesses fail closed unless its marker is present before AppKit starts.
static atomic_ulong sounds, notifications, globalEvents;
bool APQuietInterposerLoaded(void) { return true; }
unsigned long APQuietInterposedSoundCount(void) { return atomic_load(&sounds); }
unsigned long APQuietInterposedNotificationCount(void) { return atomic_load(&notifications); }
unsigned long APQuietInterposedGlobalEventCount(void) { return atomic_load(&globalEvents); }

static void quietBeep(void) { sounds++; }
static void quietSound(SystemSoundID sound) { sounds++; }
static void quietSoundCompletion(SystemSoundID sound, void (^completion)(void)) { sounds++; if (completion) completion(); }
static void quietPost(CGEventTapLocation location, CGEventRef event) { globalEvents++; }
static void quietPostToPid(pid_t pid, CGEventRef event) { globalEvents++; }
static SInt32 quietAlert(CFTimeInterval timeout, CFOptionFlags flags, CFURLRef icon,
                        CFURLRef sound, CFURLRef localization, CFStringRef header,
                        CFStringRef message, CFStringRef defaultButton, CFStringRef alternate,
                        CFStringRef other, CFOptionFlags *response) {
    notifications++; if (response) *response = kCFUserNotificationCancelResponse; return 0;
}
static void quietAccessibility(id element, NSAccessibilityNotificationName notification, NSDictionary *userInfo) {
    if ([notification isEqualToString:NSAccessibilityAnnouncementRequestedNotification]) { sounds++; return; }
    // dyld leaves calls from the replacing image bound to the system function.
    NSAccessibilityPostNotificationWithUserInfo(element, notification, userInfo);
}
#define INTERPOSE(REPLACEMENT, ORIGINAL) \
    __attribute__((used)) static struct { const void *replacement; const void *original; } \
    interpose_##ORIGINAL __attribute__((section("__DATA,__interpose"))) = \
        { (const void *)(uintptr_t)&REPLACEMENT, (const void *)(uintptr_t)&ORIGINAL };
INTERPOSE(quietBeep, NSBeep)
INTERPOSE(quietSound, AudioServicesPlaySystemSound)
INTERPOSE(quietSound, AudioServicesPlayAlertSound)
INTERPOSE(quietSoundCompletion, AudioServicesPlaySystemSoundWithCompletion)
INTERPOSE(quietSoundCompletion, AudioServicesPlayAlertSoundWithCompletion)
INTERPOSE(quietPost, CGEventPost)
INTERPOSE(quietPostToPid, CGEventPostToPid)
INTERPOSE(quietAlert, CFUserNotificationDisplayAlert)
INTERPOSE(quietAccessibility, NSAccessibilityPostNotificationWithUserInfo)
