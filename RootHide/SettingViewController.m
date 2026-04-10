#import "SettingViewController.h"
#import "AppDelegate.h"
#import "AppInfo.h"

static NSString * const RHRootHideInjectRelativePath = @"/var/mobile/Library/RootHide/pro.m1337.inject.plist";
static NSString * const RHRootHideUninjectRelativePath = @"/var/mobile/Library/RootHide/pro.m1337.uninject.plist";
static NSString * const RHRootHideInjectSystemRelativePath = @"/var/mobile/Library/RootHide/pro.m1337.inject.system.plist";
static NSString * const RHRootHideInjectWantsBlacklistRelativePath = @"/var/mobile/Library/RootHide/pro.m1337.inject.wantsblacklist.plist";
static NSString * const RHRootHideJetsamAddendRelativePath = @"/var/mobile/Library/RootHide/pro.m1337.jetsam.addend.plist";
static NSString * const RHVarCleanRulesRelativePath = @"/var/mobile/Library/RootHide/varCleanRules.plist";
static NSString * const RHVarCleanCustomRulesRelativePath = @"/var/mobile/Library/RootHide/varCleanRules-custom.plist";
static NSString * const RHRootHideHiddenWhitelistTweaksRelativePath = @"/var/mobile/Library/RootHide/pro.m1337.hiddenwhitelist.tweaks.plist";
static NSString * const RHWhitelistSortModeDefaultsKey = @"m1337.rhinject.whitelistSortMode";
static NSString * const RHWhitelistSortModeOriginal = @"original";
static NSString * const RHWhitelistSortModeAlphabetical = @"alphabetical";
static NSInteger const RHHiddenTweakAllowMode = 1;
static NSInteger const RHHiddenTweakDenyMode = 2;

void killAllForBundle(const char *bundlePath);
int spawnRoot(NSString* path, NSArray* args, NSString** stdOut, NSString** stdErr);

@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

static BOOL RHDictionaryBoolValue(id value)
{
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

static NSInteger RHDictionaryIntegerValue(id value, NSInteger fallback)
{
    return [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : fallback;
}

static NSString *RHNormalizedWhitelistSortMode(NSString *mode)
{
    if ([mode isEqualToString:RHWhitelistSortModeAlphabetical]) {
        return RHWhitelistSortModeAlphabetical;
    }
    return RHWhitelistSortModeOriginal;
}

static NSString *RHCurrentWhitelistSortMode(void)
{
    NSString *mode = [[NSUserDefaults standardUserDefaults] stringForKey:RHWhitelistSortModeDefaultsKey];
    return RHNormalizedWhitelistSortMode(mode);
}

static void RHSetCurrentWhitelistSortMode(NSString *mode)
{
    [[NSUserDefaults standardUserDefaults] setObject:RHNormalizedWhitelistSortMode(mode) forKey:RHWhitelistSortModeDefaultsKey];
}

static BOOL RHPathIsDefaultInstallationPath(NSString *path)
{
    return [path hasPrefix:@"/private/var/containers/Bundle/Application/"];
}

static NSString *RHModeDisplayName(NSString *mode)
{
    if ([mode isEqualToString:@"blacklistallowlist"]) {
        return Localized(@"Blacklist + Allowlist");
    }
    if ([mode isEqualToString:@"hiddenwhitelist"]) {
        return Localized(@"Hidden Whitelist");
    }
    if ([mode isEqualToString:@"whitelist"]) {
        return Localized(@"Whitelist");
    }
    if ([mode isEqualToString:@"blacklist"]) {
        return Localized(@"Blacklist");
    }
    return Localized(@"Stock");
}

static NSString *RHVarCleanModeDisplayName(NSString *mode)
{
    if ([mode isEqualToString:@"blacklistallowlist"]) {
        return Localized(@"Blacklist + Allowlist");
    }
    if ([mode isEqualToString:@"hiddenwhitelist"]) {
        return Localized(@"Hidden Whitelist");
    }
    if ([mode isEqualToString:@"whitelist"]) {
        return Localized(@"Whitelist");
    }
    if ([mode isEqualToString:@"blacklist"]) {
        return Localized(@"Blacklist");
    }
    return Localized(@"Inherit");
}

static NSString *RHVarCleanEntryDisplayName(id entry)
{
    if ([entry isKindOfClass:[NSString class]]) {
        return entry;
    }
    if ([entry isKindOfClass:[NSDictionary class]]) {
        NSString *match = entry[@"match"];
        NSString *name = entry[@"name"];
        if (match.length > 0 && name.length > 0) {
            return [NSString stringWithFormat:@"%@: %@", match, name];
        }
        if (name.length > 0) {
            return name;
        }
    }
    return [entry description];
}

static BOOL RHVarCleanArrayContainsEntry(NSArray *entries, id entry)
{
    for (id candidate in entries) {
        if ([candidate isEqual:entry]) {
            return YES;
        }
    }
    return NO;
}

static NSArray *RHVarCleanSortedEntries(NSArray *entries)
{
    NSMutableOrderedSet *orderedEntries = [NSMutableOrderedSet orderedSet];
    for (id entry in entries) {
        if ([entry isKindOfClass:[NSString class]] || [entry isKindOfClass:[NSDictionary class]]) {
            [orderedEntries addObject:entry];
        }
    }

    return [orderedEntries.array sortedArrayUsingComparator:^NSComparisonResult(id left, id right) {
        return [RHVarCleanEntryDisplayName(left) localizedStandardCompare:RHVarCleanEntryDisplayName(right)];
    }];
}

static NSArray *RHVarCleanEntriesForKey(NSDictionary *rule, NSString *key)
{
    NSArray *entries = [rule[key] isKindOfClass:[NSArray class]] ? rule[key] : @[];
    return RHVarCleanSortedEntries(entries);
}

static NSString *RHVarCleanRemovedKeyForMode(NSString *mode)
{
    return [mode isEqualToString:@"whitelist"] ? @"removedWhitelist" : @"removedBlacklist";
}

static NSString *RHVarCleanOppositeMode(NSString *mode)
{
    return [mode isEqualToString:@"whitelist"] ? @"blacklist" : @"whitelist";
}

static NSArray *RHVarCleanEffectiveEntriesForMode(NSDictionary *baseRule, NSDictionary *customRule, NSString *mode)
{
    NSArray *baseEntries = RHVarCleanEntriesForKey(baseRule, mode);
    NSArray *customEntries = RHVarCleanEntriesForKey(customRule, mode);
    NSArray *removedEntries = RHVarCleanEntriesForKey(customRule, RHVarCleanRemovedKeyForMode(mode));
    NSArray *oppositeCustomEntries = RHVarCleanEntriesForKey(customRule, RHVarCleanOppositeMode(mode));

    NSMutableOrderedSet *effectiveEntries = [NSMutableOrderedSet orderedSet];
    for (id entry in baseEntries) {
        if (RHVarCleanArrayContainsEntry(removedEntries, entry)) {
            continue;
        }
        if (RHVarCleanArrayContainsEntry(oppositeCustomEntries, entry)) {
            continue;
        }
        [effectiveEntries addObject:entry];
    }
    for (id entry in customEntries) {
        [effectiveEntries addObject:entry];
    }
    return RHVarCleanSortedEntries(effectiveEntries.array);
}

static NSArray<NSString *> *RHUniqStrings(NSArray<NSString *> *values)
{
    NSMutableOrderedSet<NSString *> *ordered = [NSMutableOrderedSet orderedSet];
    for (NSString *value in values) {
        if (value.length > 0) {
            [ordered addObject:value];
        }
    }
    return ordered.array;
}

static NSArray<NSString *> *RHNormalizedStringArray(id values)
{
    if (![values isKindOfClass:[NSArray class]]) {
        return @[];
    }

    NSMutableOrderedSet<NSString *> *orderedValues = [NSMutableOrderedSet orderedSet];
    for (id value in (NSArray *)values) {
        if (![value isKindOfClass:[NSString class]]) {
            continue;
        }

        NSString *trimmedValue = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmedValue.length > 0) {
            [orderedValues addObject:trimmedValue];
        }
    }
    return orderedValues.array;
}

static NSString *RHTweakSelectionSummary(NSUInteger tweakCount)
{
    if (tweakCount == 0) {
        return Localized(@"No tweaks selected");
    }
    if (tweakCount == 1) {
        return Localized(@"1 tweak selected");
    }
    return [NSString stringWithFormat:Localized(@"%lu tweaks selected"), (unsigned long)tweakCount];
}

static NSDictionary *RHHiddenWhitelistSettingsEntryForApp(AppInfo *app, NSDictionary *allSettings)
{
    if (![allSettings isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *bundleIdentifier = app.bundleIdentifier ?: @"";
    if (bundleIdentifier.length > 0) {
        NSDictionary *entry = [allSettings[bundleIdentifier] isKindOfClass:[NSDictionary class]] ? allSettings[bundleIdentifier] : nil;
        if (entry) {
            return entry;
        }
    }

    NSString *bundleExecutable = app.bundleExecutable ?: app.zqbbExecutable ?: @"";
    if (bundleExecutable.length > 0) {
        NSDictionary *entry = [allSettings[bundleExecutable] isKindOfClass:[NSDictionary class]] ? allSettings[bundleExecutable] : nil;
        if (entry) {
            return entry;
        }
    }

    return nil;
}

static NSDictionary *RHInfoDictionaryForBundlePath(NSString *bundlePath)
{
    if (bundlePath.length == 0) {
        return nil;
    }
    NSString *infoPlistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    return [info isKindOfClass:[NSDictionary class]] ? info : nil;
}

static NSString *RHDisplayNameForInfoDictionary(NSDictionary *infoDictionary, NSString *fallback)
{
    NSString *displayName = infoDictionary[@"CFBundleDisplayName"];
    if (displayName.length > 0) {
        return displayName;
    }
    NSString *bundleName = infoDictionary[@"CFBundleName"];
    if (bundleName.length > 0) {
        return bundleName;
    }
    return fallback;
}

@interface RHInjectionModeViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *modeItems;
@end

@interface RHDictionaryToggleViewController : UITableViewController
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic, copy) NSDictionary *defaults;
@property (nonatomic, copy) NSString *addEntryTitle;
@property (nonatomic, copy) NSString *addEntryMessage;
@property (nonatomic, copy) NSString *addEntryPlaceholder;
@property (nonatomic, retain) NSMutableDictionary *dictionary;
@property (nonatomic, copy) NSArray<NSString *> *sortedKeys;
- (instancetype)initWithTitle:(NSString *)title
                 relativePath:(NSString *)relativePath
                     defaults:(NSDictionary *)defaults
                   footerText:(NSString *)footerText
                addEntryTitle:(NSString *)addEntryTitle
              addEntryMessage:(NSString *)addEntryMessage
          addEntryPlaceholder:(NSString *)addEntryPlaceholder;
@end

@interface RHForcedEntriesViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *entries;
@property (nonatomic, copy) NSString *footerText;
@end

@interface RHNumberDictionaryViewController : UITableViewController
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic, copy) NSDictionary *defaults;
@property (nonatomic, copy) NSString *addEntryTitle;
@property (nonatomic, copy) NSString *addEntryMessage;
@property (nonatomic, copy) NSString *addEntryPlaceholder;
@property (nonatomic, copy) NSString *valuePlaceholder;
@property (nonatomic, retain) NSMutableDictionary *dictionary;
@property (nonatomic, copy) NSArray<NSString *> *sortedKeys;
- (instancetype)initWithTitle:(NSString *)title
                 relativePath:(NSString *)relativePath
                     defaults:(NSDictionary *)defaults
                   footerText:(NSString *)footerText
                addEntryTitle:(NSString *)addEntryTitle
              addEntryMessage:(NSString *)addEntryMessage
          addEntryPlaceholder:(NSString *)addEntryPlaceholder
             valuePlaceholder:(NSString *)valuePlaceholder;
@end

@interface RHAppRulesViewController : UITableViewController <UISearchBarDelegate>
@property (nonatomic, copy) NSString *rulesRelativePath;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic, copy) NSString *preferredMode;
@property (nonatomic, assign) BOOL showsTipsButton;
@property (nonatomic, retain) NSArray<AppInfo *> *applications;
@property (nonatomic, retain) NSArray<AppInfo *> *appsArray;
@property (nonatomic, retain) NSMutableArray<AppInfo *> *filteredApps;
@property (nonatomic, retain) UISearchController *searchController;
@property (nonatomic, assign) BOOL isFiltered;
- (instancetype)initWithTitle:(NSString *)title
            rulesRelativePath:(NSString *)rulesRelativePath
                preferredMode:(NSString *)preferredMode
                   footerText:(NSString *)footerText
              showsTipsButton:(BOOL)showsTipsButton;
- (NSMutableDictionary *)rulesDictionary;
- (NSArray<AppInfo *> *)loadApplications;
- (NSString *)applicationKeyForApp:(AppInfo *)app;
- (AppInfo *)appAtIndexPath:(NSIndexPath *)indexPath;
- (BOOL)isEnabledInRulesForApp:(AppInfo *)app rules:(NSDictionary *)rules;
- (BOOL)isRootHideHiddenApp:(AppInfo *)app;
- (UIImage *)scaledImage:(UIImage *)image size:(CGSize)size;
@end

