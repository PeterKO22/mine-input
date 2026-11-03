#!/usr/bin/env bash
# W7 (a): 采集→管线脚本化回放验证 — voice/mic/replay_test.py 包装
#
# 被测对象：voice/mic/{pipeline.py,ptt_daemon.py,ptt_client.py}（W2 核心抽取模块）。
# 日志：build/logs/w7-replay-test.log（stderr → w7-replay-stderr.log）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/voice/.venv/bin/python"
[ -x "$PY" ] || { echo "missing $PY —— 先按 voice/W2-REPORT.md §2 建 venv"; exit 1; }
mkdir -p "$ROOT/build/logs"

cd "$ROOT"
set -o pipefail
"$PY" voice/mic/replay_test.py 2>"$ROOT/build/logs/w7-replay-stderr.log" \
  | tee "$ROOT/build/logs/w7-replay-test.log"
echo "EXIT=$?"
