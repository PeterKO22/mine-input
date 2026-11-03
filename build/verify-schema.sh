#!/usr/bin/env bash
# W1 macos-core: ping_wubi_mixed schema 独立验证（rime_deployer + rime_api_console）。
# 用法：bash build/verify-schema.sh [RIME_DIR]   默认 ~/Library/Rime-mine-dev
# 说明：rime_api_console 默认 user_data_dir = 当前目录（librime deployer 默认 "."），
#       因此本脚本 cd 进 RIME_DIR 再跑 console，绝不触碰用户已有 ~/Library/Rime。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RIME_BIN="$ROOT/core/librime/build/bin"
RIME_DIR="${1:-$HOME/Library/Rime-mine-dev}"
CONSOLE="$RIME_BIN/rime_api_console"
DEPLOYER="$RIME_BIN/rime_deployer"

[ -x "$DEPLOYER" ] || { echo "missing $DEPLOYER —— 先跑 bash build/build-librime.sh"; exit 1; }

echo "== [1/3] 部署 schema 到 $RIME_DIR =="
mkdir -p "$RIME_DIR"
cp "$ROOT/schema/default.yaml" "$ROOT/schema/ping_wubi_mixed.schema.yaml" "$ROOT/schema/custom_phrase.txt" "$RIME_DIR/"
cp "$ROOT"/schema/deps/*.yaml "$RIME_DIR/"
ls "$RIME_DIR"

echo "== [2/3] rime_deployer --build =="
"$DEPLOYER" --build "$RIME_DIR"

echo "== [3/3] rime_api_console 候选实测 =="
cd "$RIME_DIR"
# 测试序列（每行一个 key sequence，{...} 为特殊键）：
#   1. 五笔一级简码：w        → 期望 人（形码命中）
#   2. 五笔编码：ggg          → 期望 五笔候选（形码命中）
#   3. 纯拼音（无五笔命中）：pinyin → 期望拼音候选自动占据最前
#   4. 拼音词组：nihao        → 期望 你好（拼音前移）
#   5. z 前缀拼音反查：zni    → 期望 你 等候选、注释带五笔编码
printf '%s\n' \
  'print schema list' \
  'select schema ping_wubi_mixed' \
  '{Escape}w' \
  'print candidate list' \
  '{Escape}gggg' \
  'print candidate list' \
  '{Escape}pinyin' \
  'print candidate list' \
  '{Escape}nihao' \
  'print candidate list' \
  '{Escape}zni' \
  'print candidate list' \
  '{Escape}' \
  'exit' \
  | "$CONSOLE" 2>&1
echo "== verify-schema done =="
