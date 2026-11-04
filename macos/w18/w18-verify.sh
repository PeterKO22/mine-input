#!/usr/bin/env bash
# W18 显示名程序化验证（无 GUI）：
#   1. 静态断言：安装的 Squirrel-dev.app 三个 lproj 的 InfoPlist.strings 必须
#      以 .dev 输入源 ID 为键、值为「提炼输入法」/ "Mine Input"（D15）
#   2. 运行时断言：TIS 探针（macos/w18/tis_probe.swift）列出
#      kTISPropertyLocalizedName，断言出现「提炼输入法」/ "Mine Input"
#      自动重试 3 次；仍失败则提示——macOS 对输入源列表有缓存，重装后
#      可能需要注销并重新登录（或重启）后刷新。
# 用法：bash macos/w18/w18-verify.sh [app 路径]（默认 ~/Library/Input Methods/Squirrel-dev.app）
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${1:-$HOME/Library/Input Methods/Squirrel-dev.app}"
PROBE_SRC="$ROOT/macos/w18/tis_probe.swift"
PROBE_BIN="$ROOT/macos/w18/tis-probe"

FAIL=0

echo "== W18 显示名验证 =="
echo "app: $APP"
[ -d "$APP" ] || { echo "RESULT: FAIL — 未安装 $APP（先 bash build/build-squirrel.sh && bash build/install-dev.sh）"; exit 1; }

echo
echo "== [1/3] 静态断言：InfoPlist.strings 本地化链（键=.dev 输入源 ID）=="
for lproj in en zh-Hans zh-Hant; do
  STR="$APP/Contents/Resources/$lproj.lproj/InfoPlist.strings"
  echo "-- $lproj.lproj/InfoPlist.strings --"
  if [ ! -f "$STR" ]; then echo "  [FAIL] 缺失 $STR"; FAIL=1; continue; fi
  plutil -p "$STR"
  for key in "im.rime.inputmethod.Squirrel.dev" "im.rime.inputmethod.Squirrel.dev.Hans" "im.rime.inputmethod.Squirrel.dev.Hant"; do
    if plutil -p "$STR" | grep -q "\"$key\""; then
      echo "  [PASS] key $key 存在"
    else
      echo "  [FAIL] key $key 缺失（显示名会退化为裸 ID）"; FAIL=1
    fi
  done
  if [ "$lproj" = "en" ]; then WANT='"Mine Input"'; else WANT='提炼输入法'; fi
  if plutil -p "$STR" | grep -q "$WANT"; then
    echo "  [PASS] 本地化值含 $WANT"
  else
    echo "  [FAIL] 本地化值不含 $WANT"; FAIL=1
  fi
done

echo
echo "== [2/3] 运行时断言：TIS 探针 kTISPropertyLocalizedName =="
if [ ! -x "$PROBE_BIN" ] || [ "$PROBE_SRC" -nt "$PROBE_BIN" ]; then
  echo "(编译探针 swiftc ...)"
  swiftc -O "$PROBE_SRC" -o "$PROBE_BIN" -framework Carbon || { echo "RESULT: FAIL — 探针编译失败"; exit 1; }
fi

for i in 1 2 3; do
  echo "-- 探针第 $i 次 --"
  "$PROBE_BIN"
  RC=$?
  if [ $RC -eq 0 ]; then break; fi
  if [ $i -lt 3 ]; then
    echo "(失败 rc=${RC}，2s 后自动重试——macOS 输入源缓存可能未刷新）"
    sleep 2
  fi
done

echo
echo "== [3/3] IME 进程拉起 + IMK 端口注册（W18 可输入性门）=="
IME_PID="$(pgrep -f "$APP/Contents/MacOS/Squirrel" | head -1 || true)"
if [ -z "$IME_PID" ]; then
  echo "  [FAIL] IME 进程不在——切换输入源会完全无法输入（W18 实测事故同因）"
  echo "  修复：open \"$APP\" 拉起进程（install-dev.sh [4/5] 已自动执行并把关）"
  RC=1; FAIL=1
else
  echo "  [PASS] IME 进程存活: pid=$IME_PID"
  IMK_LOG="$(log show --last 2m --predicate 'process == "Squirrel"' --style compact 2>/dev/null | grep -E 'inputmethodkit|Activate Server' | tail -3)"
  echo "-- IMK 注册/激活证据（unified log）--"
  echo "$IMK_LOG"
  echo "$IMK_LOG" | grep -q "inputmethodkit" && echo "  [PASS] IMK XPC 端点已注册（com.apple.inputmethodkit.setxpcendpoint）" \
    || echo "  [WARN] 日志窗口内未见 IMK 注册行（进程刚拉起时 1-2s 内出现；可重跑本脚本）"
fi

echo
if [ $RC -eq 0 ] && [ $FAIL -eq 0 ]; then
  echo "== RESULT: ALL PASS（静态 + TIS 运行时 + 进程/IMK）=="
  exit 0
elif [ $FAIL -eq 0 ] && { [ $RC -eq 2 ] || [ $RC -eq 3 ]; }; then
  echo "== RESULT: STATIC PASS / TIS STALE（静态链路正确，TIS 清单/缓存未刷新）=="
  echo "macOS 对输入源列表/显示名有缓存：重装（尤其是替换正在使用的输入法 bundle）后，"
  echo "输入源可能被系统暂时清出清单、名字也可能仍是旧的或裸 ID，"
  echo "需【注销并重新登录】（或重启）后，「添加输入法」对话框与菜单栏才恢复/显示"
  echo "「提炼输入法」（Mine Input）。重新登录后请重跑："
  echo "    bash macos/w18/w18-verify.sh"
  echo "并在 系统设置→键盘→输入法 里确认/重新添加「提炼输入法」（Mine Input）。"
  exit 2
else
  echo "== RESULT: FAIL（rc=${RC} static_fail=${FAIL}）=="
  exit 1
fi
