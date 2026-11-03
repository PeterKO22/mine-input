# mine-input AI Hub（W4 骨架）

自托管 AI Hub：FastAPI + SQLite，Docker Compose 一键起。多用户分区（朋友数据互不可见、
每用户独立密钥分区），同步（userdb 取新 / 计数器增量累加）、交互事件上行、SSE 流式建议桩。
llama.cpp 模型服务为占位（档位已定 7B Q4，本骨架不下模型）。

## 快速开始

```bash
docker compose up -d --build     # 起 Hub（宿主机端口默认 8088，HUB_PORT 可覆盖）
./smoke.sh                       # 全链路 curl 冒烟（默认 http://localhost:8088）
docker compose down              # 停（数据在 hub-data 卷，不丢）
```

> 本机宿主 8080 已被其他服务占用，故默认端口 8088；`HUB_PORT=8080 docker compose up -d`
> 可改回。smoke.sh 用 `BASE_URL` 环境变量跟随。

## API

所有业务接口需 `Authorization: Bearer <token>`，数据按 token 内 `user_id` 分区。
HTTP 字段以 `docs/技术方案-v0.4.md` 文本为准；SPI 契约字段对齐技术方案 §7.2
（v0.4 §7 引用同一契约，契约即协议，唯一契约源为 `ai/spi/ai_assist.h`——W3 车道）：

```
Candidate        := { text, score, source }
AiContext        := { before_cursor, app_id, from_voice, context_digest }
InteractionEvent := { ts, device_id, app_id, kind: key_session|voice_session|
                      candidate_pick|suggestion_feedback, text_in, text_out,
                      ocr_digest?, asr_digest?, keystroke_cadence,
                      suggestion_shown, suggestion_taken }
```

### /v1/auth

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/v1/auth/register` | 注册。入参 `{username, password}`；返回 `user_id` + `key_partition:{id,key}`（每用户独立密钥分区，FR8）。409 重名 |
| POST | `/v1/auth/token` | 签发 Bearer token（HMAC-SHA256，7 天）。返回 `access_token / token_type / expires_at / user_id / key_partition_id` |
| GET | `/v1/auth/whoami` | 当前用户与密钥分区 id |

### /v1/sync（增量同步，FR7）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/v1/sync/push` | 增量上行。入参 `{device_id, push_id, userdb:[{key,value,updated_at}], counters:{name:delta}, hotwords:[…], ai_config:{updated_at,value}, schema_version:{updated_at,value}}` |
| POST | `/v1/sync/pull` | 拉合并态。入参 `{device_id, since?}`；返回 `userdb / counters(累计) / hotwords / ai_config / schema_version / server_time` |

**合并策略**（技术方案 v0.4 §9）：

- `userdb`：时间戳**取新**（旧时间戳被拒，返回 `userdb_kept`）；
- `counters`：**增量累加**；
- `hotwords`：集合并；`ai_config` / `schema_version`：取新；
- **失败可重试**：`push_id` 为幂等键，同 `push_id` 重发返回 `{"duplicate":true}`，
  计数器不重复累加（smoke.sh 第 6 步实测）。

### /v1/ingest（交互事件上行）

`POST /v1/ingest`，入参即 `InteractionEvent` 字段（见上），`kind` 为枚举，非法值 422。
返回 `{"status":"stored","event_id",…}`。

### /v1/suggest（SSE 流式桩）

`POST /v1/suggest`，入参即 `AiContext` 字段。响应 `text/event-stream`：

```
event: suggestion
data: {"text": "…", "score": 0.86, "source": "hub-stub", "seq": 1}
…
event: done
data: {"status": "ok", "backend": "stub", "suggestions": 3, "context_digest": "…"}
```

每帧一个 `Candidate`（契约字段 text/score/source），末帧 `done`。当前为**流式桩**；
真实后端为 llama.cpp 7B Q4（见下）。客户端 800ms 超时弃本轮语义在端侧（W3 契约），
Hub 侧不做过滤。

## 卷布局与加密预留（FR8）

```
hub-data 卷 → /data
  hub.db       SQLite（WAL）：users / userdb / counters / hotwords / meta /
               pushes / ingest_events，全部按 user_id 分区
  hub-secret   Hub 服务签名密钥（token HMAC；0600）
hub-models 卷 → /models   llama.cpp 模型占位卷（当前为空）
```

- **密钥分区**：每用户 `key_partition.{id,key}`（注册时签发），为 E2E（Hub 零知识）预留；
- **静态加密**：预留位——当前 SQLite 明文落卷，上线前需卷级/库级加密；
- **TLS**：预留位——当前 HTTP（内网默认形态），远程 Hub 形态前必须上 TLS，E2E 可选。

## llama.cpp 模型服务（占位）

档位已定：**7B Q4**（T2 结论：128GB 统一内存无压力，余量可上 14B 档）。本骨架**不下模型**，
compose 里为占位服务（`profiles: ["model"]`，不启用不拉镜像）。启用：

1. 把 `qwen2.5-7b-instruct-q4_k_m.gguf`（或等价中文友好 7B Q4 模型）放进 `hub-models` 卷；
2. `docker compose --profile model up -d llama`（llama.cpp server，端口 8000）；
3. 把 `/v1/suggest` 的 stub 后端切到 llama.cpp `/completion`（`backend` 字段已预留）。

## 代码结构

```
hub/
  app/main.py     FastAPI 路由（/v1/auth /v1/sync /v1/ingest /v1/suggest）
  app/db.py       SQLite 表结构与合并逻辑（userdb 取新 / 计数器累加 / push_id 幂等）
  app/auth.py     口令哈希（PBKDF2）与 token 签发（HMAC-SHA256）
  Dockerfile      python:3.12-slim + uvicorn
  docker-compose.yml   hub 服务 + SQLite 卷 + llama.cpp 占位
  smoke.sh        全链路 curl 冒烟
  W4-REPORT.md    车道报告（含 curl 实测输出）
```
