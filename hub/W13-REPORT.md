# W13 llama-native-7b 车道报告

> 车道：W13 llama-native-7b（`hub/` + `models/` 目录）｜日期：2026-11-04
> 依据：docs/开发任务计划.md §3 工作约定 + W10-REPORT.md（前置现状）｜hub/README.md
> 结论：**模型服务改宿主机原生跑，7B Q4_K_M 真后端全链路验收达成**——
> smoke ALL GREEN（PASS=43 FAIL=0，含真 7B 档位断言）+ 7B/0.5B 双档延迟表实测。
> W10 的 Docker VM OOM blocker 以「原生跑 + host.docker.internal」绕开（blocker 本体不变，见 §7）。

## 1. 做了什么（对照交付 a–e）

| 交付 | 状态 | 说明 |
|---|---|---|
| (a) `models/run-llama-native.sh` | ✅ | start/stop/restart/status/health 五命令；PID 文件 + 日志 + /health 就绪等待（120s 上界）；llama.cpp 二进制 **GitHub Releases 预编译**（路径见 §2），脚本自动探测（LLAMA_BIN > 本目录预编译 > brew > PATH） |
| (b) hub 配置可切模型后端地址 | ✅ | `docker-compose.yml` `MODEL_URL=${MODEL_URL:-http://host.docker.internal:8092}`（Docker 内访问宿主机）默认指向原生 7B；`MODEL_NAME` 默认 `qwen2.5-7b-instruct-q4_k_m`；compose `llama` 服务保留为 **0.5B 降级档**（`MODEL_URL=http://llama:8091` 一行切回） |
| (c) smoke 全绿复测（真 7B 后端断言） | ✅ | `SMOKE_EXPECT_MODEL` 新增：解析 done 帧 `model` 字段断言档位（不靠 MODEL_NAME 环境自证）；实测 **PASS=43 FAIL=0 / ALL GREEN**，断言行：`done 帧 model=qwen2.5-7b-instruct-q4_k_m（真后端档位断言 含 qwen2.5-7b）`，见 §5 |
| (d) `bench_latency.py` 7B 延迟表 | ✅ | 5 轮/场景实测，7B 与 0.5B 同日同脚本对比表见 §6 |
| (e) 换档文档更新 | ✅ | hub/README.md「模型后端：两档切换」重写（档位表 + 默认档/降级档/drop-in 换档命令）；docker-compose.yml 注释同步；smoke.sh 头部用法同步 |

## 2. llama.cpp 二进制（路径与来源）

| 项 | 值 |
|---|---|
| 来源 | **GitHub Releases 预编译**（brew 未用，无需全局安装） |
| 版本 | llama.cpp `b12078`（`version: 0.8.0-dev (build 12078, commit 19e8a86fe)`，AppleClang 21，Darwin arm64，含 Metal） |
| URL | `https://github.com/ggml-org/llama.cpp/releases/download/b12078/llama-b12078-bin-macos-arm64.tar.gz`（16.5MB，实测可达） |
| 落盘路径 | `models/llama.cpp-b12078/llama-b12078/llama-server`（`run-llama-native.sh` 自动探测此路径；不入库，`models/.gitignore` 挡 `llama.cpp-b*/`） |
| 备选 | `brew install llama.cpp` 或 `LLAMA_BIN=<path>` 覆盖（脚本探测顺序：LLAMA_BIN > 预编译 > /opt/homebrew/bin > PATH） |

运行参数（`run-llama-native.sh start` 默认）：`--host 0.0.0.0 --port 8092 -c 2048`
（8091 留给容器内 0.5B 降级档；8088=Hub、8080/8000/8090 本机已占），模型默认
`qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf`（split 分片喂第一片，W10 已校验就位）。
实测 `/props` → `model_path=…-00001-of-00002.gguf`（7B 确证），`/completion` 探针
`Q: 中国的首都是\nA:` → `北京。`。PID 文件/日志：`models/.llama-native.{pid,log}`。

## 3. hub 后端地址切换（b）

