#include "ai/backends/null/null_proposal_agent.h"

namespace mine {
namespace ai {

// ---- v1 五方法（不动，委托 NullAiAssist）----

Status NullProposalAgent::rescore(const AiContext& ctx,
                                  std::vector<Candidate>& candidates) {
  return v1_.rescore(ctx, candidates);
}

Status NullProposalAgent::complete(const AiContext& ctx,
                                   const std::string& prefix,
                                   std::vector<Candidate>& out) {
  return v1_.complete(ctx, prefix, out);
}

Status NullProposalAgent::correct(const AiContext& ctx,
                                  const std::string& spoken,
                                  std::vector<Candidate>& out) {
  return v1_.correct(ctx, spoken, out);
}

Status NullProposalAgent::suggest(const AiContext& ctx,
                                  const SuggestCallback& on_update) {
  return v1_.suggest(ctx, on_update);
}

Status NullProposalAgent::ingest(const InteractionEvent& event) {
  return v1_.ingest(event);
}

// ---- v2：提案→确认→执行 ----

Proposal NullProposalAgent::demo_proposal() {
  Proposal p;
  p.id = "prop-null-1";
  p.kind = ProposalKind::kPlan;
  p.title = "Null 示例方案";
  p.detail =
      "空后端演示提案：确认后按动作清单逐步执行（Null 桩不产生任何真实副作用）。"
      "真实执行器（agent runner）随 Hub 迭代落地（§15.2）。";
  p.actions = {
      {"act-1", "汇总上下文", "收集当前输入情境（C0 最小上下文）"},
      {"act-2", "生成草稿", "按方案 detail 产出结果草稿"},
      {"act-3", "回填结果", "把执行结果回填提案卡（observe）"},
  };
  return p;
}

Status NullProposalAgent::propose(const AiContext& ctx,
                                  ProposalStream& stream) {
  if (ctx.secure_input) return Status::kDisabled;  // 未受理：不触碰 stream
  // 红线：只提案，绝不执行——本方法不产生任何 ExecutionHandle。
  stream.on_proposal(demo_proposal());
  stream.on_done();  // 恰好一次终止
  return Status::kOk;
}

ExecutionHandle NullProposalAgent::confirm(const std::string& proposal_id) {
  std::lock_guard<std::mutex> lock(mu_);
  // 执行的唯一入口（红线：用户显式确认才到这里；无任何自动执行路径）。
  auto it = confirmed_.find(proposal_id);
  if (it != confirmed_.end()) {
    return executions_[it->second];  // 重复 confirm 幂等：同一执行，不再跑
  }
  ExecutionHandle h;
  if (proposal_id != demo_proposal().id) {
    h.proposal_id = proposal_id;
    h.state = ExecutionState::kFailed;  // 未知提案：不执行
    h.result = "error: unknown proposal id";
    return h;
  }
  h.id = "exec-null-" + std::to_string(next_exec_++);
  h.proposal_id = proposal_id;
  h.state = ExecutionState::kQueued;  // confirm 只入队
  h.progress = 0.0;
  confirmed_[proposal_id] = h.id;
  executions_[h.id] = h;
  return h;
}

Status NullProposalAgent::observe(const ExecutionHandle& handle,
                                  const ProgressCb& on_progress) {
  ExecutionHandle base;
  {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = executions_.find(handle.id);
    if (it == executions_.end()) {
      // 红线：未经 confirm 的 handle（伪造/未知执行 id）拒绝——不回调、不执行。
      return Status::kError;
    }
    base = it->second;
  }
  if (!on_progress) return Status::kOk;
  // Null 桩演示状态流转：queued → running(0.5) → done(1.0)。
  ExecutionHandle running = base;
  running.state = ExecutionState::kRunning;
  running.progress = 0.5;
  on_progress(running);
  ExecutionHandle done = base;
  done.state = ExecutionState::kDone;
  done.progress = 1.0;
  done.result = "null 执行完成：" + demo_proposal().title + "（3 个动作）";
  on_progress(done);
  return Status::kOk;
}

std::size_t NullProposalAgent::execution_count() const {
  std::lock_guard<std::mutex> lock(mu_);
  return executions_.size();
}

}  // namespace ai
}  // namespace mine
