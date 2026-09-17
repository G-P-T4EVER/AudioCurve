#import "ACNowPlaying.h"

#import <dlfcn.h>

NSString *const ACNowPlayingDidChangeNotification =
	@"ACNowPlayingDidChangeNotification";

/* MediaRemote is private, so everything is resolved at runtime. */
typedef void (*ACGetNowPlayingInfo)(dispatch_queue_t queue,
				    void (^handler)(NSDictionary *info));
typedef void (*ACRegisterForNotifications)(dispatch_queue_t queue);
typedef void (*ACGetIsPlaying)(dispatch_queue_t queue, void (^handler)(BOOL playing));
typedef Boolean (*ACSendCommand)(int command, NSDictionary *userInfo);

static const int kACCommandTogglePlayPause = 2;

@implementation ACNowPlaying {
	ACGetNowPlayingInfo _getInfo;
	ACRegisterForNotifications _register;
	ACGetIsPlaying _getIsPlaying;
	ACSendCommand _sendCommand;
}

+ (instancetype)shared
{
	static ACNowPlaying *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		shared = [[ACNowPlaying alloc] init];
	});
	return shared;
}

- (instancetype)init
{
	if ((self = [super init])) {
		void *handle = dlopen("/System/Library/PrivateFrameworks/"
				      "MediaRemote.framework/MediaRemote",
				      RTLD_LAZY);
		if (handle) {
			_getInfo = (ACGetNowPlayingInfo)dlsym(
				handle, "MRMediaRemoteGetNowPlayingInfo");
			_register = (ACRegisterForNotifications)dlsym(
				handle,
				"MRMediaRemoteRegisterForNowPlayingNotifications");
			_getIsPlaying = (ACGetIsPlaying)dlsym(
				handle,
				"MRMediaRemoteGetNowPlayingApplicationIsPlaying");
			_sendCommand = (ACSendCommand)dlsym(
				handle, "MRMediaRemoteSendCommand");
		}
		_available = (_getInfo != NULL);
	}
	return self;
}

- (void)beginObserving
{
	if (_register) _register(dispatch_get_main_queue());

	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	for (NSString *name in @[
		     @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
		     @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
		     @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
	     ]) {
		[center addObserver:self
			  selector:@selector(refresh)
			      name:name
			    object:nil];
	}

	[self refresh];
}

- (void)refresh
{
	if (!_getInfo) return;

	__weak typeof(self) weakSelf = self;

	_getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
		typeof(self) strongSelf = weakSelf;
		if (!strongSelf) return;

		strongSelf->_title = [info[@"kMRMediaRemoteNowPlayingInfoTitle"] copy];
		strongSelf->_artist =
			[info[@"kMRMediaRemoteNowPlayingInfoArtist"] copy];

		NSData *artworkData = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
		strongSelf->_artwork =
			[artworkData isKindOfClass:[NSData class]]
				? [UIImage imageWithData:artworkData]
				: nil;

		[[NSNotificationCenter defaultCenter]
			postNotificationName:ACNowPlayingDidChangeNotification
				      object:strongSelf];
	});

	if (_getIsPlaying) {
		_getIsPlaying(dispatch_get_main_queue(), ^(BOOL playing) {
			typeof(self) strongSelf = weakSelf;
			if (!strongSelf) return;

			if (strongSelf->_playing != playing) {
				strongSelf->_playing = playing;
				[[NSNotificationCenter defaultCenter]
					postNotificationName:
						ACNowPlayingDidChangeNotification
							      object:strongSelf];
			}
		});
	}
}

- (void)togglePlayPause
{
	if (!_sendCommand) return;

	_sendCommand(kACCommandTogglePlayPause, nil);

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
		       dispatch_get_main_queue(), ^{
			       [self refresh];
		       });
}

@end
