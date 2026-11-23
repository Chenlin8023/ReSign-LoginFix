// Tweak.xm —— 阶段一补丁（先验证「云端编译 → 装进手机」这条路，同时修两个已知问题）
//
// 做三件事：
//   1. 载入时写一行日志到 /var/mobile/Documents/ReSignPatch.log —— 用来确认补丁真的生效了
//   2. 把 X-MMe-Client-Info 从 2019 年的 Mac 字符串还原成 AuthKit 给的真值
//   3. 把 User-Agent 从 2019 年的版本换成 iOS 17 的
//
// 刻意不引用原 App 的任何头文件：全部用 id + 运行时查找，保证独立编译。

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <unistd.h>

// AuthKit 的私有类：这里只是给编译器一个"形状"，运行时按名字查找，不链接该框架
@interface AKAppleIDSessionProxy : NSObject
- (instancetype)initWithIdentifier:(NSString *)identifier;
- (NSDictionary *)appleIDHeadersForRequest:(id)request;
@end

static NSString *const kLogPath = @"/var/mobile/Documents/ReSignPatch.log";

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

// 借本机 AuthKit 重新算一份「真实的」请求头
static NSDictionary *RPRealAuthHeaders(id request) {
    Class cls = objc_getClass("AKAppleIDSession");
    if (!cls) return nil;
    id session = [(AKAppleIDSessionProxy *)[cls alloc] initWithIdentifier:@"com.apple.gs.xcode.auth"];
    if (![session respondsToSelector:@selector(appleIDHeadersForRequest:)]) return nil;
    return [session appleIDHeadersForRequest:request];
}

%hook RPVAuthentication

- (id)appleIDHeadersForRequest:(id)request {
    id ret = %orig;
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
        RPLog(@"appleIDHeadersForRequest 异常");
    }
    return ret;
}

- (id)defaultRequestHeaders {
    id ret = %orig;
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

%end

%ctor {
    RPLog(@"==== ReSignPatch 已载入 (pid=%d) ====", getpid());
    RPLog(@"如果能看到这一行，说明云端编译 + 注入都成功了");
}
