#import "ACCurveView.h"

#import "ACSettings.h"
#import "ACShared.h"
#import "ac_meter.h"
#import "eq_dsp.h"

#define AC_BAR_COUNT 56
#define AC_LABEL_AREA 24.0
#define AC_SIDE_INSET 16.0

static const CGFloat kBandX[AC_BANDS] = { 0.215f, 0.5f, 0.785f };
static const CGFloat kBandFreq[AC_BANDS] = { 110.0f, 1000.0f, 6500.0f };

@implementation ACCurveView {
	CGFloat _gains[AC_BANDS];
	float _levels[AC_METER_BANDS];
	float _bars[AC_BAR_COUNT];
	NSInteger _draggingBand;
	ac_eq _preview; /* mirrors the DSP so the drawn curve is the real response */
	UIImpactFeedbackGenerator *_haptics;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	if ((self = [super initWithFrame:frame])) {
		self.backgroundColor = UIColor.clearColor;
		self.contentMode = UIViewContentModeRedraw;
		_draggingBand = NSNotFound;
		_selectedBand = 1;

		ac_eq_init(&_preview, 48000.0f);

		_haptics = [[UIImpactFeedbackGenerator alloc]
			initWithStyle:UIImpactFeedbackStyleLight];

		UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
			initWithTarget:self
				action:@selector(handlePan:)];
		pan.maximumNumberOfTouches = 1;
		[self addGestureRecognizer:pan];

		[self reloadGains];
	}
	return self;
}

#pragma mark - Geometry

- (CGRect)plotRect
{
	return CGRectMake(AC_SIDE_INSET, 8.0,
			  MAX(0.0, self.bounds.size.width - AC_SIDE_INSET * 2.0),
			  MAX(0.0, self.bounds.size.height - AC_LABEL_AREA - 16.0));
}

- (CGFloat)yForGain:(CGFloat)gain inRect:(CGRect)rect
{
	const CGFloat span = rect.size.height * 0.31;
	const CGFloat normalized = MAX(-1.0, MIN(1.0, gain / AC_GAIN_MAX));
	return CGRectGetMidY(rect) - normalized * span;
}

- (CGFloat)gainForY:(CGFloat)y inRect:(CGRect)rect
{
	const CGFloat span = rect.size.height * 0.31;
	if (span <= 0.0) return 0.0;
	return MAX(AC_GAIN_MIN,
		   MIN(AC_GAIN_MAX, (CGRectGetMidY(rect) - y) / span * AC_GAIN_MAX));
}

- (CGPoint)pointForBand:(NSInteger)band inRect:(CGRect)rect
{
	return CGPointMake(rect.origin.x + rect.size.width * kBandX[band],
			   [self yForGain:_gains[band] inRect:rect]);
}

#pragma mark - State

- (void)reloadGains
{
	ACSettings *settings = [ACSettings shared];
	for (NSInteger band = 0; band < AC_BANDS; band++)
		_gains[band] = [settings gainForBand:band];

	ac_eq_set_gains(&_preview, (float)_gains[0], (float)_gains[1],
			(float)_gains[2]);
	for (int i = 0; i < 80; i++) ac_eq_begin_block(&_preview);

	[self setNeedsDisplay];
}

- (void)updateWithLevels:(const float *)levels count:(NSInteger)count
{
	if (levels && count > 0) {
		for (NSInteger band = 0; band < AC_METER_BANDS && band < count; band++)
			_levels[band] = levels[band];
	}
	[self setNeedsDisplay];
}

/* Log frequency for a bar index, 40 Hz to 16 kHz. */
static CGFloat ACBarFrequency(NSInteger index)
{
	const double t = (double)index / (double)(AC_BAR_COUNT - 1);
	return (CGFloat)(40.0 * pow(16000.0 / 40.0, t));
}

- (float)meteredLevelAtFrequency:(CGFloat)frequency
{
	const float first = ac_meter_center(0);
	const float last = ac_meter_center(AC_METER_BANDS - 1);

	if (frequency <= first) return _levels[0];
	if (frequency >= last) return _levels[AC_METER_BANDS - 1];

	for (NSInteger band = 0; band < AC_METER_BANDS - 1; band++) {
		const float lo = ac_meter_center((int)band);
		const float hi = ac_meter_center((int)band + 1);
		if (frequency >= lo && frequency <= hi) {
			const float t = (float)((log10(frequency) - log10(lo)) /
						(log10(hi) - log10(lo)));
			return _levels[band] + (_levels[band + 1] - _levels[band]) * t;
		}
	}

	return 0.0f;
}

#pragma mark - Colors

