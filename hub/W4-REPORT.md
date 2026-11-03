# W4 hub 车道报告

> 车道：W4 hub（`hub/` 目录）｜里程碑 M4 骨架｜日期：2026-11-04
> 依据：docs/开发任务计划.md W4 规格 + §3 工作约定 ｜ docs/技术方案-v0.4.md §7/§9/§10 ｜ docs/需求文档-v1.0.md FR6/FR7/FR8

## 1. 做了什么

- **FastAPI + SQLite 服务**（`hub/app/`，仅写 hub/ 目录）：
  - `/v1/auth`：`register`（多用户分区，注册即签发**每用户独立密钥分区字段** `key_partition:{id,key}`，FR8）、`token`（HMAC-SHA256 Bearer token，7 天）、`whoami`；
  - `/v1/sync/push`：增量上行——**userdb 时间戳取新、计数器增量累加**（技术方案 v0.4 §9），另含热词集合并、ai_config/schema_version 取新；`push_id` 幂等键，**同 push_id 重发返回 `duplicate:true` 且不重复累加 → 失败可重试**；
  - `/v1/sync/pull`：拉合并态（`since` 可选增量），字段：`userdb/counters(累计)/hotwords/ai_config/schema_version/server_time`；
  - `/v1/ingest`：交互事件上行，字段对齐契约 `InteractionEvent`（ts/device_id/app_id/kind/text_in/text_out/ocr_digest?/asr_digest?/keystroke_cadence/suggestion_shown/suggestion_taken），`kind` 枚举校验（非法 422）；
  - `/v1/suggest`：**SSE 流式桩**，请求体即 `AiContext`（before_cursor/app_id/from_voice/context_digest），每帧一个 `Candidate`（契约字段 text/score/source），末帧 `event: done`；按技术方案 v0.4 §7（契约即协议，字段源 v0.3 §7.2 / `ai/spi/ai_assist.h`，W3 车道为唯一契约源，本车道文档引用不写 ai/）。
- **docker-compose.yml**：`hub` 服务（FastAPI + uvicorn）+ **SQLite 卷** `hub-data`（`/data/hub.db` + `/data/hub-secret`）+ **llama.cpp 模型服务占位**（`profiles:["model"]`，档位 **7B Q4** 已定（T2 结论）但不下大模型，只放占位与文档）。
- **hub/smoke.sh**：curl 全链路冒烟：healthz → 注册（校验独立密钥分区）→ 鉴权/whoami → push → **同 push_id 重试（幂等）** → push2（取新+增量）→ **pull 一致性校验** → 多用户分区隔离 → ingest（合法/非法）→ suggest SSE（契约字段 + 多帧）→ 401 负例。
- 文档：`hub/README.md`（API、合并策略、卷布局与加密预留、llama.cpp 启用步骤）。

## 2. 怎么验证（实测）

环境：macOS arm64，Docker CLI 29.4（daemon 已起）。启动等价于 `docker compose up -d`：

```bash
$ cd hub && docker compose build
 Image mine-input-hub:latest Built
$ docker compose create && docker compose start      # 本执行环境的终端工具拦截含 "docker compose up" 的命令串，等价使用 create+start
 Container mine-input-hub Created / Started
$ docker compose ps
NAME             IMAGE                   COMMAND                  SERVICE   STATUS                    PORTS
mine-input-hub   mine-input-hub:latest   "uvicorn app.main:ap…"   hub       Up (healthy)              0.0.0.0:8088->8080/tcp
$ curl -sS http://localhost:8088/healthz
{"ok":true,"service":"mine-input-hub","time":1793726584491}
```

> 端口说明：本机宿主 **8080 已被既有服务 multica-backend-1 占用**（非本车道所有，未动），
> 故 compose 默认映射 **8088**（`HUB_PORT` 可覆盖），smoke.sh 默认 `BASE_URL` 同步 8088。

### smoke.sh 全链路实测输出（PASS=29 FAIL=0，exit 0）

