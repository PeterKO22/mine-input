# 模型源实测记录（W10，2026-11-04）

> 环境事实：本机 HuggingFace 被墙（401/超时，W2 已实证）；hf-mirror.com 308 跳回 HF 亦不可用。
> 因此源优先级：ModelScope（www.modelscope.cn）→ GitHub Releases 直链 → 国内镜像。

## 采用源（✅ 实测可用，最终下载自此处）

| 项 | 值 |
|---|---|
| 仓库 | ModelScope 官方 `Qwen/Qwen2.5-7B-Instruct-GGUF` |
| 文件 API（列目录+SHA256） | `https://www.modelscope.cn/api/v1/models/Qwen/Qwen2.5-7B-Instruct-GGUF/repo/files?Recursive=true` |
| 下载入口 | `https://www.modelscope.cn/api/v1/models/Qwen/Qwen2.5-7B-Instruct-GGUF/repo?FilePath=<file>&Revision=master`（302 → `cdn-lfs-cn-1.modelscope.cn` 签名直链，支持 Range/续传） |
| 文件 1 | `qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf` |
| 体积 1 | 3,993,201,344 B（≈3.72 GiB） |
| SHA256 1（源提供，本地复核一致） | `dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db` |
| 文件 2 | `qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf` |
| 体积 2 | 689,872,288 B（≈0.64 GiB） |
| SHA256 2（源提供，本地复核一致） | `539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a` |
| 合计 | 4,683,073,632 B（≈4.36 GiB），即 **Qwen2.5-7B-Instruct Q4_K_M 全量**（llama.cpp split 分片命名，`-00001-of-00002.gguf` 直接喂 llama-server 即可） |

## 备选源探测记录（不采用，如实记录）

| 源 | URL | 结果 |
|---|---|---|
| HuggingFace 直连 | `https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/...` | ❌ 被墙（401/超时，W2 实证，本次未再重复耗时） |
| hf-mirror.com | `https://hf-mirror.com/Qwen/...` | ❌ 308 跳回 huggingface.co，同样被墙（W2 实证） |
| ModelScope resolve 直链 | `https://www.modelscope.cn/models/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/master/qwen2.5-7b-instruct-q4_k_m.gguf` | ❌ 404——该仓库无单文件版 `q4_k_m.gguf`，只有 split 分片（`-00001-of-00002`/`-00002-of-00002`）；换用 `api/v1/.../repo?FilePath=` 入口成功 |
| GitHub Releases 直链 | （备选，未需要） | 未触发——ModelScope 首源即成功 |

## llama.cpp 服务镜像

| 项 | 值 |
|---|---|
| 镜像 | `ghcr.io/ggml-org/llama.cpp:server` |
| 拉取 | ✅ 实测成功（本机 ghcr.io 可达） |
| Digest | `sha256:10a38e6cc91760ab157f0a0a8546218d35f4a314432a70298abfa3d096829ad7` |
