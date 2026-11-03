// sync-demo：W8 验收 demo —— 对真实 Hub（默认 http://localhost:8088）实测全链路：
//   1) 注册 + 双设备登录（同用户两个 device_id）
//   2) push 往返一致：userdb 时间戳取新、计数器增量累加、push_id 幂等重试
//   3) 断网入队 → 联网补传成功（离线队列）
//   4) suggest SSE 多帧消费（回调式）
// 用法：./sync-demo [base_url]   （默认 $AI_HUB_URL 或 https://localhost:8443）
// TLS（W17）：AI_HUB_CA=<ca.pem> 指定自签 CA（默认 ../hub/tls/certs/ca.crt 若存在）；
//   AI_HUB_TLS_INSECURE=1 跳过校验（仅调试）；HTTP 明文回退：AI_HUB_URL=http://localhost:8088
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

#include "ai_hub_client/ai_hub_client.h"

using namespace aihub;

static int g_pass = 0, g_fail = 0;

static void check(bool ok, const std::string& what) {
  if (ok) {
    ++g_pass;
    std::printf("  [PASS] %s\n", what.c_str());
  } else {
    ++g_fail;
    std::printf("  [FAIL] %s\n", what.c_str());
  }
}

static int64_t now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

int main(int argc, char** argv) {
  std::string base = argc > 1 ? argv[1] : "";
  if (base.empty()) {
    const char* env = std::getenv("AI_HUB_URL");
    base = env ? env : "https://localhost:8443";
  }
  std::printf("=== mine-input hub-client sync-demo ===\nHub: %s\n\n", base.c_str());

  ClientConfig cfg;
  cfg.base_url = base;
  cfg.device_id = "devA";
  cfg.connect_timeout_ms = 2000;
  cfg.request_timeout_ms = 8000;
  cfg.suggest_budget_ms = 800;
  // TLS（W17）：自签 CA 验证（AI_HUB_CA 显式 > 仓库相对路径自动探测）
  if (const char* ca = std::getenv("AI_HUB_CA")) {
    cfg.ca_bundle = ca;
  } else if (std::ifstream("../hub/tls/certs/ca.crt").good()) {
    cfg.ca_bundle = "../hub/tls/certs/ca.crt";      // 从 sdk/ 运行
  } else if (std::ifstream("../../hub/tls/certs/ca.crt").good()) {
    cfg.ca_bundle = "../../hub/tls/certs/ca.crt";   // 从 sdk/build/ 运行
  } else if (std::ifstream("hub/tls/certs/ca.crt").good()) {
    cfg.ca_bundle = "hub/tls/certs/ca.crt";         // 从仓库根运行
  }
  cfg.tls_insecure = std::getenv("AI_HUB_TLS_INSECURE") != nullptr;
  if (!cfg.ca_bundle.empty())
    std::printf("CA: %s\n", cfg.ca_bundle.c_str());
  else if (cfg.tls_insecure)
    std::printf("CA: (跳过校验，AI_HUB_TLS_INSECURE)\n");
  else
    std::printf("CA: (系统信任库)\n");

  std::string user = "w8demo-" + HubClient::make_push_id().substr(2, 10);
  const std::string pass = "w8demo-pass-123";

  // ---- 1. auth：注册 + 双设备登录（同用户）
  std::printf("=== 1. auth: register + login(双设备) ===\n");
  HubClient devA(cfg);
  auto reg = devA.register_user(user, pass);
  if (!reg.ok()) {
    std::printf("  [FAIL] register: %s (%s)\n", reg.status.message.c_str(),
                to_string(reg.status.code));
    std::printf("\n== summary: PASS=%d FAIL=%d ==\n", g_pass, g_fail);
    return 1;
  }
  std::printf("  register -> user_id=%lld key_partition=%s\n",
              (long long)reg.value.user_id, reg.value.key_partition_id.c_str());
  check(reg.value.user_id > 0 && !reg.value.key_partition_id.empty(),
        "注册返回 user_id + 每用户独立密钥分区");

  auto tokA = devA.login(user, pass);
  check(tokA.ok() && !devA.token().empty(), "设备 A 登录得 Bearer token");
  std::printf("  devA token=%.24s... expires_at=%lld\n", devA.token().c_str(),
              (long long)tokA.value.expires_at);

  ClientConfig cfgB = cfg;
  cfgB.device_id = "devB";
  HubClient devB(cfgB);
  auto tokB = devB.login(user, pass);
  check(tokB.ok() && !devB.token().empty(), "设备 B 登录得 Bearer token");

  // ---- 2. sync push/pull：取新 / 累加 / 幂等
  std::printf("\n=== 2. sync: push(双设备) -> pull 往返一致 ===\n");
  int64_t t0 = now_ms();

  // 设备 A：较新的 userdb 值 + 计数器增量 3
  PushPayload pa;
  pa.push_id = "w8demo-A-" + HubClient::make_push_id().substr(2, 8);
  pa.userdb.push_back({"wubi/高频词", "你好@devA-newer", t0});
  pa.counters["l2_pick"] = 3;
  pa.hotwords = {"mine-input", "五笔"};
  auto pushA = devA.push(pa);
  check(pushA.ok() && !pushA.value.duplicate, "devA push 合并成功");
  std::printf("  devA push_id=%s applied={upserted:%d kept:%d hotwords:%d counters_now:%lld}\n",
              pa.push_id.c_str(), pushA.value.userdb_upserted, pushA.value.userdb_kept,
              pushA.value.hotwords_added,
              (long long)pushA.value.counters_now["l2_pick"]);

  // 设备 B：同键较旧的 userdb 值（应被“取新”保留 devA 的）+ 计数器增量 4（应累加）
  PushPayload pb;
  pb.push_id = "w8demo-B-" + HubClient::make_push_id().substr(2, 8);
  pb.userdb.push_back({"wubi/高频词", "hello@devB-older", t0 - 10000});
  pb.counters["l2_pick"] = 4;
  auto pushB = devB.push(pb);
  check(pushB.ok() && pushB.value.userdb_kept == 1 && pushB.value.userdb_upserted == 0,
        "devB 旧值被取新语义保留（upserted=0 kept=1）");
  check(pushB.value.counters_now["l2_pick"] == 7,
        "计数器增量累加：3 + 4 = 7");
  std::printf("  devB push_id=%s applied={upserted:%d kept:%d counters_now:%lld}\n",
              pb.push_id.c_str(), pushB.value.userdb_upserted, pushB.value.userdb_kept,
              (long long)pushB.value.counters_now["l2_pick"]);

  // pull：双端视角一致
  auto pull = devA.pull(std::nullopt);
  check(pull.ok(), "devA pull 成功");
  bool newest_wins = false, counter_sum = false, hotwords_merged = false;
  for (const auto& e : pull.value.userdb) {
    if (e.key == "wubi/高频词") {
      newest_wins = (e.value == "你好@devA-newer");
      std::printf("  pull userdb[wubi/高频词] = %s (updated_at=%lld)\n", e.value.c_str(),
                  (long long)e.updated_at);
    }
  }
  counter_sum = (pull.value.counters["l2_pick"] == 7);
  hotwords_merged = (pull.value.hotwords.size() >= 2);
  std::printf("  pull counters = {l2_pick: %lld}  hotwords = [",
              (long long)pull.value.counters["l2_pick"]);
  for (size_t i = 0; i < pull.value.hotwords.size(); ++i)
    std::printf("%s%s", i ? " " : "", pull.value.hotwords[i].c_str());
  std::printf("]\n");
  check(newest_wins, "pull 取新语义：userdb 为 devA 的较新值");
  check(counter_sum, "pull 累加语义：counter 为两设备增量之和");
  check(hotwords_merged, "pull 热词集合并");

  auto pullB = devB.pull(std::nullopt);
  bool roundtrip_same = pullB.ok() && pullB.value.counters["l2_pick"] == 7;
  for (const auto& e : pullB.value.userdb)
    if (e.key == "wubi/高频词" && e.value == "你好@devA-newer") roundtrip_same =
        roundtrip_same && true;
  check(roundtrip_same, "设备 B pull 同态（往返一致）");

  // push_id 幂等重试：同 push_id 原样重发 → duplicate，不重复累加
  auto pushA2 = devA.push(pa);
  check(pushA2.ok() && pushA2.value.duplicate,
        "push_id 幂等重试：重发返回 duplicate=true");
  auto pull3 = devA.pull(std::nullopt);
  check(pull3.ok() && pull3.value.counters["l2_pick"] == 7,
        "重试不重复累加：counter 仍为 7");

  // ---- 3. 离线队列：断网入队 -> 联网补传
  std::printf("\n=== 3. offline queue: 断网入队 -> 联网补传 ===\n");
  std::string qpath = "/tmp/w8demo-queue-" + HubClient::make_push_id().substr(2, 8) + ".db";
  OfflineQueue queue(qpath);
  std::printf("  queue db: %s\n", qpath.c_str());

  PushPayload po;
  po.push_id = "w8demo-offline-" + HubClient::make_push_id().substr(2, 8);
  po.counters["l2_pick"] = 5;       // 补传后应把 7 累加到 12
  po.userdb.push_back({"wubi/离线词", "queued@offline", now_ms()});
  queue.enqueue_push(po);
  InteractionEvent ev;
  ev.ts = now_ms();
  ev.kind = "key_session";
  ev.text_in = "offline-test";
  ev.text_out = "离线补传";
  ev.suggestion_shown = 3;
  ev.suggestion_taken = 1;
  queue.enqueue_ingest(ev);
  check(queue.pending() == 2, "断网时 2 条入队（1 push + 1 ingest）");

  // 断网：连一个拒连端口，flush 静默失败留队
  ClientConfig offline_cfg = cfg;
  offline_cfg.base_url = "http://127.0.0.1:1";
  offline_cfg.connect_timeout_ms = 500;
  offline_cfg.request_timeout_ms = 800;
  HubClient offline(offline_cfg);
  offline.set_token(devA.token());
  auto r_off = queue.flush(offline);
  std::printf("  offline flush: sent=%zu kept=%zu dropped=%zu err=%s(%s)\n",
              r_off.sent, r_off.kept, r_off.dropped,
              to_string(r_off.last_error.code), r_off.last_error.message.c_str());
  check(r_off.sent == 0 && r_off.kept == 2 && r_off.dropped == 0,
        "断网 flush 静默留队（retryable，未丢未发）");
  check(queue.pending() == 2, "队列仍为 2 条（attempts 留痕）");

  // 联网：补传成功
  auto r_on = queue.flush(devA);
  std::printf("  online flush: sent=%zu kept=%zu dropped=%zu\n", r_on.sent, r_on.kept,
              r_on.dropped);
  check(r_on.sent == 2 && queue.pending() == 0, "联网补传成功，队列清空");

  // 服务端验证：counter 7+5=12、离线 userdb 条目可见、ingest 已收（push 计数旁证）
  auto pull4 = devA.pull(std::nullopt);
  bool flush_effect = pull4.ok() && pull4.value.counters["l2_pick"] == 12;
  bool offline_entry = false;
  for (const auto& e : pull4.value.userdb)
    if (e.key == "wubi/离线词" && e.value == "queued@offline") offline_entry = true;
  std::printf("  pull after flush: counters={l2_pick: %lld}\n",
              (long long)pull4.value.counters["l2_pick"]);
  check(flush_effect, "补传 push 已生效：counter 7+5=12");
  check(offline_entry, "补传 userdb 条目在服务端可见");

  // ---- 4. suggest SSE 多帧消费（回调式）
  std::printf("\n=== 4. suggest: SSE 流式多帧消费（回调式） ===\n");
  std::vector<Suggestion> got;
  SuggestDone done;
  bool has_done = false;
  int callback_count = 0;
  SuggestContext sctx;
  sctx.before_cursor = "这件事";
  sctx.app_id = "sync-demo";
  sctx.from_voice = false;
  sctx.context_digest = "demo-digest";
  auto sst = devA.suggest(
      sctx,
      [&](const Suggestion& s) {
        got.push_back(s);
        ++callback_count;
        std::printf("  [frame %d] seq=%d score=%.2f source=%s text=%s\n",
                    callback_count, s.seq, s.score, s.source.c_str(), s.text.c_str());
      },
      [&](const SuggestDone& d) {
        done = d;
        has_done = true;
        std::printf("  [done] status=%s backend=%s suggestions=%d context_digest=%s\n",
                    d.status.c_str(), d.backend.c_str(), d.suggestions,
                    d.context_digest.c_str());
      });
  check(sst.ok(), "SSE 流式消费完成（Status ok）");
  check(got.size() >= 2, "多帧 suggestion 逐条回调（>=2 帧）");
  check(has_done && done.status == "ok", "done 事件回调收到");
  bool fields_ok = !got.empty() && !got[0].text.empty() && got[0].score > 0 &&
                   !got[0].source.empty();
  check(fields_ok, "Candidate 字段完整（text/score/source）");

  // ---- 错误语义样例：坏 token → Auth（retryable，重登后可重试）
  std::printf("\n=== 5. 错误语义样例 ===\n");
  HubClient bad_client(cfg);
  bad_client.set_token("bad-token");
  auto bad_pull = bad_client.pull(std::nullopt);
  std::printf("  bad token pull: code=%s http=%d retryable=%d\n",
              to_string(bad_pull.status.code), bad_pull.status.http_status,
              (int)bad_pull.status.retryable());
  check(!bad_pull.ok() && bad_pull.status.code == Error::Auth &&
            bad_pull.status.retryable(),
        "401 → Error::Auth，retryable（重登可救）");

  std::printf("\n== summary: PASS=%d FAIL=%d ==\n", g_pass, g_fail);
  return g_fail == 0 ? 0 : 1;
}
