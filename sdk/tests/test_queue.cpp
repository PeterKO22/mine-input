// 离线队列测试：断网入队 → 联网补传 → 失败留队重试（push_id 幂等沿用）→ 永久错误丢弃。
#include <cstdio>
#include <string>
#include <vector>

#include "ai_hub_client/ai_hub_client.h"
#include "json.h"
#include "mock_http.h"
#include "testkit.h"

using namespace aihub;

namespace {

std::string tmp_db(const char* name) {
  std::string path = std::string("/tmp/w8_sdk_test_") + name + ".db";
  unlink(path.c_str());  // 每次干净起步
  return path;
}

}  // namespace

void run_queue_tests() {
  std::printf("[offline_queue]\n");

  // ---- 场景 1：断网入队（pending 计数 + 静默）
  {
    OfflineQueue q(tmp_db("q1"));
    PushPayload p;
    p.device_id = "devA";
    p.push_id = "P-fixed-001";
    p.userdb.push_back({"wubi/ni", "count=1", 1000});
    p.counters["l2_pick"] = 3;
    CHECK(q.enqueue_push(p).ok());

    InteractionEvent ev;
    ev.ts = 1793730000000LL;
    ev.kind = "key_session";
    ev.text_in = "nihao";
    CHECK(q.enqueue_ingest(ev).ok());
    CHECK_EQ(q.pending(), 2u);

    // 断网：目标端口拒连
    ClientConfig cfg;
    cfg.base_url = "http://127.0.0.1:1";
    cfg.connect_timeout_ms = 300;
    cfg.request_timeout_ms = 500;
    HubClient offline(cfg);
    auto report = q.flush(offline);
    CHECK_EQ(report.sent, 0u);
    CHECK_EQ(report.kept, 2u);
    CHECK_EQ(report.dropped, 0u);
    CHECK(report.last_error.retryable());
    CHECK_EQ(q.pending(), 2u);
    // attempts 留痕
    auto items = q.items();
    CHECK_EQ(items.size(), 2u);
    if (items.size() == 2) {
      CHECK_EQ(items[0].attempts, 1);
      CHECK_STREQ(items[0].push_id, "P-fixed-001");
    }
  }

  // ---- 场景 2：联网补传成功（push_id 沿用、载荷保真、清空队列）
  {
    std::vector<std::string> seen_push_ids;
    std::vector<std::string> seen_paths;
    std::string last_push_body;
    mockhttp::Server server([&](const mockhttp::Request& r) {
      seen_paths.push_back(r.path);
      mockhttp::Response resp;
      if (r.path == "/v1/sync/push") {
        last_push_body = r.body;
        aihub::json::Value v;
        std::string err;
        aihub::json::Value::parse(r.body, v, err);
        seen_push_ids.push_back(v.find("push_id")->as_string());
        resp.status = 200;
        resp.body =
            "{\"status\":\"merged\",\"push_id\":\"" + seen_push_ids.back() +
            "\",\"duplicate\":false,\"applied\":{\"userdb_upserted\":1,"
            "\"userdb_kept\":0,\"hotwords_added\":0,\"meta_updated\":0,"
            "\"counters_now\":{\"l2_pick\":3}}}";
      } else if (r.path == "/v1/ingest") {
        resp.status = 201;
        resp.body = "{\"status\":\"stored\",\"event_id\":7,\"kind\":\"key_session\","
                    "\"ts\":1793730000000}";
      }
      return resp;
    });

    OfflineQueue q(tmp_db("q2"));
    PushPayload p;
    p.device_id = "devA";
    p.push_id = "P-fixed-002";
    p.userdb.push_back({"wubi/ni", "count=1", 1000});
    p.counters["l2_pick"] = 3;
    q.enqueue_push(p);
    InteractionEvent ev;
    ev.ts = 1793730000000LL;
    ev.kind = "key_session";
    ev.text_in = "nihao";
    q.enqueue_ingest(ev);
    CHECK_EQ(q.pending(), 2u);

    ClientConfig cfg;
    cfg.base_url = server.base_url();
    HubClient online(cfg);
    online.set_token("tok");
    auto report = q.flush(online);
    CHECK_EQ(report.sent, 2u);
    CHECK_EQ(report.kept, 0u);
    CHECK_EQ(report.dropped, 0u);
    CHECK_EQ(q.pending(), 0u);
    // push_id 幂等键原样补传（服务端可去重）
    CHECK_EQ(seen_push_ids.size(), 1u);
    if (!seen_push_ids.empty()) CHECK_STREQ(seen_push_ids[0], "P-fixed-002");
    // 载荷保真：counters / userdb 都在
    CHECK(last_push_body.find("\"l2_pick\":3") != std::string::npos);
    CHECK(last_push_body.find("wubi/ni") != std::string::npos);
  }

  // ---- 场景 3：5xx 失败留队（attempts++），恢复后补传成功
  {
    std::atomic<int> hits{0};
    mockhttp::Server server([&](const mockhttp::Request& r) {
      int n = hits.fetch_add(1);
      mockhttp::Response resp;
      if (n == 0) {
        resp.status = 503;
        resp.body = "{\"detail\":\"busy\"}";
      } else {
        resp.status = 200;
        resp.body =
            "{\"status\":\"merged\",\"push_id\":\"x\",\"duplicate\":false,"
            "\"applied\":{\"userdb_upserted\":0,\"userdb_kept\":1,"
            "\"hotwords_added\":0,\"meta_updated\":0,\"counters_now\":{}}}";
      }
      return resp;
    });

    OfflineQueue q(tmp_db("q3"));
    PushPayload p;
    p.push_id = "P-retry";
    p.counters["c"] = 1;
    q.enqueue_push(p);

    ClientConfig cfg;
    cfg.base_url = server.base_url();
    HubClient client(cfg);
    client.set_token("tok");

    auto r1 = q.flush(client);
    CHECK_EQ(r1.sent, 0u);
    CHECK_EQ(r1.kept, 1u);
    CHECK(r1.last_error.retryable());
    CHECK_EQ(q.pending(), 1u);
    CHECK_EQ(q.items()[0].attempts, 1);

    auto r2 = q.flush(client);
    CHECK_EQ(r2.sent, 1u);
    CHECK_EQ(q.pending(), 0u);
  }

  // ---- 场景 4：永久 4xx 丢弃（不死循环）
  {
    mockhttp::Server server([](const mockhttp::Request&) {
      mockhttp::Response resp;
      resp.status = 422;
      resp.body = "{\"detail\":\"invalid kind\"}";
      return resp;
    });

    OfflineQueue q(tmp_db("q4"));
    InteractionEvent ev;
    ev.ts = 1;
    ev.kind = "key_session";
    q.enqueue_ingest(ev);
    q.enqueue_ingest(ev);

    ClientConfig cfg;
    cfg.base_url = server.base_url();
    HubClient client(cfg);
    client.set_token("tok");
    auto r = q.flush(client);
    CHECK_EQ(r.sent, 0u);
    CHECK_EQ(r.kept, 0u);
    CHECK_EQ(r.dropped, 2u);
    CHECK_EQ(q.pending(), 0u);
  }
}
