// HubClient 单测：打本地 mock HTTP（auth / push / pull / ingest / suggest SSE / 错误语义）。
#include <atomic>
#include <chrono>
#include <string>
#include <thread>
#include <vector>

#include "ai_hub_client/ai_hub_client.h"
#include "json.h"
#include "mock_http.h"
#include "testkit.h"

using namespace aihub;

namespace {

// 近似 hub/app/main.py 的桩 SSE 流
std::string stub_sse_body(const std::string& tail) {
  return "event: suggestion\ndata: {\"text\":\"" + tail +
         "——好的\",\"score\":0.86,\"source\":\"hub-stub\",\"seq\":1}\n\n"
         "event: suggestion\ndata: {\"text\":\"" + tail +
         "——请稍等\",\"score\":0.74,\"source\":\"hub-stub\",\"seq\":2}\n\n"
         "event: done\ndata: {\"status\":\"ok\",\"backend\":\"stub\",\"suggestions\":2,"
         "\"context_digest\":\"d1\"}\n\n";
}

}  // namespace

void run_client_tests() {
  std::printf("[client]\n");

  std::atomic<bool> auth_ok{false};
  std::string last_push_body;

  mockhttp::Server server([&](const mockhttp::Request& r) {
    mockhttp::Response resp;
    if (r.path == "/v1/auth/register") {
      if (r.body.find("\"username\":\"u1\"") == std::string::npos) {
        resp.status = 400;
        resp.body = "{\"detail\":\"bad\"}";
      } else {
        resp.status = 201;
        resp.body = "{\"user_id\":42,\"username\":\"u1\","
                    "\"key_partition\":{\"id\":\"kp_abc\",\"key\":\"kk\"},"
                    "\"created_at\":1793730000000}";
      }
    } else if (r.path == "/v1/auth/token") {
      resp.status = 200;
      resp.body = "{\"access_token\":\"tok-1\",\"token_type\":\"bearer\","
                  "\"expires_at\":1794331384,\"user_id\":42,"
                  "\"key_partition_id\":\"kp_abc\"}";
    } else if (r.path == "/v1/auth/whoami") {
      if (r.authorization == "Bearer tok-1") {
        auth_ok = true;
        resp.body = "{\"user_id\":42,\"username\":\"u1\","
                    "\"key_partition_id\":\"kp_abc\",\"created_at\":1}";
      } else {
        resp.status = 401;
        resp.body = "{\"detail\":\"invalid or expired token\"}";
      }
    } else if (r.path == "/v1/sync/push") {
      last_push_body = r.body;
      resp.body = "{\"status\":\"merged\",\"push_id\":\"P1\",\"duplicate\":false,"
                  "\"applied\":{\"userdb_upserted\":1,\"userdb_kept\":1,"
                  "\"hotwords_added\":2,\"meta_updated\":1,"
                  "\"counters_now\":{\"l2_pick\":7}}}";
    } else if (r.path == "/v1/sync/pull") {
      resp.body = "{\"server_time\":1793730001000,"
                  "\"userdb\":[{\"key\":\"wubi/ni\",\"value\":\"new\","
                  "\"updated_at\":2000,\"device_id\":\"devB\"}],"
                  "\"counters\":{\"l2_pick\":7},\"hotwords\":[\"五笔\"],"
                  "\"ai_config\":{\"updated_at\":1000,"
                  "\"value\":{\"model\":\"7b-q4\"}},"
                  "\"schema_version\":{\"updated_at\":1000,"
                  "\"value\":\"ping_wubi_mixed@1\"}}";
    } else if (r.path == "/v1/ingest") {
      resp.status = 201;
      resp.body = "{\"status\":\"stored\",\"event_id\":9,\"kind\":\"key_session\","
                  "\"ts\":1793730000000}";
    } else if (r.path == "/v1/suggest") {
      resp.content_type = "text/event-stream";
      resp.body = stub_sse_body("tail");
    } else if (r.path == "/v1/err503") {
      resp.status = 503;
      resp.body = "{\"detail\":\"busy\"}";
    } else if (r.path == "/v1/err422") {
      resp.status = 422;
      resp.body = "{\"detail\":\"invalid\"}";
    }
    return resp;
  });

  ClientConfig cfg;
  cfg.base_url = server.base_url();
  cfg.device_id = "devA";
  HubClient client(cfg);

  // ---- auth：注册 + 登录 + whoami（Bearer 透传）
  auto reg = client.register_user("u1", "pass-123");
  CHECK(reg.ok());
  CHECK_EQ(reg.value.user_id, 42);
  CHECK_STREQ(reg.value.key_partition_id, "kp_abc");
  CHECK_STREQ(reg.value.key_partition_key, "kk");

  auto tok = client.login("u1", "pass-123");
  CHECK(tok.ok());
  CHECK_STREQ(tok.value.access_token, "tok-1");
  CHECK_STREQ(client.token(), "tok-1");  // login 自动保存

  auto who = client.whoami();
  CHECK(who.ok());
  CHECK(auth_ok.load());
  CHECK_EQ(who.value.user_id, 42);

  // ---- push：载荷序列化（userdb/counters/hotwords/meta）+ 结果解析
  PushPayload p;
  p.push_id = "P1";
  p.userdb.push_back({"wubi/ni", "count=1", 1000});
  p.counters["l2_pick"] = 3;
  p.hotwords = {"五笔", "mine-input"};
  MetaValue meta;
  meta.updated_at = 1000;
  meta.value_json = "{\"model\":\"7b-q4\",\"enabled\":false}";
  p.ai_config = meta;
  auto push = client.push(p);
  CHECK(push.ok());
  CHECK(!push.value.duplicate);
  CHECK_EQ(push.value.userdb_upserted, 1);
  CHECK_EQ(push.value.userdb_kept, 1);
  CHECK_EQ(push.value.counters_now["l2_pick"], 7);
  // 请求体核验
  CHECK(last_push_body.find("\"push_id\":\"P1\"") != std::string::npos);
  CHECK(last_push_body.find("\"device_id\":\"devA\"") != std::string::npos);  // cfg 补默认
  CHECK(last_push_body.find("\"l2_pick\":3") != std::string::npos);
  CHECK(last_push_body.find("五笔") != std::string::npos);

  // ---- pull：合并态解析（取新/累加/热词/meta）
  auto pull = client.pull(std::nullopt);
  CHECK(pull.ok());
  CHECK_EQ(pull.value.userdb.size(), 1u);
  if (!pull.value.userdb.empty()) {
    CHECK_STREQ(pull.value.userdb[0].value, "new");
    CHECK_EQ(pull.value.userdb[0].updated_at, 2000);
  }
  CHECK_EQ(pull.value.counters["l2_pick"], 7);
  CHECK_EQ(pull.value.hotwords.size(), 1u);
  CHECK(pull.value.ai_config.has_value());
  CHECK(pull.value.schema_version.has_value());

  // ---- ingest：合法 + 客户端侧校验
  InteractionEvent ev;
  ev.ts = 1793730000000LL;
  ev.kind = "key_session";
  ev.text_in = "nihao";
  ev.suggestion_shown = 3;
  auto ing = client.ingest(ev);
  CHECK(ing.ok());
  CHECK_EQ(ing.value.event_id, 9);

  InteractionEvent bad = ev;
  bad.kind = "no_such_kind";
  auto ing_bad = client.ingest(bad);
  CHECK(!ing_bad.ok());
  CHECK(ing_bad.status.code == Error::InvalidArgument);

  // ---- suggest SSE：回调式多帧消费
  {
    std::vector<Suggestion> got;
    SuggestDone done;
    bool has_done = false;
    SuggestContext ctx;
    ctx.before_cursor = "tail";
    ctx.context_digest = "d1";
    auto st = client.suggest(
        ctx, [&](const Suggestion& s) { got.push_back(s); },
        [&](const SuggestDone& d) { done = d; has_done = true; });
    CHECK(st.ok());
    CHECK_EQ(got.size(), 2u);
    if (got.size() == 2) {
      CHECK_STREQ(got[0].text, "tail——好的");
      CHECK_EQ(got[0].seq, 1);
      CHECK_EQ(got[1].score, 0.74);
    }
    CHECK(has_done);
    CHECK_EQ(done.suggestions, 2);
    CHECK_STREQ(done.context_digest, "d1");
  }

  // ---- 错误语义：retryable 映射
  {
    // 直接打 mock 的错误路径（借 suggest/push 的 URL 不便，这里用 push 到 err 路径不行——
    // 改用 curl 层分类由 http_status 驱动：构造 503/422/401 响应验证分类）
    HubClient c503(cfg);
    c503.set_token("t");
    // push 到 mock 的 /v1/err503：借用 server 的路径路由——把 base_url 指到错误端点不行，
    // 因此直接校验 Status::retryable() 语义表：
    Status s503; s503.code = Error::Http; s503.http_status = 503;
    CHECK(s503.retryable());
    Status s429; s429.code = Error::Http; s429.http_status = 429;
    CHECK(s429.retryable());
    Status s422; s422.code = Error::Http; s422.http_status = 422;
    CHECK(!s422.retryable());
    Status s401; s401.code = Error::Auth; s401.http_status = 401;
    CHECK(s401.retryable());
    Status sNet; sNet.code = Error::Network;
    CHECK(sNet.retryable());
    Status sParse; sParse.code = Error::Parse;
    CHECK(!sParse.retryable());
  }

  // ---- suggest 预算（800ms 语义）：慢桩 → Error::Timeout，预算内返回
  {
    mockhttp::Server slow([](const mockhttp::Request&) {
      std::this_thread::sleep_for(std::chrono::milliseconds(1500));
      mockhttp::Response resp;
      resp.content_type = "text/event-stream";
      resp.body = "event: done\ndata: {\"status\":\"ok\"}\n\n";
      return resp;
    });
    ClientConfig slow_cfg;
    slow_cfg.base_url = slow.base_url();
    slow_cfg.suggest_budget_ms = 200;  // 压缩预算做单测
    HubClient slow_client(slow_cfg);
    slow_client.set_token("t");
    auto t0 = std::chrono::steady_clock::now();
    auto st = slow_client.suggest(SuggestContext{}, [](const Suggestion&) {},
                                  [](const SuggestDone&) {});
    auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
                       std::chrono::steady_clock::now() - t0)
                       .count();
    CHECK(!st.ok());
    CHECK(st.code == Error::Timeout);
    CHECK(st.retryable());
    CHECK(elapsed < 1000);  // 预算 200ms 弃一轮，不等慢桩 1.5s
  }
}
