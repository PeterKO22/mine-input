# ai_hub_client — mine-input 同步 SDK（W8）

C++17 + libcurl + SQLite3（均为 macOS/Xcode 自带），无其他依赖。对接
`hub/app/main.py`（W4 FastAPI Hub，W17 起默认走 HTTPS 边车 `https://localhost:8443`，
HTTP 明文回退 `http://localhost:8088` 仅本机）。

## TLS（W17）

- 默认 `base_url="https://localhost:8443"`，**按 CA 验证服务端**：
  `ClientConfig::ca_bundle = "<repo>/hub/tls/certs/ca.crt"`（自签 CA，`hub/tls/gen-certs.sh` 产物）；
  不设则用系统信任库（自签证书会被拒——这是预期，错误信息带修复提示）；
- `ClientConfig::tls_insecure = true` 跳过校验（**仅调试**）；
- HTTP 明文回退：`base_url="http://localhost:8088"`（无需任何 TLS 配置）；
- 环境变量（sync-demo / 单测真实 Hub 集成用）：
  `AI_HUB_URL`（默认 https://localhost:8443）、`AI_HUB_CA=<ca.pem>`、`AI_HUB_TLS_INSECURE=1`。

## 能力

| 模块 | 接口 | 语义 |
|---|---|---|
| auth | `register_user` / `login` / `whoami` | 注册返回每用户独立密钥分区（FR8）；login 自动保存 Bearer token |
| sync | `push` / `pull` | userdb **时间戳取新**、计数器**增量累加**、热词集合并、meta 取新；`push_id` 幂等，重发返回 `duplicate=true` 且不重复累加 |
| ingest | `ingest(InteractionEvent)` | 交互事件上行（字段对齐技术方案 §7/§8 契约） |
| suggest | `suggest(ctx, on_suggestion, on_done)` | SSE 流式，回调式逐帧消费（Candidate + done 事件） |
| 离线队列 | `OfflineQueue`（SQLite 文件队列） | 断网入队、联网 FIFO 补传、失败静默重试（attempts 留痕）；push 条目沿用原 `push_id` 保幂等 |

## 构建 / 测试 / demo

```bash
cd sdk
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j8
cd build && ctest --output-on-failure   # 单测（mock HTTP + 真实 Hub 集成自跳过）
./sync-demo                             # 验收 demo（默认 https://localhost:8443 + CA 自动探测；
                                        #   $AI_HUB_URL / $AI_HUB_CA / $AI_HUB_TLS_INSECURE 可覆盖）
```

## 用法摘录

```cpp
#include "ai_hub_client/ai_hub_client.h"
using namespace aihub;

ClientConfig cfg;
cfg.base_url = "https://localhost:8443";   // W17 默认 HTTPS
cfg.ca_bundle = "hub/tls/certs/ca.crt";    // 自签 CA（http:// 回退时无需）
cfg.device_id = "devA";
HubClient client(cfg);
client.login("user", "pass");

PushPayload p;
p.push_id = HubClient::make_push_id();      // 幂等键（空则自动生成）
p.userdb.push_back({"wubi/ni", "count=1", now_ms()});
p.counters["l2_pick"] = 3;                  // 增量，服务端累加
client.push(p);
auto state = client.pull(std::nullopt);     // 可传 since 做增量

client.suggest({"这件事", "app", false, "digest"},
               [](const Suggestion& s) { /* 逐帧 */ },
               [](const SuggestDone& d) { /* 收尾 */ });

// 离线：断网时入队，联网后补传
OfflineQueue q("/path/to/queue.db");
q.enqueue_push(p);                          // 或 q.enqueue_ingest(event)
q.flush(client);                            // 失败静默留队，下次再调
```

## 错误语义与超时（调用方侧建议）

- `Status::retryable()`：`Network` / `Timeout` / `Auth`（重登后可救）/ `Http 5xx|429|408`
  → 静默重试或入 `OfflineQueue`；其余 4xx（400/409/422…）为永久错误，重试无意义。
- **800ms 超时**（技术方案 v0.4 §7「超时 800ms 弃一轮」）：面向用户的 `suggest` 由调用方设
  `ClientConfig::suggest_budget_ms`（默认 800），超预算中断 SSE 流（已到帧仍经回调交付），
  返回 `Error::Timeout`；sync/ingest 走后台通道（默认 8s），失败由离线队列兜底。
- 线程模型：`HubClient` / `OfflineQueue` 非线程安全，单线程或外部加锁。

已知边界：`/v1/ingest` 服务端无幂等键，断点补传在「服务端已收但响应丢失」的极端情形下可能重复入库
（push 有 `push_id` 无此问题）；待 Hub 侧补 event_id 去重（记入 W8-REPORT 遗留）。
