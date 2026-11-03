#!/usr/bin/env bash
# W1 macos-core: 一键卸载 Squirrel 开发版（只动 dev 产物，绝不碰用户现有输入法/配置）。
# 卸载范围：
#   - ~/Library/Input Methods/Squirrel-dev.app
#   - ~/Library/Rime-mine-dev（dev 专用 RIME 用户目录；KEEP_RIME_DIR=1 可保留）
set -euo pipefail

APP_DST="$HOME/Library/Input Methods/Squirrel-dev.app"
RIME_DIR="$HOME/Library/Rime-mine-dev"

echo "== 停止 dev 进程 =="
pkill -f "Input Methods/Squirrel-dev.app" 2>/dev/null && echo "killed Squirrel-dev" || echo "no running Squirrel-dev"

echo "== 删除 $APP_DST =="
rm -rf "$APP_DST"
ls "$HOME/Library/Input Methods" 2>/dev/null || true

if [ "${KEEP_RIME_DIR:-0}" = "1" ]; then
  echo "== 保留 RIME 用户目录 $RIME_DIR（KEEP_RIME_DIR=1）=="
else
  echo "== 删除 $RIME_DIR =="
  rm -rf "$RIME_DIR"
fi

echo "卸载完成。如曾把「Squirrel Dev」加入输入法列表，可在 系统设置→键盘→输入法 手动移除。"
echo "用户已有输入法与 ~/Library/Rime 未被触碰。"