- `hub/docker-compose.yml` hub 服务 env：
  `MODEL_URL: ${MODEL_URL:-http://host.docker.internal:8092}`、
  `MODEL_NAME: ${MODEL_NAME:-qwen2.5-7b-instruct-q4_k_m}`——**默认即原生 7B 档**；
- 容器内访问宿主机统一 `host.docker.internal`（Docker Desktop macOS 内置解析，实测通）；
- **降级档保留**：compose `llama` 服务（`profiles:["model"]`，0.5B，宿主 8091）原样保留，
  切档一行：`MODEL_URL=http://llama:8091 MODEL_NAME=qwen2.5-0.5b-instruct-q4_k_m docker compose up -d`；
- `app/model_backend.py` **零改动**（本来就只认 `MODEL_URL`/`MODEL_NAME` 环境变量，
  done 帧 `model` 字段随实际档位诚实标注）。

## 4. run-llama-native.sh 实测（a）

```text
$ ./models/run-llama-native.sh start
[start] /Users/you/AITECreate/mine-input/models/llama.cpp-b12078/llama-b12078/llama-server
        model=qwen2.5-7b-instruct-q4_k_m (qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf)  port=8092  ctx=2048
[ok] llama-server 健康  http://localhost:8092  pid=47901  log=…/models/.llama-native.log

$ ./models/run-llama-native.sh health
[ok] llama-server 健康  http://localhost:8092
```

start/stop/restart/status/health 全命令可用；stop 按 PID TERM→KILL，status 同报
二进制路径/模型档位//health 结果。

## 5. smoke 全绿复测（c）——真 7B 后端断言

```text
$ SMOKE_EXPECT_MODEL=qwen2.5-7b ./smoke.sh
…
  [PASS] done 帧 backend=llama.cpp（真模型）
  [PASS] done 帧带 prompt_version（提示词模板版本化）
  [PASS] done 帧带 timings（延迟实测字段）
  [PASS] suggestion 帧 source 标注真模型
  [PASS] 真模型流式多帧（suggestion 帧数=2）
  [PASS] done 帧 model=qwen2.5-7b-instruct-q4_k_m（真后端档位断言 含 qwen2.5-7b）
  [PASS] voice_correct done ok + llama.cpp
  [PASS] rescore 每行一帧多帧（帧数=4）
  [PASS] 弃轮后 llama-server 仍健康
  [PASS] 弃轮后 suggest 链路仍可用
…
PASS=43 FAIL=0

SMOKE: ALL GREEN
```

- 断言机制（W13 新增）：`SMOKE_EXPECT_MODEL=<子串>` → smoke 解析 SSE **done 帧 `model` 字段**
  断言含期望子串（真 7B 后端证据链：done 帧由 Hub 按实际后端标注，suggestion 帧
  `source="llama.cpp:qwen2.5-7b-instruct-q4_k_m"` 交叉印证；本轮 `/props` model_path 另证 §2）；
- 档数：W10=42 项 → W13=**43 项**（+1 档位断言），全绿；
- 11e（客户端弃轮不扰服务端）在原生 7B 上复测通过——原生 llama-server 同样不受弃轮影响。

## 6. 延迟实测表（d）——7B 原生 vs 0.5B 容器（同日同脚本，各 5 轮均值）

`hub/bench_latency.py`（零改动），走完整链路 HTTP→Hub→llama.cpp→SSE：

