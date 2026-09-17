#import <UIKit/UIKit.h>

/* Band indexes match the DSP: 0 low, 1 mid, 2 high. */
@interface ACSettings : NSObject

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) NSInteger mode; /* ACModeRecommended / ACModeCustom */
@property (nonatomic, assign) CGFloat lowGain;
@property (nonatomic, assign) CGFloat midGain;
@property (nonatomic, assign) CGFloat highGain;

+ (instancetype)shared;

- (void)load;
- (void)publish;     /* write plist, push notify state, wake mediaserverd */
- (void)publishLive; /* push notify state only, safe to call while dragging */
- (void)resetCurve;

- (CGFloat)gainForBand:(NSInteger)band;
- (void)setGain:(CGFloat)gain forBand:(NSInteger)band;

@end
