/*
 * null_proposal_agent.h — Null 提案桩（W20：SPI v2「提案→确认→执行」空后端）
 *
 * 「不做任何真实任务执行」的基准后端（对拍参照，同 NullAiAssist 之于 v1）：
 *   - propose  : 流式送达恰好 1 条固定示例提案（kPlan）后 on_done 终止；
 *                secure_input 直接 kDisabled（不触碰 stream）；**只提案，绝不执行**；
 *   - confirm  : **执行的唯一入口**（红线：必须用户显式动作调用，自动执行不存在）——
 *                产生 ExecutionHandle（kQueued）；未知 id → kFailed handle（不执行）；
 *                重复 confirm 幂等（同一 handle.id，不产生第二次执行）；
 *   - observe  : 演示状态流转 queued→running→done：回填 progress 0.5（kRunning）
 *                → 1.0（kDone，result=「null 执行完成：…」）；未经 confirm 的 handle
 *                → kError，不回调、不执行；
 *   - v1 五方法 : 原样委托 NullAiAssist（v1 契约不动）。
 *
 * 测试可见内省（红线断言用）：execution_count() = 已 confirm 的执行数。
 */
#ifndef MINE_INPUT_AI_BACKENDS_NULL_NULL_PROPOSAL_AGENT_H_
#define MINE_INPUT_AI_BACKENDS_NULL_NULL_PROPOSAL_AGENT_H_

#include <cstddef>
#include <map>
#include <mutex>
#include <string>

#include "ai/backends/null/null_ai_assist.h"
#include "ai/spi/ai_assist_v2.h"

namespace mine {
namespace ai {

class NullProposalAgent final : public AiAssistV2 {
 public:
  // ---- v1 五方法（不动，委托 NullAiAssist）----
  Status rescore(const AiContext& ctx,
                 std::vector<Candidate>& candidates) override;
  Status complete(const AiContext& ctx, const std::string& prefix,
                  std::vector<Candidate>& out) override;
  Status correct(const AiContext& ctx, const std::string& spoken,
                 std::vector<Candidate>& out) override;
  Status suggest(const AiContext& ctx,
                 const SuggestCallback& on_update) override;
  Status ingest(const InteractionEvent& event) override;

  // ---- v2 三方法（提案→确认→执行）----
  Status propose(const AiContext& ctx, ProposalStream& stream) override;
  ExecutionHandle confirm(const std::string& proposal_id) override;
  Status observe(const ExecutionHandle& handle,
                 const ProgressCb& on_progress) override;

  // 测试内省：已 confirm（= 已执行）的次数。红线断言「未 confirm 不得执行」。
  std::size_t execution_count() const;

  // 固定示例提案（propose 恒定输出；测试与提案卡 UI 共用形态）。
  static Proposal demo_proposal();

 private:
  mutable std::mutex mu_;
  NullAiAssist v1_;  // v1 行为唯一事实源
  std::map<std::string, ExecutionHandle> executions_;  // exec_id → handle
  std::map<std::string, std::string> confirmed_;       // proposal_id → exec_id
  std::size_t next_exec_ = 1;
};

}  // namespace ai
}  // namespace mine

#endif  // MINE_INPUT_AI_BACKENDS_NULL_NULL_PROPOSAL_AGENT_H_
