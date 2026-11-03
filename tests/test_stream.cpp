// test_stream.cpp — 流式回调完成语义：先增量、恰好一次终止、终止后更新丢弃
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

#include "ai/audit/audit_stub.h"
#include "ai/backends/null/null_ai_assist.h"
#include "ai/spi/timeout_assist.h"
#include "test_assert.h"

using namespace mine::ai;
using namespace std::chrono_literals;

namespace {

struct UpdateLog {
  std::mutex mu;
  std::vector<SuggestUpdate> updates;
  std::condition_variable cv;

  SuggestCallback cb() {
    return [this](const SuggestUpdate& up) {
      std::lock_guard<std::mutex> lock(mu);
      updates.push_back(up);
      cv.notify_all();
    };
  }
  bool waitCount(std::size_t n, std::chrono::milliseconds max) {
    std::unique_lock<std::mutex> lock(mu);
    return cv.wait_for(lock, max, [&] { return updates.size() >= n; });
  }
  std::size_t count() {
    std::lock_guard<std::mutex> lock(mu);
    return updates.size();
  }
  SuggestUpdate at(std::size_t i) {
    std::lock_guard<std::mutex> lock(mu);
    return updates[i];
  }
};

// 脚本化流式后端：N 个增量后终止（或不终止/同步失败）。
class ScriptedStream final : public AiAssist {
 public:
  ScriptedStream(int deltas, bool terminate, Status sync_return = Status::kOk)
      : deltas_(deltas), terminate_(terminate), sync_return_(sync_return) {}

  Status suggest(const AiContext&, const SuggestCallback& cb) override {
    ++invocations;
    if (sync_return_ != Status::kOk) return sync_return_;  // 未受理：不触发回调
    for (int i = 0; i < deltas_; ++i) {
      SuggestUpdate up;
      up.status = StreamStatus::kDelta;
      up.candidates.push_back(Candidate{"s" + std::to_string(i), 0.5, "fake"});
      cb(up);
    }
    if (terminate_) {
      SuggestUpdate done;
      done.status = StreamStatus::kDone;
      cb(done);
    }
    return Status::kOk;
  }
  Status rescore(const AiContext&, std::vector<Candidate>&) override {
    return Status::kOk;
  }
  Status complete(const AiContext&, const std::string&,
                  std::vector<Candidate>&) override { return Status::kOk; }
  Status correct(const AiContext&, const std::string&,
                 std::vector<Candidate>&) override { return Status::kOk; }
  Status ingest(const InteractionEvent&) override { return Status::kOk; }

  std::atomic<int> invocations{0};

 private:
  int deltas_;
  bool terminate_;
  Status sync_return_;
};

// 迟到流式后端：本方线程在终止窗口之后继续推送（必须被丢弃）。
class LateStream final : public AiAssist {
 public:
  Status suggest(const AiContext&, const SuggestCallback& cb) override {
    worker_ = std::thread([this, cb]() {
      std::this_thread::sleep_for(400ms);
      SuggestUpdate d;
      d.status = StreamStatus::kDelta;
      d.candidates.push_back(Candidate{"late", 0.1, "fake"});
      cb(d);
      std::this_thread::sleep_for(100ms);
      SuggestUpdate done;
      done.status = StreamStatus::kDone;
      cb(done);
      late_done = true;
      {
        std::lock_guard<std::mutex> lock(mu_);
        cv_.notify_all();
      }
    });
    return Status::kOk;
  }
  ~LateStream() override {
    if (worker_.joinable()) worker_.join();
  }
  Status rescore(const AiContext&, std::vector<Candidate>&) override {
    return Status::kOk;
  }
  Status complete(const AiContext&, const std::string&,
                  std::vector<Candidate>&) override { return Status::kOk; }
  Status correct(const AiContext&, const std::string&,
                 std::vector<Candidate>&) override { return Status::kOk; }
  Status ingest(const InteractionEvent&) override { return Status::kOk; }
  bool waitLateDone(std::chrono::milliseconds max) {
    std::unique_lock<std::mutex> lock(mu_);
    return cv_.wait_for(lock, max, [this] { return late_done.load(); });
  }