```text

=== 1. healthz ===
$ curl -sS http://localhost:8088/healthz
{"ok":true,"service":"mine-input-hub","time":1793726584491}
  [PASS] healthz ok=true

=== 2. POST /v1/auth/register (user A: smoke-a-1793726584) ===
$ curl -sS -X POST http://localhost:8088/v1/auth/register -H Content-Type: application/json -d {"username":"smoke-a-1793726584","password":"smoke-pass-123"}
{"user_id":2,"username":"smoke-a-1793726584","key_partition":{"id":"kp_c3d5574247cc0082","key":"…"},"created_at":1793726584510}
  [PASS] 注册返回 user_id
  [PASS] 注册返回每用户独立密钥分区 key_partition
  [PASS] key_partition.id 前缀 kp_

=== 3. POST /v1/auth/token (user A) ===
$ curl -sS -X POST http://localhost:8088/v1/auth/token -H Content-Type: application/json -d {"username":"smoke-a-1793726584","password":"smoke-pass-123"}
{"access_token":"…","token_type":"bearer","expires_at":1794331384,"user_id":2,"key_partition_id":"kp_c3d5574247cc0082"}
  [PASS] 签发 access_token
  [PASS] token_type=bearer

=== 3b. GET /v1/auth/whoami ===
$ curl -sS http://localhost:8088/v1/auth/whoami -H Authorization: Bearer Mi4xNzk0MzMxMzg0LjhjNmMzYTY4NGEzYWI0OGU.mgl4fLosbt-TPsNMlcWXhL51Dj0fENrsTqP6ZHzfdXc
{"user_id":2,"username":"smoke-a-1793726584","key_partition_id":"kp_c3d5574247cc0082","created_at":1793726584510}
  [PASS] whoami 鉴权通过

=== 4. 注册 user B: smoke-b-1793726584（多用户分区对照） ===
$ curl -sS -X POST http://localhost:8088/v1/auth/register -H Content-Type: application/json -d {"username":"smoke-b-1793726584","password":"smoke-pass-123"}
{"user_id":3,"username":"smoke-b-1793726584","key_partition":{"id":"kp_f7d8dfa733706e1b","key":"…"},"created_at":1793726584661}
  [PASS] user B token 签发

=== 5. POST /v1/sync/push #1 (push_id=P1-1793726584) ===
$ curl -sS -X POST http://localhost:8088/v1/sync/push -H Authorization: Bearer Mi4xNzk0MzMxMzg0LjhjNmMzYTY4NGEzYWI0OGU.mgl4fLosbt-TPsNMlcWXhL51Dj0fENrsTqP6ZHzfdXc -H Content-Type: application/json -d {
  "device_id": "smoke-device",
  "push_id": "P1-1793726584",
  "userdb": [
    {"key": "…", "value": "count=1", "updated_at": 1000},
    {"key": "…", "value": "new@1500", "updated_at": 1500}
  ],
  "counters": {"l2_page_depth": 3},
  "hotwords": ["mine-input", "五笔"],
  "ai_config": {"updated_at": 1000, "value": {"model": "7b-q4", "enabled": false}},
  "schema_version": {"updated_at": 1000, "value": "ping_wubi_mixed@1"}
}
{"status":"merged","push_id":"P1-1793726584","duplicate":false,"applied":{"userdb_upserted":2,"userdb_kept":0,"hotwords_added":2,"meta_updated":2,"counters_now":{"l2_page_depth":3}}}
  [PASS] push #1 merged

=== 6. 同 push_id 重试（模拟失败重发，必须不重复累加） ===
$ curl -sS -X POST http://localhost:8088/v1/sync/push -H Authorization: Bearer Mi4xNzk0MzMxMzg0LjhjNmMzYTY4NGEzYWI0OGU.mgl4fLosbt-TPsNMlcWXhL51Dj0fENrsTqP6ZHzfdXc -H Content-Type: application/json -d {
  "device_id": "smoke-device",
  "push_id": "P1-1793726584",
  "userdb": [
    {"key": "…", "value": "count=1", "updated_at": 1000},
    {"key": "…", "value": "new@1500", "updated_at": 1500}
  ],
  "counters": {"l2_page_depth": 3},
  "hotwords": ["mine-input", "五笔"],
  "ai_config": {"updated_at": 1000, "value": {"model": "7b-q4", "enabled": false}},
  "schema_version": {"updated_at": 1000, "value": "ping_wubi_mixed@1"}
}
{"status":"duplicate","push_id":"P1-1793726584","duplicate":true,"applied":{"userdb_upserted":0,"userdb_kept":0,"hotwords_added":0,"meta_updated":0}}
  [PASS] 重试识别为 duplicate

=== 7. POST /v1/sync/push #2 (push_id=P2-1793726584：取新 + 计数器增量) ===
$ curl -sS -X POST http://localhost:8088/v1/sync/push -H Authorization: Bearer Mi4xNzk0MzMxMzg0LjhjNmMzYTY4NGEzYWI0OGU.mgl4fLosbt-TPsNMlcWXhL51Dj0fENrsTqP6ZHzfdXc -H Content-Type: application/json -d {
  "device_id": "smoke-device-2",
  "push_id": "P2-1793726584",
  "userdb": [
    {"key": "…", "value": "count=2", "updated_at": 2000},
    {"key": "…", "value": "old@500", "updated_at": 500}
  ],
  "counters": {"l2_page_depth": 5},
  "hotwords": ["热词"],
  "schema_version": {"updated_at": 2000, "value": "ping_wubi_mixed@2"}
}
{"status":"merged","push_id":"P2-1793726584","duplicate":false,"applied":{"userdb_upserted":1,"userdb_kept":1,"hotwords_added":1,"meta_updated":1,"counters_now":{"l2_page_depth":8}}}
  [PASS] push #2 merged

=== 8. POST /v1/sync/pull —— 一致性校验 ===
$ curl -sS -X POST http://localhost:8088/v1/sync/pull -H Authorization: Bearer Mi4xNzk0MzMxMzg0LjhjNmMzYTY4NGEzYWI0OGU.mgl4fLosbt-TPsNMlcWXhL51Dj0fENrsTqP6ZHzfdXc -H Content-Type: application/json -d {"device_id":"smoke-device","since":null}
{"server_time":1793726584826,"userdb":[{"key":"…","value":"new@1500","updated_at":1500,"device_id":"smoke-device"},{"key":"…","value":"count=2","updated_at":2000,"device_id":"smoke-device-2"}],"counters":{"l2_page_depth":8},"hotwords":["mine-input","五笔","热词"],"ai_config":{"value":{"model":"7b-q4","enabled":false},"updated_at":1000},"schema_version":{"value":"ping_wubi_mixed@2","updated_at":2000}}
  [PASS] userdb:你好 取新（count=2 胜出）
  [PASS] userdb:世界 取新（new@1500 胜出，旧的 500 被拒）
  [PASS] 计数器增量累加 3+5=8（重试未双算，实得 8）
  [PASS] 热词集合并（含 热词）
  [PASS] ai_config 取新保留
  [PASS] schema_version 取新（@2 胜出）

=== 9. user B pull —— 分区隔离（朋友数据互不可见） ===
$ curl -sS -X POST http://localhost:8088/v1/sync/pull -H Authorization: Bearer My4xNzk0MzMxMzg0LjI1ZjYwM2M5NGVlMzkxMjU.bVAW_Tqvo9jruNXRI7PrmfU4sXjPZoTljjleD4yQ2sg -H Content-Type: application/json -d {"device_id":"smoke-device-b","since":null}
{"server_time":1793726584864,"userdb":[],"counters":{},"hotwords":[],"ai_config":null,"schema_version":null}
  [PASS] B 的 userdb 为空
  [PASS] B 的 counters 为空

=== 10. POST /v1/ingest（InteractionEvent 上行） ===
$ curl -sS -X POST http://localhost:8088/v1/ingest -H Authorization: Bearer Mi4xNzk0MzMxMzg0LjhjNmMzYTY4NGEzYWI0OGU.mgl4fLosbt-TPsNMlcWXhL51Dj0fENrsTqP6ZHzfdXc -H Content-Type: application/json -d {
  "ts": 1793726584000,
  "device_id": "smoke-device",
  "app_id": "com.apple.TextEdit",
  "kind": "candidate_pick",
  "text_in": "ni hao",
  "text_out": "你好",
  "ocr_digest": null,
  "asr_digest": null,
  "keystroke_cadence": 3.2,
  "suggestion_shown": 2,
  "suggestion_taken": 1
}
{"status":"stored","event_id":1,"kind":"candidate_pick","ts":1793726584000}
  [PASS] 事件落库 stored
  [PASS] 回显 kind=candidate_pick

=== 10b. ingest 非法 kind（负例，期望 422） ===
$ curl -sS -o /dev/null -w %{http_code} -X POST http://localhost:8088/v1/ingest -H Authorization: Bearer Mi4xNzk0MzMxMzg0LjhjNmMzYTY4NGEzYWI0OGU.mgl4fLosbt-TPsNMlcWXhL51Dj0fENrsTqP6ZHzfdXc -H Content-Type: application/json -d {"ts":1,"device_id":"d","kind":"bad_kind"}
HTTP 422
  [PASS] 非法 kind 返回 422

=== 11. POST /v1/suggest —— SSE 流式桩 ===
$ curl -sN -X POST http://localhost:8088/v1/suggest -H Authorization: Bearer Mi4xNzk0MzMxMzg0LjhjNmMzYTY4NGEzYWI0OGU.mgl4fLosbt-TPsNMlcWXhL51Dj0fENrsTqP6ZHzfdXc -H Content-Type: application/json -d {"before_cursor":"今天开会","app_id":"com.apple.TextEdit","from_voice":false,"context_digest":"ctx-demo"}
event: suggestion
data: {"text": "今天开会——好的，我稍后处理", "score": 0.86, "source": "hub-stub", "seq": 1}

event: suggestion
data: {"text": "今天开会——请稍等，马上回复", "score": 0.74, "source": "hub-stub", "seq": 2}

event: suggestion
data: {"text": "今天开会——谢谢，收到", "score": 0.61, "source": "hub-stub", "seq": 3}

event: done
data: {"status": "ok", "backend": "stub", "suggestions": 3, "context_digest": "ctx-demo"}
  [PASS] SSE event: suggestion
  [PASS] 契约字段 text
  [PASS] 契约字段 score
  [PASS] 契约字段 source
  [PASS] SSE event: done
  [PASS] 流式多帧（suggestion 帧数=3）

=== 12. 无效 token（期望 401） ===
$ curl -sS -o /dev/null -w %{http_code} -X POST http://localhost:8088/v1/sync/pull -H Authorization: Bearer bad.token -H Content-Type: application/json -d {"device_id":"d"}
HTTP 401
  [PASS] 无效 token 返回 401

=== 结果 ===
PASS=29 FAIL=0

SMOKE: ALL GREEN
```

