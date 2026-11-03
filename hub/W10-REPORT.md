# W10 hub-model 车道报告

> 车道：W10 hub-model（`hub/` + `models/` 目录）｜日期：2026-11-04
> 依据：docs/开发任务计划.md §3 工作约定 + W10 规格 ｜ docs/技术方案-v0.4.md §7（场景顺序/800ms/审计）/§8（提词器）/§9（提示词模板=同步面）
> 结论：**链路全通**（smoke PASS=*** FAIL=0，真模型 SSE 流式 + 延迟表实测），
> 但 7B Q4_K_M 在本机 Docker VM 装不下（OOM 实证）→ 按降级验收用 ≤500MB 模型跑通全链路，
> 7B 权重已校验就位 + drop-in 一行换装 + 精确 blocker 见 §7。

## 1. 做了什么（对照交付 a–e）

| 交付 | 状态 | 说明 |
|---|---|---|
| (a) Qwen2.5-7B-Instruct-Q4_K_M GGUF → `models/` | ✅ | ModelScope 官方仓库，split 分片 2 文件共 4,683,073,632 B，SHA256 源提供+本地复核一致；源逐个实测记录见 §2 |
| (b) llama.cpp llama-server 进 compose | ✅ | `llama` 服务（`profiles:["model"]`）真跑通，宿主端口 **8091**（避开 8088/8080 及已占的 8000/8090），镜像 `ghcr.io/ggml-org/llama.cpp:server`（ghcr 实测可达） |
| (c) `/v1/suggest` 转发真模型 | ✅ | 提示词模板**版本化**（`app/prompts.py` PROMPT_VERSION=v1.0，4 场景对齐 §7/§8）；SSE 流式保留；800ms 预算语义保留（弃轮裁决在客户端，**弃一轮不影响服务端**——producer 独立读干上游流，smoke 11e 实测） |
| (d) smoke.sh 扩展真后端 case | ✅ | 新增 11b（continuation 真模型断言）/11c（voice_correct）/11d（rescore 多帧）/11e（弃轮不扰服务端）；`SMOKE_MODEL_REQUIRED=0` 可只跑桩链路 |
| (e) 延迟实测表 | ✅ | `hub/bench_latency.py` 5 轮/场景实测，表见 §6（ttft/首帧/帧间隔/总耗时） |

## 2. 模型源实测记录（URL/体积/SHA256）

### ✅ 采用源（最终下载自此处）

| 项 | 值 |
|---|---|
| 仓库 | ModelScope 官方 `Qwen/Qwen2.5-7B-Instruct-GGUF` |
| 列目录 API | `https://www.modelscope.cn/api/v1/models/Qwen/Qwen2.5-7B-Instruct-GGUF/repo/files?Recursive=true`（返回每文件 SHA256） |
| 下载入口 | `https://www.modelscope.cn/api/v1/models/Qwen/Qwen2.5-7B-Instruct-GGUF/repo?FilePath=<file>&Revision=master`（302 → `cdn-lfs-cn-1.modelscope.cn` 签名直链，支持 Range 续传，实测 ~10MB/s） |
| 文件 1 | `qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf`｜3,993,201,344 B |
| SHA256 1 | `dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db`（源提供，`shasum -a 256` 本地复核一致） |
| 文件 2 | `qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf`｜689,872,288 B |
| SHA256 2 | `539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a`（同上复核一致） |
| 合计 | 4,683,073,632 B（≈4.36 GiB）＝ Q4_K_M 全量（llama.cpp split 分片命名，喂第一片即自动加载第二片） |

### 备选/失败源（如实记录）

| 源 | URL | 结果 |
|---|---|---|
| HuggingFace 直连 | `https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/...` | ❌ 被墙（401/超时，W2 实证，本次未重复耗时） |
| hf-mirror.com | `https://hf-mirror.com/Qwen/...` | ❌ 308 跳回 huggingface.co 同样被墙（W2 实证） |
| ModelScope resolve 直链 | `.../resolve/master/qwen2.5-7b-instruct-q4_k_m.gguf` | ❌ 404——该仓库无单文件版 q4_k_m，只有 split 分片；换 `api/v1 .../repo?FilePath=` 入口成功 |
| GitHub Releases 直链 | （备选，未需要） | 未触发——ModelScope 首源即成功 |

### 降级档模型（W10 交付实际运行档，§7 blocker）

| 项 | 值 |
|---|---|
| 文件 | `qwen2.5-0.5b-instruct-q4_k_m.gguf`（`Qwen/Qwen2.5-0.5B-Instruct-GGUF`） |
| URL | `https://www.modelscope.cn/api/v1/models/Qwen/Qwen2.5-0.5B-Instruct-GGUF/repo?FilePath=qwen2.5-0.5b-instruct-q4_k_m.gguf&Revision=master` |
| 体积 | 491,400,032 B（≈469 MiB，≤500MB ✓） |
| SHA256 | `74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db`（源提供，本地复核一致） |

