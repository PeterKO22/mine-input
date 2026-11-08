#!/usr/bin/env bash
# w29-probe.sh — W29 回复留存（L3）端到端探针（确定性：ts 注入伪时钟，零 sleep、零 TCC、零 launch）。
#
# 实证链（与 Squirrel 内接线同一 API/同一落库路径）：
#   ① 关留存 → 注入 commit 事件 → interaction.db text_out 空
#   ② privacy retain on --confirm（防误触：无 --confirm 必拒）→ 注入 commit 事件
#      → interaction.db 出现 text_out 非空行
#   ③ memoryctl pair → JSONL 记忆条目（含 situation + my_reply）
#   ④ 密码框（--secure-input）→ 拒收零入库（留存开着也恒拒）
#   ⑤ 关留存 → 新事件 text_out 空（既有留存不回改）
#   ⑥ memoryctl pair 输出「段内无留存回复 / 真取消」分开计数 + 提示
#      「回复留存未开，开后新会话才会配对」
#   ⑦ ⌥M 管理浮层界面形态：「记录我的回复（用于记忆与推荐）」开关在场（w20ctl panel-dump）
#
# 用法：bash macos/w12/scripts/w29-probe.sh   （全绿 exit 0，否则 exit 非 0）
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SCRATCH="${TMPDIR:-/tmp}/w29-probe-$$"
mkdir -p "$SCRATCH"
DB="$SCRATCH/interaction.db"
MEM="$SCRATCH/memory"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
check(){ if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "${1}（未见：${2}）"; fi; }

echo "== [0/7] 构建（w12ctl / memoryctl / w20ctl，构建树只编译不 launch）=="
(cd "$ROOT/context"   && swift build --product memoryctl >/dev/null 2>&1) || { echo "memoryctl build failed"; exit 1; }
(cd "$ROOT/macos/w12" && swift build --product w12ctl     >/dev/null 2>&1) || { echo "w12ctl build failed"; exit 1; }
(cd "$ROOT/macos/w20" && swift build --product w20ctl     >/dev/null 2>&1) || { echo "w20ctl build failed"; exit 1; }
W="$ROOT/macos/w12/.build/debug/w12ctl"
M="$ROOT/context/.build/debug/memoryctl"
C="$ROOT/macos/w20/.build/debug/w20ctl"

T0=1793730973000   # 伪时钟固定点（毫秒）：T0 / T0+60s / T0+180s —— 相邻 >30s → 各自成段
T1=1793731033000
T3=1793731153000

echo "== [1/7] 关留存 → 注入 commit 事件 → text_out 空 =="
OUT="$("$W" privacy retain off --db "$DB")"
check "留存关（起始复位）" "retain explicit disable" "$OUT"
OUT="$("$W" bridge commit --ts $T0 --text-in "ni hao" --text-out "你好" --app-id com.apple.TextEdit --db "$DB")"
check "commit 事件入库" "key_session: stored" "$OUT"
ROW="$(sqlite3 "$DB" "SELECT quote(text_out) FROM events WHERE ts=$T0;")"
if [ "$ROW" = "''" ]; then ok "关留存 → interaction.db text_out 空（quote=${ROW}）"; else bad "关留存 text_out 应空（实际 ${ROW}）"; fi

echo "== [2/7] privacy retain on --confirm（防误触）→ 注入 commit 事件 → text_out 非空 =="
if OUT="$("$W" privacy retain on --db "$DB" 2>&1)"; then
  bad "retain on 无 --confirm 应拒绝"
else
  check "retain on 无 --confirm 拒绝（防误触）" "--confirm" "$OUT"
fi
OUT="$("$W" privacy retain on --confirm --db "$DB")"
check "retain on --confirm 生效" "retain explicit enable: true" "$OUT"
OUT="$("$W" privacy status --db "$DB")"
check "持久开关跨进程可见（privacy status）" "上屏文本留存(L3): on" "$OUT"
OUT="$("$W" bridge commit --ts $T1 --text-in "明天的会改到10点" --text-out "收到，我会准时到" --app-id com.apple.TextEdit --db "$DB")"
check "commit 事件入库" "key_session: stored" "$OUT"
ROW="$(sqlite3 "$DB" "SELECT text_out FROM events WHERE ts=$T1;")"
if [ "$ROW" = "收到，我会准时到" ]; then ok "开留存 → interaction.db text_out 非空行（${ROW}）"; else bad "text_out 应留存（实际：${ROW}）"; fi

