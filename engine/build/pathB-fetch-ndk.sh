#!/usr/bin/env bash
# W15 路径 B：从国内镜像获取 Android NDK（dl.google.com 被墙时的替代源）。
# 实测镜像结论（2026-11-04，全部 curl 实探）：
#   - mirrors.cloud.tencent.com/AndroidSDK/        → 567（EdgeOne WAF 拦截，带 UA 亦然）
#   - mirrors.aliyun.com/android{-sdk,go}/…        → 404（无 android repository 镜像）
#   - mirrors.huaweicloud.com/android/repository/  → ✅ 可用，但 NDK 封顶 r21（2020）
#   - tuna/ustc/nju/bfsu android/repository       → 404/403（无此镜像）
#   - github.com/android/ndk releases              → 只有源码 tag，无预编译包
# 因此本脚本取 huawei 的 android-ndk-r21-darwin-x86_64.zip（x86_64，Rosetta 2 下可运行，
# 可交叉编译 arm64-v8a 目标；API≤30，对 minSdk 29 够用）。
# 产物：engine/poc/pathB/ndk/android-ndk-r21/
set -euo pipefail

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ENGINE/poc/pathB/ndk"
ZIP="$DIR/android-ndk-r21-darwin-x86_64.zip"
URL="https://mirrors.huaweicloud.com/android/repository/android-ndk-r21-darwin-x86_64.zip"

mkdir -p "$DIR"
if [ ! -f "$ZIP" ]; then
  echo "== 下载 NDK r21（~1GB）：$URL =="
  curl -sL -o "$ZIP" "$URL"
fi
shasum -a 256 "$ZIP" | tee "$DIR/sha256.txt"

if [ ! -d "$DIR/android-ndk-r21" ]; then
  echo "== 解压（zip 内顶层目录 android-ndk-r21）=="
  unzip -q "$ZIP" -d "$DIR"
fi
"$DIR/android-ndk-r21/toolchains/llvm/prebuilt/darwin-x86_64/bin/clang" --version | head -2
echo "== pathB-fetch-ndk done: $DIR/android-ndk-r21 =="
