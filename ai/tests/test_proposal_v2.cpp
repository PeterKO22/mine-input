// test_proposal_v2.cpp — SPI v2「提案→确认→执行」契约 + Null 提案桩（W20）
//
// 核心红线断言（docs/技术方案-v0.4.md §15.2）：
//   「未 confirm 不得执行」——propose 与任何非 confirm 路径都不得产生执行；
//   confirm 必须用户显式动作（唯一入口），重复 confirm 幂等不二次执行。
#include <string>
#include <vector>

#include "ai/backends/null/null_proposal_agent.h"
#include "ai/spi/ai_assist_v2.h"
#include "test_assert.h"

using namespace mine::ai;

namespace {

// 记录式 ProposalStream：收集增量与终止次数。
class CollectStream final : public ProposalStream {
 public:
  void on_proposal(const Proposal& p) override {
    if (terminal_) ++post_terminal_updates_;  // 终止后更新必须为 0
    proposals.push_back(p);
  }
  void on_done() override {
    if (terminal_) ++post_terminal_updates_;
    terminal_ = true;
    ++terminals;
  }
  void on_error(const std::string&) override {
    if (terminal_) ++post_terminal_updates_;
    terminal_ = true;
    ++terminals;
  }
  std::vector<Proposal> proposals;
  int terminals = 0;
  int post_terminal_updates_ = 0;
  bool terminal_ = false;
};

}  // namespace

int main() {
  NullProposalAgent agent;
  AiContext ctx;

  // ---- propose：流式提案（1 条示例提案 + 恰好一次终止），且**绝不执行** ----
  {
    CollectStream s;
    CHECK(agent.propose(ctx, s) == Status::kOk);
    CHECK(s.proposals.size() == 1);
    CHECK(s.terminals == 1);                 // 恰好一次终止
    CHECK(s.post_terminal_updates_ == 0);    // 终止后无更新
    const Proposal& p = s.proposals[0];
    CHECK(p.id == "prop-null-1");
    CHECK(p.kind == ProposalKind::kPlan);
    CHECK(!p.title.empty() && !p.detail.empty());
    CHECK(p.actions.size() == 3);            // 动作清单非空（提案卡形态）
    for (const auto& a : p.actions) {
      CHECK(!a.id.empty() && !a.title.empty());
    }
    // 红线断言 ①：propose 之后没有任何执行（未 confirm 不得执行）。
    CHECK(agent.execution_count() == 0);
  }

  // ---- 红线断言 ②：observe 伪造 handle 不得执行、不得回调 ----
  {
    ExecutionHandle forged;
    forged.id = "exec-forged";               // 从未 confirm 过
    forged.proposal_id = "prop-null-1";
    int updates = 0;
    CHECK(agent.observe(forged, [&](const ExecutionHandle&) { ++updates; }) ==
          Status::kError);
    CHECK(updates == 0);
    CHECK(agent.execution_count() == 0);     // 仍未执行
  }

  // ---- 红线断言 ③：confirm 是执行唯一入口（用户显式确认）----
  {
    ExecutionHandle h = agent.confirm("prop-null-1");
    CHECK(!h.id.empty());
    CHECK(h.proposal_id == "prop-null-1");
    CHECK(h.state == ExecutionState::kQueued);  // confirm 只入队
    CHECK(h.progress == 0.0);
    CHECK(agent.execution_count() == 1);        // 执行从 confirm 起算
  }

  // ---- observe：进度回填 queued→running→done（提案卡状态流转）----
  {
    ExecutionHandle h = agent.confirm("prop-null-1");  // 幂等取同一执行
    std::vector<ExecutionHandle> snaps;
    CHECK(agent.observe(h, [&](const ExecutionHandle& s) { snaps.push_back(s); }) ==
          Status::kOk);
    CHECK(snaps.size() == 2);
    CHECK(snaps[0].state == ExecutionState::kRunning);
    CHECK(snaps[0].progress == 0.5);
    CHECK(snaps[1].state == ExecutionState::kDone);
    CHECK(snaps[1].progress == 1.0);
    CHECK(!snaps[1].result.empty());               // 执行到出结果
    CHECK(snaps[0].id == h.id && snaps[1].id == h.id);
  }

  // ---- 重复 confirm 幂等：同一执行，不产生第二次执行 ----
  {
    ExecutionHandle a = agent.confirm("prop-null-1");
    ExecutionHandle b = agent.confirm("prop-null-1");
    CHECK(a.id == b.id);
    CHECK(agent.execution_count() == 1);           // 没有第二次执行
  }

  // ---- 未知 proposal_id：kFailed handle，不执行 ----
  {
    ExecutionHandle h = agent.confirm("no-such-proposal");
    CHECK(h.state == ExecutionState::kFailed);
    CHECK(!h.result.empty());
    CHECK(agent.execution_count() == 1);           // 计数不涨
  }

  // ---- secure_input：未受理，stream 不得被触碰（同 v1 语义族）----
  {
    AiContext secure;
    secure.secure_input = true;
    CollectStream s;
    CHECK(agent.propose(secure, s) == Status::kDisabled);
    CHECK(s.proposals.empty() && s.terminals == 0);
    CHECK(agent.execution_count() == 1);
  }

  // ---- v1 五方法不动：委托 NullAiAssist 行为原样（抽测 suggest 恒等语义）----
  {
    int deltas = 0;
    int terminals = 0;
    CHECK(agent.suggest(ctx, [&](const SuggestUpdate& up) {
            if (up.status == StreamStatus::kDelta) ++deltas;
            else ++terminals;
          }) == Status::kOk);
    CHECK(deltas == 0 && terminals == 1);
    std::vector<Candidate> out;
    CHECK(agent.correct(ctx, "tongzhi", out) == Status::kOk);
    CHECK(out.size() == 1 && out[0].text == "tongzhi");
  }

  return testutil::Finish("test_proposal_v2（提案契约 v2 + Null 桩 + 未 confirm 不得执行）");
}
