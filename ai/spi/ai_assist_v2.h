/*
 * ai_assist_v2.h — AiAssist SPI v2「提案→确认→执行」契约（W20 proposal-ui，契约先行）
 *
 * 用户愿景（docs/需求文档-v1.0.md N7）：AI 不止提示候选字，而是**直接给方案**，
 * 用户确认后**开任务执行到出结果**。契约文本：docs/技术方案-v0.4.md §15.2。
 *
 * v1 五方法不动：rescore / complete / correct / suggest / ingest 仍以
 * ai/spi/ai_assist.h 为唯一契约源，本头只做**增量**（v2 继承 v1，AiAssistV2 : AiAssist）。
 *
 * 远程同契约（§7 原则）：本地调用与 Hub 远程协议**同方法签名**——
 *   propose / confirm / observe 与 v1 五方法一样，端侧后端与 Hub 后端（执行器位：
 *   agent runner，§15.2）同签名，换后端零改动；W4 起以 HTTP 映射，方法面不变。
 *
 * v2 语义（§15.2）：
 *   propose(AiContext, ProposalStream&)  流式提案：不止候选字，是「方案」——
 *                                        Proposal{title/detail/actions}，可多条增量；
 *   confirm(proposal_id) -> ExecutionHandle
 *                                        用户**显式确认后才执行**；
 *   observe(handle, ProgressCb)          执行到出结果，进度/结果回填提案卡。
 *
 * 红线（§15.2，不可协商）：
 *   1. `confirm` 必须是用户显式动作（界面上的「确认执行」按钮）——**自动执行不存在**：
 *      propose 及任何其他路径不得触发执行；未 confirm 的提案永远不执行；
 *   2. 执行从 confirm 起算：confirm 产生 ExecutionHandle（state=queued），此后
 *      observe 回填进度/结果（queued→running→done|failed）；
 *   3. 对未经 confirm 的 handle（伪造/未知 id）observe 必须拒绝（kError），不执行；
 *   4. 重复 confirm 幂等：同一 proposal_id 返回同一执行（同一 handle.id），不产生第二次执行。
 *
 * 流式提案语义（对齐 v1 suggest 语义族）：
 *   propose 同步返回值非 kOk 表示未受理（安全输入 kDisabled 等），stream 不得被触碰；
 *   受理后 stream 先收若干 on_proposal，后恰好一次终止（on_done / on_error）；
 *   终止之后的更新必须丢弃；回调内不得重入同一轮调用。
 *
 * 生命周期：同 v1（TimeoutAssist 包装层负责 800ms 超时/异步派发语义；v2 方法同样
 * 不得阻塞调用方）。执行器（真实任务执行）随 Hub 迭代落地（§15.2 v2 实施顺序）：
 * 本版只有契约 + Null 桩 + 提案卡 UI 形态。
 *
 * 依据文档：docs/技术方案-v0.4.md §15.2、docs/需求文档-v1.0.md N7。
 */
#ifndef MINE_INPUT_AI_SPI_AI_ASSIST_V2_H_
#define MINE_INPUT_AI_SPI_AI_ASSIST_V2_H_

#include <functional>
#include <string>
#include <vector>

#include "ai/spi/ai_assist.h"  // v1 契约不动：Status / AiContext / AiAssist

namespace mine {
namespace ai {

// 提案类型（§15.2：reply | task | plan）。
enum class ProposalKind {
  kReply,  // 回复方案（怎么回话）
  kTask,   // 任务方案（开任务执行）
  kPlan,   // 计划方案（多步编排）
};

// 可执行动作（提案卡「动作清单」项；执行回填按动作逐项走）。
struct Action {
  std::string id;      // 动作标识（执行进度回填引用）
  std::string title;   // 动作标题
  std::string detail;  // 动作说明
};

// 提案（方案本体）：title/detail = 方案文本，actions = 可执行动作清单。
struct Proposal {
  std::string id;
  ProposalKind kind = ProposalKind::kReply;
  std::string title;
  std::string detail;
  std::vector<Action> actions;
};

// 执行状态（§15.2：queued | running | done | failed）。
enum class ExecutionState {
  kQueued,   // 已确认，排队中
  kRunning,  // 执行中
  kDone,     // 完成（result 给结果）
  kFailed,   // 失败（result 给简要原因，字段级，不含全文）
};

// 执行句柄：confirm 的产物；observe 的进度/结果回填载体（提案卡状态流转）。
struct ExecutionHandle {
  std::string id;          // 执行 id（≠ proposal_id）
  std::string proposal_id; // 来源提案
  ExecutionState state = ExecutionState::kQueued;
  double progress = 0.0;   // 0..1
  std::string result;      // done=结果 / failed=简要原因 / 其余态为空
};

// 流式提案接口（propose 的输出参数，仿 v1 SuggestCallback 的对象化）：
// 先若干 on_proposal，后恰好一次终止（on_done / on_error）。
class ProposalStream {
 public:
  virtual ~ProposalStream() = default;
  virtual void on_proposal(const Proposal& proposal) = 0;  // 增量提案
  virtual void on_done() = 0;                              // 终止：正常
  virtual void on_error(const std::string& reason) = 0;    // 终止：错误（字段级）
};

// 进度回填回调（observe）：每次收到一份 handle 快照（state/progress/result）。
using ProgressCb = std::function<void(const ExecutionHandle&)>;

// AiAssist SPI v2 —— v1 五方法保留不动（继承），v2 新增三方法。
// 端侧后端与 Hub 后端同方法签名，本地调用与远程协议同契约（§7 原则）。
class AiAssistV2 : public AiAssist {
 public:
  // 流式提案：返回 kOk = 已受理，结果经 stream 增量推送，恰好一次终止；
  // 返回非 kOk（如安全输入 kDisabled）= 未受理，stream 不得被触碰。
  // 红线：propose 只提案，绝不执行。
  virtual Status propose(const AiContext& ctx, ProposalStream& stream) = 0;

  // 显式确认 → 开任务执行。**只允许由用户显式动作调用（界面上的「确认执行」键）**；
  // 自动执行不存在。未 confirm 的提案永远不执行。
  // 未知 proposal_id / 未流式送达的 id：返回 state=kFailed 的 handle（result 注明原因），
  // 不执行；重复 confirm 幂等（同一 handle.id，不产生第二次执行）。
  virtual ExecutionHandle confirm(const std::string& proposal_id) = 0;

  // 进度/结果回填（提案卡状态流转 queued→running→done|failed）：
  // 返回 kOk = 已受理，on_progress 收若干 handle 快照；
  // handle 未经 confirm（未知/伪造执行 id）：返回 kError，不得触发回调、不得执行。
  virtual Status observe(const ExecutionHandle& handle,
                         const ProgressCb& on_progress) = 0;
};

}  // namespace ai
}  // namespace mine

#endif  // MINE_INPUT_AI_SPI_AI_ASSIST_V2_H_
