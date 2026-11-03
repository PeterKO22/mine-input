#include "ai/backends/null/null_ai_assist.h"

namespace mine {
namespace ai {

Status NullAiAssist::rescore(const AiContext& ctx,
                             std::vector<Candidate>& candidates) {
  (void)candidates;  // 原样返回：不改顺序、不改得分
  return ctx.secure_input ? Status::kDisabled : Status::kOk;
}

Status NullAiAssist::complete(const AiContext& ctx, const std::string& prefix,
                              std::vector<Candidate>& out) {
  (void)prefix;
  out.clear();  // 空后端：无续写
  return ctx.secure_input ? Status::kDisabled : Status::kOk;
}

Status NullAiAssist::correct(const AiContext& ctx, const std::string& spoken,
                             std::vector<Candidate>& out) {
  out.clear();
  if (ctx.secure_input) return Status::kDisabled;
  // 不纠错：原文作为唯一候选回传（恒等）。
  out.push_back(Candidate{spoken, 1.0, "null"});
  return Status::kOk;
}

Status NullAiAssist::suggest(const AiContext& ctx,
                             const SuggestCallback& on_update) {
  if (ctx.secure_input) return Status::kDisabled;  // 未受理：不触发回调
  if (on_update) {
    SuggestUpdate done;
    done.status = StreamStatus::kDone;
    on_update(done);  // 恰好一次终止，无增量
  }
  return Status::kOk;
}

Status NullAiAssist::ingest(const InteractionEvent& event) {
  (void)event;  // 空后端：接收并丢弃
  return Status::kOk;
}

}  // namespace ai
}  // namespace mine