  std::atomic<bool> late_done{false};

 private:
  std::thread worker_;
  std::mutex mu_;
  std::condition_variable cv_;
};

}  // namespace

int main() {
  // 1) 完成语义：3 增量 → 恰好一次 kDone；顺序：增量全部先于终止。
  {
    ScriptedStream fake(3, true);
    MemoryAuditSink audit;
    TimeoutAssist timed(fake, &audit);
    UpdateLog log;
    timed.suggestAsync(AiContext{}, log.cb());
    CHECK(log.waitCount(4, 2000ms));
    std::this_thread::sleep_for(200ms);  // 容忍多余终止/增量
    CHECK(log.count() == 4);
    for (std::size_t i = 0; i < 3; ++i) {
      CHECK(log.at(i).status == StreamStatus::kDelta);
      CHECK(log.at(i).candidates.size() == 1);
    }
    CHECK(log.at(3).status == StreamStatus::kDone);  // 恰好一次终止、在最后
    auto snap = audit.snapshot();
    CHECK(snap.size() == 1);
    CHECK(snap[0].method == "suggest" && snap[0].status == Status::kOk);
    CHECK(snap[0].output_count == 3);  // 增量批次数（只记字段）
  }

  // 2) 超时补终止：永不终止的后端 → 150ms 时恰好一次 kTimeout 终止。
  {
    ScriptedStream fake(0, /*terminate=*/false);
    TimeoutAssist timed(fake, nullptr, 150ms);
    UpdateLog log;
    timed.suggestAsync(AiContext{}, log.cb());
    CHECK(log.waitCount(1, 2000ms));
    std::this_thread::sleep_for(300ms);
    CHECK(log.count() == 1);
    CHECK(log.at(0).status == StreamStatus::kTimeout);
    CHECK(log.at(0).error == "timeout");
  }

  // 3) 终止后更新丢弃：迟到增量与迟到终止都不得回灌。
  {
    LateStream fake;
    TimeoutAssist timed(fake, nullptr, 150ms);
    UpdateLog log;
    timed.suggestAsync(AiContext{}, log.cb());
    CHECK(log.waitCount(1, 2000ms));                 // kTimeout 终止先到
    CHECK(fake.waitLateDone(2000ms));                // 迟到推送已落地
    std::this_thread::sleep_for(100ms);
    CHECK(log.count() == 1);                         // 丢弃，无回灌
    CHECK(log.at(0).status == StreamStatus::kTimeout);
  }

  // 4) 同步失败（未受理）：包装层补恰好一次 kError 终止。
  {
    ScriptedStream fake(0, false, Status::kError);
    TimeoutAssist timed(fake, nullptr, 800ms);
    UpdateLog log;
    timed.suggestAsync(AiContext{}, log.cb());
    CHECK(log.waitCount(1, 2000ms));
    std::this_thread::sleep_for(200ms);
    CHECK(log.count() == 1);
    CHECK(log.at(0).status == StreamStatus::kError);
  }

  // 5) Null 后端经包装层：恰好一次 kDone、无增量。
  {
    NullAiAssist fake;
    TimeoutAssist timed(fake, nullptr);
    UpdateLog log;
    timed.suggestAsync(AiContext{}, log.cb());
    CHECK(log.waitCount(1, 2000ms));
    std::this_thread::sleep_for(200ms);
    CHECK(log.count() == 1);
    CHECK(log.at(0).status == StreamStatus::kDone);
  }

  // 6) secure_input：直接终止（kError "disabled"），后端不被调用。
  {
    ScriptedStream fake(3, true);
    TimeoutAssist timed(fake, nullptr);
    UpdateLog log;
    AiContext secure;
    secure.secure_input = true;
    timed.suggestAsync(secure, log.cb());
    CHECK(log.count() == 1);  // 拒绝类终止同步触发
    CHECK(log.at(0).status == StreamStatus::kError);
    CHECK(log.at(0).error == "disabled");
    CHECK(fake.invocations.load() == 0);
  }

  return testutil::Finish("test_stream");
}
