# INSTALL.md — 提炼输入法（Mine Input）安装指南

[English](INSTALL.md) | **简体中文**

> 详细安装步骤：macOS（构建 + 开发版安装）、Android（APK 侧载）、语音模型、AI 模型与 Hub、
> AI 配置、卸载与故障速查。速览版见 [README.zh-CN.md](README.zh-CN.md)。
> 所有脚本均可**幂等重跑**；外部二进制/模型一律 SHA256 钉死或记录在案（[THIRD_PARTY.md](THIRD_PARTY.md)）。

## 0. 总览：四块东西

| 块 | 装什么 | 必需性 |
|---|---|---|
| ① macOS 输入法 | librime + Squirrel-dev.app + 混合输入方案 | 核心 |
| ② Android 输入法 | APK（混输引擎 + PTT 语音） | 核心（Android 用户） |
| ③ 语音模型 | SenseVoice + VAD + 标点（~550MB，不入库） | 用 PTT 语音才需要 |
| ④ AI：模型 + Hub | llama.cpp + Qwen2.5 GGUF + Hub（Docker） | 用 AI 提词/同步才需要；不装则 AI 关、打字语音不受影响 |

系统要求：macOS 13+（Apple Silicon 优先，当前构建仅 arm64）；Android 10+（minSDK 29）；
Docker（仅 Hub 需要）。全局安装项：`brew install boost cmake`（macOS 构建）、Xcode CLI 工具。

---

## 1. macOS：构建并安装开发版

> 开发版安装**不动你现有的输入法**：bundle id / 输入源 / RIME 用户目录全部带 `dev`/`mine-dev`
> 隔离（只写 `~/Library/Input Methods/Squirrel-dev.app` 与 `~/Library/Rime-mine-dev`）。

```bash
git clone <本仓> mine-input && cd mine-input

# 1) 依赖
brew install boost cmake          # + Xcode（App Store 装一次）

# 2) 编译 librime（BSD-3）→ core/librime
bash build/build-librime.sh

# 3) 取 Squirrel 源码并构建（脚本会提示 clone；子模块自动 init）
git clone --depth 1 https://github.com/rime/squirrel.git macos/squirrel
cd macos/squirrel && git submodule update --init --recursive --depth 1 --recommend-shallow && cd ../..
bash build/build-squirrel.sh      # 自动打 build/squirrel-*.patch（dev 隔离 + 候选横排 + W7/W20 挂点）

# 4) 安装 + 部署「五笔86+拼音混合」方案
bash build/install-dev.sh         # 装入 ~/Library/Input Methods/Squirrel-dev.app
```

装完在 系统设置 → 键盘 → 输入法 添加「**提炼输入法**」（dev）。验证：

```bash
bash build/verify-schema.sh       # rime_deployer/console 级 schema 加载与候选产出
```

手工测试：TextEdit 里输入 `w`（单字）、`gggg`（词组）、`nihao`（拼音并联）、`zni`（拼音反查）。

## 2. Android：构建 APK 并侧载

