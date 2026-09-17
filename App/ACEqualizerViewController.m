#import "ACEqualizerViewController.h"

#import "ACCurveView.h"
#import "ACLevelFeed.h"
#import "ACNowPlaying.h"
#import "ACSettings.h"
#import "ACShared.h"
#import "ac_meter.h"

@interface ACEqualizerViewController () <ACCurveViewDelegate, ACLevelFeedDelegate>
@end

@implementation ACEqualizerViewController {
	ACLevelFeed *_feed;
	ACCurveView *_curveView;
	UIImageView *_artworkView;
	UILabel *_titleLabel;
	UILabel *_artistLabel;
	UIButton *_playButton;
	UILabel *_statusLabel;
	UIImageView *_recommendedCheck;
	UIImageView *_customCheck;
	NSTimeInterval _lastLivePush;
}

#pragma mark - Lifecycle

- (void)viewDidLoad
{
	[super viewDidLoad];

	self.title = @"Equalizer";
	self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
	self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

	_feed = [[ACLevelFeed alloc] init];
	_feed.delegate = self;

	[self buildInterface];
	[self updateModeChecks];

	[[NSNotificationCenter defaultCenter] addObserver:self
						 selector:@selector(nowPlayingChanged)
						     name:ACNowPlayingDidChangeNotification
						   object:nil];
	[[ACNowPlaying shared] beginObserving];
	[self nowPlayingChanged];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	[[ACSettings shared] load];
	[_curveView reloadGains];
	[self updateModeChecks];
	[[ACNowPlaying shared] refresh];
	[_feed start];
}

- (void)viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
	[_feed stop];
}

#pragma mark - Interface

- (UIView *)makeCard
{
	UIView *card = [[UIView alloc] init];
	card.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
	card.layer.cornerRadius = 12.0;
	card.layer.cornerCurve = kCACornerCurveContinuous;
	card.translatesAutoresizingMaskIntoConstraints = NO;
	return card;
}

- (UIView *)makeSeparator
{
	UIView *line = [[UIView alloc] init];
	line.backgroundColor = UIColor.separatorColor;
	line.translatesAutoresizingMaskIntoConstraints = NO;
	[line.heightAnchor constraintEqualToConstant:0.5].active = YES;
	return line;
}

