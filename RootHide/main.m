#import <dlfcn.h>
#import <spawn.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>
#import <xpc/xpc.h>
#import <sys/mount.h>
#import "AppDelegate.h"
#import "AppInfo.h"

#ifndef DEBUG
#define NSLog(...)
#endif

extern const char** environ;
int reboot(int);
typedef xpc_connection_t (*RHXPCConnectionCreateMachService)(const char *, dispatch_queue_t _Nullable, uint64_t);

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);

@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (void)unregisterApplication:(NSURL *)url;
- (void)_LSPrivateRebuildApplicationDatabasesForSystemApps:(BOOL)system internal:(BOOL)internal user:(BOOL)user;
@end

int spawn(const char* path, const char** argv, const char** envp, void(^std_out)(char*,int), void(^std_err)(char*,int))
{
    NSLog(@"spawn %s", path);
    
    __block pid_t pid=0;
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    posix_spawn_file_actions_t action;
    posix_spawn_file_actions_init(&action);

    int outPipe[2];
    pipe(outPipe);
    posix_spawn_file_actions_addclose(&action, outPipe[0]);
    posix_spawn_file_actions_adddup2(&action, outPipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&action, outPipe[1]);
    
    int errPipe[2];
    pipe(errPipe);
    posix_spawn_file_actions_addclose(&action, errPipe[0]);
    posix_spawn_file_actions_adddup2(&action, errPipe[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&action, errPipe[1]);

    
    dispatch_semaphore_t lock = dispatch_semaphore_create(0);
    
    dispatch_queue_t queue = dispatch_queue_create("spawnPipeQueue", DISPATCH_QUEUE_CONCURRENT);
    
    dispatch_source_t stdOutSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, outPipe[0], 0, queue);
    dispatch_source_t stdErrSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, errPipe[0], 0, queue);
    
    int outFD = outPipe[0];
    int errFD = errPipe[0];
    
    dispatch_source_set_cancel_handler(stdOutSource, ^{
        close(outFD);
        dispatch_semaphore_signal(lock);
        NSLog(@"stdout canceled [%d]", pid);
    });
    dispatch_source_set_cancel_handler(stdErrSource, ^{
        close(errFD);
        dispatch_semaphore_signal(lock);
        NSLog(@"stderr canceled [%d]", pid);
    });
    
    dispatch_source_set_event_handler(stdOutSource, ^{
        char buffer[BUFSIZ]={0};
        ssize_t bytes = read(outFD, buffer, sizeof(buffer)-1);
        if (bytes <= 0) {
            dispatch_source_cancel(stdOutSource);
            return;
        }
        NSLog(@"spawn[%d] stdout: %s", pid, buffer);
        if(std_out) std_out(buffer,bytes);
    });
    dispatch_source_set_event_handler(stdErrSource, ^{
        char buffer[BUFSIZ]={0};
        ssize_t bytes = read(errFD, buffer, sizeof(buffer)-1);
        if (bytes <= 0) {
            dispatch_source_cancel(stdErrSource);
            return;
        }
        NSLog(@"spawn[%d] stderr: %s", pid, buffer);
        if(std_err) std_err(buffer,bytes);
    });
    
    dispatch_resume(stdOutSource);
    dispatch_resume(stdErrSource);
    
    int spawnError = posix_spawn(&pid, path, &action, &attr, argv, envp);
    NSLog(@"spawn ret=%d, pid=%d", spawnError, pid);
    
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&action);
    
    close(outPipe[1]);
    close(errPipe[1]);
    
    if(spawnError != 0)
    {
        NSLog(@"posix_spawn error %d:%s\n", spawnError, strerror(spawnError));
        dispatch_source_cancel(stdOutSource);
        dispatch_source_cancel(stdErrSource);
        return spawnError;
    }
    
    //wait stdout
    dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
    //wait stderr
    dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
    
    int status=0;
    while(waitpid(pid, &status, 0) != -1)
    {
        if (WIFSIGNALED(status)) {
            return 128 + WTERMSIG(status);
        } else if (WIFEXITED(status)) {
            return WEXITSTATUS(status);
        }
        //keep waiting?return status;
    };
    return -1;
}

