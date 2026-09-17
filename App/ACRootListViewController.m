#import "ACRootListViewController.h"

#import "ACEqualizerViewController.h"
#import "ACSettings.h"
#import "ACShared.h"

@implementation ACRootListViewController

- (instancetype)init
{
	return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"AudioCurve";
	self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
	self.navigationController.navigationBar.prefersLargeTitles = YES;
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	[[ACSettings shared] load];
	[self.tableView reloadData];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	return 1;
}

- (NSString *)tableView:(UITableView *)tableView
	titleForFooterInSection:(NSInteger)section
{
	if (section == 0)
		return @"Applies the curve to the mixed system output inside "
		       @"mediaserverd. Turning this off restores untouched audio "
		       @"immediately, no respring needed.";
	return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
		 cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	if (indexPath.section == 0) {
		UITableViewCell *cell =
			[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
						       reuseIdentifier:@"toggle"];
		cell.textLabel.text = @"Equalizer";
		cell.selectionStyle = UITableViewCellSelectionStyleNone;

		UISwitch *toggle = [[UISwitch alloc] init];
		toggle.on = [ACSettings shared].enabled;
		[toggle addTarget:self
			      action:@selector(toggleChanged:)
		    forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = toggle;
		return cell;
	}

	UITableViewCell *cell =
		[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
					       reuseIdentifier:@"push"];
	cell.textLabel.text = @"Equalizer";
	cell.detailTextLabel.text = ([ACSettings shared].mode == ACModeCustom)
					    ? @"Custom"
					    : @"Recommended";
	cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	return cell;
}

- (void)tableView:(UITableView *)tableView
	didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	if (indexPath.section != 1) return;

	[self.navigationController pushViewController:[[ACEqualizerViewController alloc] init]
					    animated:YES];
}

- (void)toggleChanged:(UISwitch *)toggle
{
	ACSettings *settings = [ACSettings shared];
	settings.enabled = toggle.isOn;
	[settings publish];
}

@end