- (UIColor *)barColorAtPosition:(CGFloat)t
{
	/* Warm on the low end, cool on the high end, like the stock screen. */
	const CGFloat stops[4] = { 0.0, 0.32, 0.66, 1.0 };
	const CGFloat colors[4][3] = {
		{ 1.00, 0.62, 0.15 },
		{ 0.99, 0.84, 0.25 },
		{ 0.22, 0.80, 0.90 },
		{ 0.28, 0.62, 0.98 },
	};

	for (NSInteger i = 0; i < 3; i++) {
		if (t >= stops[i] && t <= stops[i + 1]) {
			const CGFloat span = stops[i + 1] - stops[i];
			const CGFloat local = span > 0 ? (t - stops[i]) / span : 0.0;
			return [UIColor
				colorWithRed:colors[i][0] +
					     (colors[i + 1][0] - colors[i][0]) * local
				       green:colors[i][1] +
					     (colors[i + 1][1] - colors[i][1]) * local
					blue:colors[i][2] +
					     (colors[i + 1][2] - colors[i][2]) * local
				       alpha:1.0];
		}
	}

	return [UIColor colorWithRed:colors[3][0]
			      green:colors[3][1]
			       blue:colors[3][2]
			      alpha:1.0];
}

/* Neutral green where the curve is flat, yellow where it is boosted or cut. */
- (UIColor *)curveColorForDeviation:(CGFloat)deviationDb
{
	const CGFloat t = MIN(1.0, fabs(deviationDb) / 6.0);
	return [UIColor colorWithRed:0.22 + (1.00 - 0.22) * t
			      green:0.80 + (0.84 - 0.80) * t
			       blue:0.42 + (0.04 - 0.42) * t
			      alpha:1.0];
}

#pragma mark - Drawing

- (void)drawRect:(CGRect)rect
{
	CGContextRef ctx = UIGraphicsGetCurrentContext();
	const CGRect plot = [self plotRect];
	if (plot.size.width <= 1.0 || plot.size.height <= 1.0) return;

	[self drawSelectionColumnInContext:ctx rect:plot];
	[self drawBarsInContext:ctx rect:plot];
	[self drawGuidesInContext:ctx rect:plot];
	[self drawCurveInContext:ctx rect:plot];
	[self drawKnobsInContext:ctx rect:plot];
	[self drawLabelsInRect:plot];
}

- (void)drawSelectionColumnInContext:(CGContextRef)ctx rect:(CGRect)rect
{
	if (_selectedBand < 0 || _selectedBand >= AC_BANDS) return;

	const CGFloat width = rect.size.width * 0.2;
	const CGFloat centerX = rect.origin.x + rect.size.width * kBandX[_selectedBand];
	const CGRect column = CGRectMake(centerX - width * 0.5, rect.origin.y, width,
					 rect.size.height);

	UIColor *tint = [UIColor.labelColor colorWithAlphaComponent:0.05];
	[[UIBezierPath bezierPathWithRoundedRect:column cornerRadius:10.0] addClip];
	CGContextSetFillColorWithColor(ctx, tint.CGColor);
	CGContextFillRect(ctx, column);
	CGContextResetClip(ctx);
}

- (void)drawGuidesInContext:(CGContextRef)ctx rect:(CGRect)rect
{
	CGContextSaveGState(ctx);
	CGContextSetStrokeColorWithColor(
		ctx, [UIColor.tertiaryLabelColor colorWithAlphaComponent:0.45].CGColor);
	CGContextSetLineWidth(ctx, 1.0);
	const CGFloat dashes[2] = { 2.0, 3.0 };
	CGContextSetLineDash(ctx, 0.0, dashes, 2);

	for (NSInteger band = 0; band < AC_BANDS; band++) {
		const CGFloat x = rect.origin.x + rect.size.width * kBandX[band];
		CGContextMoveToPoint(ctx, x, rect.origin.y);
		CGContextAddLineToPoint(ctx, x, CGRectGetMaxY(rect));
	}

	CGContextStrokePath(ctx);
	CGContextRestoreGState(ctx);
}

