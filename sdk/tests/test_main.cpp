// W8 sdk 单测入口。最后一组为「真实 Hub 集成」：AI_HUB_URL（默认
// https://localhost:8443，W17 起 HTTPS）不可达时自跳过，可达时跑最小回环
//（注册→token→whoami）。TLS：AI_HUB_CA=<ca.pem> 指定自签 CA，
// AI_HUB_TLS_INSECURE=1 跳过校验；HTTP 明文回退：AI_HUB_URL=http://localhost:8088。
#include <cstdio>
#include <cstdlib>
#include <string>

#include "ai_hub_client/ai_hub_client.h"
#include "testkit.h"

void run_json_tests();
void run_sse_tests();
void run_queue_tests();
void run_client_tests();

static void run_realhub_tests() {
  const char* url_env = std::getenv("AI_HUB_URL");
  std::string base = url_env ? url_env : "https://localhost:8443";
  std::printf("[real-hub] %s\n", base.c_str());

  aihub::ClientConfig cfg;
  cfg.base_url = base;
  cfg.connect_timeout_ms = 1500;
  cfg.request_timeout_ms = 3000;
  // TLS（W17）：AI_HUB_CA=<ca.pem>（自签 CA）；AI_HUB_TLS_INSECURE=1 仅调试
  if (const char* ca = std::getenv("AI_HUB_CA")) cfg.ca_bundle = ca;
  cfg.tls_insecure = std::getenv("AI_HUB_TLS_INSECURE") != nullptr;
  aihub::HubClient client(cfg);

  std::string user = "w8sdk-it-" + aihub::HubClient::make_push_id().substr(2, 10);
  auto reg = client.register_user(user, "w8sdk-pass-123");
  if (!reg.ok() && reg.status.code == aihub::Error::Network) {
    std::printf("  [SKIP] Hub 不可达（%s），跳过真实 Hub 集成测试\n",
                reg.status.message.c_str());
    return;
  }
  if (!reg.ok() && reg.status.code == aihub::Error::Timeout) {
    std::printf("  [SKIP] Hub 超时，跳过真实 Hub 集成测试\n");
    return;
  }
  CHECK(reg.ok());
  CHECK(reg.value.user_id > 0);
  CHECK(!reg.value.key_partition_id.empty());

  auto tok = client.login(user, "w8sdk-pass-123");
  CHECK(tok.ok());
  CHECK(!client.token().empty());

  auto who = client.whoami();
  CHECK(who.ok());
  if (who.ok()) CHECK_EQ(who.value.user_id, reg.value.user_id);
}

int main() {
  run_json_tests();
  run_sse_tests();
  run_queue_tests();
  run_client_tests();
  run_realhub_tests();

  std::printf("\n%d checks, %d failures\n", testkit::g_checks, testkit::g_failures);
  return testkit::g_failures == 0 ? 0 : 1;
}
