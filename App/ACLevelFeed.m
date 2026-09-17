#import "ACLevelFeed.h"

#import <notify.h>

#import "ACShared.h"

@implementation ACLevelFeed {
	int _token;
	CADisplayLink *_link;
	float _smoothed[AC_METER_BANDS];
	uint64_t _lastState;
	NSInteger _stateRepeats;
}

- (instancetype)init
{
	if ((self = [super init])) {
		_token = -1;
		if (notify_register_check(AC_KEY_LEVELS, &_token) != NOTIFY_STATUS_OK)
			_token = -1;
	}
	return self;
}

- (void)dealloc
{
	[self stop];
	if (_token >= 0) notify_cancel(_token);
}

- (void)start
{
	if (_link) return;

	_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
	_link.preferredFramesPerSecond = 30;
	[_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)stop
{
	[_link invalidate];
	_link = nil;
}

- (void)tick
{
	uint64_t state = 0;
	BOOL responding = NO;

	if (_token >= 0 && notify_get_state(_token, &state) == NOTIFY_STATUS_OK) {
		responding = YES;
	}

	if (state == _lastState) {
		_stateRepeats++;
	} else {
		_stateRepeats = 0;
		_lastState = state;
	}

	/* The daemon rewrites the state at 30 Hz while audio flows and fades it
	 * out when playback stops, so a frozen non zero state means the tweak is
	 * not loaded. */
	_tweakResponding = responding && _stateRepeats < 40;

	BOOL active = NO;

	for (NSInteger band = 0; band < AC_METER_BANDS; band++) {
		const uint8_t raw = (uint8_t)((state >> (band * 8)) & 0xFF);
		const float target = ac_level_decode(raw);
		const float previous = _smoothed[band];
		const float factor = target > previous ? 0.55f : 0.18f;

		_smoothed[band] = previous + (target - previous) * factor;
		if (_smoothed[band] > 0.04f) active = YES;
	}

	_audioActive = active;

	[self.delegate levelFeedDidUpdate];
}

- (float)levelForBand:(NSInteger)band
{
	if (band < 0 || band >= AC_METER_BANDS) return 0.0f;
	return _smoothed[band];
}

@end
