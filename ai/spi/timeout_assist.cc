#include "ai/spi/timeout_assist.h"

#include <condition_variable>
#include <memory>

namespace mine {
namespace ai {
namespace {

std::int64_t ElapsedMs(std::chrono::steady_clock::time_point t0) {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now() - t0)
      .count();
}

// 一轮调用的恰好一次语义：claim() 由「后端结果 / 超时看门狗」竞争，
// 先到者拿走本轮并派发回调，后到者丢弃（超时弃本轮）。
struct Round {
  std::mutex mu;
  std::condition_variable cv;
  bool finished = false;

  bool claim() {
    std::lock_guard<std::mutex> lock(mu);
    if (finished) return false;
    finished = true;
    cv.notify_all();
    return true;
  }
};

// 流式轮次：终止事件恰好一次；终止后增量丢弃。
struct StreamRound {
  std::mutex mu;
  std::condition_variable cv;
  bool finished = false;
  std::size_t delta_count = 0;
};

// suggest 终止事件 → 轮次状态（审计字段映射）。
Status StatusForTerminal(StreamStatus s) {
  switch (s) {
    case StreamStatus::kDone:
      return Status::kOk;
    case StreamStatus::kTimeout:
      return Status::kTimeout;
    default:
      return Status::kError;
  }
}

// 同步返回非 kOk 时包装层补终止事件。
SuggestUpdate TerminalForStatus(Status st) {
  SuggestUpdate up;
  switch (st) {
    case Status::kTimeout:
      up.status = StreamStatus::kTimeout;
      up.error = "timeout";
      break;
    case Status::kDisabled:
      up.status = StreamStatus::kError;
      up.error = "disabled";
      break;
    default:
      up.status = StreamStatus::kError;
      up.error = "error";
      break;
  }
  return up;
}

}  // namespace

TimeoutAssist::TimeoutAssist(AiAssist& backend, AuditSink* audit,
                             std::chrono::milliseconds timeout)
    : backend_(backend), audit_(audit), timeout_(timeout) {}

TimeoutAssist::~TimeoutAssist() {
  std::vector<std::thread> threads;
  {
    std::lock_guard<std::mutex> lock(threads_mu_);
    threads.swap(threads_);
  }
  for (auto& t : threads) {
    if (t.joinable()) t.join();
  }
}

void TimeoutAssist::spawn(std::function<void()> fn) {
  std::lock_guard<std::mutex> lock(threads_mu_);
  threads_.emplace_back(std::move(fn));
}

void TimeoutAssist::auditOnce(const char* method, const AiContext& ctx,
                              std::size_t input_count,
                              std::size_t output_count,
                              std::int64_t elapsed_ms, Status status) {
  if (audit_ == nullptr) return;
  AuditRecord rec;
  rec.method = method;
  rec.level = ctx.level;
  rec.input_count = input_count;
  rec.output_count = output_count;
  rec.elapsed_ms = elapsed_ms;
  rec.status = status;
  audit_->record(rec);
}

void TimeoutAssist::runListRound(const char* method, const AiContext& ctx,
                                 std::size_t input_count, ListCall call,
                                 ResultCallback on_done) {
  if (ctx.secure_input) {
    // 安全输入（密码框/支付）自动暂停不可关：后端不被调用（§8.2）。
    auditOnce(method, ctx, input_count, 0, 0, Status::kDisabled);
    if (on_done) on_done(Status::kDisabled, {});
    return;
  }

  auto round = std::make_shared<Round>();
  const auto t0 = std::chrono::steady_clock::now();

  // 看门狗：到点未完 → 弃本轮，回调 kTimeout。
  spawn([this, round, on_done, method, level = ctx.level, input_count, t0]() {
    std::unique_lock<std::mutex> lock(round->mu);
    const bool timed_out =
        !round->cv.wait_for(lock, timeout_, [&] { return round->finished; });
    if (!timed_out || round->finished) return;
    round->finished = true;
    lock.unlock();
    round->cv.notify_all();
    if (audit_ != nullptr) {
      AuditRecord rec;
      rec.method = method;
      rec.level = level;
      rec.input_count = input_count;
      rec.output_count = 0;
      rec.elapsed_ms = ElapsedMs(t0);
      rec.status = Status::kTimeout;
      audit_->record(rec);
    }
    if (on_done) on_done(Status::kTimeout, {});
  });

  // 后端调用线程：完成后就地派发；本轮已被超时拿走则丢弃结果。
  spawn([this, round, on_done, method, level = ctx.level, input_count, t0,
         call = std::move(call)]() mutable {
    auto outcome = call();
    if (!round->claim()) return;  // 超时弃本轮，迟到结果丢弃
    if (audit_ != nullptr) {
      AuditRecord rec;
      rec.method = method;
      rec.level = level;
      rec.input_count = input_count;
      rec.output_count = outcome.second.size();
      rec.elapsed_ms = ElapsedMs(t0);
      rec.status = outcome.first;
      audit_->record(rec);
    }
    if (on_done) on_done(outcome.first, std::move(outcome.second));
  });
}

void TimeoutAssist::runStatusRound(const char* method, const AiContext& ctx,
                                   std::size_t input_count, StatusCall call,
                                   IngestCallback on_done) {
  auto round = std::make_shared<Round>();
  const auto t0 = std::chrono::steady_clock::now();

  spawn([this, round, on_done, method, level = ctx.level, input_count, t0]() {
    std::unique_lock<std::mutex> lock(round->mu);
    const bool timed_out =
        !round->cv.wait_for(lock, timeout_, [&] { return round->finished; });
    if (!timed_out || round->finished) return;
    round->finished = true;
    lock.unlock();
    round->cv.notify_all();
    if (audit_ != nullptr) {
      AuditRecord rec;
      rec.method = method;
      rec.level = level;
      rec.input_count = input_count;
      rec.output_count = 0;
      rec.elapsed_ms = ElapsedMs(t0);
      rec.status = Status::kTimeout;
      audit_->record(rec);
    }
    if (on_done) on_done(Status::kTimeout);
  });

  spawn([this, round, on_done, method, level = ctx.level, input_count, t0,
         call = std::move(call)]() mutable {
    Status st = call();
    if (!round->claim()) return;  // 超时弃本轮
    if (audit_ != nullptr) {
      AuditRecord rec;
      rec.method = method;
      rec.level = level;
      rec.input_count = input_count;
      rec.output_count = (st == Status::kOk) ? input_count : 0;
      rec.elapsed_ms = ElapsedMs(t0);
      rec.status = st;
      audit_->record(rec);
    }
    if (on_done) on_done(st);
  });
}

void TimeoutAssist::rescoreAsync(const AiContext& ctx,
                                 std::vector<Candidate> candidates,
                                 ResultCallback on_done) {
  const std::size_t input_count = candidates.size();
  AiAssist* backend = &backend_;
  runListRound(
      "rescore", ctx, input_count,
      [backend, ctx, candidates = std::move(candidates)]() mutable {
        std::vector<Candidate> out = std::move(candidates);
        Status st = backend->rescore(ctx, out);
        return std::make_pair(st, std::move(out));
      },
      std::move(on_done));
}

void TimeoutAssist::completeAsync(const AiContext& ctx, const std::string& prefix,
                                  ResultCallback on_done) {
  AiAssist* backend = &backend_;
  runListRound(
      "complete", ctx, 1,
      [backend, ctx, prefix]() {
        std::vector<Candidate> out;
        Status st = backend->complete(ctx, prefix, out);
        return std::make_pair(st, std::move(out));
      },
      std::move(on_done));
}

void TimeoutAssist::correctAsync(const AiContext& ctx, const std::string& spoken,
                                 ResultCallback on_done) {
  AiAssist* backend = &backend_;
  runListRound(
      "correct", ctx, 1,
      [backend, ctx, spoken]() {
        std::vector<Candidate> out;
        Status st = backend->correct(ctx, spoken, out);
        return std::make_pair(st, std::move(out));
      },
      std::move(on_done));
}

void TimeoutAssist::ingestAsync(const InteractionEvent& event,
                                IngestCallback on_done) {
  AiAssist* backend = &backend_;
  AiContext ctx;  // ingest 无打字上下文；审计记默认分级
  runStatusRound(
      "ingest", ctx, 1,
      [backend, event]() { return backend->ingest(event); },
      std::move(on_done));
}

void TimeoutAssist::suggestAsync(const AiContext& ctx,
                                 SuggestCallback on_update) {
  if (ctx.secure_input) {
    // 安全输入自动暂停不可关：直接终止，后端不被调用（§8.2）。
    if (audit_ != nullptr) {
      AuditRecord rec;
      rec.method = "suggest";
      rec.level = ctx.level;
      rec.input_count = 1;
      rec.output_count = 0;
      rec.elapsed_ms = 0;
      rec.status = Status::kDisabled;
      audit_->record(rec);
    }
    if (on_update) on_update(TerminalForStatus(Status::kDisabled));
    return;
  }

  auto round = std::make_shared<StreamRound>();
  const auto t0 = std::chrono::steady_clock::now();

  // 统一出口：增量转发、终止恰好一次、终止后丢弃（保证增量先于终止有序派发）。
  auto wrapped = [round, on_update, audit = audit_, level = ctx.level, t0](
                     const SuggestUpdate& up) {
    bool terminal = false;
    {
      std::lock_guard<std::mutex> lock(round->mu);
      if (round->finished) return;  // 终止后一切更新丢弃
      if (up.status == StreamStatus::kDelta) {
        round->delta_count += 1;
      } else {
        round->finished = true;
        terminal = true;
        if (audit != nullptr) {
          AuditRecord rec;
          rec.method = "suggest";
          rec.level = level;
          rec.input_count = 1;
          rec.output_count = round->delta_count;
          rec.elapsed_ms = ElapsedMs(t0);
          rec.status = StatusForTerminal(up.status);
          audit->record(rec);
        }
      }
      if (on_update) on_update(up);  // 锁内派发：增量与终止严格有序
    }
    if (terminal) round->cv.notify_all();
  };

  // 看门狗：到点未终止 → 补 kTimeout 终止（弃本轮）。
  spawn([round, wrapped, timeout = timeout_]() {
    std::unique_lock<std::mutex> lock(round->mu);
    const bool timed_out =
        !round->cv.wait_for(lock, timeout, [&] { return round->finished; });
    if (!timed_out || round->finished) return;
    lock.unlock();
    SuggestUpdate up;
    up.status = StreamStatus::kTimeout;
    up.error = "timeout";
    wrapped(up);  // 内部竞争终止位，恰好一次
  });

  // 后端流启动线程：suggest 返回非 kOk（未受理）时由包装层补终止。
  spawn([this, wrapped, ctx]() {
    SuggestCallback cb = wrapped;
    Status st = backend_.suggest(ctx, cb);
    if (st != Status::kOk) wrapped(TerminalForStatus(st));
  });
}

}  // namespace ai
}  // namespace mine
