#import "VarCleanController.h"
#import "AppDelegate.h"
#import "VCPaths.h"
#import "ZFCheckbox.h"

@interface varCleanController ()
@property (nonatomic, retain) NSMutableArray *tableData;
@end

@implementation varCleanController

+ (instancetype)sharedInstance {
    static varCleanController *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView.tableFooterView = [[UIView alloc] init];
    self.clearsSelectionOnViewWillAppear = NO;

    [self setTitle:Localized(@"varClean")];

    UIBarButtonItem *cleanButton = [[UIBarButtonItem alloc] initWithTitle:Localized(@"Clean")
                                                                    style:UIBarButtonItemStylePlain
                                                                   target:self
                                                                   action:@selector(varClean)];
    self.navigationItem.rightBarButtonItem = cleanButton;

    UIBarButtonItem *selectAllButton = [[UIBarButtonItem alloc] initWithTitle:Localized(@"SelectAll")
                                                                        style:UIBarButtonItemStylePlain
                                                                       target:self
                                                                       action:@selector(batchSelect)];
    self.navigationItem.leftBarButtonItem = selectAllButton;

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    refreshControl.tintColor = [UIColor grayColor];
    [refreshControl addTarget:self action:@selector(manualRefresh) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refreshControl;

    self.tableData = [self updateData:NO];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(autoRefresh)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)batchSelect {
    int selected = 0;
    for (NSDictionary *group in self.tableData) {
        for (NSMutableDictionary *item in group[@"items"]) {
            if (![item[@"checked"] boolValue] && ![item[@"ignored"] boolValue]) {
                item[@"checked"] = @YES;
                selected++;
            }
        }
    }
    if (selected == 0) {
        for (NSDictionary *group in self.tableData) {
            for (NSMutableDictionary *item in group[@"items"]) {
                if ([item[@"checked"] boolValue]) {
                    item[@"checked"] = @NO;
                }
            }
        }
    }
    [self.tableView reloadData];
}

- (void)startRefresh:(BOOL)keepState {
    [self.tableView.refreshControl beginRefreshing];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSMutableArray *newData = [self updateData:keepState];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.tableData = newData;
            [self.tableView reloadData];
            [self.tableView.refreshControl endRefreshing];
        });
    });
}

- (void)manualRefresh {
    [self startRefresh:NO];
}

- (void)autoRefresh {
    [self startRefresh:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView.refreshControl beginRefreshing];
    [self.tableView.refreshControl endRefreshing];
}

static NSArray *GetDirectoryContents(NSString *path) {
    NSError *error = nil;
    NSArray *contents = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:&error];
    if (!contents) {
        NSLog(@"contentsOfDirectoryAtPath: %@ : %@", path, error);
        return nil;
    }

    NSMutableArray *result = [NSMutableArray new];
    for (NSString *item in contents) {
        NSString *fullPath = [path stringByAppendingPathComponent:item];
        BOOL isDirectory = NO;
        BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:fullPath isDirectory:&isDirectory];
        [result addObject:@{
            @"name": item,
            @"isDirectory": @(exists && isDirectory),
        }];
    }
    return result;
}

