#!/usr/bin/env bash
# W15 路径 A：获取 Trime 发布 APK（pin v3.3.13）并提取预编译 librime .so 与 JNI 绑定面。
# 产物：engine/poc/pathA/{APK, apk_extracted/, syms.txt}
set -euo pipefail

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ENGINE/poc/pathA"
TAG=v3.3.13
APK="com.osfans.trime-$TAG-0-gb5cad1a4-arm64-v8a-release.apk"
URL="https://github.com/osfans/trime/releases/download/$TAG/$APK"
NM="$(xcrun --find llvm-nm)"

mkdir -p "$DIR"
if [ ! -f "$DIR/$APK" ]; then
  echo "== 下载 $URL =="
  curl -sL -m 600 -o "$DIR/$APK" "$URL"
fi
echo "== sha256 =="
shasum -a 256 "$DIR/$APK" | tee "$DIR/sha256.txt"

echo "== 解包 =="
rm -rf "$DIR/apk_extracted"
unzip -o -q "$DIR/$APK" -d "$DIR/apk_extracted"
find "$DIR/apk_extracted" -name '*.so' -exec ls -la {} \;

echo "== JNI 绑定面清单（动态导出符号）=="
"$NM" --dynamic --defined-only "$DIR/apk_extracted/lib/arm64-v8a/librime_jni.so" \
  | awk '{print $NF}' > "$DIR/syms.txt"
echo "总导出符号: $(wc -l < "$DIR/syms.txt")"
grep '^Java_' "$DIR/syms.txt" | tee "$DIR/jni_exports.txt"
echo "--- rime C API 导出（可被自写 JNI shim 直接调用的证据）---"
grep -E '^(rime_get_api|RimeFindModule|RimeRegisterModule)' "$DIR/syms.txt" || true
echo "== fetch-trime-apk done =="