- (void)drawBarsInContext:(CGContextRef)ctx rect:(CGRect)rect
{
	const CGFloat centerY = CGRectGetMidY(rect);
	const CGFloat maxHalf = rect.size.height * 0.46;
	const CGFloat slot = rect.size.width / (CGFloat)AC_BAR_COUNT;
	const CGFloat barWidth = MAX(1.5, slot * 0.5);

	if (!self.audioActive) {
		/* Idle state matches the stock screen: a dotted center line. */
		CGContextSaveGState(ctx);
		CGContextSetStrokeColorWithColor(
			ctx, [UIColor.systemBlueColor colorWithAlphaComponent:0.55].CGColor);
		CGContextSetLineWidth(ctx, 2.0);
		CGContextSetLineCap(ctx, kCGLineCapRound);
		const CGFloat dashes[2] = { 0.5, 5.0 };
		CGContextSetLineDash(ctx, 0.0, dashes, 2);
		CGContextMoveToPoint(ctx, rect.origin.x, centerY);
		CGContextAddLineToPoint(ctx, CGRectGetMaxX(rect), centerY);
		CGContextStrokePath(ctx);
		CGContextRestoreGState(ctx);

		for (NSInteger i = 0; i < AC_BAR_COUNT; i++) _bars[i] *= 0.7f;
		return;
	}

	for (NSInteger i = 0; i < AC_BAR_COUNT; i++) {
		const CGFloat frequency = ACBarFrequency(i);
		float magnitude = [self meteredLevelAtFrequency:frequency];

		/* Let the curve shape the visualisation too. */
		const float responseDb = ac_eq_magnitude_db(&_preview, (float)frequency);
		magnitude *= powf(10.0f, responseDb / 40.0f);
		magnitude = MIN(1.0f, magnitude);

		_bars[i] += (magnitude - _bars[i]) * (magnitude > _bars[i] ? 0.6f : 0.25f);

		const CGFloat half = MAX(1.0, _bars[i] * maxHalf);
		const CGFloat x = rect.origin.x + slot * (CGFloat)i + (slot - barWidth) * 0.5;
		const CGRect bar = CGRectMake(x, centerY - half, barWidth, half * 2.0);

		UIColor *color = [self barColorAtPosition:(CGFloat)i /
							  (CGFloat)(AC_BAR_COUNT - 1)];
		CGContextSetFillColorWithColor(ctx, [color colorWithAlphaComponent:0.9].CGColor);
		CGContextAddPath(
			ctx, [UIBezierPath bezierPathWithRoundedRect:bar
							cornerRadius:barWidth * 0.5]
				     .CGPath);
		CGContextFillPath(ctx);
	}
}

- (UIBezierPath *)curvePathInRect:(CGRect)rect
{
	CGPoint knots[5];
	knots[0] = CGPointMake(rect.origin.x, [self yForGain:_gains[0] inRect:rect]);
	knots[1] = [self pointForBand:0 inRect:rect];
	knots[2] = [self pointForBand:1 inRect:rect];
	knots[3] = [self pointForBand:2 inRect:rect];
	knots[4] = CGPointMake(CGRectGetMaxX(rect),
			       [self yForGain:_gains[2] inRect:rect]);

	UIBezierPath *path = [UIBezierPath bezierPath];
	[path moveToPoint:knots[0]];

	/* Catmull-Rom through the knots, converted to cubic segments. */
	for (NSInteger i = 0; i < 4; i++) {
		const CGPoint p0 = knots[MAX(i - 1, 0)];
		const CGPoint p1 = knots[i];
		const CGPoint p2 = knots[i + 1];
		const CGPoint p3 = knots[MIN(i + 2, 4)];

		const CGPoint c1 = CGPointMake(p1.x + (p2.x - p0.x) / 6.0,
					       p1.y + (p2.y - p0.y) / 6.0);
		const CGPoint c2 = CGPointMake(p2.x - (p3.x - p1.x) / 6.0,
					       p2.y - (p3.y - p1.y) / 6.0);

		[path addCurveToPoint:p2 controlPoint1:c1 controlPoint2:c2];
	}

	return path;
}

- (void)drawCurveInContext:(CGContextRef)ctx rect:(CGRect)rect
{
	UIBezierPath *path = [self curvePathInRect:rect];

	CGContextSaveGState(ctx);
	CGContextAddPath(ctx, path.CGPath);
	CGContextSetLineWidth(ctx, 3.0);
	CGContextSetLineJoin(ctx, kCGLineJoinRound);
	CGContextSetLineCap(ctx, kCGLineCapRound);
	CGContextReplacePathWithStrokedPath(ctx);
	CGContextClip(ctx);

	NSMutableArray *colors = [NSMutableArray array];
	NSMutableArray *locations = [NSMutableArray array];
	const NSInteger samples = 24;

	for (NSInteger i = 0; i < samples; i++) {
		const CGFloat t = (CGFloat)i / (CGFloat)(samples - 1);
		const CGFloat frequency = (CGFloat)(40.0 * pow(16000.0 / 40.0, t));
		const CGFloat deviation =
			ac_eq_magnitude_db(&_preview, (float)frequency);
		[colors addObject:(id)[self curveColorForDeviation:deviation].CGColor];
		[locations addObject:@(t)];
	}

	CGFloat stops[24];
	for (NSInteger i = 0; i < samples; i++)
		stops[i] = [locations[i] doubleValue];

	CGGradientRef gradient = CGGradientCreateWithColors(
		CGColorSpaceCreateDeviceRGB(), (CFArrayRef)colors, stops);
	if (gradient) {
		CGContextDrawLinearGradient(
			ctx, gradient, CGPointMake(rect.origin.x, 0),
			CGPointMake(CGRectGetMaxX(rect), 0), 0);
		CGGradientRelease(gradient);
	}

	CGContextRestoreGState(ctx);
}

