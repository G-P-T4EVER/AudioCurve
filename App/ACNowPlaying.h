#import <UIKit/UIKit.h>

extern NSString *const ACNowPlayingDidChangeNotification;

/* Now playing info for whatever app owns audio right now, via MediaRemote.
 * Works for Music, Spotify, YouTube, podcasts and anything else that publishes
 * playback info. */
@interface ACNowPlaying : NSObject

@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSString *artist;
@property (nonatomic, readonly, strong) UIImage *artwork;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL available;

+ (instancetype)shared;

- (void)beginObserving;
- (void)refresh;
- (void)togglePlayPause;

@end
