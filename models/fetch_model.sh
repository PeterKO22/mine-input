#!/usr/bin/env bash
# 模型拉取 + 校验 + 灌入 llama.cpp 模型卷（hub_hub-models）。
#
# 源（2026-11-04 实测可用）：ModelScope 官方仓库（下载入口 api/v1 .../repo?FilePath=，
# 302 → cdn-lfs-cn-1.modelscope.cn 签名直链，支持 Range 续传）。其余源实测记录见
# models/MODEL-SOURCE.md 与 hub/W10-REPORT.md。
#
# 用法：
#   ./fetch_model.sh             # 目标档：Qwen2.5-7B-Instruct Q4_K_M（4.68GB split 分片）
#   ./fetch_model.sh fallback    # 降级档：Qwen2.5-0.5B-Instruct Q4_K_M（491MB 单文件）
#   ./fetch_model.sh verify      # 只校验已下载的文件
#   ./fetch_model.sh install     # 把本目录 *.gguf 灌入 compose 的 hub-models 卷
#
# drop-in 换模型：任意 GGUF 放本目录 → ./fetch_model.sh install →
#   换 compose 的 MODEL_FILE（或 docker compose --profile model create 时传
#   MODEL_FILE=<文件名>）→ recreate llama。/v1/suggest 只认 llama.cpp /completion 协议，
#   其余零改动。7B 档在 Docker Desktop VM 内存 ≥8GB（建议 16GB）后即可换上
#   （见 hub/W10-REPORT.md blocker）。
set -u

cd "$(dirname "$0")"

BASE="https://www.modelscope.cn/api/v1/models"

# 仓库|文件名|字节数|sha256（ModelScope 文件 API 提供，下载后本地复核）
TARGET_FILES=(
  "Qwen/Qwen2.5-7B-Instruct-GGUF|qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf|3993201344|dfce12e3862a5283ccfb88221b48480e58745165de856439950d0f22590580db"
  "Qwen/Qwen2.5-7B-Instruct-GGUF|qwen2.5-7b-instruct-q4_k_m-00002-of-00002.gguf|689872288|539cf93f78e887edea1c04e2d7d8cdaca9d01dae9c9025bcb8accbe29df3d72a"
)
FALLBACK_FILES=(
  "Qwen/Qwen2.5-0.5B-Instruct-GGUF|qwen2.5-0.5b-instruct-q4_k_m.gguf|491400032|74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"
)

verify_one() {
  local f="$1" want_size="$2" want_sha="$3"
  if [ ! -f "$f" ]; then echo "[缺失] $f"; return 1; fi
  local got_size
  got_size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
  if [ "$got_size" != "$want_size" ]; then
    echo "[体积不符] $f: $got_size != $want_size"; return 1
  fi
  local got_sha
  got_sha=$(shasum -a 256 "$f" | awk '{print $1}')
  if [ "$got_sha" != "$want_sha" ]; then
    echo "[SHA256 不符] $f: $got_sha != $want_sha"; return 1
  fi
  echo "[OK] $f  size=$got_size  sha256=$got_sha"
  return 0
}

fetch_set() {
  local rc=0
  for entry in "$@"; do
    IFS='|' read -r repo f sz sha <<<"$entry"
    if verify_one "$f" "$sz" "$sha"; then
      continue
    fi
    echo "[下载] $f  ($sz bytes)"
    echo "       URL: ${BASE}/${repo}/repo?FilePath=${f}&Revision=master"
    curl -fL -C - --retry 5 --retry-delay 3 \
      -o "$f.part" "${BASE}/${repo}/repo?FilePath=${f}&Revision=master"
    mv "$f.part" "$f"
    verify_one "$f" "$sz" "$sha" || rc=1
  done
  return $rc
}

case "${1:-target}" in
  verify)
    rc=0
    for entry in "${TARGET_FILES[@]}" "${FALLBACK_FILES[@]}"; do
      IFS='|' read -r repo f sz sha <<<"$entry"
      [ -f "$f" ] || continue   # verify 只校验已下载的
      verify_one "$f" "$sz" "$sha" || rc=1
    done
    [ $rc -eq 0 ] && echo "MODEL VERIFY: OK" || echo "MODEL VERIFY: FAILED"
    exit $rc
    ;;
  install)
    # 灌入 compose 命名卷（compose 项目名=hub → 卷名 hub_hub-models）
    docker run --rm -v hub_hub-models:/m -v "$PWD":/src:ro alpine \
      sh -c 'cp /src/*.gguf /m/ && ls -l /m/'
    ;;
  fallback)
    fetch_set "${FALLBACK_FILES[@]}" && echo "MODEL FETCH: FALLBACK VERIFIED" || echo "MODEL FETCH: FAILED"
    ;;
  target|*)
    fetch_set "${TARGET_FILES[@]}" && echo "MODEL FETCH: ALL VERIFIED" || echo "MODEL FETCH: FAILED"
    ;;
esac
