#!/usr/bin/env bash
# W7 (b): rescore 挂点单测 — 编译并运行 macos/w7/tests/test_rescore_hook.cc
#
# 被测对象：macos/w7/W7RescoreHook.{h,cc} + W3 SPI（ai/spi/timeout_assist.cc、
# ai/backends/null/null_ai_assist.cc，只读引用不改动）。
# 产物：build/w7/tests/test_rescore_hook（不入库）；日志 build/logs/w7-test-rescore.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/w7/tests"
mkdir -p "$OUT" "$ROOT/build/logs"

clang++ -std=c++17 -O1 -g \
  -I "$ROOT" \
  "$ROOT/macos/w7/tests/test_rescore_hook.cc" \
  "$ROOT/macos/w7/W7RescoreHook.cc" \
  "$ROOT/ai/spi/timeout_assist.cc" \
  "$ROOT/ai/backends/null/null_ai_assist.cc" \
  -o "$OUT/test_rescore_hook"

"$OUT/test_rescore_hook"
echo "EXIT=$?"
