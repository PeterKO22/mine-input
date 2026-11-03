/*
 * null_ai_assist.h — Null 空后端（W3 骨架参考实现）
 *
 * 「不做任何智能处理」的基准后端：换后端零改动（同 SPI 契约）的对拍参照。
 * 行为约定：
 *   - rescore  : 候选原样返回（顺序/得分不变）；
 *   - complete : 无续写（out 清空后为空）；
 *   - correct  : 不纠错，原文作为唯一候选回传（恒等）；
 *   - suggest  : 立即恰好一次 kDone 终止，无增量；
 *   - ingest   : 接收并丢弃（kOk）；
 *   - secure_input（密码框/支付）：直接 kDisabled，不做任何处理。
 */
#ifndef MINE_INPUT_AI_BACKENDS_NULL_NULL_AI_ASSIST_H_
#define MINE_INPUT_AI_BACKENDS_NULL_NULL_AI_ASSIST_H_

#include "ai/spi/ai_assist.h"

namespace mine {
namespace ai {

class NullAiAssist final : public AiAssist {
 public:
  Status rescore(const AiContext& ctx,
                 std::vector<Candidate>& candidates) override;
  Status complete(const AiContext& ctx, const std::string& prefix,
                  std::vector<Candidate>& out) override;
  Status correct(const AiContext& ctx, const std::string& spoken,
                 std::vector<Candidate>& out) override;
  Status suggest(const AiContext& ctx,
                 const SuggestCallback& on_update) override;
  Status ingest(const InteractionEvent& event) override;
};

}  // namespace ai
}  // namespace mine

#endif  // MINE_INPUT_AI_BACKENDS_NULL_NULL_AI_ASSIST_H_
