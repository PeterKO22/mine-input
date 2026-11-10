#!/usr/bin/env bash
# w30-probe.sh — W30 本地模型显式开关与配置入口 端到端探针（真实服务生命周期实证）。
#
# 实证链（开关链路与 ⌥M 面板同源：W20ModelServiceControl → models/manage-model-service.sh）：
#   ① 默认状态 = 未加载 + 无 llama-server 进程 + 无 launchd 自启（不开不加载硬保证）
#   ② ⌥M 浮层「本地模型（7B）」区块在场（w20ctl panel-dump：开关 + 状态 + 配置入口）
#   ③ 无显式确认开 = 拒绝（setEnabled(true, explicitConfirm:false) 硬门 false，零副作用）
#   ④ 显式开启（--confirm）→ 服务起 + 健康检查过（/v1/models 或 /completion）+ 进程在
#   ⑤ 幂等：二次开启 = no-op 不重复加载（引擎原话「幂等 no-op」+ pid 不变）
#   ⑥ 关闭 → 进程立即停（pgrep 无 + state=not-loaded）
#   ⑦ 幂等：二次关闭 = no-op（引擎原话「幂等」+ 仍 not-loaded）
#   ⑧ 二次 on/off 全环可重复（on→ready→off→not-loaded）
#   ⑨ 防呆审计快照（launchd plist 已删 / run-llama-native.sh 无 load·unload·serve /
#      compose llama restart: "no"）——逐条见 macos/W30-REPORT.md §3
#
# 用法：bash macos/w30/scripts/w30-probe.sh   （全绿 exit 0，否则 exit 非 0）
# 说明：7B 权重真实加载（约 10–40s/次），属真实服务生命周期实测——单测层零 sleep
# 伪时钟红线不受影响（w20/w12/context 单测仍零 sleep）。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MGR="$ROOT/models/manage-model-service.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
check(){ if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "${1}（未见：${2}）"; fi; }
ro() { "$@" >/dev/null 2>&1; }   # run-only

echo "== [0/9] 构建（w20ctl；构建树只编译不 launch）+ 脚本语法 =="
(cd "$ROOT/macos/w20" && swift build --product w20ctl >/dev/null 2>&1) || { echo "w20ctl build failed"; exit 1; }
C="$ROOT/macos/w20/.build/debug/w20ctl"
bash -n "$MGR" && bash -n "$ROOT/models/run-llama-native.sh" || { echo "script syntax failed"; exit 1; }
ok "构建/语法通过"

echo "== [1/9] 默认状态 = 未加载 + 无进程 + 无自启 =="
OUT="$("$C" model status)"
echo "$OUT" | sed 's/^/    | /'
check "默认 state=not-loaded" "state=not-loaded" "$OUT"
check "默认探活未运行" "probe=none" "$OUT"
check "默认开关态=关（未加载）" "本地模型：未加载（默认" "$OUT"
check "默认无 launchd 遗留自启" "legacy_launchd=absent" "$OUT"
if ro pgrep -f llama-server; then bad "默认不应有 llama-server 进程"; else ok "默认无 llama-server 进程"; fi

echo "== [2/9] ⌥M 浮层「本地模型（7B）」区块（panel-dump）=="
OUT="$("$C" panel-dump --dir "${TMPDIR:-/tmp}/w30-probe-mem")"
check "区块标题「本地模型（7B）」" "本地模型（7B）" "$OUT"
check "状态显示在场" "本地模型：未加载（默认" "$OUT"
check "配置入口路径（config/ai.yaml）" "config/ai.yaml" "$OUT"
check "配置打开按钮「打开配置」" "打开配置" "$OUT"
# 确认弹窗文案不在面板 dump（弹窗动态生成）——断言生产源码同源文案（约 X GB 内存/仅本机推理）
SRC="$(cat "$ROOT/macos/w20/src/W20ModelControl.swift")"
check "确认文案含资源提示（约 X GB 内存，mem_hint_gb 动态）" "约 \\(gb) GB" "$SRC"
check "确认文案含「仅本机推理」" "仅本机推理" "$SRC"

echo "== [3/9] 无显式确认开 = 拒绝（硬门，零副作用）=="
if OUT="$("$C" model on 2>&1)"; then
  bad "model on 无 --confirm 应拒绝（exit 2）"
else
  check "拒绝原因（需显式确认）" "refused: 开启本地模型需显式确认" "$OUT"
  check "setEnabled(true, explicitConfirm:false) 硬门 false" "硬门返回 false" "$OUT"
fi
OUT="$("$C" model status)"
check "拒绝后仍未加载（零副作用）" "state=not-loaded" "$OUT"
if ro pgrep -f llama-server; then bad "拒绝后不应有进程"; else ok "拒绝后无 llama-server 进程"; fi

