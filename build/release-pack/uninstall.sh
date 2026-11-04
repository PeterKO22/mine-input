#!/usr/bin/env bash
# 提炼输入法（Mine Input）— macOS 卸载脚本（Release 包内）。
# 默认保留学习数据 ~/Library/Rime-mine-dev；加 --purge 连数据一起删。
set -euo pipefail

IM_DIR="$HOME/Library/Input Methods"
APP_DST="$IM_DIR/Squirrel-dev.app"
RIME_DIR="$HOME/Library/Rime-mine-dev"

pkill -f "$APP_DST/Contents/MacOS/Squirrel" 2>/dev/null || true
rm -rf "$APP_DST"
echo "已删除 $APP_DST"

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$RIME_DIR"
  echo "已删除学习数据 $RIME_DIR"
else
  echo "保留学习数据 $RIME_DIR（如需一并删除：bash uninstall.sh --purge）"
fi

echo "提示：注销并重新登录后，输入源列表里的「提炼输入法」条目会消失。"
echo "本脚本从不触碰 /Library/Input Methods、官方 Squirrel 与 ~/Library/Rime。"
