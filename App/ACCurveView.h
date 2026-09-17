#import <UIKit/UIKit.h>

@class ACCurveView;

@protocol ACCurveViewDelegate <NSObject>
- (void)curveView:(ACCurveView *)view didChangeGain:(CGFloat)gain forBand:(NSInteger)band;
- (void)curveViewDidBeginEditing:(ACCurveView *)view;
- (void)curveViewDidEndEditing:(ACCurveView *)view;
@end

/* The AirPods style waveform plus the three draggable LOW / MID / HIGH knobs.
 * Bars are driven by the live spectrum from mediaserverd and are additionally
 * shaped by the current curve, so a bass boost visibly lifts the left side. */
@interface ACCurveView : UIView

@property (nonatomic, weak) id<ACCurveViewDelegate> delegate;
@property (nonatomic, assign) NSInteger selectedBand;
@property (nonatomic, assign) BOOL audioActive;

- (void)reloadGains;
- (void)updateWithLevels:(const float *)levels count:(NSInteger)count;

@end