echo "== [4/9] 显式开启（--confirm）→ 服务起 + 健康检查过 =="
OUT="$("$C" model on --confirm 2>&1)"
echo "$OUT" | sed 's/^/    | /'
check "启动成功" "on: 启动成功" "$OUT"
check "健康检查过（探活）" "探活" "$OUT"
OUT="$("$C" model status)"
check "state=ready" "state=ready" "$OUT"
check "探活通过（/v1/models 或 /completion）" "probe_ok=1" "$OUT"
if ro pgrep -f llama-server; then ok "llama-server 进程在"; else bad "llama-server 进程应存在"; fi
if ro curl -sf -m 3 "http://127.0.0.1:8092/v1/models"; then ok "外部复核：/v1/models 200"
elif ro curl -sf -m 8 -X POST "http://127.0.0.1:8092/completion" -H 'Content-Type: application/json' -d '{"prompt":" ","n_predict":1,"temperature":0}'; then ok "外部复核：/completion 200"
else bad "外部复核：探活均未过"; fi
PID1="$("$C" model status | sed -n 's/^pid=//p')"

echo "== [5/9] 幂等：二次开启 = no-op 不重复加载 =="
OUT="$(bash "$MGR" start 2>&1)"
echo "$OUT" | sed 's/^/    | /'
check "引擎原话：幂等 no-op（不重复加载）" "幂等 no-op" "$OUT"
OUT="$("$C" model status)"
PID2="$(sed -n 's/^pid=//p' <<<"$OUT")"
check "state 仍 ready" "state=ready" "$OUT"
if [ -n "$PID1" ] && [ "$PID1" = "${PID2}" ]; then ok "pid 不变（${PID1} = ${PID2}，未重复加载）"; else bad "pid 应不变（${PID1} vs ${PID2}）"; fi

echo "== [6/9] 关闭 → 进程立即停 =="
OUT="$("$C" model off 2>&1)"
echo "$OUT" | sed 's/^/    | /'
check "关闭成功" "off: 已停止" "$OUT"
OUT="$("$C" model status)"
check "state=not-loaded" "state=not-loaded" "$OUT"
if ro pgrep -f llama-server; then bad "关闭后不应有 llama-server 进程"; else ok "关闭后无 llama-server 进程"; fi

echo "== [7/9] 幂等：二次关闭 = no-op =="
OUT="$(bash "$MGR" stop 2>&1)"
echo "$OUT" | sed 's/^/    | /'
check "引擎原话：幂等（未在跑也是 ok）" "幂等：未在跑也是 ok" "$OUT"
OUT="$("$C" model status)"
check "仍 state=not-loaded" "state=not-loaded" "$OUT"

echo "== [8/9] 二次 on/off 全环可重复 =="
OUT="$("$C" model on --confirm 2>&1)"
check "二次开启成功" "on: 启动成功" "$OUT"
OUT="$("$C" model status)"
check "二次 ready" "state=ready" "$OUT"
OUT="$("$C" model off 2>&1)"
check "二次关闭成功" "off: 已停止" "$OUT"
OUT="$("$C" model status)"
check "二次关闭后 not-loaded" "state=not-loaded" "$OUT"

echo "== [9/9] 防呆审计快照（不开不加载硬保证）=="
if [ -f "$ROOT/models/com.mineinput.llama.plist" ]; then bad "launchd plist 应已删除"; else ok "launchd plist 已删除（RunAtLoad 自启路径不存在）"; fi
OUT="$(cat "$ROOT/models/run-llama-native.sh")"
if grep -qE 'do_load|do_unload|do_serve|"load"\)|"unload"\)|"serve"\)' <<<"$OUT"; then
  bad "run-llama-native.sh 不应再有 load/unload/serve"
else
  ok "run-llama-native.sh 无 load/unload/serve（launchd 托管路径整条删除）"
fi
OUT="$(cat "$ROOT/hub/docker-compose.yml")"
if grep -A35 '^  llama:' <<<"$OUT" | grep -q 'restart: "no"'; then ok "compose llama restart: \"no\"（不自动拉起）"; else bad "compose llama 应 restart: \"no\""; fi
if ro launchctl print "gui/$(id -u)/com.mineinput.llama"; then bad "无 launchd agent 在载"; else ok "launchd 无 com.mineinput.llama agent"; fi
if ro pgrep -f llama-server; then bad "终态应无 llama-server 进程"; else ok "终态无 llama-server 进程（默认未加载复位）"; fi

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "W30-PROBE ALL GREEN" || echo "W30-PROBE HAS FAILURES"
exit "$FAIL"
