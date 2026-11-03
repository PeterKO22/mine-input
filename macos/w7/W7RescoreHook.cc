/*
 * W7RescoreHook.cc — 候选重排挂点实现（见 W7RescoreHook.h）
 */
#include "macos/w7/W7RescoreHook.h"

#include <atomic>
#include <unordered_set>
#include <utility>

#include "ai/audit/audit_stub.h"
#include "ai/backends/null/null_ai_assist.h"
#include "ai/spi/timeout_assist.h"

namespace mine {
namespace w7 {
namespace {

// 计数审计转发：auditCount() 直接取真实落桩次数（每轮恰一条的证据链）。
struct CountingAuditSink final : mine::ai::AuditSink {
  mine::ai::AuditSink* inner;
  std::atomic<std::size_t> count{0};
  void record(const mine::ai::AuditRecord& rec) override {
    count.fetch_add(1);
    if (inner != nullptr) inner->record(rec);
  }
};

}  // namespace

struct RescoreHook::Impl {
  // 内置默认组件（仅当调用方未注入时持有）
  std::unique_ptr<mine::ai::NullAiAssist> default_backend;
  std::unique_ptr<mine::ai::MemoryAuditSink> default_audit;

  mine::ai::AiAssist* backend = nullptr;
  CountingAuditSink counter;
  // 声明顺序即析构逆序：assist_ 最后声明 → 最先析构（join 全部线程后才拆后端/审计）
  std::unique_ptr<mine::ai::TimeoutAssist> assist;

  void init(mine::ai::AiAssist* backend_in, mine::ai::AuditSink* audit_in,
            std::chrono::milliseconds timeout) {
    if (backend_in != nullptr) {
      backend = backend_in;
    } else {
      default_backend = std::make_unique<mine::ai::NullAiAssist>();
      backend = default_backend.get();
    }
    if (audit_in == nullptr) {
      default_audit = std::make_unique<mine::ai::MemoryAuditSink>();
      audit_in = default_audit.get();
    }
    counter.inner = audit_in;
    assist = std::make_unique<mine::ai::TimeoutAssist>(*backend, &counter, timeout);
  }
};

RescoreHook::RescoreHook(mine::ai::AiAssist* backend, mine::ai::AuditSink* audit,
                         std::chrono::milliseconds timeout)
    : impl_(std::make_unique<Impl>()) {
  impl_->init(backend, audit, timeout);
}

RescoreHook::~RescoreHook() = default;

void RescoreHook::request(const std::string& preedit, const std::string& text_before,
                          const std::vector<mine::ai::Candidate>& candidates,
                          RoundCallback on_done) {
  mine::ai::AiContext ctx;
  ctx.level = mine::ai::ContextLevel::kC0;  // 上下文最小化（默认 C0）
  ctx.preedit = preedit;
  ctx.text_before = text_before;
  ctx.locale = "zh-Hans";
  ctx.secure_input = false;  // Squirrel 侧可判定时由调用方注入（桥接层预留）

  const std::vector<mine::ai::Candidate> original = candidates;
  impl_->assist->rescoreAsync(
      ctx, candidates,
      [original, on_done](mine::ai::Status st, std::vector<mine::ai::Candidate> out) {
        if (on_done) on_done(group(st, original, std::move(out)));
      });
  // 上一行即「立即返回」：rescoreAsync 只做线程派发（W3 TimeoutAssist 语义）。
}

std::size_t RescoreHook::auditCount() const {
  return impl_->counter.count.load();
}

RescoreRound RescoreHook::group(mine::ai::Status status,
                                const std::vector<mine::ai::Candidate>& original,
                                std::vector<mine::ai::Candidate> rescored) {
  RescoreRound round;
  round.status = status;
  if (status != mine::ai::Status::kOk) {
    return round;  // 弃本轮/拒绝/错误 → 不出智能组（面板保持常规组）
  }
  std::unordered_set<std::string> valid;
  valid.reserve(original.size());
  for (const auto& c : original) valid.insert(c.text);
  round.smart.reserve(rescored.size());
  for (auto& c : rescored) {
    if (valid.count(c.text) != 0) {
      round.smart.push_back(std::move(c));  // 保持后端顺序 = 智能组序
    }
  }
  return round;
}

}  // namespace w7
}  // namespace mine
