#import "SettingViewController.h"
#import "AppDelegate.h"
#import "VCPaths.h"

@interface SettingViewController ()
@property (nonatomic, retain) NSMutableArray *menuData;
@end

@implementation SettingViewController

+ (instancetype)sharedInstance {
    static SettingViewController *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)reloadMenu {
    NSString *rulesFilePath = [AppDelegate configPathForFile:@"varCleanRules-custom.plist"];

    self.menuData = @[
        @{
            @"groupTitle": Localized(@"General"),
            @"items": @[
                @{
                    @"textLabel": Localized(@"Whitelist Mode"),
                    @"detailTextLabel": Localized(@"auto blacklist newly installed apps"),
                    @"type": @"switch",
                    @"switchKey": @"whitelistMode",
                    @"disabled": @YES,
                },
            ],
        },
        @{
            @"groupTitle": Localized(@"Advanced"),
            @"items": @[
                @{
                    @"textLabel": Localized(@"Edit varClean Rules"),
                    @"detailTextLabel": Localized(@"view the rules file in Filza"),
                    @"type": @"viewer",
                    @"path": rulesFilePath,
                },
            ],
        },
    ].mutableCopy;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.tableFooterView = [[UIView alloc] init];

    [self setTitle:Localized(@"Setting")];
    [self reloadMenu];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.menuData.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSDictionary *groupData = self.menuData[section];
    return [groupData[@"items"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.menuData[section][@"groupTitle"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];

    NSDictionary *item = self.menuData[indexPath.section][@"items"][indexPath.row];
    cell.textLabel.text = item[@"textLabel"];
    cell.detailTextLabel.text = item[@"detailTextLabel"];

    NSDictionary *settings = [AppDelegate getDefaultsForKey:@"settings"];
    if ([item[@"type"] isEqualToString:@"switch"]) {
        UISwitch *toggle = [[UISwitch alloc] initWithFrame:CGRectZero];
        if (item[@"status"]) {
            [toggle setOn:[item[@"status"] boolValue]];
        } else {
            [toggle setOn:[settings[item[@"switchKey"]] boolValue]];
        }
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        if (item[@"disabled"]) {
            [toggle setEnabled:![item[@"disabled"] boolValue]];
        }
        cell.accessoryView = toggle;
    }

    if ([item[@"type"] isEqualToString:@"viewer"]) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    return cell;
}

- (void)switchChanged:(id)sender {
    UISwitch *switchInCell = (UISwitch *)sender;
    CGPoint pos = [switchInCell convertPoint:switchInCell.bounds.origin toView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:pos];

    NSDictionary *item = self.menuData[indexPath.section][@"items"][indexPath.row];
    if (item[@"switchKey"]) {
        NSMutableDictionary *settings = [AppDelegate getDefaultsForKey:@"settings"];
        if (!settings) {
            settings = [[NSMutableDictionary alloc] init];
        }
        settings[item[@"switchKey"]] = @(switchInCell.on);
        [AppDelegate setDefaults:settings forKey:@"settings"];
    } else if (item[@"action"]) {
        ((void(^)(void))item[@"action"])();
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *item = self.menuData[indexPath.section][@"items"][indexPath.row];
    if (![item[@"type"] isEqualToString:@"viewer"]) {
        return;
    }

    NSString *path = item[@"path"];
    for (NSURL *url in VCViewerURLsForPath(path)) {
        if ([UIApplication.sharedApplication canOpenURL:url]) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
            return;
        }
    }

    [AppDelegate showMessage:path title:@"Viewer URL unavailable"];
}
@end