@interface RHTweakInfo : NSObject
@property (nonatomic, copy) NSString *dylibName;
@property (nonatomic, copy) NSArray<NSString *> *filterBundles;
@property (nonatomic, copy) NSArray<NSString *> *filterExecutables;
@property (nonatomic, copy) NSString *filterNote;
+ (NSArray<RHTweakInfo *> *)availableTweaksForApp:(AppInfo *)app;
@end

@interface RHTweakSelectionViewController : UITableViewController
@property (nonatomic, retain) AppInfo *app;
@property (nonatomic, copy) NSString *settingsKey;
@property (nonatomic, retain) NSArray<RHTweakInfo *> *tweaks;
@property (nonatomic, retain) NSMutableDictionary *allSettings;
@property (nonatomic, retain) NSMutableDictionary *settingsForApp;
- (instancetype)initWithApp:(AppInfo *)app;
@end

@interface RHHiddenWhitelistViewController : RHAppRulesViewController
@end

@interface RHVarCleanPathViewController : UITableViewController
@property (nonatomic, copy) NSString *rulePath;
@property (nonatomic, retain) NSDictionary *baseRule;
@property (nonatomic, retain) NSMutableDictionary *customRule;
@property (nonatomic, copy) NSArray<NSDictionary *> *whitelistEntries;
@property (nonatomic, copy) NSArray<NSDictionary *> *blacklistEntries;
- (instancetype)initWithPath:(NSString *)rulePath;
@end

@interface RHVarCleanRulesViewController : UITableViewController
@property (nonatomic, retain) NSDictionary *baseRules;
@property (nonatomic, retain) NSMutableDictionary *customRules;
@property (nonatomic, copy) NSArray<NSString *> *sortedPaths;
@end

// Generic plist viewer — shows key/value pairs for any flat or nested dictionary plist.
// Flat booleans get toggles, flat numbers/strings are editable, nested dictionaries push.
@interface RHGenericPlistViewController : UITableViewController
@property (nonatomic, copy) NSString *plistTitle;
@property (nonatomic, copy) NSString *relativePath;
@property (nonatomic, copy) NSString *footerText;
@property (nonatomic, retain) NSMutableDictionary *dictionary;
@property (nonatomic, copy) NSArray<NSString *> *sortedKeys;
// For nested views: the parent VC and the key under which this dict lives.
@property (nonatomic, weak) RHGenericPlistViewController *parentPlistVC;
@property (nonatomic, copy) NSString *parentKey;
- (instancetype)initWithTitle:(NSString *)title relativePath:(NSString *)relativePath footerText:(NSString *)footerText;
@end

@interface SettingViewController ()
@property (nonatomic, retain) NSMutableArray *menuData;
@end

@implementation RHInjectionModeViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.tableFooterView = [[UIView alloc] init];
    self.title = Localized(@"Injection Mode");
    self.modeItems = @[
        @{
            @"mode" : @"stock",
            @"title" : Localized(@"Stock"),
            @"detail" : Localized(@"Keep stock RootHide behavior."),
        },
        @{
            @"mode" : @"blacklist",
            @"title" : Localized(@"Blacklist"),
            @"detail" : Localized(@"Inject by default, but skip selected executables."),
        },
        @{
            @"mode" : @"whitelist",
            @"title" : Localized(@"Whitelist"),
            @"detail" : Localized(@"Only inject selected executables and approved system paths."),
        },
        @{
            @"mode" : @"hiddenwhitelist",
            @"title" : Localized(@"Hidden Whitelist"),
            @"detail" : Localized(@"Only inject selected executables for apps that are also marked hidden in the RootHide tab. Use the Hidden Whitelist tab to pick which tweaks may load."),
        },
        @{
            @"mode" : @"blacklistallowlist",
            @"title" : Localized(@"Blacklist + Allowlist"),
            @"detail" : Localized(@"Reuse the existing Whitelist and Hidden Whitelist settings, but keep selected apps on the blacklist-backed path with restricted Roothide access."),
        },
    ];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.modeItems.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return Localized(@"Changing the runtime mode needs a userspace reboot to affect launchd-managed spawns.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ModeCell"];
    NSDictionary *item = self.modeItems[indexPath.row];
    NSString *mode = item[@"mode"];

    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"detail"];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = [[AppDelegate rootHideInjectionMode] isEqualToString:mode] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)presentUserspaceRebootPrompt
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:Localized(@"Userspace Reboot Required")
                                                                   message:Localized(@"A userspace reboot is needed to apply the injection-mode change. Reboot now?")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Later") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Reboot Now") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [AppDelegate rebootUserspace];
    }]];
    [AppDelegate showAlert:alert];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *item = self.modeItems[indexPath.row];
    NSString *selectedMode = item[@"mode"];
    if (![[AppDelegate rootHideInjectionMode] isEqualToString:selectedMode]) {
        [AppDelegate setRootHideInjectionMode:selectedMode];
        [[NSNotificationCenter defaultCenter] postNotificationName:RHInjectSettingsChangedNotification object:nil];
        [tableView reloadData];
        [self presentUserspaceRebootPrompt];
    }
}

@end

@implementation RHDictionaryToggleViewController

- (instancetype)initWithTitle:(NSString *)title
                 relativePath:(NSString *)relativePath
                     defaults:(NSDictionary *)defaults
                   footerText:(NSString *)footerText
                addEntryTitle:(NSString *)addEntryTitle
              addEntryMessage:(NSString *)addEntryMessage
          addEntryPlaceholder:(NSString *)addEntryPlaceholder
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = title;
        self.relativePath = relativePath;
        self.defaults = defaults ?: @{};
        self.footerText = footerText;
        self.addEntryTitle = addEntryTitle;
        self.addEntryMessage = addEntryMessage;
        self.addEntryPlaceholder = addEntryPlaceholder;
    }
    return self;
}

- (void)reloadData
{
    self.dictionary = [AppDelegate rootHideDictionaryForRelativePath:self.relativePath createIfNeeded:YES defaults:self.defaults];
    self.sortedKeys = [[self.dictionary allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView.tableFooterView = [[UIView alloc] init];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(addEntry)];
    [self reloadData];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadData];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.sortedKeys.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.footerText;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"DictionaryCell"];
    NSString *key = self.sortedKeys[indexPath.row];

    cell.textLabel.text = key;
    cell.detailTextLabel.text = RHDictionaryBoolValue(self.dictionary[key]) ? Localized(@"Enabled") : Localized(@"Disabled");

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = RHDictionaryBoolValue(self.dictionary[key]);
    toggle.tag = indexPath.row;
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)switchChanged:(UISwitch *)toggle
{
    NSString *key = self.sortedKeys[toggle.tag];
    self.dictionary[key] = @(toggle.on);
    [AppDelegate writeRootHideDictionary:self.dictionary toRelativePath:self.relativePath];
    [[NSNotificationCenter defaultCenter] postNotificationName:RHInjectSettingsChangedNotification object:nil];
    [self.tableView reloadData];
}

- (void)addEntry
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:self.addEntryTitle ?: self.title
                                                                   message:self.addEntryMessage
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = self.addEntryPlaceholder;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Add") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *key = [[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
        if (key.length == 0) {
            return;
        }
        self.dictionary[key] = @YES;
        [AppDelegate writeRootHideDictionary:self.dictionary toRelativePath:self.relativePath];
        [[NSNotificationCenter defaultCenter] postNotificationName:RHInjectSettingsChangedNotification object:nil];
        [self reloadData];
        [self.tableView reloadData];
    }]];
    [AppDelegate showAlert:alert];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    (void)indexPath;
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }

    NSString *key = self.sortedKeys[indexPath.row];
    [self.dictionary removeObjectForKey:key];
    [AppDelegate writeRootHideDictionary:self.dictionary toRelativePath:self.relativePath];
    [[NSNotificationCenter defaultCenter] postNotificationName:RHInjectSettingsChangedNotification object:nil];
    [self reloadData];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

@end

@implementation RHForcedEntriesViewController

- (NSArray<NSDictionary *> *)loadEntries
{
    NSDictionary *systemRules = [AppDelegate rootHideDictionaryForRelativePath:RHRootHideInjectSystemRelativePath
                                                                 createIfNeeded:YES
                                                                       defaults:[AppDelegate defaultSystemInjection]];
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];

    for (NSString *ruleKey in [[systemRules allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
        if (!RHDictionaryBoolValue(systemRules[ruleKey]) || ruleKey.length == 0) {
            continue;
        }

        NSString *displayName = ruleKey.lastPathComponent;
        if (displayName.length == 0) {
            displayName = ruleKey;
        }
        if ([displayName isEqualToString:@".jbroot"]) {
            displayName = Localized(@"Jailbreak Apps");
        }

        if ([seenKeys containsObject:ruleKey]) {
            continue;
        }
        [seenKeys addObject:ruleKey];
        [entries addObject:@{
            @"title" : displayName,
            @"detail" : ruleKey,
        }];
    }

    return entries;
}

- (void)reloadData
{
    self.entries = [self loadEntries];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView.tableFooterView = [[UIView alloc] init];
    [self reloadData];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:RHInjectSettingsChangedNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadData];
    [self.tableView reloadData];
}

- (void)settingsChanged
{
    [self reloadData];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.entries.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.footerText;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ForcedEntryCell"];
    NSDictionary *entry = self.entries[indexPath.row];
    cell.textLabel.text = entry[@"title"];
    cell.detailTextLabel.text = entry[@"detail"];
    cell.detailTextLabel.numberOfLines = 2;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end

@implementation RHNumberDictionaryViewController

- (instancetype)initWithTitle:(NSString *)title
                 relativePath:(NSString *)relativePath
                     defaults:(NSDictionary *)defaults
                   footerText:(NSString *)footerText
                addEntryTitle:(NSString *)addEntryTitle
              addEntryMessage:(NSString *)addEntryMessage
          addEntryPlaceholder:(NSString *)addEntryPlaceholder
             valuePlaceholder:(NSString *)valuePlaceholder
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = title;
        self.relativePath = relativePath;
        self.defaults = defaults ?: @{};
        self.footerText = footerText;
        self.addEntryTitle = addEntryTitle;
        self.addEntryMessage = addEntryMessage;
        self.addEntryPlaceholder = addEntryPlaceholder;
        self.valuePlaceholder = valuePlaceholder;
    }
    return self;
}

- (void)reloadData
{
    self.dictionary = [AppDelegate rootHideDictionaryForRelativePath:self.relativePath createIfNeeded:YES defaults:self.defaults];
    self.sortedKeys = [[self.dictionary allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView.tableFooterView = [[UIView alloc] init];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(addEntry)];
    [self reloadData];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadData];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.sortedKeys.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.footerText;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"NumberCell"];
    NSString *key = self.sortedKeys[indexPath.row];
    NSInteger value = RHDictionaryIntegerValue(self.dictionary[key], 0);

    cell.textLabel.text = key;
    cell.detailTextLabel.text = [NSString stringWithFormat:Localized(@"Jetsam Addend Value: %ld"), (long)value];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)persistValue:(NSInteger)value forKey:(NSString *)key
{
    if (key.length == 0 || value <= 0) {
        return;
    }

    self.dictionary[key] = @(value);
    [AppDelegate writeRootHideDictionary:self.dictionary toRelativePath:self.relativePath];
    [[NSNotificationCenter defaultCenter] postNotificationName:RHInjectSettingsChangedNotification object:nil];
    [self reloadData];
    [self.tableView reloadData];
}

- (void)presentEditorForKey:(NSString *)existingKey value:(NSNumber *)existingValue
{
    BOOL isEditing = (existingKey.length > 0);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:(isEditing ? Localized(@"Edit Jetsam Addend Rule") : (self.addEntryTitle ?: self.title))
                                                                   message:(isEditing ? Localized(@"Set the numeric addend that should be applied when the executable matches.") : self.addEntryMessage)
                                                            preferredStyle:UIAlertControllerStyleAlert];

    if (!isEditing) {
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = self.addEntryPlaceholder;
            textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            textField.autocorrectionType = UITextAutocorrectionTypeNo;
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
    }

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = self.valuePlaceholder;
        textField.keyboardType = UIKeyboardTypeNumberPad;
        if (existingValue != nil) {
            textField.text = [existingValue stringValue];
        }
    }];

    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:(isEditing ? Localized(@"Save") : Localized(@"Add"))
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *key = existingKey;
        UITextField *valueField = alert.textFields.lastObject;
        if (!isEditing) {
            key = [[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
        }

        NSInteger value = [[valueField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] integerValue];
        if (key.length == 0 || value <= 0) {
            return;
        }
        [self persistValue:value forKey:key];
    }]];
    [AppDelegate showAlert:alert];
}

- (void)addEntry
{
    [self presentEditorForKey:nil value:nil];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    (void)indexPath;
    return YES;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *key = self.sortedKeys[indexPath.row];
    NSNumber *value = self.dictionary[key];
    [self presentEditorForKey:key value:value];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }

    NSString *key = self.sortedKeys[indexPath.row];
    [self.dictionary removeObjectForKey:key];
    [AppDelegate writeRootHideDictionary:self.dictionary toRelativePath:self.relativePath];
    [[NSNotificationCenter defaultCenter] postNotificationName:RHInjectSettingsChangedNotification object:nil];
    [self reloadData];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

@end

@implementation RHAppRulesViewController

