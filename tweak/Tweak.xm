// Tweak.xm —— 不使用 Logos / 不依赖 CydiaSubstrate 的版本
//
// 之前失败的原因：编译出的 dylib 带 /Library/Frameworks/CydiaSubstrate.framework
// 的加载命令，在 RootHide（jbroot 命名空间）里该路径不存在 → dyld 加载失败 →
// 补丁被静默跳过。本版本改用 ObjC runtime 手动 swizzle，只依赖系统框架，
// 在 rootful / rootless / roothide 上都能加载。
//
// 行为与上一版一致：
//   1. 载入即写 /var/mobile/Documents/ReSignPatch.log（证明注入成功）
//   2. 把 X-MMe-Client-Info 还原成 AuthKit 真值
//   3. 把 User-Agent 换成 iOS 17 的

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <unistd.h>

static NSString *const kLogPath = @"/var/mobile/Documents/ReSignPatch.log";
static IMP g_origAppleHeaders = NULL;
static IMP g_origDefaultHeaders = NULL;

// 私有类只给编译器一个"形状"，运行时按名字查找，不链接 AuthKit
@interface AKAppleIDSessionProxy : NSObject
- (instancetype)initWithIdentifier:(NSString *)identifier;
- (NSDictionary *)appleIDHeadersForRequest:(id)request;
@end

static void RPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kLogPath]) {
        [line writeToFile:kLogPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (__unused NSException *e) {
    } @finally {
        [fh closeFile];
    }
}

static NSDictionary *RPRealAuthHeaders(id request) {
    Class cls = objc_getClass("AKAppleIDSession");
    if (!cls) return nil;
    id session = [(AKAppleIDSessionProxy *)[cls alloc] initWithIdentifier:@"com.apple.gs.xcode.auth"];
    if (![session respondsToSelector:@selector(appleIDHeadersForRequest:)]) return nil;
    return [session appleIDHeadersForRequest:request];
}

// 替换 -[RPVAuthentication appleIDHeadersForRequest:]
static id my_appleIDHeaders(id self, SEL _cmd, id request) {
    id ret = ((id(*)(id, SEL, id))g_origAppleHeaders)(self, _cmd, request);
    @try {
        if (![ret isKindOfClass:[NSMutableDictionary class]]) return ret;
        NSMutableDictionary *headers = (NSMutableDictionary *)ret;
        NSString *cur = headers[@"X-MMe-Client-Info"];

        NSDictionary *real = RPRealAuthHeaders(request);
        NSString *realInfo = real[@"X-MMe-Client-Info"];

        RPLog(@"---- 登录请求头 ----");
        RPLog(@"X-MMe-Client-Info(代码写死) = %@", cur ?: @"(无)");
        RPLog(@"X-MMe-Client-Info(AuthKit)  = %@", realInfo ?: @"(AuthKit 没给)");

        if (realInfo.length && ![realInfo isEqualToString:cur]) {
            headers[@"X-MMe-Client-Info"] = realInfo;
            RPLog(@"已改写为 AuthKit 真值");
        }
        for (NSString *k in @[@"X-Apple-I-MD", @"X-Apple-I-MD-M", @"X-Apple-I-MD-RINFO",
                              @"X-Mme-Device-Id", @"X-Apple-I-Client-Time"]) {
            id v = headers[k];
            RPLog(@"%@ = %@", k, v ?: @"(缺失)");
        }
    } @catch (__unused NSException *e) {
        RPLog(@"appleIDHeaders 处理异常");
    }
    return ret;
}

// 替换 -[RPVLoginImpl defaultRequestHeaders]
static id my_defaultHeaders(id self, SEL _cmd) {
    id ret = ((id(*)(id, SEL))g_origDefaultHeaders)(self, _cmd);
    @try {
        if (![ret isKindOfClass:[NSMutableDictionary class]]) return ret;
        NSMutableDictionary *h = (NSMutableDictionary *)ret;
        NSString *old = h[@"User-Agent"];
        NSString *newUA = @"akd/1.0 CFNetwork/1496.0.5 Darwin/23.2.0";
        if (old.length && ![old isEqualToString:newUA]) {
            h[@"User-Agent"] = newUA;
            RPLog(@"User-Agent: %@ → %@", old, newUA);
        }
    } @catch (__unused NSException *e) {
    }
    return ret;
}

__attribute__((constructor)) static void ReSignPatchInit(void) {
    @autoreleasepool {
        RPLog(@"==== ReSignPatch 已载入 (pid=%d) ====", getpid());

        Class c1 = objc_getClass("RPVAuthentication");
        Class c2 = objc_getClass("RPVLoginImpl");

        if (c1) {
            Method m = class_getInstanceMethod(c1, sel_registerName("appleIDHeadersForRequest:"));
            if (m) {
                g_origAppleHeaders = method_getImplementation(m);
                method_setImplementation(m, (IMP)my_appleIDHeaders);
                RPLog(@"hook RPVAuthentication appleIDHeadersForRequest: 成功");
            } else {
                RPLog(@"⚠️ RPVAuthentication 里找不到 appleIDHeadersForRequest:");
            }
        } else {
            RPLog(@"⚠️ 找不到类 RPVAuthentication（注入进了错误的进程？）");
        }

        if (c2) {
            Method m2 = class_getInstanceMethod(c2, sel_registerName("defaultRequestHeaders"));
            if (m2) {
                g_origDefaultHeaders = method_getImplementation(m2);
                method_setImplementation(m2, (IMP)my_defaultHeaders);
                RPLog(@"hook RPVLoginImpl defaultRequestHeaders 成功");
            }
        }
    }
}
