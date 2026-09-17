#import "ACSettings.h"

#import <notify.h>

#import "ACShared.h"

@implementation ACSettings {
	int _token;
	uint8_t _serial;
	NSString *_path;
}

+ (instancetype)shared
{
	static ACSettings *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		shared = [[ACSettings alloc] init];
	});
	return shared;
}

- (instancetype)init
{
	if ((self = [super init])) {
		_token = -1;
		_enabled = YES;
		_mode = ACModeRecommended;
		_path = @(AC_PREFS_PATH);
		notify_register_check(AC_KEY_SETTINGS, &_token);
	}
	return self;
}

#pragma mark - Storage

- (NSString *)fallbackPath
{
	return [NSHomeDirectory()
		stringByAppendingPathComponent:
			@"Library/Preferences/" @AC_BUNDLE_ID @".plist"];
}

- (void)load
{
	NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:_path];
	if (!prefs) {
		prefs = [NSDictionary dictionaryWithContentsOfFile:[self fallbackPath]];
	}
	if (![prefs isKindOfClass:[NSDictionary class]]) return;

	id enabledValue = prefs[@"enabled"];
	_enabled = enabledValue ? [enabledValue boolValue] : YES;
	_mode = [prefs[@"mode"] integerValue];
	_lowGain = [prefs[@"lowGain"] doubleValue];
	_midGain = [prefs[@"midGain"] doubleValue];
	_highGain = [prefs[@"highGain"] doubleValue];
}

- (void)publish
{
	NSDictionary *prefs = @{
		@"enabled" : @(_enabled),
		@"mode" : @(_mode),
		@"lowGain" : @(_lowGain),
		@"midGain" : @(_midGain),
		@"highGain" : @(_highGain),
	};

	if (![prefs writeToFile:_path atomically:YES]) {
		NSString *fallback = [self fallbackPath];
		[[NSFileManager defaultManager]
			  createDirectoryAtPath:[fallback stringByDeletingLastPathComponent]
			withIntermediateDirectories:YES
					 attributes:nil
					      error:NULL];
		[prefs writeToFile:fallback atomically:YES];
	}

	[self publishLive];

	/* SpringBoard keeps a copy so settings survive a respring or reboot. */
	notify_post(AC_NOTE_RELAY_SYNC);
}

- (void)publishLive
{
	if (_token >= 0) {
		_serial = (uint8_t)(_serial + 1);
		const uint64_t packed =
			ac_pack_settings(_enabled ? 1 : 0, (int)_mode, (float)_lowGain,
					 (float)_midGain, (float)_highGain, _serial);
		notify_set_state(_token, packed);
	}

	notify_post(AC_NOTE_PREFS_CHANGED);
}

- (void)resetCurve
{
	_lowGain = 0.0;
	_midGain = 0.0;
	_highGain = 0.0;
	_mode = ACModeRecommended;
	[self publish];
}

#pragma mark - Bands

- (CGFloat)gainForBand:(NSInteger)band
{
	switch (band) {
	case 0:
		return _lowGain;
	case 1:
		return _midGain;
	default:
		return _highGain;
	}
}

- (void)setGain:(CGFloat)gain forBand:(NSInteger)band
{
	gain = MAX(AC_GAIN_MIN, MIN(AC_GAIN_MAX, gain));
	switch (band) {
	case 0:
		_lowGain = gain;
		break;
	case 1:
		_midGain = gain;
		break;
	default:
		_highGain = gain;
		break;
	}
}

@end