- (void)drawKnobsInContext:(CGContextRef)ctx rect:(CGRect)rect
{
	for (NSInteger band = 0; band < AC_BANDS; band++) {
		const CGPoint point = [self pointForBand:band inRect:rect];
		const CGFloat radius = (band == _draggingBand) ? 8.5 : 6.5;
		const CGFloat deviation =
			ac_eq_magnitude_db(&_preview, kBandFreq[band]);
		UIColor *color = [self curveColorForDeviation:deviation];

		CGContextSetShadowWithColor(ctx, CGSizeMake(0, 1), 3.0,
					    [UIColor.blackColor
						    colorWithAlphaComponent:0.25]
						    .CGColor);
		CGContextSetFillColorWithColor(ctx, color.CGColor);
		CGContextFillEllipseInRect(
			ctx, CGRectMake(point.x - radius, point.y - radius, radius * 2.0,
					radius * 2.0));
		CGContextSetShadowWithColor(ctx, CGSizeZero, 0.0, NULL);
	}
}

- (void)drawLabelsInRect:(CGRect)rect
{
	NSArray<NSString *> *titles = @[ @"LOW", @"MID", @"HIGH" ];
	NSDictionary *attributes = @{
		NSFontAttributeName : [UIFont systemFontOfSize:11.0
							weight:UIFontWeightMedium],
		NSForegroundColorAttributeName : UIColor.secondaryLabelColor,
		NSKernAttributeName : @(0.6),
	};

	for (NSInteger band = 0; band < AC_BANDS; band++) {
		NSString *title = titles[band];
		const CGSize size = [title sizeWithAttributes:attributes];
		const CGFloat x = rect.origin.x + rect.size.width * kBandX[band] -
				  size.width * 0.5;
		[title drawAtPoint:CGPointMake(x, CGRectGetMaxY(rect) + 6.0)
		    withAttributes:attributes];
	}
}

#pragma mark - Interaction

- (NSInteger)bandNearestToPoint:(CGPoint)point inRect:(CGRect)rect
{
	NSInteger best = 0;
	CGFloat bestDistance = CGFLOAT_MAX;

	for (NSInteger band = 0; band < AC_BANDS; band++) {
		const CGPoint knob = [self pointForBand:band inRect:rect];
		const CGFloat dx = knob.x - point.x;
		const CGFloat dy = (knob.y - point.y) * 0.35; /* x matters more */
		const CGFloat distance = dx * dx + dy * dy;
		if (distance < bestDistance) {
			bestDistance = distance;
			best = band;
		}
	}

	return best;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan
{
	const CGRect plot = [self plotRect];
	const CGPoint point = [pan locationInView:self];

	switch (pan.state) {
	case UIGestureRecognizerStateBegan: {
		_draggingBand = [self bandNearestToPoint:point inRect:plot];
		_selectedBand = _draggingBand;
		[_haptics prepare];
		[self.delegate curveViewDidBeginEditing:self];
		break;
	}
	case UIGestureRecognizerStateChanged: {
		if (_draggingBand == NSNotFound) break;

		const CGFloat previous = _gains[_draggingBand];
		const CGFloat gain = [self gainForY:point.y inRect:plot];
		_gains[_draggingBand] = gain;

		if ((previous > 0.0 && gain <= 0.0) || (previous < 0.0 && gain >= 0.0))
			[_haptics impactOccurred];

		ac_eq_set_gains(&_preview, (float)_gains[0], (float)_gains[1],
				(float)_gains[2]);
		for (int i = 0; i < 80; i++) ac_eq_begin_block(&_preview);

		[self.delegate curveView:self didChangeGain:gain forBand:_draggingBand];
		[self setNeedsDisplay];
		break;
	}
	case UIGestureRecognizerStateEnded:
	case UIGestureRecognizerStateCancelled:
	case UIGestureRecognizerStateFailed: {
		_draggingBand = NSNotFound;
		[self.delegate curveViewDidEndEditing:self];
		[self setNeedsDisplay];
		break;
	}
	default:
		break;
	}
}

@end
