// Tweak.xm v0.1.5 —— 核心修复：让客户端身份与 OTP 的来源一致
//
// 病因链（已用日志证实）：
//   X-Apple-I-MD（一次性口令）来自本机 akd → 退出登录后重新配对，口令是"本机"的；
//   而 X-MMe-Client-Info 被写死成 2019 年的 MacBookPro11,5 / Mac OS X 10.14.6。
//   苹果校验"口令与身份声明必须同源" → 不一致 → ec = -22410。
//
// 修法：把 X-MMe-Client-Info 统一替换为 <真实机型> <iPhone OS;版本;build>，
//   同时保留 OTP 不动。并在每个出站口都记录完整报文用于验证。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <unistd.h>
#include <sys/sysctl.h>

static NSString *const kLogPath = @"/var/mobile/Documents/ReSignPatch.log";

static IMP g_origLogin = NULL;
static IMP g_origLookup = NULL;
static IMP g_origMake = NULL;
static IMP g_origAnisette = NULL;
static IMP g_origAppleHeaders = NULL;
static IMP g_origDefaultHeaders = NULL;



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

// ---- 设备真实身份 ----
static NSString *RPDeviceModel(void) {
    size_t sz = 0;
    if (sysctlbyname("hw.machine", NULL, &sz, NULL, 0) != 0) return @"unknown";
    char *buf = (char *)malloc(sz);
    sysctlbyname("hw.machine", buf, &sz, NULL, 0);
    NSString *s = [NSString stringWithUTF8String:buf];
    free(buf);
    return s;
}

static NSString *RPOSBuild(void) {
    size_t sz = 0;
    if (sysctlbyname("kern.osversion", NULL, &sz, NULL, 0) != 0) return @"?";
    char *buf = (char *)malloc(sz);
    sysctlbyname("kern.osversion", buf, &sz, NULL, 0);
    NSString *s = [NSString stringWithUTF8String:buf];
    free(buf);
    return s;
}

// <iPhone15,2> <iPhone OS;17.2;21C66> <com.apple.AuthKit/1 (com.apple.akd/1.0)>
static NSString *RPDeviceClientInfo(void) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    return [NSString stringWithFormat:
            @"<%@> <iPhone OS;%ld.%ld;%@> <com.apple.AuthKit/1 (com.apple.akd/1.0)>",
            RPDeviceModel(), (long)v.majorVersion, (long)v.minorVersion, RPOSBuild()];
}



// 借本机 AuthKit 的头（用于对比诊断）

static void RPLogDict(NSString *tag, NSDictionary *d) {
    if (!d) { RPLog(@"%@: (nil)", tag); return; }
    NSMutableString *s = [NSMutableString string];
    for (NSString *k in d) [s appendFormat:@"%@ = %@;  ", k, d[k]];
    RPLog(@"%@: %@", tag, s);
}

// 1) -[RPVLoginImpl loginWithUsername:password:completion:]
static id my_login(id self, SEL _cmd, id user, id pass, id completion) {
    RPLog(@"════ loginWithUsername 开始：账号=%@ 密码长度=%lu ════",
          user, (unsigned long)[pass length]);
    return ((id(*)(id, SEL, id, id, id))g_origLogin)(self, _cmd, user, pass, completion);
}

// 2) -[RPVLoginImpl initialiseLookup:]
static id my_lookup(id self, SEL _cmd, id arg) {
    RPLog(@"── initialiseLookup 被调用");
    return ((id(*)(id, SEL, id))g_origLookup)(self, _cmd, arg);
}

// 3) -[RPVLoginImpl _anisetteData] —— 身份修正主战场
static id my_anisette(id self, SEL _cmd) {
    id ret = ((id(*)(id, SEL))g_origAnisette)(self, _cmd);
    @try {
        if (![ret isKindOfClass:[NSMutableDictionary class]]) {
            RPLog(@"_anisetteData 返回非字典: %@", ret);
            return ret;
        }
        NSMutableDictionary *d = (NSMutableDictionary *)ret;
        RPLog(@"---- _anisetteData（修正前）----");
        RPLogDict(@"  ", d);
        NSString *device = RPDeviceClientInfo();
        NSString *old = d[@"X-MMe-Client-Info"];
        if (![device isEqualToString:old]) {
            d[@"X-MMe-Client-Info"] = device;
            RPLog(@"✅ client-info: %@ → %@", old ?: @"(无)", device);
        }
        RPLog(@"---- _anisetteData（修正后）----");
        RPLogDict(@"  ", d);
    } @catch (NSException *e) {
        RPLog(@"_anisetteData 异常: %@", e);
    }
    return ret;
}

