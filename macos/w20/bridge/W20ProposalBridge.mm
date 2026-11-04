/*
 * W20ProposalBridge.mm — ObjC++ 桥实现（见 W20ProposalBridge.h）
 *
 * 包装 mine::ai::NullProposalAgent（W20 Null 提案桩，ai/backends/null/）：
 * propose/confirm/observe 三方法逐一透传，Swift 侧（W20CppProposalEngine）拿到的
 * 提案与执行状态流转与 ai/tests/test_proposal_v2.cpp 断言的完全同源。
 */
#import "W20ProposalBridge.h"

#include <memory>
#include <string>
#include <vector>

#include "ai/backends/null/null_proposal_agent.h"

using mine::ai::ExecutionHandle;
using mine::ai::ExecutionState;
using mine::ai::NullProposalAgent;
using mine::ai::Proposal;
using mine::ai::ProposalKind;
using mine::ai::ProposalStream;
using mine::ai::Status;

static NSString *KindToString(ProposalKind k) {
  switch (k) {
    case ProposalKind::kReply: return @"reply";
    case ProposalKind::kTask: return @"task";
    case ProposalKind::kPlan: return @"plan";
  }
  return @"plan";
}

static NSString *StateToString(ExecutionState s) {
  switch (s) {
    case ExecutionState::kQueued: return @"queued";
    case ExecutionState::kRunning: return @"running";
    case ExecutionState::kDone: return @"done";
    case ExecutionState::kFailed: return @"failed";
  }
  return @"failed";
}

static W20BProposalAction *ActionToObjc(const mine::ai::Action &a) {
  W20BProposalAction *o = [W20BProposalAction new];
  o.actionId = [NSString stringWithUTF8String:a.id.c_str()];
  o.title = [NSString stringWithUTF8String:a.title.c_str()];
  o.detail = [NSString stringWithUTF8String:a.detail.c_str()];
  return o;
}

static W20BProposalItem *ProposalToObjc(const Proposal &p) {
  W20BProposalItem *o = [W20BProposalItem new];
  o.proposalId = [NSString stringWithUTF8String:p.id.c_str()];
  o.kind = KindToString(p.kind);
  o.title = [NSString stringWithUTF8String:p.title.c_str()];
  o.detail = [NSString stringWithUTF8String:p.detail.c_str()];
  NSMutableArray<W20BProposalAction *> *acts = [NSMutableArray array];
  for (const auto &a : p.actions) [acts addObject:ActionToObjc(a)];
  o.actions = acts;
  return o;
}

static W20BExecHandle *HandleToObjc(const ExecutionHandle &h) {
  W20BExecHandle *o = [W20BExecHandle new];
  o.execId = [NSString stringWithUTF8String:h.id.c_str()];
  o.proposalId = [NSString stringWithUTF8String:h.proposal_id.c_str()];
  o.state = StateToString(h.state);
  o.progress = h.progress;
  o.result = [NSString stringWithUTF8String:h.result.c_str()];
  return o;
}

namespace {

// 收集式 ProposalStream（propose 同步送达，转数组给 Swift）。
class CollectStream final : public ProposalStream {
 public:
  void on_proposal(const Proposal &p) override { proposals.push_back(p); }
  void on_done() override {}
  void on_error(const std::string &) override {}
  std::vector<Proposal> proposals;
};

}  // namespace

@implementation W20BProposalAction
@end

@implementation W20BProposalItem
@end

@implementation W20BExecHandle
@end

@implementation W20ProposalBridge {
  std::unique_ptr<NullProposalAgent> _agent;
}

+ (instancetype)shared {
  static W20ProposalBridge *bridge;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    bridge = [[W20ProposalBridge alloc] init];
  });
  return bridge;
}

- (instancetype)init {
  if ((self = [super init])) {
    _agent = std::make_unique<NullProposalAgent>();
  }
  return self;
}

- (NSArray<W20BProposalItem *> *)proposeSecure:(BOOL)secure {
  mine::ai::AiContext ctx;
  ctx.secure_input = secure ? true : false;
  CollectStream stream;
  if (_agent->propose(ctx, stream) != Status::kOk) {
    return @[];  // 未受理（kDisabled 等）
  }
  NSMutableArray<W20BProposalItem *> *out = [NSMutableArray array];
  for (const auto &p : stream.proposals) [out addObject:ProposalToObjc(p)];
  return out;
}

- (W20BExecHandle *)confirm:(NSString *)proposalId {
  // 红线：只允许提案卡「确认执行」按钮调用到这里（自动执行不存在）。
  ExecutionHandle h = _agent->confirm(std::string(proposalId.UTF8String));
  return HandleToObjc(h);
}

- (BOOL)observe:(W20BExecHandle *)handle
       onUpdate:(void (^)(W20BExecHandle *_Nullable snap))onUpdate {
  ExecutionHandle in;
  in.id = std::string(handle.execId.UTF8String);
  in.proposal_id = std::string(handle.proposalId.UTF8String);
  Status st = _agent->observe(in, [&](const ExecutionHandle &snap) {
    if (onUpdate) onUpdate(HandleToObjc(snap));
  });
  return st == Status::kOk ? YES : NO;
}

@end
