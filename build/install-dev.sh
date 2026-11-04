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

echo "== [1/5] 安装 $APP_DST =="
mkdir -p "$IM_DIR"
# W18 坑：替换 bundle 前先停掉旧 dev IME 进程——否则旧进程占着已删除的 inode，
# 且 macOS 切换输入源时可能不再拉起新进程（实测事故：切换后无进程、完全无法输入）。
pkill -f "$APP_DST/Contents/MacOS/Squirrel" 2>/dev/null && echo "(已停止旧 dev IME 进程)" || true
rm -rf "$APP_DST"                       # 只删我们自己的 dev 产物
cp -R "$APP_SRC" "$APP_DST"
# 本地开发签名（ad-hoc）；不设 DEV_ID，不做公证
codesign --force --deep --sign - "$APP_DST" 2>/dev/null || echo "(codesign ad-hoc skipped)"
plutil -p "$APP_DST/Contents/Info.plist" | grep -E "CFBundleName|TISInputSourceID|RimeUserDir|InputMethodConnectionName" || true

echo "== [2/5] 部署并验证 RIME 用户目录 $RIME_DIR =="
bash "$ROOT/build/verify-schema.sh" "$RIME_DIR"

echo "== [3/5] 注册并启用输入源（dev）=="
# 注册用 app 自身（appDir 补丁后指向其实际位置），失败不致命（可在系统设置手动添加）
"$APP_DST/Contents/MacOS/Squirrel" --register-input-source || true
# 尽力自动启用（TIS 清单里有条目时生效；清单被 macOS 暂清时为空操作）——W18
"$APP_DST/Contents/MacOS/Squirrel" --enable-input-source 2>/dev/null || true
echo "注意（W18 实测）：替换正在使用的输入法 bundle 后，macOS 可能把输入源暂时清出"
echo "  输入法清单（添加输入法对话框里看不到），--register-input-source 已重新注册；"
echo "  清单刷新通常要注销重登（或重启）——见 [5/5] 与 macos/w18/w18-verify.sh。"

echo "== [4/5] 拉起 IME 进程并检查存活（W18 强制门）=="
# W18 实测事故：重装 bundle 后切换输入源，macOS 未拉起 IME 进程 → 键入掉空、完全无法输入
# （手动 open 启动后恢复）。对策：lsregister 刷新注册 + open 拉起 + pgrep 存活检查，
# 进程不在则本脚本报错退出（非零），绝不留下"装完但打不了字"的状态。
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_DST" 2>/dev/null || true
open "$APP_DST" 2>/dev/null || echo "(open 拉起返回非零，继续做存活检查)" >&2
IME_PID=""
for i in 1 2 3 4 5; do
  sleep 1
  IME_PID="$(pgrep -f "$APP_DST/Contents/MacOS/Squirrel" | head -1 || true)"
  [ -n "$IME_PID" ] && break
done
if [ -z "$IME_PID" ]; then
  echo "ERROR: IME 进程未拉起——此刻切换输入源会完全无法输入（W18 实测事故同因）。请手动执行：" >&2
  echo "  open \"$APP_DST\"" >&2
  echo "  进程出现后再切换输入源；必要时注销重登。" >&2
  exit 1
fi
echo "IME 进程存活: pid=$IME_PID"
echo "-- IMK 端口注册证据（InputMethodConnectionName=Squirrel_Dev_Connection，unified log）--"
log show --last 1m --predicate 'process == "Squirrel"' --style compact 2>/dev/null \
  | grep -E "inputmethodkit|Activate Server" | tail -3 || true

echo "== [5/5] 手工测试步骤（TextEdit）=="
cat <<'EOF'
0. 显示名（W18 D15）：输入源/菜单栏应显示「提炼输入法」（英文界面 Mine Input），
   不再是裸 ID im.rime.inputmethod.Squirrel.dev…。
   注意：macOS 对输入源列表/显示名有缓存，重装后名字可能仍是旧的或裸 ID，
   需注销并重新登录（或重启）后才刷新——程序化验证：bash macos/w18/w18-verify.sh
   （探针会自动重试 3 次并在失败时提示重新登录）。
   可输入性人工验证（W18 实测事故复验项）：安装脚本 [4/5] 已强制确认 IME 进程拉起
   （进程不在会报错退出）；请再切到本输入法在 TextEdit 打一个字，确认按键能上屏。
   若切换后无反应：open ~/Library/Input\ Methods/Squirrel-dev.app 拉起进程后重试。
1. 系统设置 → 键盘 → 输入法 → 添加「提炼输入法」（Mine Input）（若 --register-input-source 未自动出现，
   注销重登一次再看；macOS 对 ~/Library/Input Methods 的新输入法需要重新登录才刷新列表）。
2. 打开 TextEdit 新建纯文本，切到「提炼输入法」（Mine Input）。
3. 敲 w        → 首选「人」（五笔一级简码，形码命中）
4. 敲 pinyin   → 候选「拼音…」出现在最前（无五笔命中 → 拼音前移）
5. 敲 nihao    → 候选「你好」（拼音并联）
6. 敲 zni      → 反查候选「你…」，注释显示五笔编码（拼音反查）
7. Ctrl+` 或 F4 → 方案选单应只有「拼音五笔混合·dev」
注意：本开发版用户目录是 ~/Library/Rime-mine-dev，与官方 Squirrel 的 ~/Library/Rime 完全隔离。

W7 集成手工测试（详见 macos/W7-REPORT.md）：
A. PTT 语音上屏：按住右⌘（单键）说话 → 松开 → 转写文本上屏（首次使用会弹麦克风授权，
   需在 系统设置→隐私与安全性→麦克风 允许「提炼输入法」（Mine Input））；录音中 Esc 取消；
   兜底开关 ⌃⌥M（按一下开始、再按一下结束上屏）；说一段听不清的噪音应提示「没听清，请重说」。
B. 候选重排：敲 nihao 出候选后 ~1 秒内候选区出现「智1..智3 + ⚡AI」智能组
   （Null 后端与常规组内容一致 = 挂接验证阶段的预期行为）；点智能组条目可正常上屏。
EOF