- (instancetype)initWithTitle:(NSString *)title
            rulesRelativePath:(NSString *)rulesRelativePath
                preferredMode:(NSString *)preferredMode
                   footerText:(NSString *)footerText
              showsTipsButton:(BOOL)showsTipsButton
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = title;
        self.rulesRelativePath = rulesRelativePath;
        self.preferredMode = preferredMode;
        self.footerText = footerText;
        self.showsTipsButton = showsTipsButton;
    }
    return self;
}

- (NSMutableDictionary *)rulesDictionary
{
    return [AppDelegate rootHideDictionaryForRelativePath:self.rulesRelativePath createIfNeeded:YES defaults:@{}];
}

- (NSMutableDictionary *)rootHideHiddenAppsDictionary
{
    NSMutableDictionary *appconfig = [AppDelegate getDefaultsForKey:@"appconfig"];
    return [appconfig isKindOfClass:[NSMutableDictionary class]] ? appconfig : [appconfig mutableCopy] ?: [NSMutableDictionary dictionary];
}

- (BOOL)isWhitelistRulesController
{
    return [self.rulesRelativePath isEqualToString:RHRootHideInjectRelativePath];
}

- (NSDictionary *)systemInjectionDictionary
{
    return [AppDelegate rootHideDictionaryForRelativePath:RHRootHideInjectSystemRelativePath
                                            createIfNeeded:YES
                                                  defaults:[AppDelegate defaultSystemInjection]];
}

- (NSString *)applicationKeyForApp:(AppInfo *)app
{
    if (app.bundleExecutable.length > 0) {
        return app.bundleExecutable;
    }
    if (app.bundleIdentifier.length > 0) {
        return app.bundleIdentifier;
    }
    if (app.zqbbExecutable.length > 0) {
        return app.zqbbExecutable;
    }
    return app.zqbbIdentifier;
}

- (AppInfo *)appAtIndexPath:(NSIndexPath *)indexPath
{
    return self.isFiltered ? self.filteredApps[indexPath.row] : self.appsArray[indexPath.row];
}

- (BOOL)isRootHideHiddenApp:(AppInfo *)app
{
    if (app.bundleIdentifier.length == 0) {
        return NO;
    }
    return RHDictionaryBoolValue([self rootHideHiddenAppsDictionary][app.bundleIdentifier]);
}

- (NSString *)displayTokenForSystemRuleKey:(NSString *)ruleKey
{
    if (![ruleKey isKindOfClass:[NSString class]] || ruleKey.length == 0) {
        return nil;
    }

    NSString *token = ruleKey.lastPathComponent;
    if (token.length == 0 || [token isEqualToString:@".jbroot"]) {
        return nil;
    }
    return token;
}

- (NSString *)forcedSystemRuleKeyForApp:(AppInfo *)app systemRules:(NSDictionary *)systemRules
{
    NSString *bundlePath = app.bundleURL.path ?: @"";
    NSString *bundleExecutable = [self applicationKeyForApp:app] ?: @"";

    for (NSString *ruleKey in systemRules) {
        if (!RHDictionaryBoolValue(systemRules[ruleKey]) || ruleKey.length == 0) {
            continue;
        }

        if (bundlePath.length > 0 && [bundlePath containsString:ruleKey]) {
            return ruleKey;
        }

        NSString *displayToken = [self displayTokenForSystemRuleKey:ruleKey];
        if (displayToken.length > 0 && [bundleExecutable isEqualToString:displayToken]) {
            return ruleKey;
        }
    }

    return nil;
}

- (void)markForcedWhitelistStateForApp:(AppInfo *)app systemRules:(NSDictionary *)systemRules
{
    app.forcedEnabled = NO;
    app.forcedRuleKey = nil;

    NSString *forcedRuleKey = [self forcedSystemRuleKeyForApp:app systemRules:systemRules];
    if (forcedRuleKey.length > 0) {
        app.forcedEnabled = YES;
        app.forcedRuleKey = forcedRuleKey;
    }
}

- (AppInfo *)findAppInArray:(NSArray<AppInfo *> *)applications matchingToken:(NSString *)token
{
    if (token.length == 0) {
        return nil;
    }

    for (AppInfo *app in applications) {
        if ((app.bundleIdentifier.length > 0 && [app.bundleIdentifier isEqualToString:token])
            || (app.bundleExecutable.length > 0 && [app.bundleExecutable isEqualToString:token])
            || (app.zqbbIdentifier.length > 0 && [app.zqbbIdentifier isEqualToString:token])
            || (app.zqbbExecutable.length > 0 && [app.zqbbExecutable isEqualToString:token])) {
            return app;
        }
    }
    return nil;
}

- (void)addSyntheticAppToApplications:(NSMutableArray<AppInfo *> *)applications
                    bundleIdentifier:(NSString *)bundleIdentifier
                     bundleExecutable:(NSString *)bundleExecutable
                                 name:(NSString *)name
                          needsInject:(BOOL)needsInject
                            isJailApp:(BOOL)isJailApp
{
    if (bundleExecutable.length == 0) {
        return;
    }

    AppInfo *existing = [self findAppInArray:applications matchingToken:bundleExecutable];
    if (!existing && bundleIdentifier.length > 0) {
        existing = [self findAppInArray:applications matchingToken:bundleIdentifier];
    }

    if (existing) {
        if (needsInject) {
            existing.needsInject = YES;
        }
        return;
    }

    AppInfo *app = [AppInfo syntheticAppWithIdentifier:(bundleIdentifier.length > 0 ? bundleIdentifier : bundleExecutable)
                                            executable:bundleExecutable
                                                  name:(name.length > 0 ? name : bundleExecutable)
                                                  icon:nil
                                           needsInject:needsInject
                                             isJailApp:isJailApp];
    [applications addObject:app];
}

- (void)addPlugInsFromBundlePath:(NSString *)bundlePath
                fallbackParentName:(NSString *)fallbackParentName
                   parentIsJailApp:(BOOL)parentIsJailApp
                     toApplications:(NSMutableArray<AppInfo *> *)applications
{
    NSString *plugInsPath = [bundlePath stringByAppendingPathComponent:@"PlugIns"];
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:plugInsPath error:nil];
    for (NSString *entry in entries) {
        if (![[entry pathExtension].lowercaseString isEqualToString:@"appex"]) {
            continue;
        }

        NSString *appexPath = [plugInsPath stringByAppendingPathComponent:entry];
        NSDictionary *info = RHInfoDictionaryForBundlePath(appexPath);
        NSString *bundleIdentifier = info[@"CFBundleIdentifier"];
        NSString *bundleExecutable = info[@"CFBundleExecutable"];
        if (bundleIdentifier.length == 0 || bundleExecutable.length == 0) {
            continue;
        }

        NSString *fallbackName = [[entry lastPathComponent] stringByDeletingPathExtension];
        NSString *name = RHDisplayNameForInfoDictionary(info, fallbackName.length > 0 ? fallbackName : fallbackParentName);
        [self addSyntheticAppToApplications:applications
                           bundleIdentifier:bundleIdentifier
                            bundleExecutable:bundleExecutable
                                        name:name
                                 needsInject:NO
                                   isJailApp:parentIsJailApp];
    }
}

- (void)addBundledApplicationsFromRoot:(NSString *)applicationsRoot toApplications:(NSMutableArray<AppInfo *> *)applications
{
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:applicationsRoot error:nil];
    for (NSString *entry in entries) {
        if (![[entry pathExtension].lowercaseString isEqualToString:@"app"]) {
            continue;
        }

        NSString *bundlePath = [applicationsRoot stringByAppendingPathComponent:entry];
        NSDictionary *info = RHInfoDictionaryForBundlePath(bundlePath);
        NSString *bundleIdentifier = info[@"CFBundleIdentifier"];
        NSString *bundleExecutable = info[@"CFBundleExecutable"];
        if (bundleIdentifier.length == 0 || bundleExecutable.length == 0) {
            continue;
        }

        NSString *fallbackName = [[entry lastPathComponent] stringByDeletingPathExtension];
        NSString *displayName = RHDisplayNameForInfoDictionary(info, fallbackName);
        BOOL isJailApp = [bundlePath containsString:@".jbroot"];
        [self addSyntheticAppToApplications:applications
                           bundleIdentifier:bundleIdentifier
                            bundleExecutable:bundleExecutable
                                        name:displayName
                                 needsInject:NO
                                   isJailApp:isJailApp];
        [self addPlugInsFromBundlePath:bundlePath fallbackParentName:displayName parentIsJailApp:isJailApp toApplications:applications];
    }
}

- (NSArray<NSString *> *)extraApplicationRoots
{
    NSString *jbApplications = [AppDelegate rootHidePathForRelativePath:@"/Applications"];
    return RHUniqStrings(@[
        @"/Applications",
        jbApplications ?: @"",
    ]);
}

- (NSString *)launchDaemonExecutableForBundleIdentifier:(NSString *)bundleIdentifier
{
    if (bundleIdentifier.length == 0) {
        return nil;
    }

    NSString *plistPath = [@"/System/Library/LaunchDaemons" stringByAppendingPathComponent:[bundleIdentifier stringByAppendingString:@".plist"]];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (![plist isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSArray *programArguments = plist[@"ProgramArguments"];
    if ([programArguments isKindOfClass:[NSArray class]] && programArguments.count > 0) {
        NSString *programPath = [programArguments.firstObject description];
        return programPath.lastPathComponent;
    }

    NSString *program = plist[@"Program"];
    if (program.length > 0) {
        return program.lastPathComponent;
    }
    return nil;
}

- (void)addRequiredEntriesFromTweakInjectToApplications:(NSMutableArray<AppInfo *> *)applications
{
    NSString *tweakInjectPath = [AppDelegate rootHidePathForRelativePath:@"/usr/lib/TweakInject"];
    NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:tweakInjectPath error:nil];
    for (NSString *entry in entries) {
        if (![[entry pathExtension].lowercaseString isEqualToString:@"plist"]) {
            continue;
        }

        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:[tweakInjectPath stringByAppendingPathComponent:entry]];
        NSDictionary *filter = [plist[@"Filter"] isKindOfClass:[NSDictionary class]] ? plist[@"Filter"] : nil;
        NSArray *bundles = [filter[@"Bundles"] isKindOfClass:[NSArray class]] ? filter[@"Bundles"] : nil;
        NSArray *executables = [filter[@"Executables"] isKindOfClass:[NSArray class]] ? filter[@"Executables"] : nil;

        for (NSString *bundleIdentifier in bundles) {
            if (![bundleIdentifier isKindOfClass:[NSString class]] || bundleIdentifier.length == 0) {
                continue;
            }

            AppInfo *existing = [self findAppInArray:applications matchingToken:bundleIdentifier];
            if (existing) {
                existing.needsInject = YES;
                continue;
            }

            NSString *launchDaemonExecutable = [self launchDaemonExecutableForBundleIdentifier:bundleIdentifier];
            [self addSyntheticAppToApplications:applications
                               bundleIdentifier:bundleIdentifier
                                bundleExecutable:(launchDaemonExecutable.length > 0 ? launchDaemonExecutable : bundleIdentifier)
                                            name:bundleIdentifier
                                     needsInject:YES
                                       isJailApp:NO];
        }

        for (NSString *bundleExecutable in executables) {
            if (![bundleExecutable isKindOfClass:[NSString class]] || bundleExecutable.length == 0) {
                continue;
            }

            AppInfo *existing = [self findAppInArray:applications matchingToken:bundleExecutable];
            if (existing) {
                existing.needsInject = YES;
                continue;
            }

            [self addSyntheticAppToApplications:applications
                               bundleIdentifier:bundleExecutable
                                bundleExecutable:bundleExecutable
                                            name:bundleExecutable
                                     needsInject:YES
                                       isJailApp:NO];
        }
    }
}

- (void)addExplicitlyEnabledEntriesToApplications:(NSMutableArray<AppInfo *> *)applications
{
    NSDictionary *rules = [self rulesDictionary];
    [rules enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if (!RHDictionaryBoolValue(value) || key.length == 0) {
            return;
        }

        if (![self findAppInArray:applications matchingToken:key]) {
            [self addSyntheticAppToApplications:applications
                               bundleIdentifier:key
                                bundleExecutable:key
                                            name:key
                                     needsInject:NO
                                       isJailApp:NO];
        }
    }];
}

- (void)applyForcedWhitelistEntriesToApplications:(NSMutableArray<AppInfo *> *)applications
{
    NSDictionary *systemRules = [self systemInjectionDictionary];
    for (AppInfo *app in applications) {
        [self markForcedWhitelistStateForApp:app systemRules:systemRules];
    }

    [systemRules enumerateKeysAndObjectsUsingBlock:^(NSString *ruleKey, id value, BOOL *stop) {
        (void)stop;
        if (!RHDictionaryBoolValue(value)) {
            return;
        }

        NSString *displayToken = [self displayTokenForSystemRuleKey:ruleKey];
        if (displayToken.length == 0) {
            return;
        }

        AppInfo *existing = [self findAppInArray:applications matchingToken:displayToken];
        if (!existing) {
            [self addSyntheticAppToApplications:applications
                               bundleIdentifier:displayToken
                                bundleExecutable:displayToken
                                            name:displayToken
                                     needsInject:NO
                                       isJailApp:NO];
            existing = [self findAppInArray:applications matchingToken:displayToken];
        }

        if (existing) {
            existing.forcedEnabled = YES;
            existing.forcedRuleKey = ruleKey;
        }
    }];
}

