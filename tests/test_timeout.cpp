// test_timeout.cpp — 800ms 超时包装语义：超时弃本轮、绝不阻塞调用方、恰好一次回调
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

#include "ai/audit/audit_stub.h"
#include "ai/spi/timeout_assist.h"
#include "test_assert.h"

using namespace mine::ai;
using namespace std::chrono_literals;

namespace {

// 可注入延迟的假后端：记录调用次数与迟到结果。
class FakeAssist final : public AiAssist {
 public:
  explicit FakeAssist(std::chrono::milliseconds delay) : delay_(delay) {}

  Status rescore(const AiContext&, std::vector<Candidate>& candidates) override {
    ++rescore_calls;
    std::this_thread::sleep_for(delay_);
    candidates.assign({Candidate{"late", 1.0, "fake"}});
    return Status::kOk;
  }
  Status complete(const AiContext&, const std::string&,
                  std::vector<Candidate>& out) override {
    std::this_thread::sleep_for(delay_);
    out.assign({Candidate{"cmp", 0.5, "fake"}});
    return Status::kOk;
  }
  Status correct(const AiContext&, const std::string&,
                 std::vector<Candidate>& out) override {
    std::this_thread::sleep_for(delay_);
    out.assign({Candidate{"cor", 0.5, "fake"}});
    return Status::kOk;
  }
  Status suggest(const AiContext&, const SuggestCallback& cb) override {
    SuggestUpdate up;
    up.status = StreamStatus::kDone;
    cb(up);
    return Status::kOk;
  }
  Status ingest(const InteractionEvent&) override {
    std::this_thread::sleep_for(delay_);
    return Status::kOk;
  }

  std::atomic<int> rescore_calls{0};

 private:
  std::chrono::milliseconds delay_;
};

// 回调收集器：等待 + 恰好一次断言。
struct ResultWaiter {
  std::mutex mu;
  std::condition_variable cv;
  bool called = false;
  int count = 0;
  Status status = Status::kError;
  std::vector<Candidate> data;
  std::chrono::steady_clock::time_point at{};

  TimeoutAssist::ResultCallback cb() {
    return [this](Status st, std::vector<Candidate> d) {
      std::lock_guard<std::mutex> lock(mu);
      ++count;
      status = st;
      data = std::move(d);
      at = std::chrono::steady_clock::now();
      called = true;
      cv.notify_all();
    };
  }
  bool wait(std::chrono::milliseconds max) {
    std::unique_lock<std::mutex> lock(mu);
    return cv.wait_for(lock, max, [this] { return called; });
  }
  int counts() {
    std::lock_guard<std::mutex> lock(mu);
    return count;
  }
  std::int64_t elapsedMs() const {
    return std::chrono::duration_cast<std::chrono::milliseconds>(at - start)
        .count();
  }
  std::chrono::steady_clock::time_point start{
      std::chrono::steady_clock::now()};
};

}  // namespace