| 场景 | 档位 | 首token延迟 ttft_ms(服务端) | 首帧到达 ms(客户端) | 每帧间隔 ms | 总耗时 ms | 帧数 | token数 |
|---|---|---|---|---|---|---|---|
| continuation | **7B 原生** | 22.4 | 25.1 | 60.2 | **85.3** | 2.0 | 5.8 |
| voice_correct | **7B 原生** | 17.7 | 20.2 | 73.1 | **93.4** | 2.0 | 7.0 |
| rescore | **7B 原生** | 20.3 | 34.6 | 30.5 | **126.1** | 4.0 | 10.0 |
| teleprompter | **7B 原生** | 32.0 | 36.2 | 54.4 | **90.7** | 2.0 | 5.0 |
| continuation | 0.5B 容器 | 57.1 | 59.6 | 110.7 | 297.2 | 2.8 | 6.2 |
| voice_correct | 0.5B 容器 | 33.2 | 35.8 | 114.2 | 298.7 | 2.8 | 7.0 |
| rescore | 0.5B 容器 | 51.8 | 101.8 | 128.6 | 487.5 | 4.0 | 10.0 |
| teleprompter | 0.5B 容器 | 52.2 | 54.8 | 99.2 | 219.1 | 2.4 | 4.6 |

（5 轮均值；ttft=请求进 Hub→上游首 token；首帧/间隔/总耗时为客户端墙钟；
两档均以 done 帧 `model` 字段为准：`qwen2.5-7b-instruct-q4_k_m` /
`qwen2.5-0.5b-instruct-q4_k_m`。0.5B 行为 W13 同日复测值，W10 表（ttft 27–57ms、
总耗时 103–336ms）同量级可对照。）

- **7B 全场景总耗时 85–126ms，均 ≪ 800ms 预算**（限 max_tokens=32 短输出）；
- **7B 反而比 0.5B 快 2–3 倍**：原生 Metal GPU 推理 vs Docker VM 内 CPU 推理——
  改原生跑同时解决内存 blocker 和延迟；0.5B 容器档 rescore 总耗时 487ms 已接近预算一半；
- 逐帧流式真实发生（7B 帧距 31–73ms，非一次返回）；
- 输出质量肉眼可辨提升：7B continuation 出「销售目标和市场策略」类连贯续写，
  0.5B 档 W10 已知偶尔回显输入前缀（遗留项未复测统计）。

## 7. 遗留与 blocker

**W10 blocker 状态：本体不变，已绕开。** 7B Q4_K_M 仍无法在 Docker Desktop VM
（MemTotal 7.75GiB，共驻 ~20 容器占 ~3.5GB）内跑（OOMKilled 实证，见 W10-REPORT §7）——
该事实未变；W13 的解法是**模型服务出 Docker、宿主机原生跑**（128GB 统一内存 + Metal），
Hub 容器经 `host.docker.internal:8092` 访问。若坚持容器化模型服务，仍需
Docker VM ≥8GB（建议 16GB）后按 compose llama + `MODEL_FILE` 一行换装。

其他遗留（沿承 W10）：

1. `score` 仍为启发式占位（接 logits 置信度后续做）；
2. 审计日志仍 print 字段（不落库），沿承 W4 结论；
3. 原生服务无 launchd 守护（`run-llama-native.sh start` 需手动/开机脚本拉起；
   Hub 的 `SUGGEST_ALLOW_STUB_FALLBACK=1` 在模型服务未起时降级桩兜底，不冒充真模型）；
4. bench 仅测短输出（max_tokens=32）；长输出/并发压测未做；
5. `SMOKE_EXPECT_MODEL` 未设时档位断言 SKIP（防误伤降级档复测），复测请显式传
   `SMOKE_EXPECT_MODEL=qwen2.5-7b`。

## 8. 产物清单

- `models/run-llama-native.sh`（宿主机原生 llama.cpp 管理：start/stop/restart/status/health）
- `models/llama.cpp-b12078/`（GitHub Releases 预编译二进制，不入库）`models/.gitignore`（+忽略项）
- `hub/docker-compose.yml`（MODEL_URL/MODEL_NAME 可切，默认 host.docker.internal:8092 原生 7B；
  llama 服务保留 0.5B 降级档）
- `hub/smoke.sh`（+W13 真后端档位断言 SMOKE_EXPECT_MODEL；默认健康检查地址随默认档 :8092）
- `hub/README.md`（「模型后端：两档切换」换档文档）
- `hub/bench_latency.py`（零改动，7B/0.5B 双档实测数据在本报告 §6）
- `hub/W13-REPORT.md`（本报告）
