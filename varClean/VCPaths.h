#import <Foundation/Foundation.h>

// Keep the TrollStore-specific delta centralized here so future upstream ports
// mostly stay in the controller files and rules data.
NS_INLINE NSString *VCConfigDirectory(void) {
    return @"/var/mobile/Library/varClean";
}

NS_INLINE NSString *VCConfigPath(NSString *fileName) {
    return [VCConfigDirectory() stringByAppendingPathComponent:fileName];
}

NS_INLINE NSArray<NSURL *> *VCViewerURLsForPath(NSString *path) {
    if (path.length == 0) {
        return @[];
    }

    NSString *encodedPath = [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    if (encodedPath.length == 0) {
        return @[];
    }

    NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:2];
    for (NSString *prefix in @[@"filzer://view", @"filza://view"]) {
        NSURL *url = [NSURL URLWithString:[prefix stringByAppendingString:encodedPath]];
        if (url) {
            [urls addObject:url];
        }
    }
    return urls.copy;
}