- (NSArray<AppInfo *> *)loadApplications
{
    NSMutableArray<AppInfo *> *applications = [NSMutableArray array];

    for (id proxy in [LSApplicationWorkspace.defaultWorkspace allInstalledApplications]) {
        AppInfo *app = [AppInfo appWithPrivateProxy:proxy];
        if (app.isHiddenApp || app.bundleExecutable.length == 0) {
            continue;
        }

        app.zqbbExecutable = app.bundleExecutable;
        app.zqbbIdentifier = app.bundleIdentifier;
        app.isJailApp = [app.bundleURL.path containsString:@".jbroot"];
        [applications addObject:app];

        if (RHPathIsDefaultInstallationPath(app.bundleURL.path)) {
            [self addPlugInsFromBundlePath:app.bundleURL.path fallbackParentName:app.name parentIsJailApp:app.isJailApp toApplications:applications];
        }
    }

    for (NSString *applicationsRoot in [self extraApplicationRoots]) {
        [self addBundledApplicationsFromRoot:applicationsRoot toApplications:applications];
    }

    if ([self isWhitelistRulesController]) {
        [self addRequiredEntriesFromTweakInjectToApplications:applications];
    }

    [self addExplicitlyEnabledEntriesToApplications:applications];
    if ([self isWhitelistRulesController]) {
        [self applyForcedWhitelistEntriesToApplications:applications];
    }
    return applications;
}

- (BOOL)isAlphabeticalSortEnabled
{
    return [self isWhitelistRulesController] && [RHCurrentWhitelistSortMode() isEqualToString:RHWhitelistSortModeAlphabetical];
}

- (BOOL)isEnabledInRulesForApp:(AppInfo *)app rules:(NSDictionary *)rules
{
    NSString *key = [self applicationKeyForApp:app];
    return key.length > 0 && RHDictionaryBoolValue(rules[key]);
}

- (BOOL)isEffectivelyEnabledApp:(AppInfo *)app rules:(NSDictionary *)rules
{
    return app.forcedEnabled || [self isEnabledInRulesForApp:app rules:rules];
}

- (NSArray<AppInfo *> *)sortApplications:(NSArray<AppInfo *> *)applications sortWithStatus:(BOOL)sortWithStatus
{
    NSDictionary *rules = [self rulesDictionary];
    BOOL alphabeticalOnly = [self isAlphabeticalSortEnabled];

    return [applications sortedArrayUsingComparator:^NSComparisonResult(AppInfo *app1, AppInfo *app2) {
        if (sortWithStatus && !alphabeticalOnly) {
            BOOL enabled1 = [self isEffectivelyEnabledApp:app1 rules:rules];
            BOOL enabled2 = [self isEffectivelyEnabledApp:app2 rules:rules];
            if (enabled1 != enabled2) {
                return [@(enabled2) compare:@(enabled1)];
            }

            // Within enabled apps, show user-toggled entries first,
            // forced/auto-activated (greyed out) entries after.
            if (app1.forcedEnabled != app2.forcedEnabled) {
                return [@(app1.forcedEnabled) compare:@(app2.forcedEnabled)];
            }

            if (app1.needsInject != app2.needsInject) {
                return [@(app2.needsInject) compare:@(app1.needsInject)];
            }

            if (app1.isHiddenApp != app2.isHiddenApp) {
                return [@(app1.isHiddenApp) compare:@(app2.isHiddenApp)];
            }
        }

        return [app1.name localizedStandardCompare:app2.name];
    }];
}

- (void)reloadSearch
{
    NSString *searchText = self.searchController.searchBar.text;
    if (searchText.length == 0) {
        self.isFiltered = NO;
        self.filteredApps = nil;
        return;
    }

    self.isFiltered = YES;
    self.filteredApps = [NSMutableArray array];
    NSString *lowerSearchText = searchText.lowercaseString;
    for (AppInfo *app in self.appsArray) {
        if ([app.name.lowercaseString containsString:lowerSearchText]
            || [app.bundleIdentifier.lowercaseString containsString:lowerSearchText]
            || [app.bundleExecutable.lowercaseString containsString:lowerSearchText]) {
            [self.filteredApps addObject:app];
        }
    }
}

- (void)refreshApplications:(BOOL)resort
{
    UIRefreshControl *refreshControl = self.tableView.refreshControl;
    [refreshControl beginRefreshing];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSArray<AppInfo *> *newApplications = [self loadApplications];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.applications = newApplications;
            self.appsArray = [self sortApplications:newApplications sortWithStatus:resort];
            [self reloadSearch];
            [self.tableView reloadData];
            [refreshControl endRefreshing];
        });
    });
}

- (void)settingsChanged
{
    self.applications = [self loadApplications];
    self.appsArray = [self sortApplications:self.applications sortWithStatus:YES];
    [self reloadSearch];
    [self updateSortButton];
    [self.tableView reloadData];
}

- (void)showTips
{
    [AppDelegate showMessage:Localized(@"Those marked in red are required by the plug-in, and it is recommended to enable them.\n\nFor the UIKit global plug-in, please enable the corresponding app on your own.\n\nFor the home screen search feature, please enable Spotlight.\n\nRegarding third-party keyboard extensions, please inject the corresponding appex background. (For example, WeChat is wxkb_plugin).\n\nAfter enabling whitelist mode, the blacklist injection tab becomes inactive. QQ, WeChat, Runner, and AppStore can still use the hidden-app blacklist through inject.wantsblacklist.")
                     title:Localized(@"Tips")];
}

- (void)setWhitelistSortMode:(NSString *)sortMode
{
    RHSetCurrentWhitelistSortMode(sortMode);
    [self updateSortButton];
    self.appsArray = [self sortApplications:self.applications sortWithStatus:YES];
    [self reloadSearch];
    [self.tableView reloadData];
}

- (UIAlertAction *)sortAlertActionWithTitle:(NSString *)title
                                       mode:(NSString *)mode
{
    BOOL isActive = [RHCurrentWhitelistSortMode() isEqualToString:mode];
    NSString *displayTitle = isActive ? [NSString stringWithFormat:@"✓ %@", title] : title;
    return [UIAlertAction actionWithTitle:displayTitle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self setWhitelistSortMode:mode];
    }];
}

- (void)presentSortActionSheet
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:Localized(@"Sort")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[self sortAlertActionWithTitle:Localized(@"Original RHInject") mode:RHWhitelistSortModeOriginal]];
    [alert addAction:[self sortAlertActionWithTitle:Localized(@"Alphabetical") mode:RHWhitelistSortModeAlphabetical]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    alert.popoverPresentationController.barButtonItem = self.navigationItem.leftBarButtonItem;
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(0, 0, 1, 1);
    [AppDelegate showAlert:alert];
}

- (void)updateSortButton
{
    if (![self isWhitelistRulesController]) {
        self.navigationItem.leftBarButtonItem = nil;
        return;
    }

    if (@available(iOS 14.0, *)) {
        NSString *currentMode = RHCurrentWhitelistSortMode();
        UIAction *originalAction = [UIAction actionWithTitle:Localized(@"Original RHInject")
                                                       image:nil
                                                  identifier:nil
                                                     handler:^(__unused UIAction *action) {
            [self setWhitelistSortMode:RHWhitelistSortModeOriginal];
        }];
        originalAction.state = [currentMode isEqualToString:RHWhitelistSortModeOriginal] ? UIMenuElementStateOn : UIMenuElementStateOff;

        UIAction *alphabeticalAction = [UIAction actionWithTitle:Localized(@"Alphabetical")
                                                           image:nil
                                                      identifier:nil
                                                         handler:^(__unused UIAction *action) {
            [self setWhitelistSortMode:RHWhitelistSortModeAlphabetical];
        }];
        alphabeticalAction.state = [currentMode isEqualToString:RHWhitelistSortModeAlphabetical] ? UIMenuElementStateOn : UIMenuElementStateOff;

        UIMenu *menu = [UIMenu menuWithTitle:@""
                                       image:nil
                                  identifier:nil
                                     options:UIMenuOptionsSingleSelection
                                    children:@[ originalAction, alphabeticalAction ]];
        UIBarButtonItem *sortItem = [[UIBarButtonItem alloc] initWithTitle:Localized(@"Sort")
                                                                     style:UIBarButtonItemStylePlain
                                                                    target:nil
                                                                    action:nil];
        sortItem.menu = menu;
        self.navigationItem.leftBarButtonItem = sortItem;
    }
    else {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:Localized(@"Sort")
                                                                                 style:UIBarButtonItemStylePlain
                                                                                target:self
                                                                                action:@selector(presentSortActionSheet)];
    }
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView.tableFooterView = [[UIView alloc] init];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchBar.delegate = self;
    self.searchController.searchBar.placeholder = Localized(@"name, identifier or executable");
    self.searchController.searchBar.barTintColor = [UIColor whiteColor];
    self.searchController.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    if (self.showsTipsButton) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:Localized(@"Tips")
                                                                                  style:UIBarButtonItemStylePlain
                                                                                 target:self
                                                                                 action:@selector(showTips)];
    }
    [self updateSortButton];

    UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
    refreshControl.tintColor = [UIColor grayColor];
    [refreshControl addTarget:self action:@selector(manualRefresh) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refreshControl;

    self.applications = [self loadApplications];
    self.appsArray = [self sortApplications:self.applications sortWithStatus:YES];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(autoRefresh) name:UIApplicationWillEnterForegroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:RHInjectSettingsChangedNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self updateSortButton];
    self.appsArray = [self sortApplications:self.applications sortWithStatus:YES];
    [self reloadSearch];
    [self.tableView reloadData];
}

- (void)manualRefresh
{
    [self refreshApplications:YES];
}

- (void)autoRefresh
{
    [self refreshApplications:NO];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText
{
    (void)searchBar;
    (void)searchText;
    [self reloadSearch];
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar
{
    (void)searchBar;
    [self reloadSearch];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.isFiltered ? self.filteredApps.count : self.appsArray.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.footerText;
}

- (UIImage *)scaledImage:(UIImage *)image size:(CGSize)size
{
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    UIImage *scaledImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return scaledImage;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"AppRuleCell"];
    AppInfo *app = self.isFiltered ? self.filteredApps[indexPath.row] : self.appsArray[indexPath.row];
    NSDictionary *rules = [self rulesDictionary];

    UIImage *icon = app.icon;
    if (icon) {
        cell.imageView.image = [self scaledImage:icon size:CGSizeMake(40, 40)];
    }

    cell.textLabel.text = app.name;
    NSString *bundleIdentifier = app.bundleIdentifier ?: app.bundleExecutable ?: @"";
    NSString *bundleExecutable = [self applicationKeyForApp:app] ?: @"-";
    NSString *detailText = [NSString stringWithFormat:@"%@  •  %@", bundleIdentifier, bundleExecutable];
    if (app.forcedEnabled) {
        NSString *forcedDescription = app.isJailApp
            ? [NSString stringWithFormat:Localized(@"Forced on by whitelist helper: %@"), (app.forcedRuleKey ?: @"/.jbroot")]
            : [NSString stringWithFormat:Localized(@"Forced on by whitelist helper: %@"), (app.forcedRuleKey ?: @"")];
        detailText = [NSString stringWithFormat:@"%@\n%@", detailText, forcedDescription];
    }
    cell.detailTextLabel.text = detailText;
    cell.detailTextLabel.numberOfLines = app.forcedEnabled ? 3 : 2;
    if (app.needsInject && [self isWhitelistRulesController] && !app.forcedEnabled) {
        cell.textLabel.textColor = [UIColor systemRedColor];
    }
    else {
        cell.textLabel.textColor = UIColor.labelColor;
    }

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = app.forcedEnabled || [self isEnabledInRulesForApp:app rules:rules];
    toggle.enabled = !app.forcedEnabled;
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)switchChanged:(UISwitch *)toggle
{
    CGPoint position = [toggle convertPoint:toggle.bounds.origin toView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:position];
    if (!indexPath) {
        return;
    }

    AppInfo *app = self.isFiltered ? self.filteredApps[indexPath.row] : self.appsArray[indexPath.row];
    NSMutableDictionary *rules = [self rulesDictionary];
    NSString *appKey = [self applicationKeyForApp:app];
    if (app.forcedEnabled) {
        toggle.on = YES;
        return;
    }
    if (appKey.length == 0) {
        return;
    }

    rules[appKey] = @(toggle.on);
    [AppDelegate writeRootHideDictionary:rules toRelativePath:self.rulesRelativePath];

    // When disabling an app in whitelist mode, also remove any stale
    // hidden whitelist tweak selections so launchdhook doesn't mistakenly
    // activate hidden injection for a blacklist-only app.
    if (!toggle.on && [self isWhitelistRulesController]) {
        NSMutableDictionary *hiddenTweakSettings = [AppDelegate rootHideDictionaryForRelativePath:RHRootHideHiddenWhitelistTweaksRelativePath createIfNeeded:NO defaults:nil];
        if (hiddenTweakSettings) {
            NSString *bundleId = app.bundleIdentifier ?: @"";
            NSString *execName = app.bundleExecutable ?: @"";
            BOOL changed = NO;
            if (bundleId.length > 0 && hiddenTweakSettings[bundleId]) {
                [hiddenTweakSettings removeObjectForKey:bundleId];
                changed = YES;
            }
            if (execName.length > 0 && hiddenTweakSettings[execName]) {
                [hiddenTweakSettings removeObjectForKey:execName];
                changed = YES;
            }
            if (changed) {
                [AppDelegate writeRootHideDictionary:hiddenTweakSettings toRelativePath:RHRootHideHiddenWhitelistTweaksRelativePath];
            }
        }
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:RHInjectSettingsChangedNotification object:nil];

    if (app.bundleURL.path.length > 0) {
        killAllForBundle(app.bundleURL.path.UTF8String);
    }

    self.appsArray = [self sortApplications:self.applications sortWithStatus:YES];
    [self reloadSearch];
    [self.tableView reloadData];
}

@end

@implementation RHTweakInfo

+ (NSArray<NSString *> *)possibleInjectionLibrariesPaths
{
    return RHUniqStrings(@[
        [AppDelegate rootHidePathForRelativePath:@"/Library/MobileSubstrate/DynamicLibraries"] ?: @"",
        [AppDelegate rootHidePathForRelativePath:@"/usr/lib/TweakInject"] ?: @"",
    ]);
}

+ (NSSet<NSString *> *)hiddenWhitelistExcludedTweaks
{
    static NSSet<NSString *> *excludedTweaks;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        excludedTweaks = [NSSet setWithArray:@[
            @"Choicy",
            @"ChoicySB",
            @"MobileSafety",
            @"PreferenceLoader",
            @"preferred",
        ]];
    });
    return excludedTweaks;
}

