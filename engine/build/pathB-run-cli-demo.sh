#!/usr/bin/env bash
# W15 路径 B：把自编 librime（Android arm64）+ CLI 工具推到模拟器/真机，
# 在 Android 运行时上跑与 W1 build/verify-schema.sh 同一套键序列验收（CLI 输出）。
# 前置：bash engine/build/pathB-build-librime.sh 成功；adb 有设备。
set -euo pipefail

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ENGINE/.." && pwd)"
RIME="$ENGINE/poc/pathB/librime/build-android"
LOGDIR="$ENGINE/poc/logs"
LOG="$LOGDIR/pathb-cli-demo.log"
DIR=/data/local/tmp/w15pathb

mkdir -p "$LOGDIR"
adb get-state >/dev/null || { echo "no adb device"; exit 1; }
for f in "$RIME/lib/librime.so" "$RIME/bin/rime_deployer" "$RIME/bin/rime_api_console"; do
  [ -f "$f" ] || { echo "missing $f —— 先跑 bash engine/build/pathB-build-librime.sh"; exit 1; }
done

echo "== push artifacts + schema =="
adb shell "rm -rf $DIR && mkdir -p $DIR"
adb push "$RIME/lib/librime.so" "$DIR/" >/dev/null
adb push "$RIME/bin/rime_deployer" "$DIR/" >/dev/null
adb push "$RIME/bin/rime_api_console" "$DIR/" >/dev/null
adb push "$REPO/schema/default.yaml" "$DIR/" >/dev/null
adb push "$REPO/schema/ping_wubi_mixed.schema.yaml" "$DIR/" >/dev/null
adb push "$REPO/schema/custom_phrase.txt" "$DIR/" >/dev/null
for f in "$REPO"/schema/deps/*.yaml; do adb push "$f" "$DIR/" >/dev/null; done

echo "== on-device deploy（设备端编译 wubi86/pinyin_simp 码表）=="
adb shell "cd $DIR && chmod +x rime_deployer rime_api_console && LD_LIBRARY_PATH=$DIR ./rime_deployer --build $DIR"

echo "== on-device console 实测 =="
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
  | adb shell "cd $DIR && LD_LIBRARY_PATH=$DIR ./rime_api_console" 2>&1 | tee "$LOG"

echo "== assertions =="
fail=0
expect() { # 标签 正则
  if grep -qE "$2" "$LOG"; then echo "PASS  $1"; else echo "FAIL  $1（未匹配 $2）"; fail=1; fi
}
expect "w→人（五笔一级简码）"    '^\s*1\. \[人\]'
expect "gggg→王（五笔全码）"     '^\s*1\. \[王\]'
expect "pinyin→拼音（拼音前移）" '^\s*1\. \[拼音\]'
expect "nihao→你好"              '^\s*1\. \[你好\]'
expect "zni→反查注释含五笔码"    '你 wq|拟 rny|尼 nx|呢 knx'
if [ "$fail" -eq 0 ]; then echo "== pathB-run-cli-demo: ALL PASS =="; else echo "== pathB-run-cli-demo: FAIL =="; exit 1; fi
