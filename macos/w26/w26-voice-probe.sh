#!/usr/bin/env bash
# W26 voice-mic-perm 验收探针包装：装机证据 → 会话准备 → 音频注入/采集案例 → 清理还原。
#
# 被测对象：~/Library/Input Methods/Squirrel-dev.app（真机 IME 进程）+ voice/mic/ptt_daemon.py。
# 机制详见 macos/w26/w26_probe.swift 头注释与 macos/W26-REPORT.md。
# 用法（仓库根目录）：bash macos/w26/w26-voice-probe.sh
# 日志：build/logs/w26-voice-probe.log
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROBE_SRC="$ROOT/macos/w26/w26_probe.swift"
PROBE_BIN="$ROOT/macos/w26/w26-probe"
LOGDIR="$ROOT/build/logs"
APP="$HOME/Library/Input Methods/Squirrel-dev.app"
PROBE_DIR="$HOME/Library/Rime-mine-dev"
SCRATCH="/tmp/w26-probe-$$.txt"
mkdir -p "$LOGDIR"

# 探针 token 残留即安全门失效——无论成败都清掉
trap 'rm -f "$PROBE_DIR/w7-probe.enabled" "$PROBE_DIR/w7-probe-req.json" "$SCRATCH"' EXIT

[ -d "$APP" ] || { echo "missing $APP —— 先 bash build/build-squirrel.sh && bash build/install-dev.sh"; exit 1; }

# 探针通知需要接收方：确认 IME 进程在跑
if ! pgrep -f "$APP/Contents/MacOS/Squirrel" >/dev/null 2>&1; then
  echo "(IME 进程不在，open 拉起)"
  open "$APP" 2>/dev/null || true
  sleep 2
fi

[ -x "$PROBE_BIN" ] && [ "$PROBE_BIN" -nt "$PROBE_SRC" ] || {
  echo "(编译探针 swiftc ...)"
  swiftc -O "$PROBE_SRC" -o "$PROBE_BIN" -framework Carbon || { echo "RESULT: FAIL — 探针编译失败"; exit 1; }
}

main() {
  echo "== W26 语音权限修复验收探针 $(date '+%F %T') =="

  echo
  echo "-- [1/5] 装机产物 InfoPlist 证据（PlistBuddy，W26 验收硬项）--"
  /usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$APP/Contents/Info.plist"

  echo
  echo "-- [2/5] 会话准备：切 dev 输入源 + TextEdit 打底（尽力让 w7CommitVoiceText 有挂载目标）--"
  echo "" > "$SCRATCH"
  open -a TextEdit "$SCRATCH" 2>/dev/null || echo "open TextEdit 失败（继续）"
  sleep 1
  PREV_IMS="$("$PROBE_BIN" select-ims 2> >(sed 's/^/    /' >&2) | tail -1)"
  echo "    原输入源: ${PREV_IMS:-<unknown>}"
  if osascript -e 'tell application "TextEdit" to activate' 2>/dev/null \
     && osascript -e 'tell application "System Events" to keystroke "w"' 2>/dev/null \
     && osascript -e 'tell application "System Events" to key code 53' 2>/dev/null; then
    echo "    prime-keystroke: ok（合成 'w'+Esc，IME handle() 应已挂载 controller）"
  else
    echo "    prime-keystroke: FAILED（本进程无辅助功能权限；controller 可能未挂载，commit 事件 controller=false 亦属预期）"
  fi
  sleep 0.5

  echo
  echo "-- [3/5] 音频注入 + 采集案例（触发→证据：$PROBE_DIR/w7-probe.log）--"
  "$PROBE_BIN" run "$ROOT/voice/audio/s1.wav"
  RC=$?

  echo
  echo "-- [4/5] 上屏复核（尽力而为：读 TextEdit 文档文本）--"
  DOC_TEXT="$(osascript -e 'tell application "TextEdit" to get text of document 1' 2>/dev/null | head -2 || true)"
  echo "    TextEdit 文档文本: ${DOC_TEXT:-<读取失败或无文档>}"
  case "$DOC_TEXT" in
    *"今天天气不错"*) echo "    [PASS] 文本已上屏到 TextEdit（注入链路终点实证）" ;;
    *) echo "    （文本未在文档中——无活动 controller 时 commit 目标为空属预期；真人实测另做）" ;;
  esac
  osascript -e "tell application \"TextEdit\" to close (every document whose path is \"$SCRATCH\") saving no" 2>/dev/null || true

  echo
  echo "-- [5/5] 麦克风授权条目复核（尽力而为）+ 还原 --"
  sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
    "select client, auth_value, auth_reason from access where service='kTCCServiceMicrophone';" 2>/dev/null \
    || echo "    （TCC.db 不可读——需完全磁盘访问；请人工看 系统设置→隐私与安全性→麦克风 是否有「提炼输入法」条目）"
  [ -n "${PREV_IMS:-}" ] && "$PROBE_BIN" restore-ims "$PREV_IMS" 2> >(sed 's/^/    /' >&2) || true

  echo
  echo "== 探针退出码 ${RC}（0=全绿） =="
  return "${RC}"
}

main 2>&1 | tee "$LOGDIR/w26-voice-probe.log"
exit "${PIPESTATUS[0]}"
