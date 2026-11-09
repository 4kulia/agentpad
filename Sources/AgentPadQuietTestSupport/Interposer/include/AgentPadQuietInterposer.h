#include <stdbool.h>
#import <Foundation/Foundation.h>
bool APQuietInterposerLoaded(void);
unsigned long APQuietInterposedSoundCount(void);
unsigned long APQuietInterposedNotificationCount(void);
unsigned long APQuietInterposedGlobalEventCount(void);
void APQuietInterposedCaptureAnnouncements(bool enabled);
NSArray<NSDictionary *> *APQuietInterposedAnnouncements(void);