- (void)updateForRules:(NSDictionary *)rules
              customed:(NSMutableDictionary *)customedRules
               newData:(NSMutableArray *)newData
             keepState:(BOOL)keepState {
    for (NSString *path in rules) {
        NSMutableArray *folders = [[NSMutableArray alloc] init];
        NSMutableArray *files = [[NSMutableArray alloc] init];

        NSDictionary *ruleItem = rules[path];
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSArray *contents = GetDirectoryContents(path);

        NSArray *whiteList = ruleItem[@"whitelist"];
        NSArray *blackList = ruleItem[@"blacklist"];

        NSDictionary *customedRuleItem = customedRules[path];
        NSArray *customedWhiteList = customedRuleItem[@"whitelist"];
        NSArray *customedBlackList = customedRuleItem[@"blacklist"];
        [customedRules removeObjectForKey:path];

        NSMutableDictionary *tableGroup = @{
            @"group": path,
            @"items": @[],
        }.mutableCopy;

        for (NSDictionary *item in contents ?: @[]) {
            NSString *file = item[@"name"];

            BOOL checked = NO;
            BOOL ignored = NO;

            if ([self checkFileInList:file List:blackList]) {
                if ([self checkFileInList:file List:customedWhiteList]) {
                    ignored = YES;
                    checked = NO;
                } else {
                    checked = YES;
                }
            } else if ([self checkFileInList:file List:customedBlackList]) {
                checked = YES;
            } else if ([self checkFileInList:file List:whiteList]) {
                continue;
            } else if ([ruleItem[@"default"] isEqualToString:@"blacklist"]) {
                if ([self checkFileInList:file List:customedWhiteList] ||
                    [customedRuleItem[@"default"] isEqualToString:@"whitelist"]) {
                    ignored = YES;
                    checked = NO;
                } else {
                    checked = YES;
                }
            } else if ([ruleItem[@"default"] isEqualToString:@"whitelist"]) {
                if ([customedRuleItem[@"default"] isEqualToString:@"blacklist"]) {
                    checked = YES;
                } else {
                    continue;
                }
            } else {
                if ([self checkFileInList:file List:customedWhiteList] ||
                    [customedRuleItem[@"default"] isEqualToString:@"whitelist"]) {
                    ignored = YES;
                    checked = NO;
                } else if ([customedRuleItem[@"default"] isEqualToString:@"blacklist"]) {
                    checked = YES;
                } else {
                    checked = NO;
                }
            }

            if (keepState) {
                for (NSDictionary *group in self.tableData) {
                    if (![group[@"group"] isEqualToString:path]) {
                        continue;
                    }

                    for (NSDictionary *existingItem in group[@"items"]) {
                        if ([existingItem[@"name"] isEqualToString:file]) {
                            if (!ignored) {
                                checked = [existingItem[@"checked"] boolValue];
                            }
                            break;
                        }
                    }
                    break;
                }
            }

            NSString *fullPath = [path stringByAppendingPathComponent:file];
            BOOL isFolder = [item[@"isDirectory"] boolValue];

            NSMutableDictionary *tableItem = @{
                @"name": file,
                @"path": fullPath,
                @"isFolder": @(isFolder),
                @"checked": @(checked),
                @"ignored": @(ignored),
            }.mutableCopy;

            if (isFolder) {
                [folders addObject:tableItem];
            } else {
                [files addObject:tableItem];
            }
        }

        NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"name"
                                                                         ascending:YES
                                                                          selector:@selector(localizedCaseInsensitiveCompare:)];
        NSArray *sortedFolders = [folders sortedArrayUsingDescriptors:@[sortDescriptor]];
        NSArray *sortedFiles = [files sortedArrayUsingDescriptors:@[sortDescriptor]];

        tableGroup[@"error"] = @(!contents && [fileManager fileExistsAtPath:path]);
        tableGroup[@"items"] = [[sortedFolders arrayByAddingObjectsFromArray:sortedFiles] mutableCopy];
        [newData addObject:tableGroup];
    }
}

- (NSMutableArray *)updateData:(BOOL)keepState {
    NSLog(@"updateData...");
    NSMutableArray *newData = [[NSMutableArray alloc] init];

    NSDictionary *rules = [NSDictionary dictionaryWithContentsOfFile:[AppDelegate configPathForFile:@"varCleanRules.plist"]];
    NSMutableDictionary *customedRules = [NSMutableDictionary dictionaryWithContentsOfFile:[AppDelegate configPathForFile:@"varCleanRules-custom.plist"]];
    if (!customedRules) {
        customedRules = [[NSMutableDictionary alloc] init];
    }

    [self updateForRules:rules customed:customedRules newData:newData keepState:keepState];
    [self updateForRules:customedRules customed:nil newData:newData keepState:keepState];

    NSComparator sorter = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        if ([a[@"items"] count] != 0 && [b[@"items"] count] == 0) {
            return NSOrderedAscending;
        }
        if ([a[@"items"] count] == 0 && [b[@"items"] count] != 0) {
            return NSOrderedDescending;
        }
        return [a[@"group"] compare:b[@"group"]];
    };
    [newData sortUsingComparator:sorter];
    return newData;
}

