// Tweak.xm v0.1.3 —— 挂在真正的登录路径上，全面取证
//
// v0.1.2 的教训：appleIDHeadersForRequest: / defaultRequestHeaders 在登录时不会被调用
// （登录的 anisette 是走 _anisetteData 塞进请求体的）。本版挂到登录实际经过的每一步：
//   loginWithUsername → initialiseLookup → makeRequestWithParameters (+_anisetteData)
// 并把客户端身份修正放到 _anisetteData 上（那里才是 X-MMe-Client-Info 的真正来源）。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <unistd.h>

static NSString *const kLogPath = @"/var/mobile/Documents/ReSignPatch.log";

static IMP g_origLogin = NULL;
static IMP g_origLookup = NULL;
static IMP g_origMake = NULL;
static IMP g_origAnisette = NULL;
static IMP g_origAppleHeaders = NULL;
static IMP g_origDefaultHeaders = NULL;

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

// 用一个真实请求向本机 AuthKit 借"正确身份"的头
static NSDictionary *RPRealAuthHeaders(void) {
    Class cls = objc_getClass("AKAppleIDSession");
    if (!cls) return nil;
    @try {
        id url = [objc_getClass("NSURL") URLWithString:@"https://gsa.apple.com/grandslam/GsService2"];
        id req = [objc_getClass("NSMutableURLRequest") requestWithURL:url];
        [(NSMutableURLRequest *)req setHTTPMethod:@"POST"];
        id session = [(AKAppleIDSessionProxy *)[cls alloc] initWithIdentifier:@"com.apple.gs.xcode.auth"];
        if (![session respondsToSelector:@selector(appleIDHeadersForRequest:)]) return nil;
        return [session appleIDHeadersForRequest:req];
    } @catch (NSException *e) {
        RPLog(@"AuthKit 借头失败: %@", e);
        return nil;
    }
}

// 1) -[RPVLoginImpl loginWithUsername:password:completion:]
static id my_login(id self, SEL _cmd, id user, id pass, id completion) {
    RPLog(@"════ loginWithUsername 开始 ════");
    RPLog(@"  账号 = %@", user);
    RPLog(@"  密码长度 = %lu", (unsigned long)[pass length]);
    return ((id(*)(id, SEL, id, id, id))g_origLogin)(self, _cmd, user, pass, completion);
}

// 2) -[RPVLoginImpl initialiseLookup:]
static id my_lookup(id self, SEL _cmd, id arg) {
    RPLog(@"── initialiseLookup 被调用");
    return ((id(*)(id, SEL, id))g_origLookup)(self, _cmd, arg);
}

// 3) -[RPVLoginImpl _anisetteData] —— 真正修正身份的地方
static id my_anisette(id self, SEL _cmd) {
    id ret = ((id(*)(id, SEL))g_origAnisette)(self, _cmd);
    @try {
        if (![ret isKindOfClass:[NSMutableDictionary class]]) {
            RPLog(@"_anisetteData 返回: %@", ret);
            return ret;
        }
        NSMutableDictionary *d = (NSMutableDictionary *)ret;
        NSString *cur = d[@"X-MMe-Client-Info"];
        NSDictionary *real = RPRealAuthHeaders();
        NSString *realInfo = real[@"X-MMe-Client-Info"];
        RPLog(@"_anisetteData: 代码写死 = %@", cur ?: @"(无)");
        RPLog(@"_anisetteData: AuthKit  = %@", realInfo ?: @"(AuthKit 没给)");
        if (realInfo.length && ![realInfo isEqualToString:cur]) {
            d[@"X-MMe-Client-Info"] = realInfo;
            RPLog(@"✅ 已把 X-MMe-Client-Info 改为 AuthKit 真值");
        }
        RPLog(@"  OTP(X-Apple-I-MD) 前 24 字符 = %@",
              [([d[@"X-Apple-I-MD"] description] ?: @"") substringToIndex:MIN(24, [(d[@"X-Apple-I-MD"] description) length])]);
    } @catch (NSException *e) {
        RPLog(@"_anisetteData 处理异常: %@", e);
    }
    return ret;
}

// 4) -[RPVLoginImpl makeRequestWithParameters:completion:] —— 出站报文
static id my_make(id self, SEL _cmd, id params, id completion) {
    @try {
        NSString *desc = [params description];
        RPLog(@"── makeRequest 出站参数:");
        RPLog(@"%@", [desc length] > 1600 ? [desc substringToIndex:1600] : desc);
    } @catch (__unused NSException *e) {
    }
    return ((id(*)(id, SEL, id, id))g_origMake)(self, _cmd, params, completion);
}

// 5) -[RPVAuthentication appleIDHeadersForRequest:]（保留，开发者服务那步会用）
static id my_appleHeaders(id self, SEL _cmd, id request) {
    id ret = ((id(*)(id, SEL, id))g_origAppleHeaders)(self, _cmd, request);
    @try {
        RPLog(@"appleIDHeadersForRequest 被调用（开发者服务路径）");
        if ([ret isKindOfClass:[NSMutableDictionary class]]) {
            NSMutableDictionary *h = (NSMutableDictionary *)ret;
            NSDictionary *real = RPRealAuthHeaders();
            NSString *realInfo = real[@"X-MMe-Client-Info"];
            if (realInfo.length) h[@"X-MMe-Client-Info"] = realInfo;
        }
    } @catch (__unused NSException *e) {
    }
    return ret;
}

// 6) -[RPVLoginImpl defaultRequestHeaders]（保留）
static id my_defaultHeaders(id self, SEL _cmd) {
    id ret = ((id(*)(id, SEL))g_origDefaultHeaders)(self, _cmd);
    @try {
        if ([ret isKindOfClass:[NSMutableDictionary class]]) {
            [(NSMutableDictionary *)ret setObject:@"akd/1.0 CFNetwork/1496.0.5 Darwin/23.2.0"
                                           forKey:@"User-Agent"];
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
        RPLog(@"════ ReSignPatch v0.1.3 已载入 (pid=%d) ════", getpid());

        Class login = objc_getClass("RPVLoginImpl");
        Class auth  = objc_getClass("RPVAuthentication");

        hookMethod(login, "loginWithUsername:password:completion:", &g_origLogin, (IMP)my_login,  "RPVLoginImpl loginWithUsername:...");
        hookMethod(login, "initialiseLookup:",                     &g_origLookup, (IMP)my_lookup,  "RPVLoginImpl initialiseLookup:");
        hookMethod(login, "_anisetteData",                         &g_origAnisette,(IMP)my_anisette,"RPVLoginImpl _anisetteData");
        hookMethod(login, "makeRequestWithParameters:completion:", &g_origMake,    (IMP)my_make,    "RPVLoginImpl makeRequestWithParameters:...");
        hookMethod(login, "defaultRequestHeaders",                 &g_origDefaultHeaders, (IMP)my_defaultHeaders, "RPVLoginImpl defaultRequestHeaders");
        hookMethod(auth,  "appleIDHeadersForRequest:",             &g_origAppleHeaders,   (IMP)my_appleHeaders,  "RPVAuthentication appleIDHeadersForRequest:");

        RPLog(@"全部挂钩安装完毕，请现在去点「登录」");
    }
}
