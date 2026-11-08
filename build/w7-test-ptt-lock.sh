#!/usr/bin/env bash
# W28: PTT 锁定态状态机伪时钟单测 — 编译并运行 macos/w7/tests/test_ptt_lock.swift
#
# 被测对象：macos/w7/src/W7PttLockMachine.swift（纯 Foundation，零 Squirrel 依赖）。
# 硬约束（W27-fix 前车之鉴）：阈值/时长一律伪时钟注入，零 Thread.sleep；
# swiftc 独立编译，不触 TCC、不拉起任何 app。
# 产物：build/w7/tests/test_ptt_lock（不入库）；日志 build/logs/w7-test-ptt-lock.log
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/w7/tests"
mkdir -p "$OUT" "$ROOT/build/logs"

swiftc -O -g \
  "$ROOT/macos/w7/src/W7PttLockMachine.swift" \
  "$ROOT/macos/w7/tests/test_ptt_lock.swift" \
  -o "$OUT/test_ptt_lock"

"$OUT/test_ptt_lock"
echo "EXIT=$?"