int spawnRoot(NSString* path, NSArray* args, NSString** stdOut, NSString** stdErr)
{
    NSLog(@"spawnRoot %@ with %@", path, args);
    
    NSMutableArray* argsM = args.mutableCopy ?: [NSMutableArray new];
    [argsM insertObject:path atIndex:0];
    
    NSUInteger argCount = [argsM count];
    char **argsC = (char **)malloc((argCount + 1) * sizeof(char*));

    for (NSUInteger i = 0; i < argCount; i++)
    {
        argsC[i] = strdup([[argsM objectAtIndex:i] UTF8String]);
    }
    argsC[argCount] = NULL;

    
    __block NSMutableString* outString=nil;
    __block NSMutableString* errString=nil;
    
    if(stdOut) outString = [NSMutableString new];
    if(stdErr) errString = [NSMutableString new];
    
    int retval = spawn(path.fileSystemRepresentation, argsC, environ, ^(char* outstr, int length){
        NSString *str = [[NSString alloc] initWithBytes:outstr length:length encoding:NSASCIIStringEncoding];
        if(stdOut) [outString appendString:str];
    }, ^(char* errstr, int length){
        NSString *str = [[NSString alloc] initWithBytes:errstr length:length encoding:NSASCIIStringEncoding];
        if(stdErr) [errString appendString:str];
    });
    
    if(stdOut) *stdOut = outString.copy;
    if(stdErr) *stdErr = errString.copy;
    
    for (NSUInteger i = 0; i < argCount; i++)
    {
        free(argsC[i]);
    }
    free(argsC);
    
    return retval;
}

BOOL isUUIDPathOf(NSString* path, NSString* parent)
{
    if(!path || !parent) return NO;

    const char* _path = path.UTF8String;
    const char* _parent = parent.UTF8String;
    
    char rp[PATH_MAX];
    if(!realpath(_path, rp)) return NO;
    
    char rpp[PATH_MAX+1];
    if(!realpath(_parent, rpp)) return NO;
    
    size_t rpplen = strlen(rpp);
    
    if(rpp[rpplen] != '/') {
        strcat(rpp, "/");
        rpplen++;
    }

    if(strncmp(rp, rpp, rpplen) != 0)
        return NO;

    char* p1 = rp + rpplen;
    char* p2 = strchr(p1, '/');
    if(!p2) p2 = rp + strlen(rp);

    //is normal app or jailbroken app/daemon?
    if((p2 - p1) != (sizeof("xxxxxxxx-xxxx-xxxx-yxxx-xxxxxxxxxxxx")-1))
        return NO;

    return YES;
}

#include <sys/sysctl.h>

int proc_pidpath(int pid, void * buffer, uint32_t  buffersize);

void killAllForBundle(const char* bundlePath)
{
    NSLog(@"killAllForBundle: %s", bundlePath);
    
    char realBundlePath[PATH_MAX+1];
    if(!realpath(bundlePath, realBundlePath))
        return;
    
    size_t realBundlePathLen = strlen(realBundlePath);
    if(realBundlePath[realBundlePathLen] != '/') {
        strcat(realBundlePath, "/");
        realBundlePathLen++;
    }

    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL};
    struct kinfo_proc *info;
    size_t length;
    size_t count;
    
    if (sysctl(mib, 3, NULL, &length, NULL, 0) < 0)
        return;
    if (!(info = malloc(length)))
        return;
    if (sysctl(mib, 3, info, &length, NULL, 0) < 0) {
        free(info);
        return;
    }
    count = length / sizeof(struct kinfo_proc);
    for (int i = 0; i < count; i++) {
        pid_t pid = info[i].kp_proc.p_pid;
        if (pid == 0) {
            continue;
        }
        
        char executablePath[PATH_MAX];
        if(proc_pidpath(pid, executablePath, sizeof(executablePath)) > 0) {
//            NSLog(@"executablePath [%d] %s", pid, executablePath);
            char realExecutablePath[PATH_MAX];
            if (realpath(executablePath, realExecutablePath)
                && strncmp(realExecutablePath, realBundlePath, realBundlePathLen) == 0) {
                int ret = kill(pid, SIGKILL);
                NSLog(@"killAllForBundle %s -> %d", realExecutablePath, ret);
            }
        }
    }
    free(info);
}

