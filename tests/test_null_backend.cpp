// test_null_backend.cpp — Null 空后端行为 + 审计桩（只记字段不记全文）
#include <string>
#include <vector>

#include "ai/audit/audit_stub.h"
#include "ai/backends/null/null_ai_assist.h"
#include "ai/spi/timeout_assist.h"
#include "test_assert.h"

using namespace mine::ai;

int main() {
  NullAiAssist backend;
  AiContext ctx;

  // rescore：候选原样返回（顺序/文本不变），kOk。
  {
    std::vector<Candidate> cands = {
        {"一", 0.9, "wubi"}, {"二", 0.5, "pinyin"}, {"三", 0.2, "pinyin"}};
    CHECK(backend.rescore(ctx, cands) == Status::kOk);
    CHECK(cands.size() == 3);
    CHECK(cands[0].text == "一" && cands[1].text == "二" && cands[2].text == "三");
  }

  // complete：无续写，out 清空后为空。
  {
    std::vector<Candidate> out = {{"junk", 1.0, "junk"}};
    CHECK(backend.complete(ctx, "ni", out) == Status::kOk);
    CHECK(out.empty());
  }

  // correct：不纠错，原文作为唯一候选回传（恒等）。
  {
    std::vector<Candidate> out;
    CHECK(backend.correct(ctx, "tongzhi", out) == Status::kOk);
    CHECK(out.size() == 1);
    CHECK(out[0].text == "tongzhi");
    CHECK(out[0].source == "null");
  }

  // suggest：恰好一次 kDone 终止、无增量（流式完成语义的空后端基线）。
  {
    int deltas = 0;
    int terminals = 0;
    StreamStatus last = StreamStatus::kDelta;
    CHECK(backend.suggest(ctx, [&](const SuggestUpdate& up) {
            if (up.status == StreamStatus::kDelta) {
              ++deltas;
            } else {
              ++terminals;
              last = up.status;
            }
          }) == Status::kOk);
    CHECK(deltas == 0);
    CHECK(terminals == 1);
    CHECK(last == StreamStatus::kDone);
  }

  // ingest：接收并丢弃，kOk。
  {
    InteractionEvent ev;
    ev.timestamp_ms = 1762300000000LL;
    ev.type = InteractionEventType::kCommit;
    CHECK(backend.ingest(ev) == Status::kOk);
  }

  // secure_input（密码框/支付）：全部直接 kDisabled，不做任何处理。
  {
    AiContext secure;
    secure.secure_input = true;
    std::vector<Candidate> untouched = {{"keep", 1.0, "pre"}};
    CHECK(backend.rescore(secure, untouched) == Status::kDisabled);
    CHECK(untouched.size() == 1 && untouched[0].text == "keep");  // 未被处理
    std::vector<Candidate> out;
    CHECK(backend.complete(secure, "x", out) == Status::kDisabled);
    CHECK(out.empty());
    CHECK(backend.correct(secure, "y", out) == Status::kDisabled);
    CHECK(out.empty());
    int calls = 0;
    CHECK(backend.suggest(secure, [&](const SuggestUpdate&) { ++calls; }) ==
          Status::kDisabled);
    CHECK(calls == 0);  // 未受理：不触发回调
  }

  // 审计桩：只记字段（方法名/计数/耗时/状态），结构上无全文。
  {
    MemoryAuditSink audit(4);
    AuditRecord rec;
    rec.method = "rescore";
    rec.level = ContextLevel::kC0;
    rec.input_count = 3;
    rec.output_count = 3;
    rec.elapsed_ms = 12;
    rec.status = Status::kOk;
    audit.record(rec);
    CHECK(audit.size() == 1);
    auto snap = audit.snapshot();
    CHECK(snap.size() == 1);
    CHECK(snap[0].method == "rescore");
    CHECK(snap[0].input_count == 3 && snap[0].output_count == 3);
    CHECK(snap[0].elapsed_ms == 12 && snap[0].status == Status::kOk);
    // 环形容量：写满后丢最旧
    audit.record(rec);
    audit.record(rec);
    audit.record(rec);
    audit.record(rec);
    CHECK(audit.size() == 4);
  }

  return testutil::Finish("test_null_backend");
}
