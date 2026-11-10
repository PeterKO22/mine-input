# INSTALL.md — Mine Input (提炼输入法) Installation Guide

**English** | [简体中文](INSTALL.zh-CN.md)

> Detailed installation steps: macOS (build + dev install), Android (APK sideload), voice models,
> AI model and Hub, AI configuration, uninstall, and troubleshooting. For the quick version see
> [README.md](README.md).
> All scripts are **idempotent** — safe to re-run; external binaries/models are SHA256-pinned or
> recorded ([THIRD_PARTY.md](THIRD_PARTY.md)).

## 0. Overview: Four Pieces

| Piece | What gets installed | Required? |
|---|---|---|
| ① macOS IME | librime + Squirrel-dev.app + hybrid input schema | Core |
| ② Android IME | APK (hybrid engine + PTT voice) | Core (for Android users) |
| ③ Voice models | SenseVoice + VAD + punctuation (~550MB, not committed) | Only for PTT voice |
| ④ AI: model + Hub | llama.cpp + Qwen2.5 GGUF + Hub (Docker) | Only for AI suggestions/sync; skip it and AI is simply off — typing and voice are unaffected |

System requirements: macOS 13+ (Apple Silicon preferred; the current build is arm64-only);
Android 10+ (minSDK 29); Docker (Hub only). Global prerequisites: `brew install boost cmake`
(macOS build), Xcode command-line tools.

---

## 1. macOS: Build and Install the Dev Version

> The dev install **leaves your existing input methods untouched**: bundle id / input source / RIME
> user directory are all isolated under `dev`/`mine-dev` (it only writes
> `~/Library/Input Methods/Squirrel-dev.app` and `~/Library/Rime-mine-dev`).

```bash
git clone <本仓> mine-input && cd mine-input

# 1) Dependencies
brew install boost cmake          # + Xcode (install once from the App Store)

# 2) Build librime (BSD-3) → core/librime
bash build/build-librime.sh

# 3) Fetch the Squirrel sources and build (the script prompts the clone; submodules auto-init)
git clone --depth 1 https://github.com/rime/squirrel.git macos/squirrel
cd macos/squirrel && git submodule update --init --recursive --depth 1 --recommend-shallow && cd ../..
bash build/build-squirrel.sh      # applies build/squirrel-*.patch automatically (dev isolation + horizontal candidates + W7/W20 hooks)

# 4) Install + deploy the "Wubi 86 + Pinyin hybrid" schema
bash build/install-dev.sh         # installs to ~/Library/Input Methods/Squirrel-dev.app
```

After installing, add "**Mine Input** (提炼输入法)" (dev) under System Settings → Keyboard →
Input Methods. Verify with:

```bash
bash build/verify-schema.sh       # schema loading & candidate output at the rime_deployer/console level
```

Manual smoke test: in TextEdit type `w` (single character), `gggg` (phrase), `nihao` (Pinyin
fallback), `zni` (Pinyin reverse lookup).

## 2. Android: Build the APK and Sideload

```bash
cd android
bash fetch-deps.sh                # sherpa-onnx 2.0.1 AAR + commons jars (SHA256-verified)
bash fetch-rime-jni.sh            # Trime v3.3.13 prebuilt librime_jni.so (GPL, see android/LICENSE.md)
./gradlew assembleDebug           # → app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

- First enable: Settings → System → Languages & input → turn on "Mine Input (提炼输入法)",
  and go through the **informed-consent page** (everything off by default, item-by-item explicit
  consent, withdrawable at any time);
- PTT voice downloads its models automatically on first use (SHA256-verified);
- If `librime_jni.so` is missing, the script first runs `engine/build/fetch-trime-apk.sh` to
  re-extract it.

## 3. Voice Models (macOS, ~550MB, not committed)

```bash
mkdir -p voice/models && cd voice/models
curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2
curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
curl -L -O https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2
tar xjf sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2
tar xjf sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8.tar.bz2
```

SHA256 sums and file sizes are in `voice/W2-REPORT.md` §3; on the Python side install
`sherpa-onnx` into a venv (PoC: `voice/poc/asr_poc.py`).

## 4. AI: Model + Hub

### 4a. Model (Qwen2.5 GGUF, **not distributed with the package** — fetch it yourself, SHA256-verified)

```bash
./models/fetch_model.sh             # 7B Q4_K_M (4.68GB, ModelScope source; fallback=0.5B)
./models/fetch_model.sh verify      # verify only
./models/fetch_model.sh install     # install into the Hub model volume
```

### 4b. Model server (native 7B on the host, recommended)

The model server is **off by default and never auto-starts** (W30 hard guarantee — nothing
loads the model until you explicitly turn it on). Turn it on from the ⌥M management panel
(「本地模型（7B）」 toggle: confirm the resource hint → start + health check) or from the CLI:

```bash
./models/manage-model-service.sh start   # explicit on: start + health check (/v1/models or /completion)
./models/manage-model-service.sh status  # state=not-loaded|loading|ready + probe result
./models/manage-model-service.sh stop    # explicit off: stop immediately (idempotent)
```

`models/run-llama-native.sh` is the internal engine (do not call it directly). The old
launchd auto-start (`load`/`unload`/`serve`, `com.mineinput.llama.plist`) was **removed**:
login auto-start / crash respawn violated "the user must open it before it loads";
`manage-model-service.sh stop/status` also purges any previously installed leftover agent.

### 4c. Hub (Docker; one machine serving 2–5 friends)

```bash
cd hub
./tls/gen-certs.sh                  # self-signed CA + HTTPS cert (private key not committed)
docker compose up -d --build        # Hub + nginx TLS sidecar
./smoke.sh                          # all green (PASS=42) and it's ready to serve
```

Friends get three things: the address `https://<host>:8443`, the CA certificate
`hub/tls/certs/ca.crt`, and how to register — details in
[hub/DEPLOY-FRIENDS.md](hub/DEPLOY-FRIENDS.md) (firewall, backup/restore, troubleshooting).

