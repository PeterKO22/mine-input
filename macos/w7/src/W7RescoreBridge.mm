/*
 * W7RescoreBridge.m — ObjC++ 桥实现（见 W7RescoreBridge.h）
 *
 * 包装 mine::w7::RescoreHook（macos/w7/W7RescoreHook.{h,cc}）；
 * 后端 = W3 NullAiAssist（本阶段验证挂接），审计 = 内存桩（每轮恰一条）。
 * include 路径依赖构建的 HEADER_SEARCH_PATHS（仓库根，$(SRCROOT)/../..）。
 */
#import "W7RescoreBridge.h"

#include <memory>
#include <string>
#include <vector>

#include "ai/spi/ai_assist.h"
#include "macos/w7/W7RescoreHook.h"

static W7RescoreStatus FromStatus(mine::ai::Status st) {
  switch (st) {
    case mine::ai::Status::kOk:
      return W7RescoreStatusOk;
    case mine::ai::Status::kTimeout:
      return W7RescoreStatusTimeout;
    case mine::ai::Status::kDisabled:
      return W7RescoreStatusDisabled;
    default:
      return W7RescoreStatusError;
  }
}

@implementation W7RescoreBridge {
  std::unique_ptr<mine::w7::RescoreHook> _hook;
}

+ (instancetype)shared {
  static W7RescoreBridge *bridge;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    bridge = [[W7RescoreBridge alloc] init];
  });
  return bridge;
}

- (instancetype)init {
  if ((self = [super init])) {
    _hook = std::make_unique<mine::w7::RescoreHook>();  // Null 后端 + 内存审计桩 + 800ms
  }
  return self;
}

- (NSInteger)auditCount {
  return static_cast<NSInteger>(_hook->auditCount());
}

- (void)rescoreWithPreedit:(NSString *)preedit
                textBefore:(NSString *)textBefore
                candidates:(NSArray<NSString *> *)texts
                  callback:(void (^)(W7RescoreStatus, NSArray<NSString *> *))callback {
  std::vector<mine::ai::Candidate> cands;
  cands.reserve(texts.count);
  for (NSString *t in texts) {
    mine::ai::Candidate c;
    c.text = t.UTF8String;
    c.source = "rime";
    cands.push_back(std::move(c));
  }
  const std::string preeditCpp = preedit.UTF8String ?: "";
  const std::string beforeCpp = textBefore.UTF8String ?: "";
  // 立即返回（TimeoutAssist 只做线程派发）；回调在后台线程，恰好一次。
  _hook->request(preeditCpp, beforeCpp, cands,
                 [callback](const mine::w7::RescoreRound &round) {
                   NSMutableArray<NSString *> *smart = [NSMutableArray array];
                   for (const auto &c : round.smart) {
                     [smart addObject:[NSString stringWithUTF8String:c.text.c_str()]];
                   }
                   if (callback) {
                     callback(FromStatus(round.status), [smart copy]);
                   }
                 });
}

@end