```bash
cd android
bash fetch-deps.sh                # sherpa-onnx 2.0.1 AAR + commons jar（SHA256 校验）
bash fetch-rime-jni.sh            # Trime v3.3.13 预编译 librime_jni.so（GPL，见 android/LICENSE.md）
./gradlew assembleDebug           # → app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

- 首次启用：设置 → 系统 → 语言和输入法 → 开启「提炼输入法」，并走**知情同意页**
  （默认全关、逐项显式同意、随时撤回）；
- PTT 语音首次使用时自动下载模型（SHA256 校验）；
- `librime_jni.so` 缺失时脚本会先跑 `engine/build/fetch-trime-apk.sh` 重新提取。

## 3. 语音模型（macOS，~550MB，不入库）

```bash
mkdir -p voice/models && cd voice/models
curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2
curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2
tar xjf sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2
tar xjf sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2
```

SHA256 与体积见 `voice/W2-REPORT.md` §3；Python 侧用 venv 装 `sherpa-onnx`（PoC：`voice/poc/asr_poc.py`）。

## 4. AI：模型 + Hub

### 4a. 模型（Qwen2.5 GGUF，**不随包分发**，自取 + SHA256 校验）

```bash
./models/fetch_model.sh             # 7B Q4_K_M（4.68GB，ModelScope 源；备选 fallback=0.5B）
./models/fetch_model.sh verify      # 只校验
./models/fetch_model.sh install     # 灌入 Hub 模型卷
```

### 4b. 模型服务（宿主机原生 7B，推荐）

```bash
./models/run-llama-native.sh load   # launchd 托管：自启/崩溃拉起/日志轮转
./models/run-llama-native.sh status # 应显示 launchd 在 + /health 200（端口 :8092）
```

### 4c. Hub（Docker，一台机器服务 2–5 个朋友）

```bash
cd hub
./tls/gen-certs.sh                  # 自签 CA + HTTPS 证书（私钥不入库）
docker compose up -d --build        # Hub + nginx TLS 边车
./smoke.sh                          # 全绿（PASS=42）即可对外
```

朋友侧拿到三样：地址 `https://<host>:8443`、CA 证书 `hub/tls/certs/ca.crt`、注册方式——
详见 [hub/DEPLOY-FRIENDS.md](hub/DEPLOY-FRIENDS.md)（含防火墙、备份恢复、故障速查）。

## 5. AI 配置（config/ai.yaml）

```bash
cp config/ai.example.yaml config/ai.yaml    # 按需改 backend/model/endpoint/budget_ms
eval "$(config/ai-env.sh)"                  # 映射为 MODEL_NAME/MODEL_URL/SUGGEST_BUDGET_MS/...
docker compose -f hub/docker-compose.yml -f config/ai-compose.override.yml up -d
```

- 逐键说明见 [config/ai.example.yaml](config/ai.example.yaml)（backend=`local_gguf`|`openai_compatible`|`hub`）；
- 不想用文件：直接 export 同名环境变量（env 映射表在 ai.example.yaml 尾部），**环境变量优先**；
- `ai-compose.override.yml` 只为把 `budget_ms` 透传进容器（compose 合并已实测），不改 `hub/` 原文件；
- 验证：`curl --cacert hub/tls/certs/ca.crt https://localhost:8443/healthz`，再看 `/v1/suggest`
  返回的 `source` 字段是否如实标注你配的模型。

## 6. 卸载

```bash
bash build/uninstall-dev.sh         # macOS：移除 Squirrel-dev.app + Rime-mine-dev（只删自己的）
adb uninstall com.mineinput.ime     # Android
docker compose down                 # Hub（数据在 hub-data 卷，不丢）
./models/run-llama-native.sh unload # 模型服务
```

## 7. 故障速查

| 症状 | 处理 |
|---|---|
| librime 编译报「platform no longer supported by libc++」 | 清 `core/librime/deps/*/build` 重跑（脚本已固定 `MACOSX_DEPLOYMENT_TARGET=13.0`） |
| 装完切换输入法后打不出字 | 旧进程占 inode：重跑 `install-dev.sh`（内含 pkill + 存活门），看 IMK 端点日志 |
| Android 构建缺 AAR/.so | 重跑 `android/fetch-deps.sh` / `android/fetch-rime-jni.sh`（幂等，SHA256 校验） |
| Hub suggest 降级成 stub | 模型服务没起：`models/run-llama-native.sh status`；或 `SUGGEST_ALLOW_STUB_FALLBACK=0` 强制不降级 |
| curl 报证书错 | 没带 `--cacert hub/tls/certs/ca.crt`（自签 CA 必须显式信任） |
| 7B 在 Docker VM OOM | 用宿主机原生跑（§4b）或 0.5B 降级档（`MODEL_NAME=qwen2.5-0.5b-instruct-q4_k_m`） |
| 恢复备份后 token 全失效 | 备份包内 `hub-secret` 与现网不同——用备份同包恢复或重新登录 |

更多：[hub/DEPLOY-FRIENDS.md](hub/DEPLOY-FRIENDS.md) §7、各 `W*-REPORT.md` 的实测记录。