+ (BOOL)matchesApp:(AppInfo *)app filterBundles:(NSArray<NSString *> *)filterBundles filterExecutables:(NSArray<NSString *> *)filterExecutables
{
    NSString *bundleIdentifier = app.bundleIdentifier ?: @"";
    NSString *bundleExecutable = app.bundleExecutable ?: app.zqbbExecutable ?: @"";

    if (filterBundles.count == 0 && filterExecutables.count == 0) {
        return YES;
    }
    if (bundleIdentifier.length > 0 && [filterBundles containsObject:bundleIdentifier]) {
        return YES;
    }
    if (bundleExecutable.length > 0 && [filterExecutables containsObject:bundleExecutable]) {
        return YES;
    }
    return NO;
}

+ (NSArray<RHTweakInfo *> *)availableTweaksForApp:(AppInfo *)app
{
    NSMutableArray<RHTweakInfo *> *tweaks = [NSMutableArray array];
    NSMutableSet<NSString *> *seenDylibNames = [NSMutableSet set];

    for (NSString *directoryPath in [self possibleInjectionLibrariesPaths]) {
        NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directoryPath error:nil];
        for (NSString *entry in entries) {
            if (![[entry pathExtension].lowercaseString isEqualToString:@"dylib"]) {
                continue;
            }

            NSString *dylibName = entry.stringByDeletingPathExtension;
            if (dylibName.length == 0 || [[self hiddenWhitelistExcludedTweaks] containsObject:dylibName] || [seenDylibNames containsObject:dylibName]) {
                continue;
            }

            NSString *plistPath = [[directoryPath stringByAppendingPathComponent:dylibName] stringByAppendingPathExtension:@"plist"];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            NSDictionary *filter = [plist[@"Filter"] isKindOfClass:[NSDictionary class]] ? plist[@"Filter"] : nil;
            NSArray<NSString *> *filterBundles = RHNormalizedStringArray(filter[@"Bundles"]);
            NSArray<NSString *> *filterExecutables = RHNormalizedStringArray(filter[@"Executables"]);
            BOOL hasPlistMetadata = [[NSFileManager defaultManager] fileExistsAtPath:plistPath];
            BOOL matchesApp = [self matchesApp:app filterBundles:filterBundles filterExecutables:filterExecutables];

            RHTweakInfo *tweakInfo = [[RHTweakInfo alloc] init];
            tweakInfo.dylibName = dylibName;
            tweakInfo.filterBundles = filterBundles ?: @[];
            tweakInfo.filterExecutables = filterExecutables ?: @[];
            if (!hasPlistMetadata) {
                tweakInfo.filterNote = Localized(@"No plist filter metadata");
            }
            else if (filterBundles.count == 0 && filterExecutables.count == 0) {
                tweakInfo.filterNote = Localized(@"Global filter");
            }
            else if (!matchesApp) {
                tweakInfo.filterNote = Localized(@"Filter does not match this app");
            }
            [tweaks addObject:tweakInfo];
            [seenDylibNames addObject:dylibName];
        }
    }

    [tweaks sortUsingComparator:^NSComparisonResult(RHTweakInfo *left, RHTweakInfo *right) {
        return [left.dylibName localizedStandardCompare:right.dylibName];
    }];
    return tweaks;
}

@end

@implementation RHTweakSelectionViewController

- (instancetype)initWithApp:(AppInfo *)app
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.app = app;
        self.settingsKey = app.bundleIdentifier.length > 0 ? app.bundleIdentifier : app.bundleExecutable;
        self.title = app.name;
    }
    return self;
}

- (void)reloadConfiguration
{
    self.allSettings = [AppDelegate rootHideDictionaryForRelativePath:RHRootHideHiddenWhitelistTweaksRelativePath createIfNeeded:YES defaults:@{}];

    NSDictionary *storedSettings = [self.allSettings[self.settingsKey] isKindOfClass:[NSDictionary class]] ? self.allSettings[self.settingsKey] : nil;
    NSMutableDictionary *settings = storedSettings.mutableCopy ?: [NSMutableDictionary dictionary];

    NSInteger allowDenyMode = RHDictionaryIntegerValue(settings[@"allowDenyMode"], RHHiddenTweakAllowMode);
    if (allowDenyMode != RHHiddenTweakDenyMode) {
        allowDenyMode = RHHiddenTweakAllowMode;
    }

    settings[@"allowDenyMode"] = @(allowDenyMode);
    settings[@"allowedTweaks"] = RHNormalizedStringArray(settings[@"allowedTweaks"]);
    settings[@"deniedTweaks"] = RHNormalizedStringArray(settings[@"deniedTweaks"]);

    self.settingsForApp = settings;
    self.tweaks = [RHTweakInfo availableTweaksForApp:self.app];
}

- (void)persistConfiguration
{
    NSArray<NSString *> *allowedTweaks = RHNormalizedStringArray(self.settingsForApp[@"allowedTweaks"]);
    NSArray<NSString *> *deniedTweaks = RHNormalizedStringArray(self.settingsForApp[@"deniedTweaks"]);
    NSInteger allowDenyMode = RHDictionaryIntegerValue(self.settingsForApp[@"allowDenyMode"], RHHiddenTweakAllowMode);

    if (allowDenyMode != RHHiddenTweakDenyMode) {
        allowDenyMode = RHHiddenTweakAllowMode;
    }

    if (allowedTweaks.count == 0 && deniedTweaks.count == 0) {
        [self.allSettings removeObjectForKey:self.settingsKey];
    }
    else {
        self.allSettings[self.settingsKey] = @{
            @"allowDenyMode" : @(allowDenyMode),
            @"allowedTweaks" : allowedTweaks,
            @"deniedTweaks" : deniedTweaks,
        };
    }

    [AppDelegate writeRootHideDictionary:self.allSettings toRelativePath:RHRootHideHiddenWhitelistTweaksRelativePath];
    [[NSNotificationCenter defaultCenter] postNotificationName:RHInjectSettingsChangedNotification object:nil];

    if (self.app.bundleURL.path.length > 0) {
        killAllForBundle(self.app.bundleURL.path.UTF8String);
    }
}

- (BOOL)isTweakEnabled:(RHTweakInfo *)tweakInfo
{
    NSString *key = tweakInfo.dylibName ?: @"";
    NSInteger allowDenyMode = RHDictionaryIntegerValue(self.settingsForApp[@"allowDenyMode"], RHHiddenTweakAllowMode);
    if (allowDenyMode == RHHiddenTweakDenyMode) {
        return [RHNormalizedStringArray(self.settingsForApp[@"deniedTweaks"]) containsObject:key];
    }
    return [RHNormalizedStringArray(self.settingsForApp[@"allowedTweaks"]) containsObject:key];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView.tableFooterView = [[UIView alloc] init];
    [self reloadConfiguration];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadConfiguration];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return (section == 0) ? 1 : self.tweaks.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return (section == 0) ? Localized(@"Mode") : Localized(@"Tweaks");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0) {
        return Localized(@"Choose whether the listed tweaks are explicitly allowed or explicitly denied when hidden injection loads TweakLoader for this app.");
    }
    if (self.tweaks.count == 0) {
        return Localized(@"No tweak dylibs were found in the standard injection directories.");
    }
    return Localized(@"All tweak dylibs found in the standard injection directories are listed here. Hidden Whitelist only uses the names you explicitly select.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"HiddenTweakCell"];

    if (indexPath.section == 0) {
        cell.textLabel.text = Localized(@"Per-app hidden tweak filter");
        cell.detailTextLabel.text = Localized(@"This stays separate from Choicy. Hidden Whitelist uses it to decide which tweak dylibs may load.");
        cell.detailTextLabel.numberOfLines = 2;

        UISegmentedControl *segmentedControl = [[UISegmentedControl alloc] initWithItems:@[ Localized(@"Allow"), Localized(@"Deny") ]];
        segmentedControl.selectedSegmentIndex = RHDictionaryIntegerValue(self.settingsForApp[@"allowDenyMode"], RHHiddenTweakAllowMode) == RHHiddenTweakDenyMode ? 1 : 0;
        [segmentedControl addTarget:self action:@selector(modeChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = segmentedControl;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    RHTweakInfo *tweakInfo = self.tweaks[indexPath.row];
    cell.textLabel.text = tweakInfo.dylibName;

    NSMutableArray<NSString *> *detailParts = [NSMutableArray array];
    if (tweakInfo.filterBundles.count > 0) {
        [detailParts addObject:[NSString stringWithFormat:@"B: %@", [tweakInfo.filterBundles componentsJoinedByString:@", "]]];
    }
    if (tweakInfo.filterExecutables.count > 0) {
        [detailParts addObject:[NSString stringWithFormat:@"E: %@", [tweakInfo.filterExecutables componentsJoinedByString:@", "]]];
    }
    if (tweakInfo.filterNote.length > 0) {
        [detailParts addObject:tweakInfo.filterNote];
    }
    cell.detailTextLabel.text = detailParts.count > 0 ? [detailParts componentsJoinedByString:@"\n"] : Localized(@"Global filter");
    cell.detailTextLabel.numberOfLines = detailParts.count > 1 ? 3 : 1;

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = [self isTweakEnabled:tweakInfo];
    toggle.tag = indexPath.row;
    [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)modeChanged:(UISegmentedControl *)segmentedControl
{
    self.settingsForApp[@"allowDenyMode"] = @(segmentedControl.selectedSegmentIndex == 1 ? RHHiddenTweakDenyMode : RHHiddenTweakAllowMode);
    [self persistConfiguration];
    [self.tableView reloadData];
}

- (void)toggleChanged:(UISwitch *)toggle
{
    if (toggle.tag < 0 || toggle.tag >= self.tweaks.count) {
        return;
    }

    RHTweakInfo *tweakInfo = self.tweaks[toggle.tag];
    NSString *key = tweakInfo.dylibName ?: @"";
    NSInteger allowDenyMode = RHDictionaryIntegerValue(self.settingsForApp[@"allowDenyMode"], RHHiddenTweakAllowMode);
    NSString *listKey = (allowDenyMode == RHHiddenTweakDenyMode) ? @"deniedTweaks" : @"allowedTweaks";
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSetWithArray:RHNormalizedStringArray(self.settingsForApp[listKey])];

    if (toggle.on) {
        [names addObject:key];
    }
    else {
        [names removeObject:key];
    }

    self.settingsForApp[listKey] = names.array;
    [self persistConfiguration];
    [self.tableView reloadData];
}

@end

@implementation RHHiddenWhitelistViewController

- (instancetype)init
{
    self = [super initWithTitle:Localized(@"Hidden Whitelist")
              rulesRelativePath:RHRootHideInjectRelativePath
                  preferredMode:@"hiddenwhitelist"
                     footerText:Localized(@"Apps shown here are both hidden in Classic RootHide and enabled in Whitelist. Tap an app to choose which tweaks may load in Hidden Whitelist or Blacklist + Allowlist mode.")
                showsTipsButton:NO];
    return self;
}

- (NSArray<AppInfo *> *)loadApplications
{
    NSArray<AppInfo *> *applications = [super loadApplications];
    NSDictionary *rules = [self rulesDictionary];

    NSMutableArray<AppInfo *> *filteredApplications = [NSMutableArray array];
    for (AppInfo *app in applications) {
        if (app.forcedEnabled || app.bundleIdentifier.length == 0) {
            continue;
        }
        if (![self isRootHideHiddenApp:app]) {
            continue;
        }
        if (![self isEnabledInRulesForApp:app rules:rules]) {
            continue;
        }
        [filteredApplications addObject:app];
    }
    return filteredApplications;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"HiddenWhitelistCell"];
    AppInfo *app = [self appAtIndexPath:indexPath];

    if (app.icon) {
        cell.imageView.image = [self scaledImage:app.icon size:CGSizeMake(40, 40)];
    }

    NSDictionary *allHiddenTweakSettings = [AppDelegate rootHideDictionaryForRelativePath:RHRootHideHiddenWhitelistTweaksRelativePath createIfNeeded:YES defaults:@{}];
    NSDictionary *appHiddenTweakSettings = RHHiddenWhitelistSettingsEntryForApp(app, allHiddenTweakSettings);
    NSInteger allowDenyMode = RHDictionaryIntegerValue(appHiddenTweakSettings[@"allowDenyMode"], RHHiddenTweakAllowMode);
    NSArray<NSString *> *allowedTweaks = RHNormalizedStringArray(appHiddenTweakSettings[@"allowedTweaks"]);
    NSArray<NSString *> *deniedTweaks = RHNormalizedStringArray(appHiddenTweakSettings[@"deniedTweaks"]);
    NSUInteger tweakCount = allowDenyMode == RHHiddenTweakDenyMode ? deniedTweaks.count : allowedTweaks.count;

    cell.textLabel.text = app.name;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  •  %@\n%@",
                                 app.bundleIdentifier ?: @"",
                                 [self applicationKeyForApp:app] ?: @"-",
                                 RHTweakSelectionSummary(tweakCount)];
    cell.detailTextLabel.numberOfLines = 3;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    AppInfo *app = [self appAtIndexPath:indexPath];
    [self.navigationController pushViewController:[[RHTweakSelectionViewController alloc] initWithApp:app] animated:YES];
}

@end

@implementation RHVarCleanPathViewController

- (instancetype)initWithPath:(NSString *)rulePath
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.rulePath = rulePath;
    }
    return self;
}

