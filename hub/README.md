# mine-input AI Hub（W4 骨架）

自托管 AI Hub：FastAPI + SQLite，Docker Compose 一键起。多用户分区（朋友数据互不可见、
每用户独立密钥分区），同步（userdb 取新 / 计数器增量累加）、交互事件上行、SSE 流式建议。
`/v1/suggest` 已接 **llama.cpp llama-server 真模型后端**（W10；提示词模板版本化，
模型档位可 drop-in 更换，见下「模型灌入与换模型」）。

## 快速开始

```bash
./models/run-llama-native.sh start    # 起宿主机原生模型后端（默认 7B Q4_K_M，端口 8092）
docker compose up -d --build          # 起 Hub（宿主机端口默认 8088，HUB_PORT 可覆盖）
./smoke.sh                            # 全链路 curl 冒烟（默认 http://localhost:8088）
docker compose down                   # 停（数据在 hub-data 卷，不丢）
./models/run-llama-native.sh stop     # 停原生模型后端
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

### /v1/suggest（SSE 流式，真模型后端 W10）

`POST /v1/suggest`，入参即 `AiContext` 字段 + 场景扩展（W10）：
`scene: continuation|voice_correct|rescore|teleprompter`（对齐技术方案 §7 场景顺序
与 §8 提词器）、`candidates:[…]`（rescore 用）、`max_tokens`。
响应 `text/event-stream`：

```
event: suggestion
data: {"text": "…", "score": 0.85, "source": "llama.cpp:qwen2.5-…", "seq": 1}
…
event: done
data: {"status": "ok", "backend": "llama.cpp", "model": "…", "suggestions": 3,
       "context_digest": "…", "prompt_version": "v1.0", "scene": "…",
       "budget_ms": 800, "timings": {"ttft_ms": …, "total_ms": …, "frames": …,
       "tokens": …, "inter_frame_avg_ms": …}}
```

- 每帧一个 `Candidate`（契约字段 text/score/source + seq），末帧 `done`；
  帧语义：续写/纠错/提词为**增量累积**（text=当前全文，客户端按帧刷新），
  rescore 为**每完整行一帧**（候选原样文本，score=名次分）；
- **提示词模板版本化**（`app/prompts.py`，`prompt_version` 随 done 帧下发）：
  4 场景各一模板（few-shot 紧凑示例），换模板必须升版本号；
- `score` 当前为启发式占位（部分帧 0.5 / 完整帧 0.85 / 重排名次分），
  后续接 logits 置信度；
- **800ms 预算语义**：弃轮裁决在客户端（W3 契约 800ms 超时弃本轮），Hub 不裁剪；
  **客户端弃一轮不影响服务端**——上游消费独立 task 读干 llama.cpp 流（smoke 11e 实测）；
- 模型不可达且 `SUGGEST_ALLOW_STUB_FALLBACK=1`（默认）→ 降级回流式桩，
  done 帧 `backend:"stub-fallback"` 显式标注，绝不冒充真模型。

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

## 模型后端：两档切换（W13：宿主机原生 7B 默认档 + 容器内 0.5B 降级档）

`/v1/suggest` 的 llama.cpp 后端地址由 `MODEL_URL` 切换（Docker 内访问宿主机走
`host.docker.internal`），`MODEL_NAME` 同步标注实际档位（done 帧 model 字段，诚实标注）：

| 档位 | 跑法 | 服务地址（Hub 侧 MODEL_URL） | MODEL_NAME | 端口 |
|---|---|---|---|---|
| **默认档 7B Q4_K_M**（宿主机原生，W13） | `./models/run-llama-native.sh start` | `http://host.docker.internal:8092` | `qwen2.5-7b-instruct-q4_k_m` | 宿主 8092 |
| 降级档 0.5B Q4_K_M（compose 容器内，W10） | `docker compose --profile model up -d llama` | `http://llama:8091` | `qwen2.5-0.5b-instruct-q4_k_m` | 宿主 8091 |

