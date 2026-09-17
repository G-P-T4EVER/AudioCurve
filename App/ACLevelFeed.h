#import <UIKit/UIKit.h>

#import "ac_meter.h"

@protocol ACLevelFeedDelegate <NSObject>
- (void)levelFeedDidUpdate;
@end

/* Polls the 8 band magnitudes that mediaserverd publishes and smooths them for
 * display. Nothing here talks to the audio session, so it also reflects audio
 * coming from other apps. */
@interface ACLevelFeed : NSObject

@property (nonatomic, weak) id<ACLevelFeedDelegate> delegate;
@property (nonatomic, readonly) BOOL audioActive;
@property (nonatomic, readonly) BOOL tweakResponding;

- (void)start;
- (void)stop;
- (float)levelForBand:(NSInteger)band;

@end
