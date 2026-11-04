# 第三方许可证归属（THIRD_PARTY）

> 本文件记录 **提炼输入法 / Mine Input**（下称「本项目」）分发物中包含、构建期引入或运行时按需下载的
> 第三方组件及其许可证归属。本项目本体以 **GPL-3.0-only** 发布（见 [LICENSE](LICENSE)）。
>
> **核验方法**：2026-11-04 用 `curl` 直拉上游许可证原文（`raw.githubusercontent.com` / HuggingFace raw），
> 下表「核验」列给出实测 URL 与原文 SHA256，可独立复核：
> `curl -s <URL> | shasum -a 256`。除特别注明外每行均已实测通过（27/28 直拉成功；
> Sparkle 一项上游 raw 路径 404，改以构建树内 vendored 副本为证，如实标注）。

---

## A. 随仓库源码分发（入库文件）

| 组件 | 取用点（本仓路径） | 上游 | 许可证 | 核验（URL · SHA256） |
|---|---|---|---|---|
| rime-wubi（五笔 86 词库） | `schema/deps/wubi86.dict.yaml` | [rime/rime-wubi](https://github.com/rime/rime-wubi) | **LGPL-3.0** | [LICENSE](https://raw.githubusercontent.com/rime/rime-wubi/master/LICENSE) · `da7eabb7…64768` |
| rime-pinyin-simp（袖珍拼音） | `schema/deps/pinyin_simp.dict.yaml`、`pinyin_simp.schema.yaml` | [rime/rime-pinyin-simp](https://github.com/rime/rime-pinyin-simp) | **Apache-2.0** | [LICENSE](https://raw.githubusercontent.com/rime/rime-pinyin-simp/master/LICENSE) · `cfc7749b…3d30` |
| rime-prelude（RIME 基础配置） | `schema/deps/key_bindings.yaml`、`punctuation.yaml`、`symbols.yaml` | [rime/rime-prelude](https://github.com/rime/rime-prelude) | **LGPL-3.0** | [LICENSE](https://raw.githubusercontent.com/rime/rime-prelude/master/LICENSE) · `da7eabb7…64768` |
| Trime JNI 胶水类（复刻） | `android/app/src/main/java/com/osfans/trime/core/*.kt`（SPDX 头保留） | [osfans/trime](https://github.com/osfans/trime) v3.3.13 | **GPL-3.0-or-later** | [LICENSE](https://raw.githubusercontent.com/osfans/trime/master/LICENSE) · `8ceb4b9e…b903` |

> `schema/ping_wubi_mixed.schema.yaml`、`schema/default.yaml`、`schema/custom_phrase.txt`、
> `schema/squirrel.custom.yaml` 及 `ai/ sdk/ hub/ voice/ macos/ core/ context/ tests/` 自研部分为本项目原创，随本项目 GPL-3.0-only。
> 其中 `schema/` 配置以 rime-wubi / rime-pinyin-simp / rime-prelude 的 schema 派生改写（混合输入方案），
> 派生数据按上游许可证（LGPL-3.0 / Apache-2.0）随附署名分发。

## B. 构建期引入 · 随二进制/安装包分发

### macOS（Squirrel-dev.app / Squirrel.app）

| 组件 | 版本/取用点 | 上游 | 许可证 | 核验 |
|---|---|---|---|---|
| librime | 1.17.x（`macos/squirrel/librime/`） | [rime/librime](https://github.com/rime/librime) | **BSD-3-Clause** | [LICENSE](https://raw.githubusercontent.com/rime/librime/master/LICENSE) · `f67d27a6…c400` |
| Squirrel（fork + 本仓 patch） | `build/squirrel-*.patch` 派生 | [rime/squirrel](https://github.com/rime/squirrel) | **GPL-3.0** | [LICENSE.txt](https://raw.githubusercontent.com/rime/squirrel/master/LICENSE.txt) · `8ceb4b9e…b903` |
| Sparkle | Squirrel 子模块（自动更新框架） | [apple/Sparkle](https://github.com/apple/Sparkle) | **MIT** | 上游 raw 404（文件布局差异）；vendored 副本 `macos/squirrel/Sparkle/LICENSE` · `78babcec…25f6` |
| OpenCC | librime 依赖 | [BYVoid/OpenCC](https://github.com/BYVoid/OpenCC) | **Apache-2.0** | [LICENSE](https://raw.githubusercontent.com/BYVoid/OpenCC/master/LICENSE) · `b534e465…4308` |
| LevelDB | librime 依赖 | [google/leveldb](https://github.com/google/leveldb) | **BSD-3-Clause** | [LICENSE](https://raw.githubusercontent.com/google/leveldb/main/LICENSE) · `ccc19f1d…db19` |
| yaml-cpp | librime 依赖 | [jbeder/yaml-cpp](https://github.com/jbeder/yaml-cpp) | **MIT** | [LICENSE](https://raw.githubusercontent.com/jbeder/yaml-cpp/master/LICENSE) · `aa6fcc27…4f1b` |
| marisa-trie | librime/OpenCC 依赖 | [s-yata/marisa-trie](https://github.com/s-yata/marisa-trie) | **BSD-2-Clause OR LGPL-2.1-or-later** | [COPYING.md](https://raw.githubusercontent.com/s-yata/marisa-trie/master/COPYING.md) · `edf58dab…cb8d1` |
| glog | librime 依赖 | [google/glog](https://github.com/google/glog) | **BSD-3-Clause** | [LICENSE.md](https://raw.githubusercontent.com/google/glog/master/LICENSE.md) · `3d8faa7c…38f0` |
| cppjieba | OpenCC jieba 插件依赖 | [yanyiwu/cppjieba](https://github.com/yanyiwu/cppjieba) | **MIT** | [LICENSE](https://raw.githubusercontent.com/yanyiwu/cppjieba/master/LICENSE) · `ba898a14…851b` |
| rime-essay（essay.txt） | Squirrel.app SharedSupport（plum 取用，不入 git） | [rime/rime-essay](https://github.com/rime/rime-essay) | **LGPL-3.0** | [LICENSE](https://raw.githubusercontent.com/rime/rime-essay/master/LICENSE) · `da7eabb7…64768` |
| rime-stroke（stroke.dict.yaml） | 同上（pinyin_simp 反查依赖） | [rime/rime-stroke](https://github.com/rime/rime-stroke) | **LGPL-3.0** | [LICENSE](https://raw.githubusercontent.com/rime/rime-stroke/master/LICENSE) · `da7eabb7…64768` |

### Android（app-debug.apk）

| 组件 | 版本/取用点 | 上游 | 许可证 | 核验 |
|---|---|---|---|---|
| librime_jni.so（Trime 预编译） | `fetch-rime-jni.sh` 提取（不入 git）；内含 librime/opencc/leveldb/marisa/yaml-cpp | [osfans/trime](https://github.com/osfans/trime) v3.3.13 | **GPL-3.0-or-later**（内含件同上表） | [LICENSE](https://raw.githubusercontent.com/osfans/trime/master/LICENSE) · `8ceb4b9e…b903`；详见 [android/LICENSE.md](android/LICENSE.md) |
| sherpa-onnx（AAR + onnxruntime） | 2.0.1（`fetch-deps.sh`，SHA256 钉死，不入 git） | [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | **Apache-2.0** | [LICENSE](https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/LICENSE) · `cfc7749b…3d30` |
| ONNX Runtime | 随 sherpa-onnx AAR 打包 | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime) | **MIT** | [LICENSE](https://raw.githubusercontent.com/microsoft/onnxruntime/main/LICENSE) · `2f07c727…922c` |
| commons-compress | 1.26.2（`fetch-deps.sh`，SHA256 钉死） | [apache/commons-compress](https://github.com/apache/commons-compress) | **Apache-2.0** | [LICENSE.txt](https://raw.githubusercontent.com/apache/commons-compress/master/LICENSE.txt) · `51b88fd3…733c1` |
| commons-io | 2.16.1（同上） | [apache/commons-io](https://github.com/apache/commons-io) | **Apache-2.0** | [LICENSE.txt](https://raw.githubusercontent.com/apache/commons-io/master/LICENSE.txt) · `c1d1a38c…2a4c6` |

### Hub / 模型服务（Docker + 宿主机原生）

| 组件 | 版本/取用点 | 上游 | 许可证 | 核验 |
|---|---|---|---|---|
| llama.cpp（llama-server + dylib，`ghcr.io/ggml-org/llama.cpp:server`） | b12078（`models/llama.cpp-b12078/`，构建期拉取，不入 git） | [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) | **MIT** | [LICENSE](https://raw.githubusercontent.com/ggml-org/llama.cpp/master/LICENSE) · `94f29bbe…010d` |
| FastAPI | `hub/requirements.txt` | [fastapi/fastapi](https://github.com/fastapi/fastapi) | **MIT** | [LICENSE](https://raw.githubusercontent.com/fastapi/fastapi/master/LICENSE) · `4ec89ffc…c744e` |
| Pydantic | 同上 | [pydantic/pydantic](https://github.com/pydantic/pydantic) | **MIT** | [LICENSE](https://raw.githubusercontent.com/pydantic/pydantic/main/LICENSE) · `a9e186f3…29ef3` |
| httpx | 同上 | [encode/httpx](https://github.com/encode/httpx) | **BSD-3-Clause** | [LICENSE.md](https://raw.githubusercontent.com/encode/httpx/master/LICENSE.md) · `4ec59d54…8d8d` |
| uvicorn | 同上 | [encode/uvicorn](https://github.com/encode/uvicorn) | **BSD-3-Clause** | [LICENSE.md](https://raw.githubusercontent.com/encode/uvicorn/master/LICENSE.md) · `efe1acf3…371` |
| nginx:alpine | TLS 边车镜像 | [nginx](https://hub.docker.com/_/nginx) | BSD-2-Clause（nginx 自身） | 镜像内 LICENSE；未随仓库分发 |

## C. 运行时按需下载 · **不随仓库/安装包分发**

| 组件 | 用途 | 上游 | 许可证 | 核验 |
|---|---|---|---|---|
| **Qwen2.5-7B-Instruct GGUF**（Q4_K_M，4.68GB） | Hub/端侧 LLM（`models/fetch_model.sh`，ModelScope 源，SHA256 钉死） | [QwenLM/Qwen2.5](https://github.com/QwenLM/Qwen2.5) / [Qwen/Qwen2.5-7B-Instruct](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct) | **Apache-2.0** | [HF LICENSE](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct/raw/main/LICENSE) · `832dd9e0…e92e` |
| **Qwen2.5-0.5B-Instruct GGUF**（Q4_K_M，491MB） | 降级档 | 同上 | **Apache-2.0** | [HF LICENSE](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct/raw/main/LICENSE) · `832dd9e0…e92e` |
| SenseVoiceSmall(int8) | 离线 ASR（`voice/models/`，不入 git） | [FunAudioLLM/SenseVoice](https://github.com/FunAudioLLM/SenseVoice) | **MIT** | [LICENSE](https://raw.githubusercontent.com/FunAudioLLM/SenseVoice/main/LICENSE) · `4bc3bffe…de5f` |
| Silero VAD | 语音切段 | [snakers4/silero-vad](https://github.com/snakers4/silero-vad) | **MIT** | [LICENSE](https://raw.githubusercontent.com/snakers4/silero-vad/master/LICENSE) · `2e63e9a3…520b` |
| CT-Transformer 标点(int8) | 标点恢复 | [k2-fsa/sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) 模型库 | **Apache-2.0** | [LICENSE](https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/LICENSE) · `cfc7749b…3d30` |

> 模型权重**不随本项目分发**：`models/`、`voice/models/`、`android/.../jniLibs/` 均 .gitignore 排除，
> 由 `models/fetch_model.sh`、W2-REPORT §3、`android/fetch-*.sh` 可复现获取（含 SHA256 校验）。
> 模型许可证仅约束你**自行下载**的权重，不影响本项目代码的 GPL-3.0。

## D. 构建/运行工具链（不随包分发，仅使用）

| 组件 | 用途 | 许可证 | 核验 |
|---|---|---|---|
| Xcode / clang / macOS SDK | macOS 构建 | Apple SLA（专有，仅使用不分发） | — |
| CMake、Boost | librime 构建（`brew install boost cmake`） | BSL-1.0 / BSL-1.0 | 未随包分发 |
| Gradle / Android Gradle Plugin / Kotlin | Android 构建 | **Apache-2.0** | 未随包分发 |
| Android SDK / NDK | Android 构建（NDK 仅 W15 路径 B PoC） | Android SDK License（专有，仅使用） | — |
| Docker / Docker Compose | Hub 部署 | Apache-2.0 | 未随包分发 |
| Python 3 + venv | Hub/语音脚本 | PSF | 未随包分发 |

---

## 分发边界（说清楚什么给、什么不给）

| 层 | 内容 | 边界 |
|---|---|---|
| **GitHub 公开源码仓** | 287 个入库文件：本项目全部自研源码 + `schema/` 数据（A 表）+ 构建/部署脚本 | 随 GPL-3.0-only 分发，A 表组件按其原许可证随附 |
| **macOS 安装包**（Squirrel-dev.app，未签名/未公证） | 自研 patch 派生的 Squirrel + librime + B 表 macOS 全部件 | **整体 GPL-3.0**（Squirrel 传染）→ 对应源码即本仓 + `build/squirrel-*.patch` + 上游仓库，满足 GPLv3 §6 对应源 |
| **Android APK**（侧载） | 自研 IMS + Trime JNI（GPL-3.0-or-later）+ sherpa-onnx 等 B 表 Android 件 | **整体 GPL-3.0-or-later**（android/LICENSE.md）；换芯路线（自编 librime）可解除，见该文件 |
| **Hub（Docker）** | FastAPI 自研服务 + llama.cpp/llama-server | 自研服务 GPL-3.0-only；llama.cpp MIT 兼容 |
| **模型/语音权重** | C 表 | **不随包分发**，用户自取，各按上游许可证 |

### GPL 合规要点（D5）

1. 本项目选 **GPL-3.0-only** 作为整仓许可证，正是因为 macOS 壳（Squirrel，GPL-3.0）与 Android JNI 层
   （Trime，GPL-3.0-or-later）为衍生/组合分发——GPLv3 是两者的**合规交集**（Trime 的 or-later 允许以 GPLv3 分发）；
2. librime（BSD-3）及其依赖（A/B 表）均为宽松许可，可自由组合进 GPL 分发物；
3. RIME 词库配方混杂 **LGPL-3.0**（rime-wubi / rime-prelude / rime-essay / rime-stroke）与 **Apache-2.0**
   （rime-pinyin-simp）：数据文件原样随附、保留署名与许可证文本即合规；Apache-2.0 与 GPLv3 兼容；
4. **Qwen2.5（Apache-2.0）不随包分发**，仅作用户自选的可选下载，不改变本项目许可证；
5. 疑义以各上游 LICENSE 原文为准（上表 URL 实测可达）；如与本文件冲突，以上游原文为准并请开 issue。

*核验日志：2026-11-04 逐条 curl 实测（27/28 直拉成功，Sparkle 一项以 vendored 副本为证）。*
