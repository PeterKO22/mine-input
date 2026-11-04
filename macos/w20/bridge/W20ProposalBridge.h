/*
 * W20ProposalBridge.h — ObjC++ 桥（仅编进 Squirrel.app 目标）：提案契约 v2
 *
 * 包装 **C++ Null 提案桩** mine::ai::NullProposalAgent
 * （ai/backends/null/null_proposal_agent.cc；契约 = ai/spi/ai_assist_v2.h）：
 * 提案卡 UI（W20ProposalCard）经 W20CppProposalEngine 走本桥，与 ai/ 单测断言的
 * 是同一个桩。include 依赖构建的 HEADER_SEARCH_PATHS（仓库根 $(SRCROOT)/../..）。
 *
 * 类名带 B 前缀（B=bridge），避免与 W20ProposalModel.swift 的 Swift 同名类型冲突。
 *
 * 红线（§15.2）：confirm 只允许提案卡「确认执行」按钮触发；本桥不做任何自动 confirm。
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface W20BProposalAction : NSObject
@property(nonatomic, copy) NSString *actionId;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@end

@interface W20BProposalItem : NSObject
@property(nonatomic, copy) NSString *proposalId;
@property(nonatomic, copy) NSString *kind;  // "reply" | "task" | "plan"
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *detail;
@property(nonatomic, copy) NSArray<W20BProposalAction *> *actions;
@end

@interface W20BExecHandle : NSObject
@property(nonatomic, copy) NSString *execId;
@property(nonatomic, copy) NSString *proposalId;
@property(nonatomic, copy) NSString *state;  // "queued"|"running"|"done"|"failed"
@property(nonatomic) double progress;        // 0..1
@property(nonatomic, copy) NSString *result;
@end

@interface W20ProposalBridge : NSObject

+ (instancetype)shared;

/// 流式提案（同步展平为数组）：secure=YES 未受理（空数组，同 v1 kDisabled）。
/// 红线：只提案，绝不执行。
- (NSArray<W20BProposalItem *> *)proposeSecure:(BOOL)secure;

/// 显式确认 → 开任务执行（**只允许「确认执行」按钮调用**）。
/// 未知 id → state="failed"（不执行）；重复 confirm 幂等（同一执行，不二次执行）。
- (W20BExecHandle *)confirm:(NSString *)proposalId;

/// 进度/结果回填：state queued→running→done（快照逐次回调）。
/// handle 未经 confirm（未知执行 id）→ NO，不回调、不执行。
- (BOOL)observe:(W20BExecHandle *)handle
       onUpdate:(void (^)(W20BExecHandle *_Nullable snap))onUpdate;

@end

NS_ASSUME_NONNULL_END
