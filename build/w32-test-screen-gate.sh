#!/usr/bin/env bash
# W32: 读屏门禁伪时钟单测 — 编译并运行 macos/w12/tests/test_screen_gate.swift
#
# 被测对象：macos/w12/src/W12ScreenCapture.swift（W12ScreenGate/W12ScreenAccess）+
# macos/w12/src/W12C1Collector.swift（采集入口门禁）+ W12Privacy 读屏显式开关。
# 硬约束（W27 弹窗风暴前车之鉴）：时间一律伪时钟注入、录屏授权状态 mock 注入，
# 零 Thread.sleep、零 CGRequest、零 TCC 交互；swiftc 独立编译，不拉起任何 app。
# 产物：build/w32/tests/test_screen_gate（不入库）；日志 build/logs/w32-test-screen-gate.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/w32/tests"
mkdir -p "$OUT" "$ROOT/build/logs"

swiftc -O -g \
  "$ROOT"/context/Sources/ContextCore/*.swift \
  "$ROOT/macos/w12/src/W12AsrClient.swift" \
  "$ROOT/macos/w12/src/W12C1Collector.swift" \
  "$ROOT/macos/w12/src/W12Config.swift" \
  "$ROOT/macos/w12/src/W12Digest.swift" \
  "$ROOT/macos/w12/src/W12EventBridge.swift" \
  "$ROOT/macos/w12/src/W12OCR.swift" \
  "$ROOT/macos/w12/src/W12ScreenCapture.swift" \
  "$ROOT/macos/w12/tests/test_screen_gate.swift" \
  -D W12_STANDALONE -lsqlite3 \
  -o "$OUT/test_screen_gate"

"$OUT/test_screen_gate" 2>&1 | tee "$ROOT/build/logs/w32-test-screen-gate.log"
exit "${PIPESTATUS[0]}"