// 4) -[RPVLoginImpl makeRequestWithParameters:completion:]
static id my_make(id self, SEL _cmd, id params, id completion) {
    @try {
        NSString *desc = [params description];
        RPLog(@"── makeRequest 出站参数:");
        RPLog(@"%@", [desc length] > 2400 ? [desc substringToIndex:2400] : desc);
    } @catch (__unused NSException *e) {
    }
    return ((id(*)(id, SEL, id, id))g_origMake)(self, _cmd, params, completion);
}

// 5) -[RPVAuthentication appleIDHeadersForRequest:]
static id my_appleHeaders(id self, SEL _cmd, id request) {
    id ret = ((id(*)(id, SEL, id))g_origAppleHeaders)(self, _cmd, request);
    @try {
        RPLog(@"---- appleIDHeadersForRequest（登录用到了它）----");
        RPLogDict(@"  原始", ret);

        if ([ret isKindOfClass:[NSMutableDictionary class]]) {
            NSMutableDictionary *h = (NSMutableDictionary *)ret;
            NSString *device = RPDeviceClientInfo();
            NSString *old = h[@"X-MMe-Client-Info"];
            if (![device isEqualToString:old]) {
                h[@"X-MMe-Client-Info"] = device;
                RPLog(@"✅ 头部 client-info: %@ → %@", old ?: @"(无)", device);
            }
        }
    } @catch (NSException *e) {
        RPLog(@"appleIDHeaders 异常: %@", e);
    }
    return ret;
}

// 6) -[RPVLoginImpl defaultRequestHeaders]
static id my_defaultHeaders(id self, SEL _cmd) {
    id ret = ((id(*)(id, SEL))g_origDefaultHeaders)(self, _cmd);
    @try {
        if ([ret isKindOfClass:[NSMutableDictionary class]]) {
            NSMutableDictionary *h = (NSMutableDictionary *)ret;
            NSString *device = RPDeviceClientInfo();
            RPLog(@"---- defaultRequestHeaders ----");
            RPLogDict(@"  修正前", h);
            h[@"X-MMe-Client-Info"] = device;
            h[@"User-Agent"] = [NSString stringWithFormat:
                @"akd/1.0 CFNetwork/1496.0.7 Darwin/23.2.0 (%@; iPhone OS %ld.%ld)",
                RPDeviceModel(), (long)[[NSProcessInfo processInfo] operatingSystemVersion].majorVersion,
                (long)[[NSProcessInfo processInfo] operatingSystemVersion].minorVersion];
        }
    } @catch (__unused NSException *e) {
    }
    return ret;
}

static void hookMethod(Class c, const char *selName, IMP *origOut, IMP newImp, const char *label) {
    if (!c) { RPLog(@"⚠️ 类不存在: %s", label); return; }
    Method m = class_getInstanceMethod(c, sel_registerName(selName));
    if (!m) { RPLog(@"⚠️ 方法不存在: %s", label); return; }
    *origOut = method_getImplementation(m);
    method_setImplementation(m, newImp);
    RPLog(@"hook 成功: %s", label);
}

__attribute__((constructor)) static void ReSignPatchInit(void) {
    @autoreleasepool {
        RPLog(@"════ ReSignPatch v0.1.5 已载入 (pid=%d) ════", getpid());
        NSOperatingSystemVersion vNow = [[NSProcessInfo processInfo] operatingSystemVersion];
        RPLog(@"本机机型 = %@, 系统版本 = %ld.%ld",
              RPDeviceModel(), (long)vNow.majorVersion, (long)vNow.minorVersion);
        RPLog(@"将使用的 client-info = %@", RPDeviceClientInfo());

        Class login = objc_getClass("RPVLoginImpl");
        Class auth  = objc_getClass("RPVAuthentication");

        hookMethod(login, "loginWithUsername:password:completion:", &g_origLogin,          (IMP)my_login,         "RPVLoginImpl loginWithUsername:...");
        hookMethod(login, "initialiseLookup:",                     &g_origLookup,         (IMP)my_lookup,        "RPVLoginImpl initialiseLookup:");
        hookMethod(login, "_anisetteData",                         &g_origAnisette,       (IMP)my_anisette,      "RPVLoginImpl _anisetteData");
        hookMethod(login, "makeRequestWithParameters:completion:", &g_origMake,           (IMP)my_make,          "RPVLoginImpl makeRequestWithParameters:...");
        hookMethod(login, "defaultRequestHeaders",                 &g_origDefaultHeaders, (IMP)my_defaultHeaders, "RPVLoginImpl defaultRequestHeaders");
        hookMethod(auth,  "appleIDHeadersForRequest:",             &g_origAppleHeaders,   (IMP)my_appleHeaders,  "RPVAuthentication appleIDHeadersForRequest:");

        RPLog(@"全部挂钩安装完毕，请现在去点「登录」");
    }
}