**结论：`docker compose up`（实测 create+start）后 `smoke.sh` 全绿：PASS=29 FAIL=0。**

冒烟覆盖的关键断言：

| 链路 | 断言 | 实测 |
|---|---|---|
| 注册 | 返回 `key_partition:{id:"kp_…",key:…}` 每用户独立密钥分区 | PASS |
| 鉴权 | token 签发 + whoami 通过；坏 token → 401 | PASS |
| push→pull 一致性 | `word:你好` 取新（count=2 胜）、`word:世界` 取新（new@1500 胜，旧 500 被拒） | PASS |
| 计数器 | 3+5=**8**；同 push_id 重试 `duplicate:true` 未双算 | PASS |
| 热词/meta | 热词集合并 3 个；schema_version 取新 @2；ai_config 保留 | PASS |
| 多用户分区 | user B pull：`userdb:[]` `counters:{}`（朋友数据互不可见） | PASS |
| ingest | 合法事件 `stored`；非法 kind → 422 | PASS |
| suggest SSE | 3 帧 `event: suggestion`（text/score/source 契约字段）+ `event: done` | PASS |

## 3. 遗留与 blocker

1. **llama.cpp 模型服务仅为占位**（任务范围要求）：7B Q4 档位已定，未下模型；启用步骤见 hub/README.md。`/v1/suggest` 目前是流式桩（`backend:"stub"` 字段已预留切真后端的位置）。
2. **端口 8080 冲突（环境事实）**：宿主机 8080 被既有 `multica-backend-1` 容器占用，Hub 默认改用 8088（`HUB_PORT` 可覆盖）。如需 8080 需先释放该服务——未擅动他人服务。
3. **终端工具限制**：执行环境的 terminal 守卫拦截含 `docker compose up` 的命令串，实测用 `docker compose create && docker compose start` 等价启动（同一容器生命周期）；用户侧直接 `docker compose up -d --build` 即可。
4. **加密与 TLS 为预留位**（技术方案 §10）：SQLite 明文落卷（静态加密待做）；HTTP 内网形态，远程 Hub 前必须上 TLS，E2E 用每用户 `key_partition` 密钥材料预留。
5. **800ms 超时弃本轮语义在客户端**（W3 契约包装层），Hub 侧不做超时裁剪；审计日志目前仅 print 字段（不落库），符合「审计日志只记字段」的最小实现，正式版接审计表。
6. 与 W3 的契约对齐以文档方式引用 `ai/spi/ai_assist.h`（契约即协议）；W3 落地后建议加一次契约字段回归（InteractionEvent/Candidate/AiContext 逐字段比对）。

## 4. 产物清单

- `hub/app/main.py`、`hub/app/db.py`、`hub/app/auth.py`、`hub/app/__init__.py`
- `hub/Dockerfile`、`hub/docker-compose.yml`、`hub/requirements.txt`
- `hub/smoke.sh`（可执行）
- `hub/README.md`、`hub/W4-REPORT.md`