NSString* RootUserClearAppData(AppInfo* app) {
    NSString* error=nil;
    NSString* result=nil;
    int ret = spawnRoot(NSBundle.mainBundle.executablePath, @[@"clearAppData", app.bundleIdentifier], &result, &error);
    if(ret != 0) {
        NSLog(@"removeItemAtPath failed: %@", error);
        return error;
    }
    return nil;
}

BOOL RootUserRemoveItemAtPath(NSString* path)
{
    NSString* error=nil;
    NSString* result=nil;
    int ret = spawnRoot(NSBundle.mainBundle.executablePath, @[@"removeItemAtPath", path], &result, &error);
    if(ret != 0) {
        NSLog(@"removeItemAtPath failed: %@", error);
        return NO;
    }
    return YES;
}

BOOL RootUserGetDirectoryContents(NSString* path, NSString* cacheFile)
{
    NSString* error=nil;
    NSString* result=nil;
    int ret = spawnRoot(NSBundle.mainBundle.executablePath, @[@"getDirectoryContents", path, cacheFile], &result, &error);
    if(ret != 0) {
        NSLog(@"getDirectoryContents failed: %@", error);
        return NO;
    }
    return YES;
}

static int RHUserspaceReboot(void)
{
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(request, "cmd", 5);

    int unlinkResult = unlink("/private/var/mobile/Library/MemoryMaintenance/mmaintenanced");
    if (unlinkResult != 0 && errno != ENOENT) {
        NSLog(@"could not delete mmaintenanced last reboot file");
        return -1;
    }

    RHXPCConnectionCreateMachService createMachService = (RHXPCConnectionCreateMachService)dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (!createMachService) {
        NSLog(@"xpc_connection_create_mach_service unavailable");
        return -1;
    }

    xpc_connection_t connection = createMachService("com.apple.mmaintenanced", NULL, 0);
    if (xpc_get_type(connection) == XPC_TYPE_ERROR) {
        char *description = xpc_copy_description(connection);
        NSLog(@"XPC_TYPE_ERROR: %s", description);
        free(description);
        return -1;
    }

    xpc_connection_set_event_handler(connection, ^(__unused xpc_object_t event) {
    });
    xpc_connection_activate(connection);

    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(connection, request);
    int result = 0;
    if (reply != NULL) {
        char *description = xpc_copy_description(reply);
        NSLog(@"reply: %s", description);
        free(description);
    }
    else {
        NSLog(@"no reply received from mmaintenanced");
        result = -1;
    }

    xpc_connection_cancel(connection);
    return result;
}

static int RHRefreshAppRegistrations(void)
{
    LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
    if (workspace && [workspace respondsToSelector:@selector(_LSPrivateRebuildApplicationDatabasesForSystemApps:internal:user:)]) {
        [workspace _LSPrivateRebuildApplicationDatabasesForSystemApps:YES internal:YES user:YES];
        return 0;
    }
    return -1;
}

static int RHRebuildIconCache(void)
{
    [[NSFileManager defaultManager] removeItemAtPath:@"/var/containers/Shared/SystemGroup/systemgroup.com.apple.lsd.iconscache/Library/Caches/com.apple.IconsCache" error:nil];
    int refreshResult = RHRefreshAppRegistrations();
    if (refreshResult != 0) {
        return refreshResult;
    }
    return spawnRoot(jbroot(@"/usr/bin/uicache"), @[@"-a"], nil, nil);
}

static int RHStandardRespring(void)
{
    return spawnRoot(jbroot(@"/usr/bin/killall"), @[@"SpringBoard"], nil, nil);
}

