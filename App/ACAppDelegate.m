#import "ACAppDelegate.h"

#import "ACRootListViewController.h"
#import "ACSettings.h"

@implementation ACAppDelegate

- (BOOL)application:(UIApplication *)application
	didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	[[ACSettings shared] load];

	UINavigationController *nav = [[UINavigationController alloc]
		initWithRootViewController:[[ACRootListViewController alloc] init]];
	nav.navigationBar.prefersLargeTitles = NO;

	self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
	self.window.rootViewController = nav;
	[self.window makeKeyAndVisible];

	return YES;
}

@end