- (UIView *)makeRowWithTitle:(NSString *)title
		   checkmark:(UIImageView **)checkOut
		      action:(SEL)action
{
	UIView *row = [[UIView alloc] init];
	row.translatesAutoresizingMaskIntoConstraints = NO;

	UILabel *label = [[UILabel alloc] init];
	label.text = title;
	label.font = [UIFont systemFontOfSize:17.0];
	label.textColor = UIColor.labelColor;
	label.translatesAutoresizingMaskIntoConstraints = NO;
	[row addSubview:label];

	UIImageView *check = [[UIImageView alloc]
		initWithImage:[UIImage systemImageNamed:@"checkmark"]];
	check.tintColor = UIColor.systemBlueColor;
	check.contentMode = UIViewContentModeScaleAspectFit;
	check.translatesAutoresizingMaskIntoConstraints = NO;
	[row addSubview:check];

	[NSLayoutConstraint activateConstraints:@[
		[row.heightAnchor constraintEqualToConstant:44.0],
		[label.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16.0],
		[label.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
		[check.trailingAnchor constraintEqualToAnchor:row.trailingAnchor
						     constant:-18.0],
		[check.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
		[check.widthAnchor constraintEqualToConstant:16.0],
		[check.heightAnchor constraintEqualToConstant:16.0],
	]];

	row.userInteractionEnabled = YES;
	[row addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
									  action:action]];

	if (checkOut) *checkOut = check;
	return row;
}

- (UILabel *)makeFootnoteWithText:(NSString *)text
{
	UILabel *label = [[UILabel alloc] init];
	label.text = text;
	label.font = [UIFont systemFontOfSize:13.0];
	label.textColor = UIColor.secondaryLabelColor;
	label.numberOfLines = 0;
	label.translatesAutoresizingMaskIntoConstraints = NO;
	return label;
}

- (void)buildInterface
{
	UIScrollView *scroll = [[UIScrollView alloc] init];
	scroll.alwaysBounceVertical = YES;
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:scroll];

	UIStackView *stack = [[UIStackView alloc] init];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 8.0;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[scroll addSubview:stack];

	[NSLayoutConstraint activateConstraints:@[
		[scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

		[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor
						constant:16.0],
		[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor
						   constant:-28.0],
		[stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor
						    constant:16.0],
		[stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor
						     constant:-16.0],
	]];

	/* Mode card. */
	UIView *modeCard = [self makeCard];
	UIStackView *modeStack = [[UIStackView alloc] init];
	modeStack.axis = UILayoutConstraintAxisVertical;
	modeStack.translatesAutoresizingMaskIntoConstraints = NO;
	[modeCard addSubview:modeStack];
	[NSLayoutConstraint activateConstraints:@[
		[modeStack.topAnchor constraintEqualToAnchor:modeCard.topAnchor],
		[modeStack.bottomAnchor constraintEqualToAnchor:modeCard.bottomAnchor],
		[modeStack.leadingAnchor constraintEqualToAnchor:modeCard.leadingAnchor],
		[modeStack.trailingAnchor constraintEqualToAnchor:modeCard.trailingAnchor],
	]];

	[modeStack addArrangedSubview:[self makeRowWithTitle:@"Recommended"
							  checkmark:&_recommendedCheck
							     action:@selector(selectRecommended)]];
	[modeStack addArrangedSubview:[self makeSeparator]];
	[modeStack addArrangedSubview:[self makeRowWithTitle:@"Custom"
							  checkmark:&_customCheck
							     action:@selector(selectCustom)]];
	[stack addArrangedSubview:modeCard];

	UILabel *footnote = [self
		makeFootnoteWithText:
			@"Your iPhone is tuned to play music, video and calls the way "
			@"they were mastered. If you prefer a different sound profile, "
			@"customize how every app on your iPhone sounds. The curve is "
			@"applied to the mixed system output, so it affects Music, "
			@"Spotify, YouTube, Safari and games alike."];
	UIView *footnoteWrapper = [[UIView alloc] init];
	footnoteWrapper.translatesAutoresizingMaskIntoConstraints = NO;
	[footnoteWrapper addSubview:footnote];
	[NSLayoutConstraint activateConstraints:@[
		[footnote.topAnchor constraintEqualToAnchor:footnoteWrapper.topAnchor
						   constant:6.0],
		[footnote.bottomAnchor constraintEqualToAnchor:footnoteWrapper.bottomAnchor
						      constant:-10.0],
		[footnote.leadingAnchor constraintEqualToAnchor:footnoteWrapper.leadingAnchor
						       constant:16.0],
		[footnote.trailingAnchor constraintEqualToAnchor:footnoteWrapper.trailingAnchor
							constant:-16.0],
	]];
	[stack addArrangedSubview:footnoteWrapper];

	/* Now playing plus waveform card. */
	UIView *playerCard = [self makeCard];

	_artworkView = [[UIImageView alloc] init];
	_artworkView.backgroundColor = UIColor.tertiarySystemFillColor;
	_artworkView.layer.cornerRadius = 8.0;
	_artworkView.layer.cornerCurve = kCACornerCurveContinuous;
	_artworkView.clipsToBounds = YES;
	_artworkView.contentMode = UIViewContentModeScaleAspectFill;
	_artworkView.translatesAutoresizingMaskIntoConstraints = NO;
	[playerCard addSubview:_artworkView];

	_titleLabel = [[UILabel alloc] init];
	_titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
	_titleLabel.textColor = UIColor.labelColor;
	_titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[playerCard addSubview:_titleLabel];

	_artistLabel = [[UILabel alloc] init];
	_artistLabel.font = [UIFont systemFontOfSize:13.0];
	_artistLabel.textColor = UIColor.secondaryLabelColor;
	_artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[playerCard addSubview:_artistLabel];

	_playButton = [UIButton buttonWithType:UIButtonTypeSystem];
	_playButton.tintColor = UIColor.labelColor;
	_playButton.backgroundColor = UIColor.tertiarySystemFillColor;
	_playButton.layer.cornerRadius = 19.0;
	_playButton.translatesAutoresizingMaskIntoConstraints = NO;
	[_playButton setImage:[UIImage systemImageNamed:@"play.fill"]
		     forState:UIControlStateNormal];
	[_playButton addTarget:self
			action:@selector(togglePlayback)
	      forControlEvents:UIControlEventTouchUpInside];
	[playerCard addSubview:_playButton];

	UIView *separator = [self makeSeparator];
	[playerCard addSubview:separator];

	_curveView = [[ACCurveView alloc] initWithFrame:CGRectZero];
	_curveView.delegate = self;
	_curveView.translatesAutoresizingMaskIntoConstraints = NO;
	[playerCard addSubview:_curveView];

	[NSLayoutConstraint activateConstraints:@[
		[_artworkView.topAnchor constraintEqualToAnchor:playerCard.topAnchor
						       constant:14.0],
		[_artworkView.leadingAnchor constraintEqualToAnchor:playerCard.leadingAnchor
							  constant:16.0],
		[_artworkView.widthAnchor constraintEqualToConstant:56.0],
		[_artworkView.heightAnchor constraintEqualToConstant:56.0],

		[_playButton.trailingAnchor constraintEqualToAnchor:playerCard.trailingAnchor
							  constant:-16.0],
		[_playButton.centerYAnchor constraintEqualToAnchor:_artworkView.centerYAnchor],
		[_playButton.widthAnchor constraintEqualToConstant:38.0],
		[_playButton.heightAnchor constraintEqualToConstant:38.0],

		[_titleLabel.leadingAnchor constraintEqualToAnchor:_artworkView.trailingAnchor
							 constant:12.0],
		[_titleLabel.trailingAnchor constraintEqualToAnchor:_playButton.leadingAnchor
							  constant:-12.0],
		[_titleLabel.topAnchor constraintEqualToAnchor:_artworkView.topAnchor
						      constant:8.0],

		[_artistLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
		[_artistLabel.trailingAnchor constraintEqualToAnchor:_titleLabel.trailingAnchor],
		[_artistLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor
						       constant:3.0],

		[separator.topAnchor constraintEqualToAnchor:_artworkView.bottomAnchor
						    constant:14.0],
		[separator.leadingAnchor constraintEqualToAnchor:playerCard.leadingAnchor
							constant:16.0],
		[separator.trailingAnchor constraintEqualToAnchor:playerCard.trailingAnchor],

		[_curveView.topAnchor constraintEqualToAnchor:separator.bottomAnchor],
		[_curveView.leadingAnchor constraintEqualToAnchor:playerCard.leadingAnchor],
		[_curveView.trailingAnchor constraintEqualToAnchor:playerCard.trailingAnchor],
		[_curveView.bottomAnchor constraintEqualToAnchor:playerCard.bottomAnchor],
		[_curveView.heightAnchor constraintEqualToConstant:196.0],
	]];
	[stack addArrangedSubview:playerCard];

	/* Reset card. */
	UIView *resetCard = [self makeCard];
	UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
	[reset setTitle:@"Reset" forState:UIControlStateNormal];
	reset.titleLabel.font = [UIFont systemFontOfSize:17.0];
	reset.translatesAutoresizingMaskIntoConstraints = NO;
	[reset addTarget:self
		      action:@selector(resetCurve)
	    forControlEvents:UIControlEventTouchUpInside];
	[resetCard addSubview:reset];
	[NSLayoutConstraint activateConstraints:@[
		[reset.topAnchor constraintEqualToAnchor:resetCard.topAnchor],
		[reset.bottomAnchor constraintEqualToAnchor:resetCard.bottomAnchor],
		[reset.leadingAnchor constraintEqualToAnchor:resetCard.leadingAnchor],
		[reset.trailingAnchor constraintEqualToAnchor:resetCard.trailingAnchor],
		[reset.heightAnchor constraintEqualToConstant:48.0],
	]];
	[stack addArrangedSubview:resetCard];

	_statusLabel = [self makeFootnoteWithText:@""];
	_statusLabel.font = [UIFont systemFontOfSize:12.0];
	_statusLabel.textColor = UIColor.tertiaryLabelColor;
	UIView *statusWrapper = [[UIView alloc] init];
	statusWrapper.translatesAutoresizingMaskIntoConstraints = NO;
	[statusWrapper addSubview:_statusLabel];
	[NSLayoutConstraint activateConstraints:@[
		[_statusLabel.topAnchor constraintEqualToAnchor:statusWrapper.topAnchor
						       constant:8.0],
		[_statusLabel.bottomAnchor constraintEqualToAnchor:statusWrapper.bottomAnchor],
		[_statusLabel.leadingAnchor constraintEqualToAnchor:statusWrapper.leadingAnchor
							  constant:16.0],
		[_statusLabel.trailingAnchor constraintEqualToAnchor:statusWrapper.trailingAnchor
							   constant:-16.0],
	]];
	[stack addArrangedSubview:statusWrapper];
}

#pragma mark - Actions

- (void)updateModeChecks
{
	const BOOL custom = ([ACSettings shared].mode == ACModeCustom);
	_recommendedCheck.hidden = custom;
	_customCheck.hidden = !custom;
}

- (void)selectRecommended
{
	ACSettings *settings = [ACSettings shared];
	[settings resetCurve];
	[_curveView reloadGains];
	[self updateModeChecks];
}

- (void)selectCustom
{
	ACSettings *settings = [ACSettings shared];
	settings.mode = ACModeCustom;
	[settings publish];
	[self updateModeChecks];
}

- (void)resetCurve
{
	[[ACSettings shared] resetCurve];
	[_curveView reloadGains];
	[self updateModeChecks];
}

- (void)togglePlayback
{
	[[ACNowPlaying shared] togglePlayPause];
}

- (void)nowPlayingChanged
{
	ACNowPlaying *player = [ACNowPlaying shared];

	_titleLabel.text = player.title.length ? player.title : @"Not Playing";
	_artistLabel.text = player.artist ?: @"";
	_artworkView.image = player.artwork;

	NSString *symbol = player.playing ? @"pause.fill" : @"play.fill";
	[_playButton setImage:[UIImage systemImageNamed:symbol]
		     forState:UIControlStateNormal];

	if (!player.available) {
		_statusLabel.text = @"MediaRemote is unavailable, so track info is hidden.";
	}
}

#pragma mark - ACLevelFeedDelegate

- (void)levelFeedDidUpdate
{
	float levels[AC_METER_BANDS];
	for (NSInteger band = 0; band < AC_METER_BANDS; band++)
		levels[band] = [_feed levelForBand:band];

	_curveView.audioActive = _feed.audioActive;
	[_curveView updateWithLevels:levels count:AC_METER_BANDS];

	if ([ACNowPlaying shared].available) {
		_statusLabel.text = _feed.tweakResponding
					    ? @"Filtering the system mix in mediaserverd."
					    : @"mediaserverd is not reporting levels. "
					      @"Respring, or check that the tweak is "
					      @"injected.";
	}
}

#pragma mark - ACCurveViewDelegate

- (void)curveView:(ACCurveView *)view didChangeGain:(CGFloat)gain forBand:(NSInteger)band
{
	ACSettings *settings = [ACSettings shared];
	settings.mode = ACModeCustom;
	[settings setGain:gain forBand:band];
	[self updateModeChecks];

	/* Push the light weight notify state while dragging, ~25 Hz. */
	const NSTimeInterval now = CACurrentMediaTime();
	if (now - _lastLivePush > 0.04) {
		_lastLivePush = now;
		[settings publishLive];
	}
}

- (void)curveViewDidBeginEditing:(ACCurveView *)view
{
	/* nothing to do, kept for symmetry */
}

- (void)curveViewDidEndEditing:(ACCurveView *)view
{
	[[ACSettings shared] publish];
}

@end
