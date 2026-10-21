#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
/// Test-process containment: DEBUG harnesses and XCTest in either build mode.
/// Ordinary release applications cannot enable this support.
FOUNDATION_EXPORT void APQuietInstall(void);
FOUNDATION_EXPORT void APQuietStart(void);
FOUNDATION_EXPORT void APQuietSelectWindow(NSWindow *window);
FOUNDATION_EXPORT void APQuietSendEvent(NSEvent *event, NSWindow *window);
FOUNDATION_EXPORT NSString * _Nullable APQuietFailure(void);
FOUNDATION_EXPORT NSString *APQuietFinish(void);
FOUNDATION_EXPORT BOOL APQuietIsEnabled(void);
FOUNDATION_EXPORT NSUInteger APQuietMutedSoundCount(void);
/// Original application window ownership, bypassing routing and inherited focus.
FOUNDATION_EXPORT BOOL APQuietWindowHasOSFocus(NSWindow *window);
NS_ASSUME_NONNULL_END
