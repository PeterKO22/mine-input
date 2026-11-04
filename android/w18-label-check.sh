#!/usr/bin/env bash
# W18 Android 应用名断言：aapt dump badging → application-label 必须是
#   默认（zh）「提炼输入法」、en "Mine Input"（D15）。
# 用法：bash android/w18-label-check.sh   （先 cd android && ./gradlew assembleDebug）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APK="$ROOT/android/app/build/outputs/apk/debug/app-debug.apk"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

[ -f "$APK" ] || { echo "RESULT: FAIL — 缺 APK：$APK（先 cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew assembleDebug）"; exit 1; }

AAPT="$(ls "$SDK"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1)"
AAPT2="$(ls "$SDK"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)"
if [ -n "$AAPT" ]; then
  DUMP="$("$AAPT" dump badging "$APK")"
elif [ -n "$AAPT2" ]; then
  DUMP="$("$AAPT2" dump badging "$APK")"
else
  echo "RESULT: FAIL — build-tools 里没有 aapt/aapt2"; exit 1
fi

echo "== aapt dump badging（application-label 相关）=="
echo "$DUMP" | grep -E "^package:|application-label" || true

FAIL=0
echo "$DUMP" | grep -q "application-label:'提炼输入法'" && echo "  [PASS] application-label:'提炼输入法'" \
  || { echo "  [FAIL] application-label 默认名不是「提炼输入法」"; FAIL=1; }
echo "$DUMP" | grep -q "application-label-en:'Mine Input'" && echo "  [PASS] application-label-en:'Mine Input'" \
  || { echo "  [FAIL] application-label-en 不是 'Mine Input'"; FAIL=1; }

# 输入法服务标签（ime_name）打包后同样来自 strings.xml——用 aapt/aapt2 资源 dump 复核
RES=""
if [ -n "$AAPT2" ]; then
  RES="$("$AAPT2" dump resources "$APK" 2>/dev/null | grep -A3 'string/ime_name' | head -4)"
fi
if [ -z "$RES" ] && [ -n "$AAPT" ]; then
  RES="$("$AAPT" dump --values resources "$APK" 2>/dev/null | grep -A2 'string/ime_name' | head -4)"
fi
echo "== ime_name 资源 =="
echo "$RES"
echo "$RES" | grep -q '提炼输入法' && echo "  [PASS] ime_name 含「提炼输入法」" \
  || { echo "  [FAIL] ime_name 不含「提炼输入法」"; FAIL=1; }
echo "$RES" | grep -q 'Mine Input' && echo "  [PASS] ime_name(en) = 'Mine Input'" \
  || { echo "  [FAIL] ime_name(en) 不是 'Mine Input'"; FAIL=1; }

if [ $FAIL -eq 0 ]; then echo "RESULT: ALL PASS"; else echo "RESULT: FAIL"; fi
exit $FAIL
