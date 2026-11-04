#!/usr/bin/env bash
# W23 ci-release: 打包 macOS Release zip（Squirrel.app + install.sh + uninstall.sh + 快速开始 README）。
# 输入：build-squirrel.sh 产物 macos/squirrel/build/Build/Products/Release/Squirrel.app
# 输出：build/dist/mine-input-v<版本>-macos-arm64.zip
# 用法：bash build/package-macos.sh [版本号]   默认 0.1.0（不带 v）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VER="${1:-0.1.0}"
VER="${VER#v}"
NAME="mine-input-v${VER}-macos-arm64"
APP="$ROOT/macos/squirrel/build/Build/Products/Release/Squirrel.app"
DIST="$ROOT/build/dist"
STAGE="$DIST/$NAME"

[ -d "$APP" ] || { echo "missing $APP —— 先跑 bash build/build-squirrel.sh" >&2; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Squirrel.app"

# schema 随包（install.sh 部署到 RIME 用户目录 ~/Library/Rime-mine-dev）。
# 分发红线：模型权重/密钥/用户数据绝不入包（下方断言兜底）。
mkdir -p "$STAGE/Squirrel.app/Contents/Resources/mine-schema"
cp "$ROOT/schema/default.yaml" "$ROOT/schema/ping_wubi_mixed.schema.yaml" \
   "$ROOT/schema/custom_phrase.txt" "$STAGE/Squirrel.app/Contents/Resources/mine-schema/"
cp "$ROOT"/schema/deps/*.yaml "$STAGE/Squirrel.app/Contents/Resources/mine-schema/"

cp "$ROOT/build/release-pack/install.sh" "$ROOT/build/release-pack/uninstall.sh" \
   "$ROOT/build/release-pack/README.md" "$STAGE/"
chmod +x "$STAGE/install.sh" "$STAGE/uninstall.sh"

# 分发包安全断言（RELEASE-CHECKLIST §5）：不含模型权重/密钥/用户数据
if find "$STAGE" \( -name '*.gguf' -o -name '*.keystore' -o -name '*.key' -o -name '*.pem' \) \
     | grep -q .; then
  echo "FAIL: 包内发现模型权重/密钥类文件" >&2
  find "$STAGE" \( -name '*.gguf' -o -name '*.keystore' -o -name '*.key' -o -name '*.pem' \) >&2
  exit 1
fi

# ditto 打 zip：保留 app bundle 符号链接与签名（Finder/终端解压均还原）
ditto -c -k --sequesterRsrc --keepParent "$STAGE" "$DIST/${NAME}.zip"

echo "== artifact =="
ls -la "$DIST/${NAME}.zip"
shasum -a 256 "$DIST/${NAME}.zip"
echo "（SHA256SUMS.txt 由 CI checksums job 统一产出）"
