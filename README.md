# 提炼输入法（Mine Input）

[![CI](https://github.com/PeterKO22/mine-input/actions/workflows/ci.yml/badge.svg)](https://github.com/PeterKO22/mine-input/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/PeterKO22/mine-input)](https://github.com/PeterKO22/mine-input/releases/latest)

> 一套 **五笔 86 + 拼音混合、按住即说** 的输入法，跑在你的 **macOS** 与 **Android** 上；
> 背后是**你自己的 AI**——懂你的上下文，像动态提词器一样跟着你的语音走；
> 习惯数据全端同步，**隐私不出你自己的地盘**。

- 产品名：**提炼输入法**（英文 **Mine Input**）｜仓库名：`mine-input`
- 许可证：**GPL-3.0-only**（[LICENSE](LICENSE)）｜第三方归属：[THIRD_PARTY.md](THIRD_PARTY.md)
- 当前范围：**macOS + Android 先行**（Windows / iOS 后续再排）；个人自用，亦可分发给朋友
  （数据互相隔离、知情同意、自助安装）

---

## 功能矩阵

| 能力 | 说明 | macOS | Android |
|---|---|---|---|
| **混合输入** | 五笔 86 与拼音同流混输：形码优先、拼音并联兜底、免切换免模式感知；拼音反查五笔编码；词频学习 + 自动造词常开；自定义短语 | ✅ | ✅（同一引擎逐项一致，按键→候选 p95 0.27ms） |
| **PTT 语音** | 按住指定键（默认右⌘，可配）即说，松开上屏，Esc 取消；说话期间候选区流式滚动转写；全离线管线（VAD → SenseVoice → 标点 → 热词纠偏）；**音频不落盘**（内存环形缓冲，转写完即弃） | ✅ 全管线 <0.5s | ✅ 键盘 PTT 大键长按 |
| **动态提词器** | ⌥Esc 唤起流式建议面板；随打即出智能候选（单独一组、只建议不上屏不抢焦点）；语音输入中建议实时刷新；AI 挂掉/超时不影响打字 | ✅ | 规划中 |
| **记忆库** | 「在什么情况下，我回了什么话」为单位的 JSONL 对话记忆（需求 N6）：按日时间线查看/编辑/删除/搜索/导出（⌥M 浮层）；取消不记；熔断/清空联动 | ✅ | 规划中 |
| **提案执行契约** | AI 不止提示要打什么字——直接给**方案**，用户显式「确认执行」后开任务执行到出结果（需求 N7）：SPI v2 `propose/confirm/observe`，**未 confirm 不得执行**红线有单测断言 | ✅ | 规划中 |
| **自适应学习** | L1 词频造词随用随学 → L2 习惯画像（只建议不自动改）→ L3 个人语料热词（默认关）；一键重置回出厂手感；学习成果跨端共享 | ✅ | ✅ |
| **数据同步** | 设备 ⇄ 自有 Hub（TLS），分钟级最终一致，断网静默排队；多用户分区（朋友数据互不可见） | ✅ | ✅ |
| **上下文引擎** | 采集分级 C0（输入框前后文）/ C1（屏幕 OCR + 音频转写，仅输入时触发）；敏感应用黑名单、密码框自动暂停；一键熔断 | ✅ | C0 |

性能底线（实测）：按键→上屏 ≤30ms（本地路径）、语音松开→上屏 ≤1.5s（实测 0.38–0.49s）、
AI 建议异步 800ms 预算弃本轮、**永不阻塞输入**。

---

## 🔒 安全承诺

**你的数据只进你自己的设备和你自己的 Hub，不经过任何第三方云。** 具体承诺：

1. **无遥测**——本项目不含任何统计/埋点/崩溃上报；不向开发者或任何第三方发送数据；
2. **数据去向唯一**——输入习惯、记忆库、交互日志只存「你的设备 + 你自托管的 Hub」（或干脆不同步）；
3. **采集分级 + 显式同意**——默认仅 C0；高敏采集（屏幕/音频）逐项显式同意、随时撤回；
   密码框/支付场景自动暂停且不可关闭；仅输入时采集，**无持续录音**；
4. **一键熔断**——全局停止一切采集，状态常显；一键清空、一键学习重置、一键导出随时可用；
5. **音频不落盘**——语音走内存环形缓冲，转写完即弃；
6. **传输 TLS**——Hub 对外仅 HTTPS（自签 CA，见 [hub/DEPLOY-FRIENDS.md](hub/DEPLOY-FRIENDS.md)）；
   多用户数据分区隔离。

信任边界（诚实版）：自托管 Hub 的**主机管理员**当前可读数据库文件（静态加密与 E2E 零知识为预留项）；
介意就不同步敏感内容。完整威胁模型、披露流程与安全审计见 **[SECURITY.md](SECURITY.md)**。

---

## 🤖 AI 可配置专区

AI 后端**完全由你配置**，全部旋钮就 4 个——文件在
**[config/ai.example.yaml](config/ai.example.yaml)**（含逐键注释）：

```bash
cp config/ai.example.yaml config/ai.yaml   # 改你自己的（不入库）
```

| 键 | 取值 | 含义 |
|---|---|---|
| `backend` | `local_gguf` \| `openai_compatible` \| `hub` | 后端形态：本地 GGUF（默认，离线优先）/ 任意 OpenAI 兼容接口（预留）/ 统一走你的 Hub |
| `model` | 如 `qwen2.5-7b-instruct-q4_k_m` | 模型名（如实标注在建议的 `source` 字段，不冒充） |
| `endpoint` | URL | 后端地址：llama-server / OpenAI 兼容 base / Hub 地址 |
| `budget_ms` | 默认 `800` | 单轮建议总预算，超时弃本轮，AI 永不阻塞输入 |

让它生效（映射为 Hub 环境变量，实测可用）：

```bash
eval "$(config/ai-env.sh)"
docker compose -f hub/docker-compose.yml -f config/ai-compose.override.yml up -d
```

不想用文件也行：直接 `export MODEL_NAME=... MODEL_URL=... SUGGEST_BUDGET_MS=...`
（env 映射表见 [config/ai.example.yaml](config/ai.example.yaml) 尾部、步骤见 [INSTALL.md](INSTALL.md) §5）。
换任何 GGUF 模型：`models/fetch_model.sh install` → 改 `model` → 重启 Hub，**零代码改动**。

> **未来**：Hub 账号登录后，模型选择会做成设置页可视化下拉（登录即自动下发同一份配置），
> 不再手改 YAML；本文件格式保持向后兼容。

---

## 安装

详细步骤（含依赖、模型、Hub、故障速查）见 **[INSTALL.md](INSTALL.md)**。速览：

**macOS**（开发版安装，不动你现有输入法）：

```bash
git clone <本仓> && cd mine-input
bash build/build-librime.sh      # 编译 librime（brew install boost cmake）
bash build/build-squirrel.sh     # 构建 Squirrel-dev.app
bash build/install-dev.sh        # 装入 ~/Library/Input Methods + 部署混合方案
```

**Android**（侧载 APK，不上商店）：

```bash
cd android
bash fetch-deps.sh               # sherpa-onnx AAR + jar（SHA256 钉死）
bash fetch-rime-jni.sh           # Trime 预编译 librime_jni.so（GPL，见 android/LICENSE.md）
./gradlew assembleDebug          # 出 APK → adb install -r app/build/outputs/apk/debug/app-debug.apk
```

**AI Hub**（一台机器跑服务，朋友可连）：见 [hub/DEPLOY-FRIENDS.md](hub/DEPLOY-FRIENDS.md)（三条命令起服务）。

---

## 构建依赖清单

| 平台/部件 | 依赖 | 许可证 |
|---|---|---|
| macOS 公共 | Xcode（clang）、CMake ≥3.x、Homebrew `boost` `cmake` | — |
| macOS 壳 | [rime/squirrel](https://github.com/rime/squirrel)（fork + `build/squirrel-*.patch`）、librime（make deps 自取 opencc/leveldb/marisa/yaml-cpp/glog） | GPLv3 / BSD-3 及各宽松许可（[THIRD_PARTY.md](THIRD_PARTY.md) B 表） |
| Android | Android SDK（minSDK 29）、Gradle/AGP（内置 Kotlin）、`fetch-deps.sh`（sherpa-onnx 2.0.1 AAR、commons-compress/io）、`fetch-rime-jni.sh`（Trime `librime_jni.so`） | 见 [android/LICENSE.md](android/LICENSE.md) |
| 语音 | sherpa-onnx + SenseVoiceSmall(int8) / Silero VAD / CT-Transformer 标点（`voice/models/`，不入库） | Apache-2.0 / MIT |
| AI | llama.cpp（b12078，`ghcr.io/ggml-org/llama.cpp:server` 或宿主机原生）+ Qwen2.5 GGUF（**不随包分发**，`models/fetch_model.sh`） | MIT / Apache-2.0 |
| Hub | Docker Compose、Python 3（fastapi/uvicorn/pydantic/httpx，`hub/requirements.txt`）、nginx TLS 边车 | MIT / BSD-3 |

---

## 架构图

```
┌─────────────────────────── 你的设备 ────────────────────────────┐
│  macOS (Squirrel-dev.app, GPLv3 派生)     Android (Kotlin IMS)  │
│  ┌─────────────────────────┐  ┌─────────────────────────────┐  │
│  │ 混合输入 schema/        │  │ 混输引擎 (librime_jni.so)   │  │
│  │ (librime BSD-3)         │  │ + PTT 语音 (sherpa-onnx)    │  │
│  ├─────────────────────────┤  ├─────────────────────────────┤  │
│  │ PTT 语音 (sherpa-onnx)  │  │ 同步 SDK (离线队列)         │  │
│  │ 提词器/记忆库/提案卡    │  └──────────────┬──────────────┘  │
│  │ 上下文引擎 C0/C1        │                 │                 │
│  ├─────────────────────────┤                 │                 │
│  │ AI SPI (ai/spi)         │                 │                 │
│  │  rescore/complete/...   │                 │                 │
│  │  propose/confirm/observe│                 │                 │
│  └───────────┬─────────────┘                 │                 │
└──────────────┼───────────────────────────────┼─────────────────┘
               │  同步 SDK（TLS，断网排队）     │
               ▼                               ▼
┌──────────────────── 你的 Hub（自托管，Docker）──────────────────┐
│  FastAPI + SQLite（多用户分区）  ←→  llama.cpp llama-server     │
│  /v1/auth /v1/sync /v1/ingest /v1/suggest(SSE)   Qwen2.5 GGUF   │
│  nginx TLS 边车 :8443（自签 CA）      （local_gguf 后端）        │
└─────────────────────────────────────────────────────────────────┘
        数据只有这两个去向；无第三方云、无遥测（见 🔒 安全承诺）
```

---

## 路线图

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0–M3 | 骨架 → 混合输入 + 自学习 → 语音 MVP → AI 本地 | ✅ 已完成 |
| M4 | Hub 同步 + 多用户 + TLS + 备份 | ✅ 已完成 |
| N6–N8 | 记忆库 JSONL / 提案执行契约 / 记忆管理界面 | ✅ 已完成 |
| 近期 | macOS 设置界面 UI、L2 习惯报告 UI、rescore 本地挂点接真后端、真人实测矩阵 | 🚧 进行中 |
| M5 | 签名分发（Apple Developer 公证，分发给朋友） | ⏳ 待决策 |
| M6+ | Android 提词器/记忆库、账号登录可视化模型选择、Windows/iOS 再评估 | 📋 规划 |

---

## 文档索引

| 文档 | 说明 |
|---|---|
| [INSTALL.md](INSTALL.md) | 安装与构建详细步骤 |
| [THIRD_PARTY.md](THIRD_PARTY.md) | 第三方许可证归属（逐条 curl 实证）与分发边界 |
| [SECURITY.md](SECURITY.md) | 安全承诺、威胁模型、漏洞披露 |
| [docs/需求文档-v1.0.md](docs/需求文档-v1.0.md) | 需求定稿：决策台账 D1–D15、FR/NFR |
| [docs/技术方案-v0.4.md](docs/技术方案-v0.4.md) | 技术定稿：架构、模块、里程碑 |
| [docs/开发任务计划.md](docs/开发任务计划.md) | 任务图与各车道实测记录 |
| [docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md) | 发布前检查清单 |
| [hub/DEPLOY-FRIENDS.md](hub/DEPLOY-FRIENDS.md) | Hub 朋友部署一页纸 |
| [android/LICENSE.md](android/LICENSE.md) | Android 端 GPL 许可说明与换芯路线 |

## 许可证

本项目以 **GPL-3.0-only** 发布（[LICENSE](LICENSE)）——因 macOS 壳派生自 Squirrel（GPL-3.0）、
Android JNI 层复用 Trime（GPL-3.0-or-later），GPLv3 是合规交集。第三方组件归属与分发边界见
[THIRD_PARTY.md](THIRD_PARTY.md)。© 2026 Mine Input contributors。
