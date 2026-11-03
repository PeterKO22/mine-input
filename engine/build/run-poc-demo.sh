#!/usr/bin/env bash
# W15 路径 A：在 Android 模拟器/真机上跑最小 JNI demo 并断言验收输出。
# 用法：bash engine/build/run-poc-demo.sh   （需 adb 有设备；产物 APK 由 build-poc-apk.sh 生成）
# 验收断言（对齐 W1 §3.1）：w→人、gggg→王、pinyin→拼音、nihao→你好；zni 反查注释含五笔码。
set -euo pipefail

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
APK="$ENGINE/poc/out/w15-rime-poc.apk"
LOGDIR="$ENGINE/poc/logs"
LOG="$LOGDIR/demo-logcat.txt"
PKG=com.mineinput.engine.rimepoc
ACT="$PKG/.RimePocActivity"
TIMEOUT_S="${1:-300}"

mkdir -p "$LOGDIR"
[ -f "$APK" ] || { echo "missing $APK —— 先跑 bash engine/build/build-poc-apk.sh"; exit 1; }
adb get-state >/dev/null || { echo "no adb device"; exit 1; }

echo "== install =="
adb install -r -t "$APK"
echo "== launch $ACT =="
adb logcat -c || true
adb shell am force-stop "$PKG" || true
adb shell am start -W -n "$ACT" | grep -E 'Status|TotalTime' || true

echo "== wait for W15POC DONE (timeout ${TIMEOUT_S}s) =="
deadline=$(( $(date +%s) + TIMEOUT_S ))
status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  out="$(adb logcat -d -s W15POC 2>/dev/null || true)"
  if echo "$out" | grep -q 'DONE all cases ok'; then status=done; break; fi
  if echo "$out" | grep -q 'POC FAILED'; then status=failed; break; fi
  sleep 3
done

adb logcat -d -s W15POC > "$LOG" || true
echo "--- logcat (W15POC) saved: $LOG ---"
cat "$LOG"

fail=0
check() { # seq 期望首选
  if grep -E "RESULT\|seq=$1\|" "$LOG" | grep -q "|1=$2("; then
    echo "PASS  $1 -> $2"
  else
    echo "FAIL  $1 -> $2 未命中"; fail=1
  fi
}
echo "== assertions =="
check w 人
check gggg 王
check pinyin 拼音
check nihao 你好
# zni 反查：候选注释里应出现五笔编码（如 你(wq wqi wqiy)）
if grep -E 'RESULT\|seq=zni\|' "$LOG" | grep -qE 'wq|wqiy|rny|nxv|knx'; then
  echo "PASS  zni -> 反查注释含五笔编码"
else
  echo "FAIL  zni -> 未见五笔编码注释"; fail=1
fi
if [ "$status" = done ]; then echo "PASS  demo finished (DONE marker)"; else echo "FAIL  demo status=$status"; fail=1; fi

if [ "$fail" -eq 0 ]; then echo "== run-poc-demo: ALL PASS =="; else echo "== run-poc-demo: FAIL =="; exit 1; fi
