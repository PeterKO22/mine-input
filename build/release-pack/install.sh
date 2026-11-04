#!/usr/bin/env bash
# 提炼输入法（Mine Input）— macOS 安装脚本（Release 包内，自包含，无需仓库）。
#
# 安全边界（绝不动用户现有输入法/配置）：
#   - 只写 ~/Library/Input Methods/Squirrel-dev.app（用户级；与官方 Squirrel 共存，
#     bundle id/连接名均带 .dev，见 build/W1-REPORT.md dev 隔离）
#   - 只写 ~/Library/Rime-mine-dev；绝不读写 /Library/Input Methods 与 ~/Library/Rime
# 卸载：bash uninstall.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_SRC="./Squirrel.app"
IM_DIR="$HOME/Library/Input Methods"
APP_DST="$IM_DIR/Squirrel-dev.app"
RIME_DIR="$HOME/Library/Rime-mine-dev"

[ -d "$APP_SRC" ] || { echo "ERROR: 包内缺 Squirrel.app，请重新解压完整压缩包"; exit 1; }

echo "== [1/4] 安装 $APP_DST =="
mkdir -p "$IM_DIR"
# 替换 bundle 前先停旧 IME 进程（W18 实测：否则旧进程占着已删 inode，切换输入源后无进程）
pkill -f "$APP_DST/Contents/MacOS/Squirrel" 2>/dev/null || true
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
# 未签名/未公证（M5 决策）：清 Gatekeeper 隔离属性 + ad-hoc 签名
xattr -rd com.apple.quarantine "$APP_DST" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DST" 2>/dev/null || echo "(codesign ad-hoc skipped)"

echo "== [2/4] 部署「拼音五笔混合」方案到 $RIME_DIR =="
mkdir -p "$RIME_DIR"
cp "$APP_DST/Contents/Resources/mine-schema/"*.yaml "$RIME_DIR/"
echo "(首次启用输入法时 Squirrel 自动编译码表，约 5–10 秒，仅此一次)"

echo "== [3/4] 注册并拉起输入源 =="
"$APP_DST/Contents/MacOS/Squirrel" --register-input-source || true
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_DST" 2>/dev/null || true
open "$APP_DST" 2>/dev/null || echo "(open 返回非零，继续做存活检查)" >&2

echo "== [4/4] 确认 IME 进程存活（W18 强制门）=="
IME_PID=""
for _ in 1 2 3 4 5; do
  sleep 1
  IME_PID="$(pgrep -f "$APP_DST/Contents/MacOS/Squirrel" | head -1 || true)"
  [ -n "$IME_PID" ] && break
done
if [ -z "$IME_PID" ]; then
  echo "ERROR: IME 进程未拉起——此刻切换输入源会无法输入。请手动执行：" >&2
  echo "  open \"$APP_DST\"" >&2
  exit 1
fi
echo "IME 进程存活: pid=$IME_PID"

cat <<'EOF'

安装完成。接下来：
1. 系统设置 → 键盘 → 输入法 → 添加「提炼输入法」（Mine Input）；
   （macOS 对新输入法列表有缓存，看不到就注销重登一次）
2. 打开 TextEdit，切到「提炼输入法」，试一试：
   敲 w      → 首选「人」（五笔一级简码）
   敲 pinyin → 「拼音」出现在最前（拼音并联兜底）
   敲 nihao  → 「你好」
   敲 zni    → 反查候选，注释显示五笔编码
3. PTT 语音（按住右⌘说话松开上屏）首次使用会请求麦克风权限。
   麦克风/屏幕等高敏采集逐项显式同意、随时可撤回（见 SECURITY.md）。
EOF
