#!/usr/bin/env bash
# w20-demo.sh — W20 验收序列（脚本化可验部分；界面手动步骤见 macos/W20-REPORT.md §6）
# 1) ai/ C++ 单测（含红线「未 confirm 不得执行」） 2) macos/w20 SwiftPM 单测
# 3) w20ctl 数据层操作（时间线/搜索/编辑/删除/导出） 4) 一键熔断（ContextCore 同源）
# 5) 提案卡 state 流转（Null 桩） 6) 界面形态 dump 断言
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
W20="$ROOT/macos/w20"
SCRATCH="${TMPDIR:-/tmp}/w20-demo-$$"
mkdir -p "$SCRATCH"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
check(){ if grep -q "$2" <<<"$3"; then ok "$1"; else bad "$1（未见：$2）"; fi; }

echo "== [1/6] ai/ C++ 单测（提案契约 v2 + 未 confirm 不得执行）=="
CTEST_OUT="$(ctest --test-dir "$ROOT/build" --output-on-failure 2>&1)"
if echo "$CTEST_OUT" | grep -q "100% tests passed"; then
  ok "ctest 全绿（$(echo "$CTEST_OUT" | grep -c 'Passed') 个）"
else
  bad "ctest 未全绿"; echo "$CTEST_OUT" | tail -5
fi

echo "== [2/6] macos/w20 SwiftPM 单测 =="
SWIFT_OUT="$(cd "$W20" && swift test 2>&1)"
if echo "$SWIFT_OUT" | grep -q "Executed 15 tests, with 0 failures"; then
  ok "swift test 15/15 全绿"
else
  bad "swift test 未全绿"; echo "$SWIFT_OUT" | tail -5
fi

echo "== [3/6] w20ctl 数据层（时间线/搜索/编辑/删除/导出）=="
cat > "$SCRATCH/2026-11-03.jsonl" <<'EOF'
{"id":"m-1","ts":"2026-11-03T09:00:00+08:00","device":"mac","app_id":"com.apple.mail","situation":{"before_cursor":"好的，我","screen_digest":"sha256:aaa len:10","thread":["对方:明天开会吗","我:开的"]},"my_reply":{"text":"开的，明天十点","mode":"text"},"meta":{"from_suggestion":"prop-9|","confidence":0.8,"session_id":"s1"},"consent":"c1"}
{"id":"m-2","ts":"2026-11-03T10:00:00+08:00","device":"mac","app_id":"com.tencent.xinWeChat","situation":{"before_cursor":"收到","thread":["对方:文件发我一下"]},"my_reply":{"text":"稍等","mode":"voice"},"consent":"c0"}
EOF
cat > "$SCRATCH/2026-11-04.jsonl" <<'EOF'
{"id":"m-3","ts":"2026-11-04T08:30:00+08:00","device":"mac","app_id":"com.apple.mail","situation":{"before_cursor":"关于报价","thread":[]},"my_reply":{"text":"报价单见附件","mode":"text"},"consent":"c1"}
EOF
CTL="$W20/.build/debug/w20ctl"
OUT="$("$CTL" list --dir "$SCRATCH")"
check "按日分组（新日在前）" "2026-11-04  1 条" "$OUT"
OUT="$("$CTL" search --dir "$SCRATCH" --keyword 报价)"
check "搜索 keyword 命中 my_reply" "hits=1" "$OUT"
OUT="$("$CTL" search --dir "$SCRATCH" --keyword 文件发我)"
check "搜索 keyword 命中 thread" "id=m-2" "$OUT"
BEFORE_LINE="$(grep '"id":"m-1"' "$SCRATCH/2026-11-03.jsonl")"
OUT="$("$CTL" edit --dir "$SCRATCH" --id m-2 --situation 改后情境 --thread '对方:新线程' --reply 改后回复)"
check "编辑 situation+my_reply" "updated: m-2" "$OUT"
grep -q '"before_cursor":"改后情境"' "$SCRATCH/2026-11-03.jsonl" && ok "situation 已重写当日文件" || bad "situation 未落盘"
grep -q '"mode":"voice"' "$SCRATCH/2026-11-03.jsonl" && ok "未提及字段（mode）保留" || bad "mode 丢失"
AFTER_LINE="$(grep '"id":"m-1"' "$SCRATCH/2026-11-03.jsonl")"
[ "$BEFORE_LINE" = "$AFTER_LINE" ] && ok "未改动行字节级原样" || bad "未改动行被重写"
OUT="$("$CTL" delete --dir "$SCRATCH" --id m-1)"
check "删除（物理移除该行）" "deleted: m-1" "$OUT"
if grep -q '"id":"m-1"' "$SCRATCH/2026-11-03.jsonl" 2>/dev/null; then
  bad "m-1 行仍在"
else
  ok "m-1 行已不存在（物理移除）"
fi
OUT="$("$CTL" export --dir "$SCRATCH" --app com.apple.mail --out "$SCRATCH/export.jsonl")"
check "导出 JSONL" "exported 1 条" "$OUT"

echo "== [4/6] 一键熔断（ContextCore CircuitBreaker 同源）=="
DB="$SCRATCH/interaction.db"
OUT="$("$CTL" breaker trip --db "$DB")"
check "熔断生效" "TRIPPED" "$OUT"
OUT="$("$CTL" breaker status --db "$DB")"
check "状态=熔断中" "熔断中" "$OUT"
OUT="$("$CTL" breaker reset --db "$DB")"
check "解除熔断" "off" "$OUT"

echo "== [5/6] 提案卡 state 流转（Null 桩）=="
OUT="$("$CTL" proposal demo)"
check "propose 后未执行（红线）" "executionCount=0 （红线：propose 后必须为 0）" "$OUT"
check "伪造 handle 被拒（红线）" "refused ✓" "$OUT"
check "confirm → queued" "state=queued" "$OUT"
check "observe → running" "state=running" "$OUT"
check "observe → done（执行到出结果）" "state=done" "$OUT"
check "重复 confirm 幂等" "executionCount=1（应为 1）" "$OUT"

echo "== [6/6] 界面形态 dump（记忆管理 + 提案卡）=="
OUT="$("$CTL" panel-dump --dir "$SCRATCH")"
check "顶部采集状态常显" "采集状态" "$OUT"
check "一键熔断开关" "一键熔断" "$OUT"
check "时间线按日分组" "2026-11-03 · 1 条" "$OUT"
check "situation 编辑区" "情境 situation · before_cursor" "$OUT"
check "my_reply 编辑区" "我的回复 my_reply · text" "$OUT"
check "保存/删除/导出按钮" "保存修改" "$OUT"
check "提案卡标题/详情/动作清单" "Null 示例方案" "$OUT"
check "显式确认执行按钮" "确认执行" "$OUT"

rm -rf "$SCRATCH"
echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "W20-DEMO ALL GREEN" || echo "W20-DEMO HAS FAILURES"
exit "$FAIL"
