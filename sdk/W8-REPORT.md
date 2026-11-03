# W8 hub-client 车道报告

> 车道：W8 hub-client（`sdk/` 目录）｜Wave 2｜日期：2026-11-04
> 依据：docs/开发任务计划.md §2 W8 规格 + §3 工作约定 ｜ docs/技术方案-v0.4.md §7.2（契约即协议）/ §7（800ms 超时）/ §9（同步合并）｜ API 实现为准：hub/app/main.py + hub/app/db.py（W4）

## 1. 做了什么

`ai_hub_client` 静态库（**C++17 + libcurl + SQLite3，均为 macOS/Xcode 自带，零第三方依赖**），只写 `sdk/`：

| 交付 | 文件 | 说明 |
|---|---|---|
| 公共 API | `include/ai_hub_client/ai_hub_client.h` | `HubClient` + `OfflineQueue` + 数据模型 + `Status/Result` 错误语义 |
| auth | `src/client.cpp` | `register_user`（返回每用户独立密钥分区 FR8）/ `login`（token 自动保存）/ `whoami` |
| sync push/pull | `src/client.cpp` | userdb 时间戳取新、计数器增量累加、热词集合并、meta 取新；**push_id 幂等**（自动生成或调用方指定，重发 `duplicate=true` 不重复累加）；pull 支持 `since` 增量 |
| ingest | `src/client.cpp` | `InteractionEvent` 上行（ts/device_id/app_id/kind/text_in/text_out/ocr_digest?/asr_digest?/keystroke_cadence?/suggestion_shown?/suggestion_taken?），kind 枚举客户端侧预校验 |
| suggest SSE | `src/client.cpp` + `src/sse.cpp` | POST `/v1/suggest` 流式消费，**回调式**逐帧交付（`on_suggestion` 每帧 Candidate + `on_done` 收尾）；增量帧解析器（任意碎片粒度、`\r\n` 兼容、多行 data） |
| 离线队列 | `src/offline_queue.cpp` | **SQLite 文件队列**：断网入队（push/ingest）、联网 FIFO 补传、失败静默重试（attempts 留痕）；push 条目持久化原 push_id 保幂等；可重试错误留队即停（保序），永久 4xx 丢弃防死循环 |
| HTTP 层 | `src/http.cpp` | libcurl 封装：Bearer 透传、connect/整体超时、SSE 流式块回调、预算中断（xferinfo deadline） |
| JSON | `src/json.h/.cpp` | 自研极简 JSON（含 `\uXXXX`/代理对/大整数精确往返），避免引第三方 |
| 单测 | `tests/`（mock_http.h + 4 组测试 + 入口） | **本地 mock HTTP**（裸 socket 线程服务器）覆盖 auth/push/pull/ingest/suggest/错误语义/队列 4 场景/SSE 碎片化/预算超时；另含真实 Hub 集成（不可达自跳过） |
| 验收 demo | `sync-demo/main.cpp` | 对真实 Hub 全链路实测（见 §2） |

### 错误语义与 800ms 超时建议（调用方侧）

- `Status::retryable()`：`Network` / `Timeout` / `Auth`（重登后可救）/ `Http 5xx|429|408` → 静默重试或入离线队列；其余 4xx（400/409/422…）永久错误，不上报重试。
- **800ms**（技术方案 §7「超时 800ms 弃一轮」）：面向用户的 `suggest` 总预算由调用方设 `ClientConfig::suggest_budget_ms`（默认 800），超时中断 SSE 流、已到帧仍经回调交付，返回 `Error::Timeout`；sync/ingest 为后台通道（默认 8s），失败由离线队列兜底，不受 800ms 约束。单测实证预算内中断（预算 200ms 对 1.5s 慢桩）。

## 2. 怎么验证（实测）

环境：macOS arm64，Apple clang 21.0.0，CMake 4.3.3；Hub 容器 `mine-input-hub` @ `http://localhost:8088`（8080 被占，沿用 W4 结论）。

### 构建 + 单测（mock HTTP + 真实 Hub 集成）

```bash
$ cd sdk && cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j8
[100%] Built target sync-demo / sdk_tests（零警告通过）

$ cd build && ctest --output-on-failure
    Start 1: sdk_tests
1/1 Test #1: sdk_tests ........................   Passed    1.58 sec
100% tests passed, 0 tests failed out of 1

$ ./sdk_tests
[json]
[sse]
[offline_queue]
[client]
[real-hub] http://localhost:8088

118 checks, 0 failures
```