echo "== [3/7] memoryctl pair → JSONL 记忆条目（situation + my_reply）=="
OUT="$("$M" pair --db "$DB" --memory-dir "$MEM")"
echo "$OUT" | sed 's/^/    | /'
check "pair 产出 1 条记忆" "→ 1 memories" "$OUT"
check "分开计数：真取消 1（留存开着，text_out 全空段）" "真取消 1" "$OUT"
JSONL="$(ls "$MEM"/*.jsonl 2>/dev/null | head -1)"
if [ -n "$JSONL" ]; then
  ok "JSONL 记忆文件落盘（${JSONL}）"
  CONTENT="$(cat "$JSONL")"
  check "记忆条目含 situation" '"situation"' "$CONTENT"
  check "记忆条目含 my_reply" '"my_reply"' "$CONTENT"
  check "my_reply=我回的话" "收到，我会准时到" "$CONTENT"
  check "situation=当时情境" "明天的会改到10点" "$CONTENT"
else
  bad "JSONL 记忆文件未生成"
fi

echo "== [4/7] 密码框（secure input）→ 拒收恒不变（留存开着也拒）=="
BEFORE="$(sqlite3 "$DB" "SELECT COUNT(*) FROM events;")"
if OUT="$("$W" bridge commit --secure-input --ts $T3 --text-in "pw" --text-out "hunter2" --app-id com.apple.TextEdit --db "$DB" 2>&1)"; then
  bad "密码框应拒收（exit 非 0）"
else
  check "密码框拒收原因" "refused" "$OUT"
fi
AFTER="$(sqlite3 "$DB" "SELECT COUNT(*) FROM events;")"
if [ "$BEFORE" = "$AFTER" ]; then ok "密码框零入库（count ${BEFORE} 不变）"; else bad "密码框不应入库（${BEFORE} → ${AFTER}）"; fi

echo "== [5/7] 关留存 → 新事件 text_out 空（既有留存不回改）=="
OUT="$("$W" privacy retain off --db "$DB")"
check "retain off 生效" "retain explicit disable" "$OUT"
OUT="$("$W" bridge commit --ts $T3 --text-in "晚上一起吃饭" --text-out "好的晚上见" --app-id com.apple.TextEdit --db "$DB")"
check "commit 事件入库" "key_session: stored" "$OUT"
ROW="$(sqlite3 "$DB" "SELECT quote(text_out) FROM events WHERE ts=$T3;")"
if [ "$ROW" = "''" ]; then ok "关留存 → 新事件 text_out 空"; else bad "新事件 text_out 应空（实际 ${ROW}）"; fi
ROW="$(sqlite3 "$DB" "SELECT text_out FROM events WHERE ts=$T1;")"
if [ "$ROW" = "收到，我会准时到" ]; then ok "既有留存不回改（可查可删）"; else bad "既有留存被回改（${ROW}）"; fi

echo "== [6/7] memoryctl pair：「段内无留存回复」与「真取消」分开计数 + 提示 =="
OUT="$("$M" pair --db "$DB" --memory-dir "$MEM")"
echo "$OUT" | sed 's/^/    | /'
check "无留存回复单独计数（2 段：关留存期的两个 commit）" "段内无留存回复 2" "$OUT"
check "真取消单独计数（留存开着时不冒充）" "真取消 0" "$OUT"
check "已记会话重放幂等跳过" "dedup-skipped=1" "$OUT"
check "误导修复提示语" "回复留存未开，开后新会话才会配对" "$OUT"

echo "== [7/7] ⌥M 管理浮层界面形态（记录我的回复开关在场）=="
OUT="$("$C" panel-dump --dir "$MEM")"
check "开关标题「记录我的回复（用于记忆与推荐）」" "记录我的回复（用于记忆与推荐）" "$OUT"

rm -rf "$SCRATCH"
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "W29-PROBE ALL GREEN" || echo "W29-PROBE HAS FAILURES"
exit "$FAIL"