llama.cpp 镜像：`ghcr.io/ggml-org/llama.cpp:server`，digest
`sha256:10a38e6cc91760ab157f0a0a8546218d35f4a314432a70298abfa3d096829ad7`（ghcr 实测可达）。
获取脚本 `models/fetch_model.sh`（`target`/`fallback`/`verify`/`install` 四模式，断点续传+校验）。

## 3. llama-server 进 compose（b）

- `docker-compose.yml` 的 `llama` 服务启用真配置：`profiles:["model"]`，端口 **8091**，
  `-m /models/${MODEL_FILE:-qwen2.5-0.5b-instruct-q4_k_m.gguf}`（drop-in 换档），`-c 2048`；
- 模型经命名卷 `hub-models` → `/models`（`models/fetch_model.sh install` 灌入；
  实测 VirtioFS bind-mount 直挂大文件在本机 VM 内存受限时会 OOM，命名卷更稳）；
- hub 服务经 `MODEL_URL=http://llama:8091`（compose 网络服务名）直连，
  `MODEL_NAME` 随 done 帧诚实标注实际档位。

## 4. /v1/suggest 真模型转发（c）

- `app/prompts.py`：**提示词模板 versioned**（`PROMPT_VERSION="v1.0"`，done 帧回带），
  4 场景对齐技术方案 §7 场景顺序 + §8 提词器：
  `voice_correct`（语音同音字纠错）/ `rescore`（候选重排）/ `continuation`（续写联想）/
  `teleprompter`（提词）。纠错/重排带 few-shot 紧凑示例（0.5B 小模型实测无示例不听指令，
  有示例后纠错实证 音行→银行）。换模板必须升 PROMPT_VERSION（技术方案 §9 同步面）。
- `app/model_backend.py`：llama-server `/completion`（stream）→ Hub 组帧
  （契约 `Candidate{text,score,source}`+seq）→ SSE。帧语义：续写/纠错/提词为增量累积
  （text=当前全文，客户端按帧刷新），rescore 为每完整行一帧（原样候选文本，名次分）。
- **800ms 预算语义**：done 帧带 `budget_ms:800`；弃不弃由客户端（W3 契约）裁决，
  Hub 不裁剪；**客户端弃一轮不影响服务端**：上游消费在独立 task 中读干 llama.cpp 流，
  consumer 断开不级联取消（producer 内存由 max_tokens 上界约束）。
- 降级保护：llama-server 不可达且 `SUGGEST_ALLOW_STUB_FALLBACK=1`（默认）→ 流式桩，
  done 帧 `backend:"stub-fallback"` 显式标注，**绝不冒充真模型**。
- `score` 为启发式占位（部分帧 0.5/完整帧 0.85/重排名次分），后续接 logits 置信度（诚实标注）。

真模型 SSE 实测样例（smoke 11b）：

```
event: suggestion
data: {"text": "会议", "score": 0.5, "source": "llama.cpp:qwen2.5-0.5b-instruct-q4_k_m", "seq": 1}

event: suggestion
data: {"text": "会议讨论了第三季度的。", "score": 0.5, "source": "llama.cpp:qwen2.5-0.5b-instruct-q4_k_m", "seq": 2}

event: suggestion
data: {"text": "会议讨论了第三季度的。", "score": 0.85, "source": "llama.cpp:qwen2.5-0.5b-instruct-q4_k_m", "seq": 3}

event: done
data: {"status": "ok", "backend": "llama.cpp", "model": "qwen2.5-0.5b-instruct-q4_k_m", "suggestions": 3, "context_digest": "ctx-model", "prompt_version": "v1.0", "scene": "continuation", "budget_ms": 800, "timings": {"ttft_ms": 23.4, "total_ms": 292.3, "frames": 3, "tokens": 6, "inter_frame_avg_ms": 134.5}}
```

## 5. smoke.sh 扩展（d）与实测

新增 case：11b 真模型断言（backend=llama.cpp/prompt_version/timings/source/多帧）、
11c voice_correct、11d rescore（每行一帧多帧）、11e **弃轮不扰服务端**
（curl --max-time 2 提前断开 → llama /health 仍 ok → 复测 suggest 链路仍可用）。

```text
=== 结果 ===
PASS=42 FAIL=0

SMOKE: ALL GREEN
```

（含 W4 原 29 项全绿 + 11 真模型通用项 + 11b–11e 12 项；真模型 case 需 `--profile model` 起 llama，
仅跑桩链路 `SMOKE_MODEL_REQUIRED=0 ./smoke.sh`。）

