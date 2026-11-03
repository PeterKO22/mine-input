#!/usr/bin/env bash
# W1 macos-core: 安装 Squirrel 开发版到 ~/Library/Input Methods/Squirrel-dev.app
# 并部署 ping_wubi_mixed 到 dev 专用 RIME 用户目录 ~/Library/Rime-mine-dev。
#
# 安全边界（绝不动用户现有输入法/配置）：
#   - 只写 ~/Library/Input Methods/Squirrel-dev.app（用户级、dev 命名）
#   - 只写 ~/Library/Rime-mine-dev；绝不读写 /Library/Input Methods 与 ~/Library/Rime
#   - 一键卸载：bash build/uninstall-dev.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SQ_SRC="$ROOT/macos/squirrel"
APP_SRC="$SQ_SRC/build/Build/Products/Release/Squirrel.app"
IM_DIR="$HOME/Library/Input Methods"
APP_DST="$IM_DIR/Squirrel-dev.app"
RIME_DIR="$HOME/Library/Rime-mine-dev"

[ -d "$APP_SRC" ] || {
  echo "missing $APP_SRC —— 先跑 bash build/build-squirrel.sh"; exit 1
}

echo "== [1/4] 安装 $APP_DST =="
mkdir -p "$IM_DIR"
rm -rf "$APP_DST"                       # 只删我们自己的 dev 产物
cp -R "$APP_SRC" "$APP_DST"
# 本地开发签名（ad-hoc）；不设 DEV_ID，不做公证
codesign --force --deep --sign - "$APP_DST" 2>/dev/null || echo "(codesign ad-hoc skipped)"
plutil -p "$APP_DST/Contents/Info.plist" | grep -E "CFBundleName|TISInputSourceID|RimeUserDir|InputMethodConnectionName" || true

echo "== [2/4] 部署并验证 RIME 用户目录 $RIME_DIR =="
bash "$ROOT/build/verify-schema.sh" "$RIME_DIR"

echo "== [3/4] 注册输入源（dev）=="
# 注册用 app 自身（appDir 补丁后指向其实际位置），失败不致命（可在系统设置手动添加）
"$APP_DST/Contents/MacOS/Squirrel" --register-input-source || true

echo "== [4/4] 手工测试步骤（TextEdit）=="
cat <<'EOF'
1. 系统设置 → 键盘 → 输入法 → 添加「Squirrel Dev」（若 --register-input-source 未自动出现，
   注销重登一次再看；macOS 对 ~/Library/Input Methods 的新输入法需要重新登录才刷新列表）。
2. 打开 TextEdit 新建纯文本，切到「Squirrel Dev」。
3. 敲 w        → 首选「人」（五笔一级简码，形码命中）
4. 敲 pinyin   → 候选「拼音…」出现在最前（无五笔命中 → 拼音前移）
5. 敲 nihao    → 候选「你好」（拼音并联）
6. 敲 zni      → 反查候选「你…」，注释显示五笔编码（拼音反查）
7. Ctrl+` 或 F4 → 方案选单应只有「拼音五笔混合·dev」
注意：本开发版用户目录是 ~/Library/Rime-mine-dev，与官方 Squirrel 的 ~/Library/Rime 完全隔离。

W7 集成手工测试（详见 macos/W7-REPORT.md）：
A. PTT 语音上屏：按住右⌘（单键）说话 → 松开 → 转写文本上屏（首次使用会弹麦克风授权，
   需在 系统设置→隐私与安全性→麦克风 允许「Squirrel Dev」）；录音中 Esc 取消；
   兜底开关 ⌃⌥M（按一下开始、再按一下结束上屏）；说一段听不清的噪音应提示「没听清，请重说」。
B. 候选重排：敲 nihao 出候选后 ~1 秒内候选区出现「智1..智3 + ⚡AI」智能组
   （Null 后端与常规组内容一致 = 挂接验证阶段的预期行为）；点智能组条目可正常上屏。
EOF
