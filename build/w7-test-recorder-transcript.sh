#!/usr/bin/env bash
# W31: 记录员模式（实时分段转写）伪时钟单测 — 编译并运行 macos/w7/tests/test_recorder_transcript.swift
#
# 被测对象：macos/w7/src/W7RecorderTranscript.swift（纯 Foundation，零 Squirrel 依赖；
# 锁定态用例同时编入 W7PttLockMachine.swift 模拟 W28 锁定相位）。
# 硬约束（W27-fix/W28 前车之鉴）：时间一律伪时钟注入、mock daemon 注入转写结果，
# 零 Thread.sleep；swiftc 独立编译，不触 TCC、不拉起任何 app。
# 产物：build/w7/tests/test_recorder_transcript（不入库）；日志 build/logs/w7-test-recorder-transcript.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/w7/tests"
mkdir -p "$OUT" "$ROOT/build/logs"

swiftc -O -g \
  "$ROOT/macos/w7/src/W7RecorderTranscript.swift" \
  "$ROOT/macos/w7/src/W7PttLockMachine.swift" \
  "$ROOT/macos/w7/tests/test_recorder_transcript.swift" \
  -o "$OUT/test_recorder_transcript"

"$OUT/test_recorder_transcript"
echo "EXIT=$?"
