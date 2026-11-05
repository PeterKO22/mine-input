# Mine Input (提炼输入法)

[![CI](https://github.com/PeterKO22/mine-input/actions/workflows/ci.yml/badge.svg)](https://github.com/PeterKO22/mine-input/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/PeterKO22/mine-input)](https://github.com/PeterKO22/mine-input/releases/latest)

**English** | [简体中文](README.zh-CN.md)

> An input method that mixes **Wubi 86 + Pinyin in one stream** with **push-to-talk** speech,
> running on your **macOS** and **Android** devices; behind it is **your own AI** — it knows your
> context and follows your voice like a dynamic teleprompter; habit data syncs across your
> devices, and **your privacy never leaves your own turf**.

- Product name: **Mine Input** (Chinese: **提炼输入法**) | Repository: `mine-input`
- License: **GPL-3.0-only** ([LICENSE](LICENSE)) | Third-party attributions: [THIRD_PARTY.md](THIRD_PARTY.md)
- Current scope: **macOS + Android first** (Windows / iOS to be scheduled later); built for personal use,
  also distributable to friends (per-user data isolation, informed consent, self-service install)

---

## Feature Matrix

| Capability | Description | macOS | Android |
|---|---|---|---|
| **Hybrid input** | Wubi 86 and Pinyin typed in a single stream: shape codes take priority with Pinyin running in parallel as fallback — no switching, no mode awareness; reverse-lookup Wubi codes from Pinyin; frequency learning + auto word-building always on; custom phrases | ✅ | ✅ (same engine, feature-by-feature identical; keystroke→candidate p95 0.27ms) |
| **PTT voice** | Hold a designated key (right ⌘ by default, configurable) to speak, release to commit, Esc to cancel; the candidate area streams the transcription as you speak; fully offline pipeline (VAD → SenseVoice → punctuation → hotword correction); **audio never touches disk** (in-memory ring buffer, discarded once transcribed) | ✅ full pipeline <0.5s | ✅ keyboard PTT via long-press on a large key |
| **Dynamic teleprompter** | ⌥Esc summons a streaming suggestion panel; smart candidates appear as you type (in a separate group — suggest-only, never commits, never steals focus); suggestions refresh in real time during voice input; if the AI dies or times out, typing is unaffected | ✅ | Planned |
| **Memory store** | JSONL conversation memory keyed on "in this situation, here's what I replied" (requirement N6): browse/edit/delete/search/export on a daily timeline (⌥M overlay); cancelled actions are not recorded; circuit breaker and clear-all are linked | ✅ | Planned |
| **Proposal execution contract** | The AI doesn't just hint at what to type — it hands you a **proposal**, and only after the user explicitly "confirms execution" does a task run through to a result (requirement N7): SPI v2 `propose/confirm/observe`; the red line "**no execution without confirm**" is enforced by unit-test assertions | ✅ | Planned |
| **Adaptive learning** | L1 frequency-based word building learns as you go → L2 habit profile (suggests only, never auto-modifies) → L3 personal-corpus hotwords (off by default); one-click reset back to factory feel; learning results shared across devices | ✅ | ✅ |
| **Data sync** | Device ⇄ self-hosted Hub (TLS), minute-level eventual consistency, silently queues while offline; multi-user partitioning (friends' data invisible to one another) | ✅ | ✅ |
| **Context engine** | Tiered capture: C0 (input-field context) / C1 (screen OCR + audio transcription, triggered only while typing); sensitive-app blacklist, auto-pause in password fields; one-click circuit breaker | ✅ | C0 |

Performance floor (measured): keystroke→commit ≤30ms (local path), voice release→commit ≤1.5s
(measured 0.38–0.49s), AI suggestions get an async 800ms budget and the round is dropped on timeout —
**typing is never blocked**.

---

## 🔒 Security Promises

**Your data goes only into your own devices and your own Hub — never any third-party cloud.** Specific promises:

1. **No telemetry** — this project contains no analytics/tracking/crash reporting; nothing is sent to the
   developers or any third party;
2. **One destination only** — typing habits, memory store, and interaction logs live only on
   "your device + the Hub you self-host" (or simply aren't synced at all);
3. **Tiered capture + explicit consent** — C0 only by default; high-sensitivity capture (screen/audio)
   requires item-by-item explicit consent and can be withdrawn at any time; password fields / payment
   scenarios auto-pause and this cannot be turned off; capture happens only while typing —
   **no continuous recording**;
4. **One-click circuit breaker** — stops all capture globally, with the status always visible; one-click
   clear-all, one-click learning reset, and one-click export are always available;
5. **Audio never touches disk** — voice goes through an in-memory ring buffer and is discarded once
   transcribed;
6. **TLS in transit** — the Hub exposes HTTPS only (self-signed CA, see
   [hub/DEPLOY-FRIENDS.md](hub/DEPLOY-FRIENDS.md)); multi-user data is partitioned and isolated.

Trust boundary (the honest version): the **host administrator** of a self-hosted Hub can currently read the
database files (at-rest encryption and E2E zero-knowledge are reserved items); if that bothers you, just
don't sync sensitive content. The full threat model, disclosure process, and security audit are in
**[SECURITY.md](SECURITY.md)**.

---

## 🤖 AI Configuration

The AI backend is **entirely yours to configure**, with just 4 knobs — the file is
**[config/ai.example.yaml](config/ai.example.yaml)** (annotated key by key):

```bash
cp config/ai.example.yaml config/ai.yaml   # make it your own (not committed)
```

| Key | Values | Meaning |
|---|---|---|
| `backend` | `local_gguf` \| `openai_compatible` \| `hub` | Backend shape: local GGUF (default, offline-first) / any OpenAI-compatible API (reserved) / everything through your Hub |
| `model` | e.g. `qwen2.5-7b-instruct-q4_k_m` | Model name (reported faithfully in the suggestion's `source` field — never passed off as something else) |
| `endpoint` | URL | Backend address: llama-server / OpenAI-compatible base / Hub address |
| `budget_ms` | default `800` | Total budget for one suggestion round; on timeout the round is dropped — AI never blocks typing |

To activate it (mapped to Hub environment variables, verified working):

```bash
eval "$(config/ai-env.sh)"
docker compose -f hub/docker-compose.yml -f config/ai-compose.override.yml up -d
```

Prefer not to use a file? Just `export MODEL_NAME=... MODEL_URL=... SUGGEST_BUDGET_MS=...`
(the env mapping table is at the end of [config/ai.example.yaml](config/ai.example.yaml),
steps in [INSTALL.md](INSTALL.md) §5).
Switching to any GGUF model: `models/fetch_model.sh install` → change `model` → restart the Hub,
**zero code changes**.

> **Future**: once Hub account login lands, model selection will become a visual dropdown in the settings
> page (logging in auto-delivers the same config), no more hand-editing YAML; this file's format stays
> backward compatible.

---

## Installation

Detailed steps (dependencies, models, Hub, troubleshooting) are in **[INSTALL.md](INSTALL.md)**. Quick look:

**macOS** (dev install — leaves your existing input methods untouched):

```bash
git clone <本仓> && cd mine-input
bash build/build-librime.sh      # build librime (brew install boost cmake)
bash build/build-squirrel.sh     # build Squirrel-dev.app
bash build/install-dev.sh        # install to ~/Library/Input Methods + deploy the hybrid schema
```

**Android** (sideloaded APK, not on any store):

```bash
cd android
bash fetch-deps.sh               # sherpa-onnx AAR + jars (SHA256-pinned)
bash fetch-rime-jni.sh           # Trime prebuilt librime_jni.so (GPL, see android/LICENSE.md)
./gradlew assembleDebug          # produces APK → adb install -r app/build/outputs/apk/debug/app-debug.apk
```

**AI Hub** (one machine runs the service, friends can connect): see
[hub/DEPLOY-FRIENDS.md](hub/DEPLOY-FRIENDS.md) (three commands to bring it up).

---

## Build Dependency Matrix

| Platform / part | Dependencies | License |
|---|---|---|
| macOS common | Xcode (clang), CMake ≥3.x, Homebrew `boost` `cmake` | — |
| macOS shell | [rime/squirrel](https://github.com/rime/squirrel) (fork + `build/squirrel-*.patch`), librime (make deps pulls opencc/leveldb/marisa/yaml-cpp/glog itself) | GPLv3 / BSD-3 and other permissive licenses ([THIRD_PARTY.md](THIRD_PARTY.md) table B) |
| Android | Android SDK (minSDK 29), Gradle/AGP (Kotlin built in), `fetch-deps.sh` (sherpa-onnx 2.0.1 AAR, commons-compress/io), `fetch-rime-jni.sh` (Trime `librime_jni.so`) | see [android/LICENSE.md](android/LICENSE.md) |
| Voice | sherpa-onnx + SenseVoiceSmall(int8) / Silero VAD / CT-Transformer punctuation (`voice/models/`, not committed) | Apache-2.0 / MIT |
| AI | llama.cpp (b12078, `ghcr.io/ggml-org/llama.cpp:server` or native on the host) + Qwen2.5 GGUF (**not distributed with the package**, `models/fetch_model.sh`) | MIT / Apache-2.0 |
| Hub | Docker Compose, Python 3 (fastapi/uvicorn/pydantic/httpx, `hub/requirements.txt`), nginx TLS sidecar | MIT / BSD-3 |

---

## Architecture

```
┌────────────────────────── Your devices ──────────────────────────┐
│  macOS (Squirrel-dev.app, GPLv3-derived)  Android (Kotlin IMS)   │
│  ┌─────────────────────────┐  ┌─────────────────────────────┐    │
│  │ Hybrid input schema/    │  │ Hybrid engine               │    │
│  │ (librime BSD-3)         │  │ (librime_jni.so)            │    │
│  ├─────────────────────────┤  │ + PTT voice (sherpa-onnx)   │    │
│  │ PTT voice (sherpa-onnx) │  ├─────────────────────────────┤    │
│  │ Teleprompter/memory/    │  │ Sync SDK (offline queue)    │    │
│  │ proposal cards          │  └──────────────┬──────────────┘    │
│  │ Context engine C0/C1    │                 │                   │
│  ├─────────────────────────┤                 │                   │
│  │ AI SPI (ai/spi)         │                 │                   │
│  │  rescore/complete/...   │                 │                   │
│  │  propose/confirm/observe│                 │                   │
│  └───────────┬─────────────┘                 │                   │
└──────────────┼───────────────────────────────┼───────────────────┘
               │ Sync SDK (TLS, queues offline)│
               ▼                               ▼
┌───────────────── Your Hub (self-hosted, Docker) ─────────────────┐
│  FastAPI + SQLite (multi-user partitions)  ←→  llama.cpp server  │
│  /v1/auth /v1/sync /v1/ingest /v1/suggest(SSE)     Qwen2.5 GGUF  │
│  nginx TLS sidecar :8443 (self-signed CA)   (local_gguf backend) │
└──────────────────────────────────────────────────────────────────┘
```

---

## Roadmap

| Milestone | Content | Status |
|---|---|---|
| M0–M3 | Skeleton → hybrid input + self-learning → voice MVP → local AI | ✅ Done |
| M4 | Hub sync + multi-user + TLS + backup | ✅ Done |
| N6–N8 | Memory store JSONL / proposal execution contract / memory management UI | ✅ Done |
| Near-term | macOS settings UI, L2 habit-report UI, rescore local hook wired to a real backend, real-user test matrix | 🚧 In progress |
| M5 | Signed distribution (Apple Developer notarization, share with friends) | ⏳ Pending decision |
| M6+ | Android teleprompter/memory store, visual model selection with account login, re-evaluate Windows/iOS | 📋 Planned |

---

## Documentation Index

| Document | Description |
|---|---|
| [INSTALL.md](INSTALL.md) | Installation and build walkthrough |
| [THIRD_PARTY.md](THIRD_PARTY.md) | Third-party license attributions (each curl-verified) and distribution boundaries |
| [SECURITY.md](SECURITY.md) | Security promises, threat model, vulnerability disclosure |
| [docs/需求文档-v1.0.md](docs/需求文档-v1.0.md) | Requirements spec: decision log D1–D15, FR/NFR (Chinese) |
| [docs/技术方案-v0.4.md](docs/技术方案-v0.4.md) | Technical spec: architecture, modules, milestones (Chinese) |
| [docs/开发任务计划.md](docs/开发任务计划.md) | Task graph and per-lane measured records (Chinese) |
| [docs/RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md) | Pre-release checklist (Chinese) |
| [hub/DEPLOY-FRIENDS.md](hub/DEPLOY-FRIENDS.md) | One-page Hub deployment guide for friends (Chinese) |
| [android/LICENSE.md](android/LICENSE.md) | Android GPL licensing notes and re-licensing path (Chinese) |

## License

This project is released under **GPL-3.0-only** ([LICENSE](LICENSE)) — because the macOS shell derives
from Squirrel (GPL-3.0) and the Android JNI layer reuses Trime (GPL-3.0-or-later), GPLv3 is the
compliance intersection. Third-party attributions and distribution boundaries are in
[THIRD_PARTY.md](THIRD_PARTY.md). © 2026 Mine Input contributors.
