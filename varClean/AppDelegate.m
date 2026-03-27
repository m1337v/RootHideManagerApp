#import "AppDelegate.h"
#import "VarCleanController.h"
#import "SettingViewController.h"
#import "NSJSONSerialization+Comments.h"
#import "VCPaths.h"
#include <assert.h>
#include <unistd.h>

@implementation AppDelegate

+ (NSString *)configPathForFile:(NSString *)fileName {
    return VCConfigPath(fileName);
}

+ (id)getDefaultsForKey:(NSString*)key {
    NSDictionary *defaults = [NSDictionary dictionaryWithContentsOfFile:[self configPathForFile:@"varCleanConfig.plist"]];
    return defaults[key];
}

+ (void)setDefaults:(NSObject*)value forKey:(NSString*)key {
    NSString *configFilePath = [self configPathForFile:@"varCleanConfig.plist"];
    NSMutableDictionary *defaults = [NSMutableDictionary dictionaryWithContentsOfFile:configFilePath];
    if (!defaults) {
        defaults = [[NSMutableDictionary alloc] init];
    }
    defaults[key] = value;
    [defaults writeToFile:configFilePath atomically:YES];
}

+ (void)showAlert:(UIAlertController *)alert {
    static dispatch_queue_t alertQueue = nil;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        alertQueue = dispatch_queue_create("alertQueue", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(alertQueue, ^{
        __block BOOL presenting = NO;
        __block BOOL presented = NO;

        while (!presenting) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                UIWindow *keyWindow = nil;
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    if (![scene isKindOfClass:UIWindowScene.class]) {
                        continue;
                    }
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    for (UIWindow *window in windowScene.windows) {
                        if (window.isKeyWindow) {
                            keyWindow = window;
                            break;
                        }
                    }
                    if (keyWindow) {
                        break;
                    }
                }

                UIViewController *viewController = keyWindow.rootViewController;
                while (viewController.presentedViewController) {
                    viewController = viewController.presentedViewController;
                    if (viewController.isBeingDismissed) {
                        return;
                    }
                }
                presenting = YES;
                [viewController presentViewController:alert animated:YES completion:^{
                    presented = YES;
                }];
            });
            if (!presenting) {
                usleep(1000 * 100);
            }
        }

        while (!presented) {
            usleep(100 * 1000);
        }
    });
}

+ (void)showMessage:(NSString *)msg title:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Got It")
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self showAlert:alert];
    });
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    __block int repeatCount = 0;
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        NSArray<NSDictionary *> *paths = @[
            @{@"directory": @"Library/Preferences", @"suffix": @".plist"},
            @{@"directory": @"Library/Application Support/Containers", @"suffix": @""},
            @{@"directory": @"Library/SplashBoard/Snapshots", @"suffix": @""},
            @{@"directory": @"Library/Caches", @"suffix": @""},
            @{@"directory": @"Library/Saved Application State", @"suffix": @".savedState"},
            @{@"directory": @"Library/WebKit", @"suffix": @""},
            @{@"directory": @"Library/Cookies", @"suffix": @".binarycookies"},
            @{@"directory": @"Library/HTTPStorages", @"suffix": @""},
        ];

        for (NSDictionary *item in paths) {
            NSString *path = [NSString stringWithFormat:@"/var/mobile/%@/%@%@",
                              item[@"directory"],
                              bundleIdentifier,
                              item[@"suffix"]];
            if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                NSLog(@"remove app file %@", path);
            }
        }

        repeatCount++;
        if (repeatCount > 40) {
            [timer invalidate];
        }
    }];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSString *configDirectory = VCConfigDirectory();
    if (![NSFileManager.defaultManager fileExistsAtPath:configDirectory]) {
        NSDictionary *attributes = @{
            NSFilePosixPermissions: @(0755),
            NSFileOwnerAccountID: @(501),
            NSFileGroupOwnerAccountID: @(501),
        };
        assert([NSFileManager.defaultManager createDirectoryAtPath:configDirectory
                                       withIntermediateDirectories:YES
                                                        attributes:attributes
                                                             error:nil]);
    }

    NSString *jsonPath = [NSBundle.mainBundle pathForResource:@"varCleanRules" ofType:@"json"];
    NSData *jsonData = [NSData dataWithContentsOfFile:jsonPath];
    assert(jsonData != NULL);

    NSError *error = nil;
    NSDictionary *rules = [NSJSONSerialization JSONObjectWithCommentedData:jsonData
                                                                   options:NSJSONReadingMutableContainers
                                                                     error:&error];
    if (error) {
        NSLog(@"json error=%@", error);
    }
    assert(rules != NULL);

    NSString *rulesFilePath = [AppDelegate configPathForFile:@"varCleanRules.plist"];
    if ([NSFileManager.defaultManager fileExistsAtPath:rulesFilePath]) {
        assert([NSFileManager.defaultManager removeItemAtPath:rulesFilePath error:nil]);
    }
    assert([rules writeToFile:rulesFilePath atomically:YES]);

    NSString *customRulesFilePath = [AppDelegate configPathForFile:@"varCleanRules-custom.plist"];
    if (![NSFileManager.defaultManager fileExistsAtPath:customRulesFilePath]) {
        NSDictionary *template = [[NSDictionary alloc] init];
        assert([template writeToFile:customRulesFilePath atomically:YES]);
    }

    self.window = UIWindow.alloc.init;
    self.window.backgroundColor = [UIColor clearColor];
    [self.window makeKeyAndVisible];

    varCleanController *cleanController = [varCleanController sharedInstance];
    SettingViewController *settingsController = [SettingViewController sharedInstance];

    cleanController.tabBarItem = [[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"varClean", @"")
                                                               image:[UIImage systemImageNamed:@"trash"]
                                                                 tag:1];
    settingsController.tabBarItem = [[UITabBarItem alloc] initWithTitle:NSLocalizedString(@"Setting", @"")
                                                                   image:[UIImage systemImageNamed:@"gearshape"]
                                                                     tag:2];

    UINavigationController *cleanNavigationController = [[UINavigationController alloc] initWithRootViewController:cleanController];
    UINavigationController *settingsNavigationController = [[UINavigationController alloc] initWithRootViewController:settingsController];

    UITabBarController *tabBarController = [[UITabBarController alloc] init];
    tabBarController.viewControllers = @[cleanNavigationController, settingsNavigationController];
    self.window.rootViewController = tabBarController;

    // Keep the TrollStore build focused on /var cleanup. Jailbreak-only runtime
    // checks and preboot mutations stay out of this port.
    return YES;
}
@end
