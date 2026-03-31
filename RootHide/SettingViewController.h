#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SettingViewController : UITableViewController

+ (instancetype)sharedInstance;
+ (UIViewController *)whitelistController;
+ (UIViewController *)blacklistController;

@end

NS_ASSUME_NONNULL_END
