/*
 * W7RescoreBridge.h — Swift ↔ C++ rescore 挂点桥（W7 macos 集成）
 *
 * 纯 ObjC 头（经 Squirrel-Bridging-Header.h 暴露给 Swift）；实现见
 * W7RescoreBridge.mm（ObjC++，包 macos/w7/W7RescoreHook.h）。
 *
 * 语义与 ai/spi/timeout_assist.h 一致：调用立即返回，callback 恰好一次
 * （含 800ms 超时轮）；callback 在后台线程触发，Swift 侧自行切主线程。
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, W7RescoreStatus) {
  W7RescoreStatusOk = 0,       // 重排完成（智能组有效）
  W7RescoreStatusTimeout = 1,  // 800ms 超时弃本轮（NFR3）
  W7RescoreStatusDisabled = 2, // 开关关闭 / 安全输入暂停（FR6）
  W7RescoreStatusError = 3,    // 后端错误
};

@interface W7RescoreBridge : NSObject

+ (instancetype)shared;

/// 已记审计条数（每轮恰一条，含超时轮）——挂点自检用。
@property (nonatomic, readonly) NSInteger auditCount;

/// 异步重排一轮候选：立即返回；callback 恰好一次。
/// smartOrder 为智能组候选文本（保持后端重排序；弃本轮时为空数组）。
- (void)rescoreWithPreedit:(NSString *)preedit
                textBefore:(NSString *)textBefore
                candidates:(NSArray<NSString *> *)texts
                  callback:(void (^)(W7RescoreStatus status, NSArray<NSString *> *smartOrder))callback;

@end

NS_ASSUME_NONNULL_END