- (NSMutableDictionary *)loadAllCustomRules
{
    return [NSMutableDictionary dictionaryWithContentsOfFile:[AppDelegate rootHidePathForRelativePath:RHVarCleanCustomRulesRelativePath]] ?: [NSMutableDictionary dictionary];
}

- (NSMutableArray *)mutableCustomEntriesForKey:(NSString *)key
{
    return [RHVarCleanEntriesForKey(self.customRule, key) mutableCopy];
}

- (void)setCustomEntries:(NSArray *)entries forKey:(NSString *)key
{
    NSArray *sortedEntries = RHVarCleanSortedEntries(entries);
    if (sortedEntries.count > 0) {
        self.customRule[key] = sortedEntries;
    }
    else {
        [self.customRule removeObjectForKey:key];
    }
}

- (NSArray<NSDictionary *> *)entryDescriptorsForMode:(NSString *)mode
{
    NSArray *effectiveEntries = RHVarCleanEffectiveEntriesForMode(self.baseRule, self.customRule, mode);
    NSArray *baseEntries = RHVarCleanEntriesForKey(self.baseRule, mode);
    NSArray *customEntries = RHVarCleanEntriesForKey(self.customRule, mode);

    NSMutableArray<NSDictionary *> *descriptors = [NSMutableArray array];
    for (id entry in effectiveEntries) {
        [descriptors addObject:@{
            @"entry" : entry,
            @"mode" : mode,
            @"builtIn" : @(RHVarCleanArrayContainsEntry(baseEntries, entry)),
            @"custom" : @(RHVarCleanArrayContainsEntry(customEntries, entry)),
        }];
    }
    return descriptors;
}

- (void)reloadRule
{
    NSDictionary *allBaseRules = [NSDictionary dictionaryWithContentsOfFile:[AppDelegate rootHidePathForRelativePath:RHVarCleanRulesRelativePath]] ?: @{};
    NSDictionary *allCustomRules = [self loadAllCustomRules];

    self.baseRule = [allBaseRules[self.rulePath] isKindOfClass:[NSDictionary class]] ? allBaseRules[self.rulePath] : @{};
    self.customRule = [[allCustomRules[self.rulePath] isKindOfClass:[NSDictionary class]] ? allCustomRules[self.rulePath] : @{} mutableCopy];
    self.whitelistEntries = [self entryDescriptorsForMode:@"whitelist"];
    self.blacklistEntries = [self entryDescriptorsForMode:@"blacklist"];

    NSString *title = self.rulePath.lastPathComponent;
    self.title = title.length > 0 ? title : self.rulePath;
}

- (void)persistCustomRule
{
    NSMutableDictionary *allCustomRules = [self loadAllCustomRules];
    if (self.customRule.count > 0) {
        allCustomRules[self.rulePath] = self.customRule;
    }
    else {
        [allCustomRules removeObjectForKey:self.rulePath];
    }
    [AppDelegate writeRootHideDictionary:allCustomRules toRelativePath:RHVarCleanCustomRulesRelativePath];
}

- (void)persistAndReload
{
    [self persistCustomRule];
    [self reloadRule];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 2;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView.tableFooterView = [[UIView alloc] init];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(addEntry)];
    [self reloadRule];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadRule];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    return (section == 0) ? self.whitelistEntries.count : self.blacklistEntries.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return (section == 0) ? Localized(@"Whitelist") : Localized(@"Blacklist");
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    if (section == 0) {
        return [NSString stringWithFormat:Localized(@"Path: %@\nEntries in Whitelist stay preserved during varClean. Swipe left on any entry to remove it or move it to Blacklist."), self.rulePath];
    }
    return Localized(@"Entries in Blacklist are force-cleaned during varClean. Swipe left on any entry to remove it or move it to Whitelist.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"VarCleanPathCell"];
    NSDictionary *descriptor = (indexPath.section == 0) ? self.whitelistEntries[indexPath.row] : self.blacklistEntries[indexPath.row];
    BOOL builtIn = [descriptor[@"builtIn"] boolValue];
    BOOL custom = [descriptor[@"custom"] boolValue];

    cell.textLabel.text = RHVarCleanEntryDisplayName(descriptor[@"entry"]);
    if (builtIn && custom) {
        cell.detailTextLabel.text = Localized(@"Built-in and custom");
    }
    else if (builtIn) {
        cell.detailTextLabel.text = Localized(@"Built-in");
    }
    else if (custom) {
        cell.detailTextLabel.text = Localized(@"Custom");
    }
    else {
        cell.detailTextLabel.text = nil;
    }
    cell.detailTextLabel.numberOfLines = 2;
    return cell;
}

- (void)addEntryObject:(id)entry toKey:(NSString *)key
{
    NSMutableArray *entries = [self mutableCustomEntriesForKey:key];
    if (!RHVarCleanArrayContainsEntry(entries, entry)) {
        [entries addObject:entry];
    }
    [self setCustomEntries:entries forKey:key];
}

- (void)removeEntryObject:(id)entry fromKey:(NSString *)key
{
    NSMutableArray *entries = [self mutableCustomEntriesForKey:key];
    NSIndexSet *indexes = [entries indexesOfObjectsPassingTest:^BOOL(id candidate, NSUInteger idx, BOOL *stop) {
        (void)idx;
        (void)stop;
        return [candidate isEqual:entry];
    }];
    if (indexes.count > 0) {
        [entries removeObjectsAtIndexes:indexes];
    }
    [self setCustomEntries:entries forKey:key];
}

- (void)removeEntryDescriptor:(NSDictionary *)descriptor fromMode:(NSString *)mode
{
    id entry = descriptor[@"entry"];
    NSString *removedKey = RHVarCleanRemovedKeyForMode(mode);
    if ([descriptor[@"custom"] boolValue]) {
        [self removeEntryObject:entry fromKey:mode];
    }
    if ([descriptor[@"builtIn"] boolValue]) {
        [self addEntryObject:entry toKey:removedKey];
    }
    [self persistAndReload];
}

- (void)moveEntryDescriptor:(NSDictionary *)descriptor fromMode:(NSString *)mode
{
    id entry = descriptor[@"entry"];
    NSString *destinationMode = RHVarCleanOppositeMode(mode);
    [self removeEntryObject:entry fromKey:mode];
    [self removeEntryObject:entry fromKey:RHVarCleanRemovedKeyForMode(destinationMode)];
    [self addEntryObject:entry toKey:destinationMode];
    [self persistAndReload];
}

- (void)presentAddEntryAlertForMode:(NSString *)mode
{
    BOOL isWhitelist = [mode isEqualToString:@"whitelist"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:(isWhitelist ? Localized(@"Add to Whitelist") : Localized(@"Add to Blacklist"))
                                                                   message:(isWhitelist ? Localized(@"Add an exact entry name that should stay in Whitelist for this path.") : Localized(@"Add an exact entry name that should stay in Blacklist for this path."))
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = Localized(@"Entry name");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Add") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *entry = [[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
        if (entry.length == 0) {
            return;
        }
        [self removeEntryObject:entry fromKey:RHVarCleanRemovedKeyForMode(mode)];
        [self addEntryObject:entry toKey:mode];
        [self persistAndReload];
    }]];
    [AppDelegate showAlert:alert];
}

- (void)addEntry
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:Localized(@"Add Entry")
                                                                   message:Localized(@"Choose which list should receive the new entry.")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Whitelist")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self presentAddEntryAlertForMode:@"whitelist"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Blacklist")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self presentAddEntryAlertForMode:@"blacklist"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [AppDelegate showAlert:alert];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    NSString *mode = (indexPath.section == 0) ? @"whitelist" : @"blacklist";
    NSDictionary *descriptor = (indexPath.section == 0) ? self.whitelistEntries[indexPath.row] : self.blacklistEntries[indexPath.row];

    UIContextualAction *removeAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:Localized(@"Remove")
                                                                             handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self removeEntryDescriptor:descriptor fromMode:mode];
        completionHandler(YES);
    }];

    NSString *moveTitle = [mode isEqualToString:@"whitelist"] ? Localized(@"Move to Blacklist") : Localized(@"Move to Whitelist");
    UIContextualAction *moveAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
                                                                             title:moveTitle
                                                                           handler:^(__unused UIContextualAction *action, __unused UIView *sourceView, void (^completionHandler)(BOOL)) {
        [self moveEntryDescriptor:descriptor fromMode:mode];
        completionHandler(YES);
    }];
    moveAction.backgroundColor = UIColor.systemBlueColor;

    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[removeAction, moveAction]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}

@end

@implementation RHVarCleanRulesViewController

- (void)reloadRules
{
    self.baseRules = [NSDictionary dictionaryWithContentsOfFile:[AppDelegate rootHidePathForRelativePath:RHVarCleanRulesRelativePath]] ?: @{};
    self.customRules = [NSMutableDictionary dictionaryWithContentsOfFile:[AppDelegate rootHidePathForRelativePath:RHVarCleanCustomRulesRelativePath]] ?: [NSMutableDictionary dictionary];

    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSetWithArray:[self.baseRules allKeys]];
    [paths addObjectsFromArray:[self.customRules allKeys]];
    self.sortedPaths = [paths.array sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (void)persistCustomRules
{
    [AppDelegate writeRootHideDictionary:self.customRules toRelativePath:RHVarCleanCustomRulesRelativePath];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView.tableFooterView = [[UIView alloc] init];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(addRulePath)];
    self.title = Localized(@"varClean Rules");
    [self reloadRules];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadRules];
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.sortedPaths.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return Localized(@"Changes are stored in varCleanRules-custom.plist. Open a path to review its Whitelist and Blacklist entries, add new ones, or swipe existing entries to remove or move them.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"VarCleanRuleCell"];
    NSString *path = self.sortedPaths[indexPath.row];
    NSDictionary *baseRule = [self.baseRules[path] isKindOfClass:[NSDictionary class]] ? self.baseRules[path] : @{};
    NSDictionary *customRule = [self.customRules[path] isKindOfClass:[NSDictionary class]] ? self.customRules[path] : nil;
    NSArray *effectiveWhitelist = RHVarCleanEffectiveEntriesForMode(baseRule, customRule ?: @{}, @"whitelist");
    NSArray *effectiveBlacklist = RHVarCleanEffectiveEntriesForMode(baseRule, customRule ?: @{}, @"blacklist");

    cell.textLabel.text = path;
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@: %ld  •  %@: %ld",
                                 Localized(@"Whitelist"),
                                 (long)effectiveWhitelist.count,
                                 Localized(@"Blacklist"),
                                 (long)effectiveBlacklist.count];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)addRulePath
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:Localized(@"Add varClean Path")
                                                                   message:Localized(@"Create a custom varClean rule path. Leave it empty if you only want to edit an existing built-in path.")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = Localized(@"Filesystem path");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Add") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *path = [[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
        if (path.length == 0) {
            return;
        }
        if (![self.customRules[path] isKindOfClass:[NSDictionary class]]) {
            self.customRules[path] = @{};
            [self persistCustomRules];
        }
        [self reloadRules];
        [self.tableView reloadData];
        [self.navigationController pushViewController:[[RHVarCleanPathViewController alloc] initWithPath:path] animated:YES];
    }]];
    [AppDelegate showAlert:alert];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    NSString *path = self.sortedPaths[indexPath.row];
    return [self.customRules[path] isKindOfClass:[NSDictionary class]];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) {
        return;
    }

    NSString *path = self.sortedPaths[indexPath.row];
    [self.customRules removeObjectForKey:path];
    [self persistCustomRules];
    [self reloadRules];
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *path = self.sortedPaths[indexPath.row];
    [self.navigationController pushViewController:[[RHVarCleanPathViewController alloc] initWithPath:path] animated:YES];
}

@end

//------------------------------------------------------------------------------
#pragma mark - Generic Plist Viewer/Editor

@implementation RHGenericPlistViewController

- (instancetype)initWithTitle:(NSString *)title relativePath:(NSString *)relativePath footerText:(NSString *)footerText
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.plistTitle = title;
        self.relativePath = relativePath;
        self.footerText = footerText;
    }
    return self;
}