static int RHHideApps(void)
{
    NSLog(@"Listing all installed applications:");

    NSArray *installedApplications = [LSApplicationWorkspace.defaultWorkspace allInstalledApplications];
    NSString *selfBundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSFileManager *fileManager = NSFileManager.defaultManager;

    for (id proxy in installedApplications) {
        AppInfo *app = [AppInfo appWithPrivateProxy:proxy];
        NSString *bundleIdentifier = app.bundleIdentifier;
        NSString *bundlePath = app.bundleURL.path;
        if (bundlePath.length == 0) {
            continue;
        }
        if ([bundleIdentifier isEqualToString:selfBundleIdentifier]) {
            NSLog(@"Skipping self app.");
            continue;
        }

        struct statfs fileSystemInfo = {};
        if (statfs(bundlePath.fileSystemRepresentation, &fileSystemInfo) != 0) {
            continue;
        }
        if (strcmp(fileSystemInfo.f_mntonname, "/") == 0) {
            continue;
        }

        BOOL shouldHide = YES;
        if (isUUIDPathOf(bundlePath, @"/private/var/containers/Bundle/Application/")) {
            BOOL hasTrollStoreMarker = [fileManager fileExistsAtPath:[bundlePath stringByAppendingString:@"/../_TrollStore"]]
                || [fileManager fileExistsAtPath:[bundlePath stringByAppendingString:@"/../_TrollStoreLite"]];
            shouldHide = hasTrollStoreMarker;
            if (!shouldHide) {
                NSLog(@"skipping normal app: %@", bundleIdentifier);
                continue;
            }
        }

        NSLog(@"App: %@ - %@", bundleIdentifier, app.name);
        [LSApplicationWorkspace.defaultWorkspace unregisterApplication:app.bundleURL];
    }

    sleep(1);

    NSURL *selfBundleURL = NSBundle.mainBundle.bundleURL;
    if (selfBundleURL) {
        [LSApplicationWorkspace.defaultWorkspace unregisterApplication:selfBundleURL];
    }

    NSLog(@"Finished hiding apps.");
    return 0;
}

int main(int argc, char * argv[]) {
    
    //Keyboard Preference & Localized won't work
//    assert(setuid(0) == 0);
//    assert(getuid() == 0);
//    assert(setgid(0) == 0);
//    assert(getgid() == 0);
    
    NSLog(@"uid=%d euid=%d gid=%d egid=%d issetugid=%d", getuid(), geteuid(), getgid(), getegid(), issetugid());
    
    if(argc >= 2)
    {
        if(strcmp(argv[1], "hideapps")==0) {
            return RHHideApps();
        }
        if(strcmp(argv[1], "refreshreg")==0) {
            return RHRefreshAppRegistrations();
        }
        if(strcmp(argv[1], "rebuildiconcache")==0) {
            return RHRebuildIconCache();
        }
        if(strcmp(argv[1], "respring")==0) {
            return RHStandardRespring();
        }
        if(strcmp(argv[1], "usreboot")==0) {
            if(argc >= 3 && strcmp(argv[2], "hide")==0) {
                RHHideApps();
                sync();
                sleep(5);
            }
            return RHUserspaceReboot();
        }
        if(strcmp(argv[1], "reboot")==0) {
            if(argc >= 3 && strcmp(argv[2], "hide")==0) {
                RHHideApps();
                sync();
                sleep(5);
            }
            return reboot(0);
        }
        if(argc==3 && strcmp(argv[1], "removeItemAtPath")==0) {
            NSError* err;
            if(![NSFileManager.defaultManager removeItemAtPath:@(argv[2]) error:&err]) {
                fprintf(stderr, "%s", err.description.UTF8String);
                return -1;
            }
            return 0;
        }
        if(argc==4 && strcmp(argv[1], "getDirectoryContents")==0) {
            NSArray* GetDirectoryContents(NSString* path);
            NSArray* contents = GetDirectoryContents(@(argv[2]));
            if(!contents) {
                return -1;
            }
            if(![contents writeToFile:@(argv[3]) atomically:YES]) {
                return -2;
            }
            return 0;
        }
        if(argc==3 && strcmp(argv[1], "clearAppData")==0) {
            AppInfo* app = [AppInfo appWithBundleIdentifier:@(argv[2])];
            NSString* clearAppData(AppInfo* app);
            NSString* error = clearAppData(app);
            if(error) {
                fprintf(stderr, "%s", error.UTF8String);
                return -1;
            }
            return 0;
        }
    }
    
    NSString * appDelegateClassName;
    @autoreleasepool {
        // Setup code that might create autoreleased objects goes here.
        appDelegateClassName = NSStringFromClass([AppDelegate class]);
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
