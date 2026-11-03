#!/usr/bin/env bash
# W16：把 Trime v3.3.13 预编译 librime_jni.so 放进 android/app/src/main/jniLibs/。
# .so 是外部预编译产物（GPL-3.0-or-later，Trime JNI 层），不进 git（见 android/.gitignore），
# 由本脚本幂等落位；缺失时先跑 engine/build/fetch-trime-apk.sh 重新提取（含 sha256 校验）。
#
# 复现：bash android/fetch-rime-jni.sh
set -euo pipefail

ANDROID="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$ANDROID/.." && pwd)"
SRC_DIR="$REPO/engine/poc/pathA/apk_extracted/lib/arm64-v8a"
DST_DIR="$ANDROID/app/src/main/jniLibs/arm64-v8a"
SO="librime_jni.so"

if [ ! -f "$SRC_DIR/$SO" ]; then
  echo "== 缺少 $SRC_DIR/$SO —— 先跑 engine/build/fetch-trime-apk.sh =="
  bash "$REPO/engine/build/fetch-trime-apk.sh"
fi
[ -f "$SRC_DIR/$SO" ] || { echo "FAIL: $SO 提取失败"; exit 1; }

mkdir -p "$DST_DIR"
cp "$SRC_DIR/$SO" "$DST_DIR/$SO"
echo "== 放置完成 =="
shasum -a 256 "$SRC_DIR/$SO" | tee "$DST_DIR/sha256.txt"
ls -la "$DST_DIR"