单测覆盖：JSON 转义/代理对/大整数往返与坏输入拒绝；SSE 1 字节碎片喂入、`\r\n`、注释、多行 data、流尾兜底；离线队列 4 场景（断网留队、联网补传载荷保真 + push_id 沿用、5xx 留队 attempts++ 恢复补传、永久 422 丢弃）；mock HTTP 下 auth/push/pull/ingest 请求体与响应解析、Bearer 透传、suggest 回调多帧、错误语义表（503/429 retryable、422/Parse 不可重试）、suggest 预算超时中断。

### sync-demo 验收实测输出（真实 Hub localhost:8088，PASS=24 FAIL=0，exit 0）

```text
=== mine-input hub-client sync-demo ===
Hub: http://localhost:8088

=== 1. auth: register + login(双设备) ===
  register -> user_id=11 key_partition=kp_7391368513645907
  [PASS] 注册返回 user_id + 每用户独立密钥分区
  [PASS] 设备 A 登录得 Bearer token
  devA token=MTEuMTc5NDMzNTgyOS4zNzM0... expires_at=1794335829
  [PASS] 设备 B 登录得 Bearer token

=== 2. sync: push(双设备) -> pull 往返一致 ===
  [PASS] devA push 合并成功
  devA push_id=w8demo-A-724591e9 applied={upserted:1 kept:0 hotwords:2 counters_now:3}
  [PASS] devB 旧值被取新语义保留（upserted=0 kept=1）
  [PASS] 计数器增量累加：3 + 4 = 7
  devB push_id=w8demo-B-6f9b69e2 applied={upserted:0 kept:1 counters_now:7}
  [PASS] devA pull 成功
  pull userdb[wubi/高频词] = 你好@devA-newer (updated_at=1793731029601)
  pull counters = {l2_pick: 7}  hotwords = [mine-input 五笔]
  [PASS] pull 取新语义：userdb 为 devA 的较新值
  [PASS] pull 累加语义：counter 为两设备增量之和
  [PASS] pull 热词集合并
  [PASS] 设备 B pull 同态（往返一致）
  [PASS] push_id 幂等重试：重发返回 duplicate=true
  [PASS] 重试不重复累加：counter 仍为 7

=== 3. offline queue: 断网入队 -> 联网补传 ===
  queue db: /tmp/w8demo-queue-f8f6c661.db
  [PASS] 断网时 2 条入队（1 push + 1 ingest）
  offline flush: sent=0 kept=2 dropped=0 err=network(curl error: Couldn't connect to server)
  [PASS] 断网 flush 静默留队（retryable，未丢未发）
  [PASS] 队列仍为 2 条（attempts 留痕）
  online flush: sent=2 kept=0 dropped=0
  [PASS] 联网补传成功，队列清空
  pull after flush: counters={l2_pick: 12}
  [PASS] 补传 push 已生效：counter 7+5=12
  [PASS] 补传 userdb 条目在服务端可见

=== 4. suggest: SSE 流式多帧消费（回调式） ===
  [frame 1] seq=1 score=0.86 source=hub-stub text=这件事——好的，我稍后处理
  [frame 2] seq=2 score=0.74 source=hub-stub text=这件事——请稍等，马上回复
  [frame 3] seq=3 score=0.61 source=hub-stub text=这件事——谢谢，收到
  [done] status=ok backend=stub suggestions=3 context_digest=demo-digest
  [PASS] SSE 流式消费完成（Status ok）
  [PASS] 多帧 suggestion 逐条回调（>=2 帧）
  [PASS] done 事件回调收到
  [PASS] Candidate 字段完整（text/score/source）

=== 5. 错误语义样例 ===
  bad token pull: code=auth http=401 retryable=1
  [PASS] 401 → Error::Auth，retryable（重登可救）

== summary: PASS=24 FAIL=0 ==
```

验收点对照：**注册双设备 → push → pull 往返一致（取新/累加语义正确）→ 断网入队 → 联网补传成功 → SSE 多帧消费**，全部实测通过。

## 3. 遗留与 blocker

无 blocker。遗留：

1. **ingest 无服务端幂等**：`/v1/ingest`（hub/app/main.py）无 event_id 去重，断点补传在「服务端已写入但响应丢失」的极端情形下可能重复入库（push 有 `push_id` 无此问题）。建议 Hub 侧后续加 client event_id 去重表（需动 hub/ 目录，属 W4 所有，未越界修改）。
2. **TLS 未实测**：SDK 走 libcurl，`https://` 取决于 curl 后端（系统 curl + SecureTransport 可用）；本地 Hub 为 HTTP，TLS 部署（技术方案 §9/§10）待 Hub 正式化（M4 后续）一并验。
3. **线程模型**：`HubClient`/`OfflineQueue` 非线程安全（文档已注明）；如端侧（W7/W9）要多线程投递，可加内部互斥或由调用方串行化。
4. suggest 超时中断后服务端侧流仍在发送（HTTP 无法取消服务端计算），真正止损待 llama.cpp 后端接入取消语义。