- (void)reloadData
{
    // Nested views don't re-read from disk — their data comes from the parent.
    if (!self.parentPlistVC) {
        self.dictionary = [AppDelegate rootHideDictionaryForRelativePath:self.relativePath createIfNeeded:NO defaults:nil];
        if (!self.dictionary) {
            self.dictionary = [NSMutableDictionary dictionary];
        }
    }
    self.sortedKeys = [[self.dictionary allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = self.plistTitle;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addEntry)];
    [self reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    return self.sortedKeys.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView;
    (void)section;
    NSString *resolvedPath = [AppDelegate rootHidePathForRelativePath:self.relativePath];
    if (self.footerText.length > 0) {
        return [NSString stringWithFormat:@"%@\n\n%@", self.footerText, resolvedPath];
    }
    return resolvedPath;
}

static NSString *RHPlistValueDescription(id value)
{
    if (!value) return @"(null)";
    if ([value isKindOfClass:[NSNumber class]]) {
        if (strcmp([value objCType], @encode(BOOL)) == 0 || strcmp([value objCType], @encode(char)) == 0) {
            return [value boolValue] ? @"YES" : @"NO";
        }
        return [value stringValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        return [NSString stringWithFormat:@"{ %lu keys }", (unsigned long)[(NSDictionary *)value count]];
    }
    if ([value isKindOfClass:[NSArray class]]) {
        return [NSString stringWithFormat:@"[ %lu items ]", (unsigned long)[(NSArray *)value count]];
    }
    return [value description];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"GenericPlistCell"];
    NSString *key = self.sortedKeys[indexPath.row];
    id value = self.dictionary[key];

    cell.textLabel.text = key;
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
    cell.detailTextLabel.text = RHPlistValueDescription(value);
    cell.detailTextLabel.numberOfLines = 3;

    if ([value isKindOfClass:[NSDictionary class]] || [value isKindOfClass:[NSArray class]]) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if ([value isKindOfClass:[NSNumber class]] &&
               (strcmp([value objCType], @encode(BOOL)) == 0 || strcmp([value objCType], @encode(char)) == 0)) {
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = [value boolValue];
        toggle.tag = indexPath.row;
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    return cell;
}

- (void)persistChanges
{
    if (self.parentPlistVC) {
        // Write our dictionary back into the parent's key, then let parent persist.
        self.parentPlistVC.dictionary[self.parentKey] = [self.dictionary copy];
        [self.parentPlistVC persistChanges];
    } else {
        [AppDelegate writeRootHideDictionary:self.dictionary toRelativePath:self.relativePath];
        [[NSNotificationCenter defaultCenter] postNotificationName:RHInjectSettingsChangedNotification object:nil];
    }
}

- (void)switchChanged:(UISwitch *)toggle
{
    if (toggle.tag >= (NSInteger)self.sortedKeys.count) return;
    NSString *key = self.sortedKeys[toggle.tag];
    self.dictionary[key] = @(toggle.on);
    [self persistChanges];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *key = self.sortedKeys[indexPath.row];
    id value = self.dictionary[key];

    if ([value isKindOfClass:[NSDictionary class]]) {
        // Push a nested plist viewer that saves back through us.
        RHGenericPlistViewController *nested = [[RHGenericPlistViewController alloc]
            initWithTitle:key
             relativePath:self.relativePath
               footerText:[NSString stringWithFormat:@"Nested dictionary under key \"%@\"", key]];
        nested.dictionary = [value mutableCopy];
        nested.sortedKeys = [[value allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
        nested.parentPlistVC = self;
        nested.parentKey = key;
        [self.navigationController pushViewController:nested animated:YES];
        return;
    }

    if ([value isKindOfClass:[NSArray class]]) {
        // Show array items as a simple read-only list (e.g. allowedTweaks)
        NSArray *array = (NSArray *)value;
        NSMutableString *items = [NSMutableString string];
        for (NSUInteger i = 0; i < array.count; i++) {
            [items appendFormat:@"%lu. %@\n", (unsigned long)(i + 1), array[i]];
        }
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:key
                                                                       message:items.length > 0 ? items : @"(empty)"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:Localized(@"OK") style:UIAlertActionStyleDefault handler:nil]];
        [AppDelegate showAlert:alert];
        return;
    }

    if ([value isKindOfClass:[NSString class]] || ([value isKindOfClass:[NSNumber class]] && strcmp([value objCType], @encode(BOOL)) != 0 && strcmp([value objCType], @encode(char)) != 0)) {
        // Edit string/number value
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:key
                                                                       message:Localized(@"Edit value")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.text = [value isKindOfClass:[NSString class]] ? value : [value stringValue];
            textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Save") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *newValue = alert.textFields.firstObject.text;
            if ([value isKindOfClass:[NSNumber class]]) {
                self.dictionary[key] = @(newValue.doubleValue);
            } else {
                self.dictionary[key] = newValue ?: @"";
            }
            [self persistChanges];
            [self reloadData];
            [self.tableView reloadData];
        }]];
        [AppDelegate showAlert:alert];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    (void)indexPath;
    return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath
{
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    NSString *key = self.sortedKeys[indexPath.row];
    [self.dictionary removeObjectForKey:key];
    [self persistChanges];
    [self reloadData];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

- (void)addEntry
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:Localized(@"Add Entry")
                                                                   message:Localized(@"Enter key and value")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = Localized(@"Key");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = Localized(@"Value (text, number, or true/false)");
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Add") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *key = [alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *valueStr = [alert.textFields[1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (key.length == 0) return;

        id value;
        if ([valueStr caseInsensitiveCompare:@"true"] == NSOrderedSame || [valueStr caseInsensitiveCompare:@"yes"] == NSOrderedSame) {
            value = @YES;
        } else if ([valueStr caseInsensitiveCompare:@"false"] == NSOrderedSame || [valueStr caseInsensitiveCompare:@"no"] == NSOrderedSame) {
            value = @NO;
        } else {
            NSScanner *scanner = [NSScanner scannerWithString:valueStr];
            double numValue = 0;
            if ([scanner scanDouble:&numValue] && scanner.isAtEnd) {
                value = @(numValue);
            } else {
                value = valueStr;
            }
        }
        self.dictionary[key] = value;
        [self persistChanges];
        [self reloadData];
        [self.tableView reloadData];
    }]];
    [AppDelegate showAlert:alert];
}

@end

//------------------------------------------------------------------------------
#pragma mark - RootHide Blacklist Plist Viewer (RootHideConfig.plist appconfig)

@interface RHBlacklistPlistViewController : UITableViewController
@property (nonatomic, retain) NSMutableDictionary *appconfig;
@property (nonatomic, copy) NSArray<NSString *> *sortedKeys;
@end

@implementation RHBlacklistPlistViewController

- (instancetype)init
{
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)reloadData
{
    NSMutableDictionary *config = [AppDelegate getDefaultsForKey:@"appconfig"];
    self.appconfig = [config isKindOfClass:[NSMutableDictionary class]] ? config : [config mutableCopy] ?: [NSMutableDictionary dictionary];
    self.sortedKeys = [[self.appconfig allKeys] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = Localized(@"Blacklist (RootHideConfig)");
    [self reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    return self.sortedKeys.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    (void)tableView; (void)section;
    NSString *resolvedPath = jbroot(@"/var/mobile/Library/RootHide/RootHideConfig.plist");
    return [NSString stringWithFormat:@"The \"appconfig\" dictionary from RootHideConfig.plist.\nApps marked YES are hidden (blacklisted) from tweak injection.\n\n%@", resolvedPath ?: @""];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"BlacklistPlistCell"];
    NSString *key = self.sortedKeys[indexPath.row];
    BOOL enabled = RHDictionaryBoolValue(self.appconfig[key]);

    cell.textLabel.text = key;
    cell.textLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    cell.detailTextLabel.text = enabled ? @"Hidden (blacklisted)" : @"Not hidden";

    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.on = enabled;
    toggle.tag = indexPath.row;
    [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    return cell;
}

- (void)switchChanged:(UISwitch *)toggle
{
    if (toggle.tag >= (NSInteger)self.sortedKeys.count) return;
    NSString *key = self.sortedKeys[toggle.tag];
    self.appconfig[key] = @(toggle.on);
    [AppDelegate setDefaults:self.appconfig forKey:@"appconfig"];
    [[NSNotificationCenter defaultCenter] postNotificationName:RHInjectSettingsChangedNotification object:nil];
}

@end

@implementation SettingViewController

+ (instancetype)sharedInstance
{
    static SettingViewController *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

+ (UIViewController *)whitelistController
{
    static RHAppRulesViewController *whitelistController = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        whitelistController = [[RHAppRulesViewController alloc] initWithTitle:Localized(@"Whitelist")
                                                            rulesRelativePath:RHRootHideInjectRelativePath
                                                                preferredMode:@"whitelist"
                                                                   footerText:Localized(@"These executable names are allowed to inject when whitelist mode is active. Locked entries are forced by whitelist helpers and can be reviewed in Settings.")
                                                              showsTipsButton:YES];
    });
    return whitelistController;
}

+ (UIViewController *)blacklistController
{
    static RHAppRulesViewController *blacklistController = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        blacklistController = [[RHAppRulesViewController alloc] initWithTitle:Localized(@"Blacklist")
                                                            rulesRelativePath:RHRootHideUninjectRelativePath
                                                                preferredMode:@"blacklist"
                                                                   footerText:Localized(@"These executable names are skipped when blacklist mode is active.")
                                                              showsTipsButton:NO];
    });
    return blacklistController;
}

+ (UIViewController *)hiddenWhitelistController
{
    static RHHiddenWhitelistViewController *hiddenWhitelistController = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hiddenWhitelistController = [[RHHiddenWhitelistViewController alloc] init];
    });
    return hiddenWhitelistController;
}

- (NSDictionary *)menuItemWithTitle:(NSString *)title detail:(NSString *)detail type:(NSString *)type target:(NSString *)target
{
    return @{
        @"textLabel" : title ?: @"",
        @"detailTextLabel" : detail ?: @"",
        @"type" : type ?: @"",
        @"target" : target ?: @"",
    };
}

- (void)reloadMenu
{
    NSString *mode = [AppDelegate rootHideInjectionMode];
    self.menuData = @[
        @{
            @"groupTitle" : Localized(@"General"),
            @"items" : @[
                [self menuItemWithTitle:Localized(@"Injection Mode")
                                 detail:RHModeDisplayName(mode)
                                   type:@"controller"
                                 target:@"mode"],
                [self menuItemWithTitle:Localized(@"Userspace Reboot")
                                 detail:Localized(@"Apply launchd-managed changes now.")
                                   type:@"action"
                                 target:@"reboot"],
                [self menuItemWithTitle:Localized(@"Standard Respring")
                                 detail:Localized(@"Restart SpringBoard without a userspace reboot.")
                                   type:@"action"
                                 target:@"respring"],
                [self menuItemWithTitle:Localized(@"Reboot Device")
                                 detail:Localized(@"Restart the device completely.")
                                   type:@"action"
                                 target:@"rebootDevice"],
                [self menuItemWithTitle:Localized(@"TrollStore Functions")
                                 detail:Localized(@"Restore app registrations or rebuild icon cache after visibility changes.")
                                   type:@"action"
                                 target:@"trollStoreActions"],
                [self menuItemWithTitle:Localized(@"HideApps Actions")
                                 detail:Localized(@"Hide TrollStore and jailbreak app registrations, optionally followed by a userspace reboot.")
                                   type:@"action"
                                 target:@"hideAppsActions"],
                [self menuItemWithTitle:Localized(@"Reset All RHInject Settings")
                                 detail:Localized(@"Delete all cn.zqbb.* and pro.m1337.* plists for a fresh start.")
                                   type:@"action"
                                 target:@"resetAllSettings"],
            ],
        },
        @{
            @"groupTitle" : Localized(@"Injection Rules & Plist Editors"),
            @"items" : @[
                [self menuItemWithTitle:Localized(@"Whitelist Apps")
                                 detail:Localized(@"Executables explicitly enabled in pro.m1337.inject.plist.")
                                   type:@"controller"
                                 target:@"whitelistApps"],
                [self menuItemWithTitle:Localized(@"Forced Whitelist Entries")
                                 detail:Localized(@"Read-only view of entries forced on by whitelist helpers.")
                                   type:@"controller"
                                 target:@"forcedWhitelistEntries"],
                [self menuItemWithTitle:Localized(@"System Injection Paths")
                                 detail:Localized(@"System executables that may still inject in whitelist mode.")
                                   type:@"controller"
                                 target:@"systemInjection"],
                [self menuItemWithTitle:Localized(@"Wants Blacklist Execs")
                                 detail:Localized(@"Executables that still honor the hide-app blacklist in whitelist mode.")
                                   type:@"controller"
                                 target:@"wantsBlacklist"],
                [self menuItemWithTitle:Localized(@"Jetsam Addend")
                                 detail:Localized(@"Additional executables that should receive the jetsam multiplier.")
                                   type:@"controller"
                                 target:@"jetsamAddend"],
                [self menuItemWithTitle:Localized(@"Blacklist (RootHideConfig)")
                                 detail:Localized(@"View/edit the appconfig dictionary in RootHideConfig.plist.")
                                   type:@"controller"
                                 target:@"plistBlacklist"],
                [self menuItemWithTitle:Localized(@"Whitelist Rules (raw)")
                                 detail:Localized(@"pro.m1337.inject.plist — raw key/value editor.")
                                   type:@"controller"
                                 target:@"plistWhitelist"],
                [self menuItemWithTitle:Localized(@"Blacklist Rules (raw)")
                                 detail:Localized(@"pro.m1337.uninject.plist — raw key/value editor.")
                                   type:@"controller"
                                 target:@"plistUninject"],
                [self menuItemWithTitle:Localized(@"Hidden Whitelist Tweaks")
                                 detail:Localized(@"pro.m1337.hiddenwhitelist.tweaks.plist — per-app tweak selections.")
                                   type:@"controller"
                                 target:@"plistHiddenTweaks"],
            ],
        },
        @{
            @"groupTitle" : Localized(@"Advanced"),
            @"items" : @[
                [self menuItemWithTitle:Localized(@"varClean Rules")
                                 detail:Localized(@"Edit custom keep/remove overrides in-app.")
                                   type:@"controller"
                                 target:@"varCleanRules"],
            ],
        },
    ].mutableCopy;
}