## 5. AI Configuration (config/ai.yaml)

`config/ai.yaml` (copied from `config/ai.example.yaml`) is the **single configuration
entry** for the AI chain — the four keys are all you need to know:

```bash
cp config/ai.example.yaml config/ai.yaml    # edit backend/model/endpoint/budget_ms as needed
eval "$(config/ai-env.sh)"                  # maps to MODEL_NAME/MODEL_URL/SUGGEST_BUDGET_MS/...
docker compose -f hub/docker-compose.yml -f config/ai-compose.override.yml up -d
```

| key | meaning |
|---|---|
| `backend` | AI backend shape: `local_gguf` (local llama.cpp, offline-first) / `openai_compatible` / `hub` |
| `model` | model name, honestly reported in each suggestion's `source` field (e.g. `qwen2.5-7b-instruct-q4_k_m`) |
| `endpoint` | backend address (local llama-server base, e.g. `http://127.0.0.1:8092`) |
| `budget_ms` | per-suggestion latency budget (default 800; over budget the round is dropped, typing never blocks) |

- Per-key documentation is in [config/ai.example.yaml](config/ai.example.yaml)
  (backend=`local_gguf`|`openai_compatible`|`hub`);
- The ⌥M management panel shows the config path with a one-click「打开配置」button
  (opens `config/ai.yaml` in your default editor; copies it from the example on first use);
- Prefer not to use a file: export the same-named environment variables directly (the env mapping
  table is at the end of ai.example.yaml); **environment variables win**;
- `ai-compose.override.yml` exists only to pass `budget_ms` through into the container (the compose
  merge is verified); it changes nothing under `hub/`;
- Verify with `curl --cacert hub/tls/certs/ca.crt https://localhost:8443/healthz`, then check that
  the `source` field returned by `/v1/suggest` faithfully reports the model you configured.

## 6. Uninstall

```bash
bash build/uninstall-dev.sh         # macOS: removes Squirrel-dev.app + Rime-mine-dev (only its own)
adb uninstall com.mineinput.ime     # Android
docker compose down                 # Hub (data lives in the hub-data volume, nothing is lost)
./models/manage-model-service.sh stop  # model server (off = not loaded; idempotent)
```

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| librime build fails with "platform no longer supported by libc++" | Clean `core/librime/deps/*/build` and re-run (the script pins `MACOSX_DEPLOYMENT_TARGET=13.0`) |
| After installing and switching IMEs, nothing types | A stale process is holding the inode: re-run `install-dev.sh` (it contains pkill + a liveness gate) and check the IMK endpoint log |
| Android build missing AAR/.so | Re-run `android/fetch-deps.sh` / `android/fetch-rime-jni.sh` (idempotent, SHA256-verified) |
| Hub suggest degrades to a stub | The model server isn't up (it is **off by default** — turn it on via the ⌥M「本地模型（7B）」toggle or `models/manage-model-service.sh start`): `models/manage-model-service.sh status`; or forbid the fallback with `SUGGEST_ALLOW_STUB_FALLBACK=0` |
| curl reports a certificate error | You didn't pass `--cacert hub/tls/certs/ca.crt` (a self-signed CA must be explicitly trusted) |
| 7B OOMs inside the Docker VM | Run it natively on the host (§4b) or drop to the 0.5B tier (`MODEL_NAME=qwen2.5-0.5b-instruct-q4_k_m`) |
| All tokens invalid after restoring a backup | The backup's `hub-secret` differs from the live one — restore with the backup's bundle or log in again |

More: [hub/DEPLOY-FRIENDS.md](hub/DEPLOY-FRIENDS.md) §7 and the measured records in each
`W*-REPORT.md`.