## 6. 延迟实测（e）

`hub/bench_latency.py`，每场景 5 轮，走完整链路（HTTP→Hub→llama.cpp→SSE）：

| 场景 | 首token延迟 ttft_ms(服务端) | 首帧到达 ms(客户端) | 每帧间隔 ms | 总耗时 ms | 帧数 | token数 |
|---|---|---|---|---|---|---|
| continuation | 56.9 | 59.3 | 97.7 | 251.8 | 2.6 | 7.4 |
| voice_correct | 32.0 | 34.5 | 91.4 | 203.9 | 2.6 | 7.0 |
| rescore | 41.2 | 92.9 | 81.1 | 336.3 | 4.0 | 10.0 |
| teleprompter | 27.3 | 29.5 | 53.9 | 102.9 | 2.2 | 4.0 |

（5 轮均值；ttft=请求进 Hub→上游首 token；首帧/间隔/总耗时为客户端墙钟；
模型 qwen2.5-0.5b-instruct-q4_k_m——降级档，以 done 帧 model 字段为准。）

- 全部场景**总耗时 ≪ 800ms 预算**（限 max_tokens=32 的短输出）；
- 逐帧流式真实发生（帧距 ~54–138ms，非一次返回）；
- ⚠️ 0.5B 档数据**不代表 7B 目标档**（7B CPU 推理慢一个量级，ttft/生成都会更高）；
  7B 换装后需重跑 `bench_latency.py` 更新本表（脚本零改动）。

## 7. 遗留与 blocker（精确）

**Blocker：7B Q4_K_M 无法在本机 Docker Desktop VM 内运行（OOM）。**

| 证据 | 实测值 |
|---|---|
| Docker VM 总内存 | `MemTotal: 8124424 kB`（7.75 GiB）——`docker info` 同值 |
| 共驻容器占用 | ~3.5GB（supabase 栈/neo4j×3/mysql/multica 等 ~20 个非本车道容器，未动） |
| 加载期可用内存 | `MemAvailable ≈ 2.3–3.4GB` < 4.68GB 权重 |
| 失败形态 1 | bind-mount + `-c 4096`：`docker inspect` → `OOMKilled=true`，`RestartCount=21` 崩溃循环 |
| 失败形态 2 | 命名卷 + `-c 2048`：仍加载中途死亡崩溃循环（restarts=5+） |
| 升配路径 | Docker Desktop VM 内存 ≥8GB（建议 16GB）→ 一行换装（README「换模型」）；`settings-store.json` 被 TCC 拦截（读都不可），且改内存需重启 Docker 引擎会波及 ~20 个共驻服务——**未擅动** |

**降级交付（按降级验收形态）**：≤500MB 模型（Qwen2.5-0.5B-Instruct Q4_K_M，491MB）跑通全链路
（smoke 全绿 + 真模型流式 + 延迟表）+ drop-in 换模型文档（README「模型灌入与换模型」，
`models/fetch_model.sh` 已就位）+ 本节精确 blocker。7B 权重已下载校验在 `models/` 就位，
换装是纯配置一步。

其他遗留（沿承 W4）：

1. `score` 为启发式占位（接 logits 置信度后续做）；
2. 0.5B 档输出质量有限（续写偶尔回显输入前缀、重排排序不稳定）——few-shot 后可用但不达
   7B 档水准；语音纠错实证有效（音行→银行）；
3. 审计日志仍 print 字段（不落库），沿承 W4 结论；
4. 建议 W3 契约回归：`Candidate/AiContext` 逐字段比对（本次 suggest 扩展字段
   `scene/candidates/max_tokens` 为可选向后兼容扩展，W8 SDK/W9 老客户端不受影响）。

## 8. 产物清单

- `hub/app/prompts.py`（版本化提示词模板）`hub/app/model_backend.py`（llama.cpp 转发+组帧）
  `hub/app/main.py`（suggest 接线）`hub/requirements.txt`（+httpx）
- `hub/docker-compose.yml`（llama 真服务 8091 + MODEL_FILE/MODEL_NAME drop-in）
- `hub/smoke.sh`（+真后端 case 11b–11e）`hub/bench_latency.py`（延迟实测）
- `hub/README.md`（真后端文档 + 模型灌入/换模型 + blocker 注）
- `models/fetch_model.sh`（拉取/校验/灌卷，含 7B 目标档 + 0.5B 降级档）`models/.gitignore`
  `models/MODEL-SOURCE.md`（源实测记录）；GGUF 本体在 `models/`（不入库）
- `hub/W10-REPORT.md`（本报告）