- (void)settingsChanged
{
    [self reloadMenu];
    [self.tableView reloadData];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.navigationController.navigationBar.hidden = NO;
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.tableFooterView = [[UIView alloc] init];
    self.title = Localized(@"Settings");

    [self reloadMenu];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:RHInjectSettingsChangedNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadMenu];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
    (void)tableView;
    return self.menuData.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    NSDictionary *groupData = self.menuData[section];
    return [groupData[@"items"] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    (void)tableView;
    return self.menuData[section][@"groupTitle"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"SettingCell"];
    NSDictionary *groupData = self.menuData[indexPath.section];
    NSDictionary *item = groupData[@"items"][indexPath.row];

    cell.textLabel.text = item[@"textLabel"];
    cell.detailTextLabel.text = item[@"detailTextLabel"];
    cell.detailTextLabel.numberOfLines = 2;

    if ([item[@"type"] isEqualToString:@"controller"] || [item[@"type"] isEqualToString:@"url"]) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    else if ([item[@"type"] isEqualToString:@"action"]) {
        NSString *target = item[@"target"];
        if ([target isEqualToString:@"hideAppsActions"] || [target isEqualToString:@"resetAllSettings"]) {
            cell.textLabel.textColor = UIColor.systemRedColor;
            cell.detailTextLabel.textColor = UIColor.systemRedColor;
        }
        else {
            cell.textLabel.textColor = self.view.tintColor;
        }
    }

    return cell;
}

- (UIViewController *)viewControllerForTarget:(NSString *)target
{
    if ([target isEqualToString:@"mode"]) {
        return [[RHInjectionModeViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    }
    if ([target isEqualToString:@"whitelistApps"]) {
        return [[RHDictionaryToggleViewController alloc] initWithTitle:Localized(@"Whitelist Apps")
                                                          relativePath:RHRootHideInjectRelativePath
                                                              defaults:@{}
                                                            footerText:Localized(@"These executable names are explicitly enabled in whitelist mode.")
                                                         addEntryTitle:Localized(@"Add to Whitelist")
                                                       addEntryMessage:Localized(@"Enter an executable name that should be explicitly enabled in whitelist mode.")
                                                   addEntryPlaceholder:Localized(@"Executable name")];
    }
    if ([target isEqualToString:@"forcedWhitelistEntries"]) {
        RHForcedEntriesViewController *controller = [[RHForcedEntriesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        controller.title = Localized(@"Forced Whitelist Entries");
        controller.footerText = Localized(@"These entries are forced on by whitelist helpers and appear locked in the whitelist app browser.");
        return controller;
    }
    if ([target isEqualToString:@"systemInjection"]) {
        return [[RHDictionaryToggleViewController alloc] initWithTitle:Localized(@"System Injection Paths")
                                                          relativePath:RHRootHideInjectSystemRelativePath
                                                              defaults:[AppDelegate defaultSystemInjection]
                                                            footerText:Localized(@"Path matches that stay injectable even when whitelist mode is active.")
                                                         addEntryTitle:Localized(@"Add System Injection Path")
                                                       addEntryMessage:Localized(@"Enter a path fragment to keep injectable in whitelist mode.")
                                                   addEntryPlaceholder:Localized(@"Executable path fragment")];
    }
    if ([target isEqualToString:@"wantsBlacklist"]) {
        return [[RHDictionaryToggleViewController alloc] initWithTitle:Localized(@"Wants Blacklist Execs")
                                                          relativePath:RHRootHideInjectWantsBlacklistRelativePath
                                                              defaults:[AppDelegate defaultWantsBlacklist]
                                                            footerText:Localized(@"Executables that still consult the hidden-app blacklist while whitelist mode is active.")
                                                         addEntryTitle:Localized(@"Add Wants-Blacklist Executable")
                                                       addEntryMessage:Localized(@"Enter an executable name that should still honor the hidden-app blacklist.")
                                                   addEntryPlaceholder:Localized(@"Executable name")];
    }
    if ([target isEqualToString:@"jetsamAddend"]) {
        return [[RHNumberDictionaryViewController alloc] initWithTitle:Localized(@"Jetsam Addend")
                                                          relativePath:RHRootHideJetsamAddendRelativePath
                                                              defaults:[AppDelegate defaultJetsamAddend]
                                                            footerText:Localized(@"Configure per-executable numeric jetsam addends.")
                                                         addEntryTitle:Localized(@"Add Jetsam Addend Executable")
                                                       addEntryMessage:Localized(@"Enter an executable name and numeric jetsam addend.")
                                                   addEntryPlaceholder:Localized(@"Executable name")
                                                      valuePlaceholder:Localized(@"Jetsam addend value")];
    }
    if ([target isEqualToString:@"varCleanRules"]) {
        return [[RHVarCleanRulesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    }
    // Plist Editors
    if ([target isEqualToString:@"plistBlacklist"]) {
        return [[RHBlacklistPlistViewController alloc] init];
    }
    if ([target isEqualToString:@"plistWhitelist"]) {
        return [[RHGenericPlistViewController alloc] initWithTitle:Localized(@"Whitelist Rules")
                                                      relativePath:RHRootHideInjectRelativePath
                                                        footerText:Localized(@"Per-executable whitelist toggles. Keys are executable names, values are booleans.")];
    }
    if ([target isEqualToString:@"plistUninject"]) {
        return [[RHGenericPlistViewController alloc] initWithTitle:Localized(@"Blacklist Rules")
                                                      relativePath:RHRootHideUninjectRelativePath
                                                        footerText:Localized(@"Per-executable blacklist toggles. Keys are executable names, values are booleans.")];
    }
    if ([target isEqualToString:@"plistHiddenTweaks"]) {
        return [[RHGenericPlistViewController alloc] initWithTitle:Localized(@"Hidden Whitelist Tweaks")
                                                      relativePath:RHRootHideHiddenWhitelistTweaksRelativePath
                                                        footerText:Localized(@"Per-app tweak selections for hidden whitelist mode. Keys are bundle IDs, values are dictionaries with allowDenyMode and tweak lists.")];
    }
    return nil;
}

- (void)runPrivilegedActionWithArguments:(NSArray<NSString *> *)arguments
                                   title:(NSString *)title
                             successText:(NSString *)successText
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *standardOutput = nil;
        NSString *standardError = nil;
        int status = spawnRoot(NSBundle.mainBundle.executablePath, arguments, &standardOutput, &standardError);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status == 0) {
                if (successText.length > 0) {
                    [AppDelegate showMessage:successText title:title];
                }
                return;
            }

            NSString *message = standardError.length > 0 ? standardError : standardOutput;
            if (message.length == 0) {
                message = [NSString stringWithFormat:Localized(@"Command failed with status %d."), status];
            }
            [AppDelegate showMessage:message title:Localized(@"Error")];
        });
    });
}

- (void)presentHideAppsActionSheetFromSourceView:(UIView *)sourceView
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:Localized(@"HideApps Actions")
                                                                   message:Localized(@"HideApps unregisters TrollStore and jailbreak apps. Use TrollStore Functions to restore app registrations or rebuild icon cache afterward.")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"HideApps")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self runPrivilegedActionWithArguments:@[@"hideapps"]
                                         title:Localized(@"HideApps")
                                   successText:Localized(@"HideApps finished. Relaunch any affected apps if needed.")];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"HideApps + Reboot Device")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self runPrivilegedActionWithArguments:@[@"reboot", @"hide"]
                                         title:Localized(@"HideApps + Reboot Device")
                                   successText:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"HideApps + Reboot Userspace")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [self runPrivilegedActionWithArguments:@[@"usreboot", @"hide"]
                                         title:Localized(@"HideApps + Reboot Userspace")
                                   successText:nil];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    alert.popoverPresentationController.sourceView = sourceView ?: self.view;
    alert.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : self.view.bounds;
    [AppDelegate showAlert:alert];
}

- (void)presentTrollStoreActionSheetFromSourceView:(UIView *)sourceView
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:Localized(@"TrollStore Functions")
                                                                   message:Localized(@"Restore app registrations or rebuild icon cache after HideApps or other registration issues.")
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Refresh App Registrations")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self runPrivilegedActionWithArguments:@[@"refreshreg"]
                                         title:Localized(@"Refresh App Registrations")
                                   successText:Localized(@"Application registrations were refreshed.")];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Rebuild Icon Cache")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        [self runPrivilegedActionWithArguments:@[@"rebuildiconcache"]
                                         title:Localized(@"Rebuild Icon Cache")
                                   successText:Localized(@"Icon cache rebuild finished.")];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];

    alert.popoverPresentationController.sourceView = sourceView ?: self.view;
    alert.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : self.view.bounds;
    [AppDelegate showAlert:alert];
}

- (void)presentResetAllSettingsConfirmation
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:Localized(@"Reset All RHInject Settings")
                                                                   message:Localized(@"This will delete all cn.zqbb.* and pro.m1337.* plists from the RootHide directory, giving you a completely fresh start.\n\nThis does NOT touch RootHideConfig.plist (Classic RootHide blacklist).\n\nA userspace reboot is recommended afterward.")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Reset + Reboot Userspace") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self performResetAllSettings];
        [AppDelegate rebootUserspace];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Reset Only") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [self performResetAllSettings];
        [AppDelegate showMessage:Localized(@"All RHInject plists deleted. A userspace reboot is recommended to apply the changes.") title:Localized(@"Reset Complete")];
    }]];
    [AppDelegate showAlert:alert];
}

- (void)performResetAllSettings
{
    NSString *rootHideDir = [AppDelegate rootHidePathForRelativePath:@"/var/mobile/Library/RootHide"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:rootHideDir error:nil];
    NSUInteger deletedCount = 0;
    for (NSString *file in files) {
        if ([file hasPrefix:@"cn.zqbb."] || [file hasPrefix:@"pro.m1337."]) {
            NSString *fullPath = [rootHideDir stringByAppendingPathComponent:file];
            NSError *error = nil;
            if ([fm removeItemAtPath:fullPath error:&error]) {
                deletedCount++;
            }
        }
    }
    NSLog(@"[RHInject] Reset: deleted %lu plist files from %@", (unsigned long)deletedCount, rootHideDir);
    [[NSNotificationCenter defaultCenter] postNotificationName:RHInjectSettingsChangedNotification object:nil];
    [self reloadMenu];
    [self.tableView reloadData];
}

- (void)handleActionTarget:(NSString *)target
{
    if ([target isEqualToString:@"reboot"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:Localized(@"Userspace Reboot")
                                                                       message:Localized(@"Reboot userspace now?")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Reboot Now") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [AppDelegate rebootUserspace];
        }]];
        [AppDelegate showAlert:alert];
        return;
    }

    if ([target isEqualToString:@"rebootDevice"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:Localized(@"Reboot Device")
                                                                       message:Localized(@"Reboot device now?")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Reboot Now") style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [self runPrivilegedActionWithArguments:@[@"reboot"]
                                             title:Localized(@"Reboot Device")
                                       successText:nil];
        }]];
        [AppDelegate showAlert:alert];
        return;
    }

    if ([target isEqualToString:@"respring"]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:Localized(@"Standard Respring")
                                                                       message:Localized(@"Restart SpringBoard now?")
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:Localized(@"Respring Now") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self runPrivilegedActionWithArguments:@[@"respring"]
                                             title:Localized(@"Standard Respring")
                                       successText:nil];
        }]];
        [AppDelegate showAlert:alert];
        return;
    }

    if ([target isEqualToString:@"hideAppsActions"]) {
        [self presentHideAppsActionSheetFromSourceView:nil];
        return;
    }

    if ([target isEqualToString:@"trollStoreActions"]) {
        [self presentTrollStoreActionSheetFromSourceView:nil];
        return;
    }

    if ([target isEqualToString:@"resetAllSettings"]) {
        [self presentResetAllSettingsConfirmation];
        return;
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *groupData = self.menuData[indexPath.section];
    NSDictionary *item = groupData[@"items"][indexPath.row];
    NSString *type = item[@"type"];
    NSString *target = item[@"target"];

    if ([type isEqualToString:@"controller"]) {
        UIViewController *viewController = [self viewControllerForTarget:target];
        if (viewController) {
            [self.navigationController pushViewController:viewController animated:YES];
        }
    }
    else if ([type isEqualToString:@"action"]) {
        [self handleActionTarget:target];
    }
}

@end
