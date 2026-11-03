/*
 * timeout_assist.h — 800ms 超时包装（SPI 语义的一部分，W3）
 *
 * 语义（需求 NFR3 / 技术方案 §7）：
 *   - 超时弃本轮：一轮调用超过 timeout（默认 kAiTimeout = 800ms）即判负，
 *     回调收到 kTimeout，后端迟到的结果一律丢弃，绝不回灌；
 *   - 绝不阻塞调用方：所有 *Async 方法立即返回（只做线程派发），
 *     按键→上屏路径永不等待 AI；
 *   - 恰好一次回调：每轮 on_done / on_update 的终止事件恰好触发一次；
 *   - 审计：每轮恰好记一条 AuditRecord（只记字段不记全文），超时记 kTimeout；
 *   - secure_input（密码框/支付）自动暂停：直接回 kDisabled，后端不被调用。
 *
 * suggest 流式：包装层保证「先增量、后恰好一次终止（kDone/kError/kTimeout）」，
 *   终止后后端再来的增量/终止全部丢弃。
 *
 * 生命周期：析构 join 全部已派发线程；先销毁本类，再销毁后端与 AuditSink。
 * 回调内不得重入同一轮调用。
 */
#ifndef MINE_INPUT_AI_SPI_TIMEOUT_ASSIST_H_
#define MINE_INPUT_AI_SPI_TIMEOUT_ASSIST_H_

#include <chrono>
#include <cstddef>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "ai/spi/ai_assist.h"

namespace mine {
namespace ai {

class TimeoutAssist {
 public:
  using ResultCallback =
      std::function<void(Status, std::vector<Candidate>)>;
  using IngestCallback = std::function<void(Status)>;

  explicit TimeoutAssist(AiAssist& backend, AuditSink* audit = nullptr,
                         std::chrono::milliseconds timeout = kAiTimeout);
  ~TimeoutAssist();

  TimeoutAssist(const TimeoutAssist&) = delete;
  TimeoutAssist& operator=(const TimeoutAssist&) = delete;

  // 全部方法：立即返回；回调恰好一次；超时弃本轮（迟到结果丢弃）。
  void rescoreAsync(const AiContext& ctx, std::vector<Candidate> candidates,
                    ResultCallback on_done);
  void completeAsync(const AiContext& ctx, const std::string& prefix,
                     ResultCallback on_done);
  void correctAsync(const AiContext& ctx, const std::string& spoken,
                    ResultCallback on_done);
  void suggestAsync(const AiContext& ctx, SuggestCallback on_update);
  void ingestAsync(const InteractionEvent& event, IngestCallback on_done);

 private:
  using ListCall =
      std::function<std::pair<Status, std::vector<Candidate>>()>;
  using StatusCall = std::function<Status()>;

  void runListRound(const char* method, const AiContext& ctx,
                    std::size_t input_count, ListCall call,
                    ResultCallback on_done);
  void runStatusRound(const char* method, const AiContext& ctx,
                      std::size_t input_count, StatusCall call,
                      IngestCallback on_done);
  void spawn(std::function<void()> fn);
  void auditOnce(const char* method, const AiContext& ctx,
                 std::size_t input_count, std::size_t output_count,
                 std::int64_t elapsed_ms, Status status);

  AiAssist& backend_;
  AuditSink* audit_;
  std::chrono::milliseconds timeout_;
  std::mutex threads_mu_;
  std::vector<std::thread> threads_;
};

}  // namespace ai
}  // namespace mine

#endif  // MINE_INPUT_AI_SPI_TIMEOUT_ASSIST_H_