```bash
# 1) 默认档：宿主机原生 7B（llama.cpp GitHub Releases 预编译 b12078，Metal；
#    二进制在 models/llama.cpp-b12078/，脚本自动探测，也可 brew install llama.cpp）
./models/run-llama-native.sh start     # start/stop/restart/status/health
./models/run-llama-native.sh health    # 健康检查（curl :8092/health）

# 2) Hub 用默认档（compose 默认值即原生 7B，无需传参）
docker compose up -d --build           # 或已建容器：rm -sf + create + start 换 env

# 3) 冒烟（含真后端 case 11b–11e + W13 真 7B 档位断言）
SMOKE_EXPECT_MODEL=qwen2.5-7b ./smoke.sh
```

**换档到 0.5B 降级档**（原生 7B 不可用时；容器内 0.5B ≤500MB，Docker VM 内存装得下）：

```bash
./models/fetch_model.sh install        # 模型灌入 hub-models 卷（一次性）
docker compose --profile model up -d llama
MODEL_URL=http://llama:8091 MODEL_NAME=qwen2.5-0.5b-instruct-q4_k_m docker compose up -d
SMOKE_EXPECT_MODEL=qwen2.5-0.5b MODEL_HEALTH_URL=http://localhost:8091/health ./smoke.sh
```

**换任意 GGUF（drop-in，零代码改动）**：放 `models/` → `./models/run-llama-native.sh restart`
（或 `MODEL_FILE=<文件名> ./run-llama-native.sh start`）→ 同步 `MODEL_NAME`（done 帧诚实标注）
→ recreate hub。`/v1/suggest` 只认 llama.cpp `/completion` 协议。

```bash
# 例：原生换上 0.5B 跑（对照档）
MODEL_FILE=qwen2.5-0.5b-instruct-q4_k_m.gguf MODEL_NAME=qwen2.5-0.5b-instruct-q4_k_m \
  ./models/run-llama-native.sh restart
MODEL_NAME=qwen2.5-0.5b-instruct-q4_k_m docker compose up -d
```

> 📌 **W10 blocker 的 W13 解法**：7B Q4_K_M 在 Docker Desktop VM（7.75GB）内 OOM（W10-REPORT
> §7 实证），故 W13 起模型服务改**宿主机原生**跑（128GB 统一内存 + Metal，实测 7B 无压力），
> Hub 容器经 `host.docker.internal:8092` 访问；容器内 0.5B 保留为降级档。VM 内跑 7B 的
> 原 blocker 依旧存在（VM 内存 ≥8GB 后也可走 compose llama + MODEL_FILE 一行换装）。

## 代码结构

```
hub/
  app/main.py         FastAPI 路由（/v1/auth /v1/sync /v1/ingest /v1/suggest）
  app/db.py           SQLite 表结构与合并逻辑（userdb 取新 / 计数器累加 / push_id 幂等）
  app/auth.py         口令哈希（PBKDF2）与 token 签发（HMAC-SHA256）
  app/prompts.py      版本化提示词模板（4 场景，few-shot；W10）
  app/model_backend.py  llama.cpp 转发 + SSE 组帧 + 弃轮不扰服务端（W10）
  Dockerfile          python:3.12-slim + uvicorn
  docker-compose.yml   hub 服务 + SQLite 卷 + llama.cpp 模型服务（profile: model）
  smoke.sh            全链路 curl 冒烟（含真模型 case 11b–11e + W13 档位断言 SMOKE_EXPECT_MODEL）
  bench_latency.py    延迟实测（ttft/帧间隔/总耗时，markdown 表）
  W4-REPORT.md        车道报告（含 curl 实测输出）
  W10-REPORT.md       W10 真模型后端报告（延迟表 + blocker）
  W13-REPORT.md       W13 宿主机原生 7B 报告（延迟表 7B vs 0.5B + 换档）
models/               大模型文件（不入库；fetch_model.sh 可复现拉取/校验/灌入卷）
  run-llama-native.sh 宿主机原生 llama.cpp 管理（start/stop/restart/status/health，默认 7B）
  llama.cpp-b12078/   llama.cpp GitHub Releases 预编译（macOS arm64 + Metal，不入库）
```