- (BOOL)checkFileInList:(NSString *)fileName List:(NSArray *)list {
    for (NSObject *item in list) {
        if ([item isKindOfClass:NSString.class]) {
            if ([fileName isEqualToString:(NSString *)item]) {
                return YES;
            }
        } else if ([item isKindOfClass:NSDictionary.class]) {
            NSDictionary *condition = (NSDictionary *)item;
            NSString *name = condition[@"name"];
            NSString *match = condition[@"match"];

            if ([match isEqualToString:@"include"]) {
                if ([fileName rangeOfString:name].location != NSNotFound) {
                    return YES;
                }
            } else if ([match isEqualToString:@"regexp"]) {
                NSRegularExpression *regex = [[NSRegularExpression alloc] initWithPattern:name options:0 error:nil];
                NSUInteger result = [regex numberOfMatchesInString:fileName options:0 range:NSMakeRange(0, fileName.length)];
                if (result != 0) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

- (void)performClean {
    [self.tableView.refreshControl beginRefreshing];

    for (NSDictionary *group in [self.tableData copy]) {
        for (NSDictionary *item in [group[@"items"] copy]) {
            if (![item[@"checked"] boolValue]) {
                continue;
            }

            NSError *error = nil;
            if (![NSFileManager.defaultManager removeItemAtPath:item[@"path"] error:&error]) {
                NSLog(@"clean failed: %@", error);
                continue;
            }

            NSIndexPath *indexPath = [NSIndexPath indexPathForRow:[group[@"items"] indexOfObject:item]
                                                        inSection:[self.tableData indexOfObject:group]];
            [group[@"items"] removeObject:item];
            [self.tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationLeft];
        }
    }

    [self.tableView.refreshControl endRefreshing];
    self.tableData = [self updateData:NO];
    [self.tableView reloadData];
}

- (void)varClean {
    NSMutableString *deletionList = [NSMutableString stringWithString:Localized(@"You are about to delete the following items:\n")];

    for (NSDictionary *group in self.tableData) {
        for (NSDictionary *item in group[@"items"]) {
            if ([item[@"checked"] boolValue]) {
                [deletionList appendFormat:@"%@\n", item[@"path"]];
            }
        }
    }

    NSString *alertMessage = [NSString stringWithFormat:@"%@\n%@",
                              Localized(@"Are you sure you want to clean selected items?"),
                              deletionList];
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:Localized(@"Confirmation")
                                                                             message:alertMessage
                                                                      preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:Localized(@"Confirm")
                                                            style:UIAlertActionStyleDestructive
                                                          handler:^(__unused UIAlertAction *action) {
        [self performClean];
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:Localized(@"Cancel")
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];

    [alertController addAction:confirmAction];
    [alertController addAction:cancelAction];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.tableData.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.tableData[section][@"items"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.tableData[section][@"group"];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    NSDictionary *groupData = self.tableData[section];
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;

    if ([groupData[@"error"] boolValue]) {
        header.textLabel.textColor = UIColor.systemRedColor;
    } else if ([groupData[@"items"] count] > 0) {
        header.textLabel.textColor = UIColor.secondaryLabelColor;
    } else {
        header.textLabel.textColor = UIColor.tertiaryLabelColor;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"Cell"];

    NSDictionary *item = self.tableData[indexPath.section][@"items"][indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@",
                           [item[@"isFolder"] boolValue] ? @"🗂️" : @"📄",
                           item[@"name"]];
    cell.textLabel.textColor = [item[@"ignored"] boolValue] ? UIColor.grayColor : UIColor.labelColor;

    ZFCheckbox *checkbox = [[ZFCheckbox alloc] initWithFrame:CGRectMake(0, 0, 20, 20)];
    checkbox.userInteractionEnabled = NO;
    [checkbox setSelected:[item[@"checked"] boolValue]];
    cell.accessoryView = checkbox;

    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(cellLongPress:)];
    [cell.contentView addGestureRecognizer:gesture];
    gesture.view.tag = indexPath.row | indexPath.section << 32;
    gesture.minimumPressDuration = 1;

    return cell;
}

- (void)cellLongPress:(UIGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }

    long tag = recognizer.view.tag;
    NSIndexPath *indexPath = [NSIndexPath indexPathForRow:tag & 0xFFFFFFFF inSection:tag >> 32];
    NSDictionary *item = self.tableData[indexPath.section][@"items"][indexPath.row];
    NSString *path = item[@"path"];

    UIPasteboard.generalPasteboard.string = path;
    for (NSURL *url in VCViewerURLsForPath(path)) {
        if ([UIApplication.sharedApplication canOpenURL:url]) {
            [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
            return;
        }
    }

    [AppDelegate showMessage:path title:@"Path copied to clipboard"];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    ZFCheckbox *checkbox = (ZFCheckbox *)cell.accessoryView;
    BOOL newState = !checkbox.selected;
    [checkbox setSelected:newState animated:YES];

    NSMutableDictionary *item = self.tableData[indexPath.section][@"items"][indexPath.row];
    item[@"checked"] = @(newState);
}
@end
