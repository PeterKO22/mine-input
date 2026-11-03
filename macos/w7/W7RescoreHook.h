/*
 * W7RescoreHook.h — Squirrel 候选链的 AI 重排挂点（W7 macos 集成 / 基于 W3 SPI）
 *
 * 职责（W7 任务 (b)）：
 *   - 把 librime 候选链的候选列表异步交给 ai/spi/ai_assist.h 的 rescore；
 *   - 800ms 超时弃本轮（TimeoutAssist 语义），绝不阻塞按键→上屏路径；
 *   - 审计桩每轮恰记一条 AuditRecord（TimeoutAssist 保证，本类透传）；
 *   - 产出「常规/智能」两组：常规组 = librime 原序（调用方持有），
 *     智能组 = 后端重排结果（group() 过滤为原候选的安全子集，保持后端顺序）。
 *
 * 当前后端为 W3 NullAiAssist（rescore 原样返回）——本阶段验证「挂接」本身：
 * 异步 / 超时 / 恰一次回调 / 恰一条审计 / 两组数据通路。真实 GGUF 后端换入时
 * 本类零改动（SPI 同签名）。
 *
 * 线程模型：request() 立即返回（只做派发）；回调在后台线程触发，恰好一次；
 * 回调内不得重入 request()。析构 join 全部已派发线程（先销毁本类再销毁注入的
 * 后端与 AuditSink）。
 */
#ifndef MINE_INPUT_MACOS_W7_RESCORE_HOOK_H_
#define MINE_INPUT_MACOS_W7_RESCORE_HOOK_H_

#include <chrono>
#include <cstddef>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "ai/spi/ai_assist.h"

namespace mine {
namespace w7 {

// 一轮 rescore 的结果：智能组候选（常规组由调用方按 librime 原序保留）。
struct RescoreRound {
  mine::ai::Status status = mine::ai::Status::kOk;
  std::vector<mine::ai::Candidate> smart;  // 智能组；弃本轮/拒绝/错误时为空
};

class RescoreHook {
 public:
  using RoundCallback = std::function<void(const RescoreRound&)>;

  // backend / audit 可注入（测试用）；nullptr 时内置 Null 后端 + 内存审计桩。
  explicit RescoreHook(mine::ai::AiAssist* backend = nullptr,
                       mine::ai::AuditSink* audit = nullptr,
                       std::chrono::milliseconds timeout = mine::ai::kAiTimeout);
  ~RescoreHook();

  RescoreHook(const RescoreHook&) = delete;
  RescoreHook& operator=(const RescoreHook&) = delete;

  // 异步发起一轮重排：立即返回；on_done 恰好一次（含超时轮）；
  // 超时弃本轮 → status=kTimeout 且 smart 为空（面板保持常规组，不阻塞上屏）。
  void request(const std::string& preedit, const std::string& text_before,
               const std::vector<mine::ai::Candidate>& candidates,
               RoundCallback on_done);

  // 已记审计条数（每轮恰 +1，含超时轮与 secure_input 轮）；供测试/挂点自检。
  std::size_t auditCount() const;

  // 分组纯函数（可单测）：
  //   - status 非 kOk → 智能组为空（弃本轮不出组）；
  //   - 智能组 = rescored 顺序，但只保留 text 出现在 original 中的条目
  //     （面板点选按 text 映射回 librime 候选索引，越界条目必须滤掉）。
  static RescoreRound group(mine::ai::Status status,
                            const std::vector<mine::ai::Candidate>& original,
                            std::vector<mine::ai::Candidate> rescored);

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace w7
}  // namespace mine

#endif  // MINE_INPUT_MACOS_W7_RESCORE_HOOK_H_