int main() {
  // 1) 快路径：默认 800ms 超时下正常完成，回调恰好一次，审计各记一条。
  {
    FakeAssist fake(0ms);
    MemoryAuditSink audit;
    TimeoutAssist timed(fake, &audit);  // 默认 kAiTimeout = 800ms
    ResultWaiter w;
    timed.rescoreAsync(AiContext{}, {{"一", 1.0, "wubi"}, {"二", 0.5, "pinyin"}},
                       w.cb());
    CHECK(w.wait(2000ms));
    CHECK(w.status == Status::kOk);
    CHECK(w.data.size() == 1 && w.data[0].text == "late");
    std::this_thread::sleep_for(200ms);
    CHECK(w.counts() == 1);  // 恰好一次

    ResultWaiter w2;
    timed.completeAsync(AiContext{}, "ni", w2.cb());
    CHECK(w2.wait(2000ms));
    CHECK(w2.status == Status::kOk && w2.data.size() == 1);

    auto snap = audit.snapshot();
    CHECK(snap.size() == 2);
    CHECK(snap[0].method == "rescore" && snap[0].status == Status::kOk);
    CHECK(snap[0].input_count == 2 && snap[0].output_count == 1);
    CHECK(snap[1].method == "complete" && snap[1].status == Status::kOk);
  }

  // 2) 超时弃本轮：800ms 到点回调 kTimeout，迟到结果丢弃，回调仍恰好一次。
  {
    FakeAssist fake(1500ms);
    MemoryAuditSink audit;
    TimeoutAssist timed(fake, &audit);  // 默认 800ms
    ResultWaiter w;
    timed.rescoreAsync(AiContext{}, {{"一", 1.0, "wubi"}}, w.cb());
    CHECK(w.wait(2000ms));
    CHECK(w.status == Status::kTimeout);           // 超时弃本轮
    CHECK(w.data.empty());                         // 无结果回灌
    CHECK(w.elapsedMs() >= 750);                   // ~800ms 到点才判负
    CHECK(w.elapsedMs() <= 1500);
    CHECK(fake.rescore_calls.load() == 1);         // 后端确实被调用过
    // 等后端迟到结果落地（1500ms 后），确认被丢弃：回调仍恰好一次
    std::this_thread::sleep_for(1200ms);
    CHECK(w.counts() == 1);
    auto snap = audit.snapshot();
    CHECK(snap.size() == 1);
    CHECK(snap[0].status == Status::kTimeout);
    CHECK(snap[0].method == "rescore");
    CHECK(snap[0].elapsed_ms >= 750);
  }

  // 3) 绝不阻塞调用方：慢后端下 rescoreAsync 立即返回（<100ms）。
  {
    FakeAssist fake(1500ms);
    TimeoutAssist timed(fake, nullptr, 150ms);  // 缩短超时，快速收尾
    ResultWaiter w;
    const auto t0 = std::chrono::steady_clock::now();
    timed.rescoreAsync(AiContext{}, {{"一", 1.0, "wubi"}}, w.cb());
    const auto call_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                             std::chrono::steady_clock::now() - t0)
                             .count();
    CHECK(call_ms < 100);  // 调用方毫秒级脱身
    CHECK(w.wait(2000ms));
    CHECK(w.status == Status::kTimeout);
  }

  // 4) 自定义短超时：150ms 到点判负（窗口断言）。
  {
    FakeAssist fake(600ms);
    TimeoutAssist timed(fake, nullptr, 150ms);
    ResultWaiter w;
    timed.rescoreAsync(AiContext{}, {{"一", 1.0, "wubi"}}, w.cb());
    CHECK(w.wait(2000ms));
    CHECK(w.status == Status::kTimeout);
    CHECK(w.elapsedMs() >= 140 && w.elapsedMs() <= 600);
  }

  // 5) secure_input：直接 kDisabled，后端不被调用；审计记 kDisabled。
  {
    FakeAssist fake(0ms);
    MemoryAuditSink audit;
    TimeoutAssist timed(fake, &audit);
    AiContext secure;
    secure.secure_input = true;
    ResultWaiter w;
    timed.rescoreAsync(secure, {{"一", 1.0, "wubi"}}, w.cb());
    CHECK(w.counts() == 1);  // 拒绝类回调同步触发
    CHECK(w.status == Status::kDisabled);
    CHECK(fake.rescore_calls.load() == 0);  // 后端从未被调用
    auto snap = audit.snapshot();
    CHECK(snap.size() == 1 && snap[0].status == Status::kDisabled);
  }

  // 6) ingestAsync / correctAsync：快路径回调恰好一次。
  {
    FakeAssist fake(0ms);
    TimeoutAssist timed(fake, nullptr);
    std::mutex mu;
    std::condition_variable cv;
    int calls = 0;
    Status got = Status::kError;
    timed.ingestAsync(InteractionEvent{}, [&](Status st) {
      std::lock_guard<std::mutex> lock(mu);
      ++calls;
      got = st;
      cv.notify_all();
    });
    {
      std::unique_lock<std::mutex> lock(mu);
      CHECK(cv.wait_for(lock, 2000ms, [&] { return calls == 1; }));
      CHECK(got == Status::kOk);
    }
    ResultWaiter w;
    timed.correctAsync(AiContext{}, "tongzhi", w.cb());
    CHECK(w.wait(2000ms));
    CHECK(w.status == Status::kOk && w.data.size() == 1);
  }

  return testutil::Finish("test_timeout");
}
