#!/usr/bin/env bash
# mine-input · W9 脚本化演示（验收序列）：
#   注入会话事件 → 日志入库 → sqlite3 查询输出 → suggest 流式刷新 → 熔断后停止入库
# 另含：C0 采集（NSWorkspace/剪贴板默认关）、可导、提词器流式面板（Tab 采纳）、可一键清空。
# 用法：bash scripts/demo.sh 2>&1 | tee .demo/demo-output.txt
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=.build/release/contextctl
DB=.demo/interaction.db
mkdir -p .demo && rm -f "$DB"

banner() { printf '\n=== %s ===\n' "$1"; }

banner "0. 构建与测试（swift build / swift test）"
swift build -c release 2>&1 | tail -1
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1

banner "1. C0 采集器：frontmost 应用（NSWorkspace）+ 采集状态"
"$BIN" init --db "$DB"
"$BIN" collect app --db "$DB"
"$BIN" collect status --db "$DB"

banner "2. 输入会话事件入库 API（C0Collector.record*，供 W7 上报）"
"$BIN" --commit-retention collect inject --db "$DB" --kind key_session \
  --text-in "ni hao" --text-out "你好" --cadence 3.2 --shown 2 --taken 1 --app-id com.apple.TextEdit
"$BIN" --commit-retention collect inject --db "$DB" --kind key_session \
  --text-in "shijie" --text-out "世界" --cadence 3.1 --app-id com.apple.TextEdit
"$BIN" --commit-retention collect inject --db "$DB" --kind voice_session \
  --text-in "今天开会" --text-out "今天开会。" --shown 3 --taken 1 --app-id com.apple.TextEdit
"$BIN" --commit-retention collect inject --db "$DB" --kind candidate_pick \
  --text-in "zni" --text-out "智能" --cadence 2.8 --app-id com.apple.TextEdit
"$BIN" --commit-retention collect inject --db "$DB" --kind suggestion_feedback \
  --text-in "今天开会" --text-out "今天开会——好的，我稍后处理" --shown 3 --taken 1
echo "-- 负例 1：安全输入（密码框/支付）自动暂停不可关 → 期望拒收"
"$BIN" collect inject --db "$DB" --kind key_session \
  --text-in "password123" --secure-input || echo "  (exit=$? 按预期拒绝)"
echo "-- 负例 2：敏感应用黑名单（keychain）→ 期望拒收"
"$BIN" collect inject --db "$DB" --kind key_session \
  --text-in "x" --app-id com.apple.keychainaccess || echo "  (exit=$? 按预期拒绝)"
echo "-- 隐私默认：不带 --commit-retention 时上屏文本留存关闭（text_out 为空）"
"$BIN" collect inject --db "$DB" --kind key_session \
  --text-in "留存默认关" --text-out "上屏文本不应留存"
sqlite3 -header -column "$DB" \
  "SELECT id,text_in,text_out FROM events WHERE text_in='留存默认关';"

banner "3. 交互日志：sqlite3 查询输出（可查，时间索引）"
echo '$ sqlite3 '"$DB"' ".schema events"'
sqlite3 "$DB" ".schema events"
echo '$ sqlite3 -header -column '"$DB"' "SELECT ... FROM events ORDER BY id"'
sqlite3 -header -column "$DB" "SELECT id, ts, kind, app_id, text_in, text_out, \
  keystroke_cadence AS cad, suggestion_shown AS shown, suggestion_taken AS taken \
  FROM events ORDER BY id;"
echo '$ sqlite3 '"$DB"' "SELECT COUNT(*) FROM events"'
sqlite3 "$DB" "SELECT COUNT(*) FROM events;"

banner "4. 可导（JSONL / CSV）"
echo '$ contextctl log export --format jsonl'
"$BIN" log export --db "$DB" --format jsonl
echo '$ contextctl log export --format csv'
"$BIN" log export --db "$DB" --format csv

banner "5. suggest 客户端：Hub /v1/suggest SSE 流式刷新（localhost:8088）"
TOKEN=$("$BIN" hub-token --username w9-demo --password w9-demo-pass)
echo "hub-token: len=${#TOKEN}（register 忽略 409 → token）"
echo '$ contextctl suggest --backend hub --text "今天开会"'
"$BIN" suggest --backend hub --token "$TOKEN" --text "今天开会"
echo '$ contextctl suggest --backend null --text "语音转写"   # Null 后端离线兜底'
"$BIN" suggest --backend null --text "语音转写"
echo '$ contextctl suggest --backend hub --text "超时用例" --timeout-ms 80   # 超时弃本轮（NFR3）'
"$BIN" suggest --backend hub --token "$TOKEN" --text "超时用例" --timeout-ms 80 || true

banner "6. 动态提词器 · 终端流式面板（转写/上下文增量→建议实时刷新→Tab 采纳）"
echo '$ printf "今天开会\\n\\t\\n" | contextctl prompter --backend hub --from-voice'
printf '今天开会\n\t\n' | "$BIN" prompter --db "$DB" --backend hub --token "$TOKEN" --from-voice
echo '$ printf "语音转写\\n\\t\\n" | contextctl prompter --backend null   # 离线兜底'
printf '语音转写\n\t\n' | "$BIN" prompter --db "$DB" --backend null

banner "7. 剪贴板采集默认关（隐私红线：显式开关才采，且只记摘要/长度不记内容）"
echo '$ contextctl collect clipboard   # 未显式开启'
"$BIN" collect clipboard --db "$DB"
echo '$ contextctl collect clipboard --enable-explicit   # 显式开启（仅 demo）'
"$BIN" collect clipboard --db "$DB" --enable-explicit

banner "8. 熔断开关：开启后一切采集立即停（日志保留不新增）"
echo '$ sqlite3 "SELECT COUNT(*) FROM events"   # 熔断前'
sqlite3 "$DB" "SELECT COUNT(*) FROM events;"
echo '$ contextctl breaker status'
"$BIN" breaker status --db "$DB"
echo '$ contextctl breaker trip'
"$BIN" breaker trip --db "$DB"
echo '$ contextctl collect inject ... （熔断后注入 → 期望拒收）'
"$BIN" collect inject --db "$DB" --kind key_session \
  --text-in "熔断后不应入库" || echo "  (exit=$? 按预期拒绝)"
echo '$ printf "熔断后提词\\n\\t\\n" | contextctl prompter --backend null   # 采纳入库同样被拒'
printf '熔断后提词\n\t\n' | "$BIN" prompter --db "$DB" --backend null
echo '$ sqlite3 "SELECT COUNT(*) FROM events"   # 熔断后：应与熔断前一致'
sqlite3 "$DB" "SELECT COUNT(*) FROM events;"
echo '$ contextctl breaker reset   # 显式恢复'
"$BIN" breaker reset --db "$DB"
"$BIN" collect inject --db "$DB" --kind key_session \
  --text-in "熔断解除恢复入库" --app-id com.apple.TextEdit

banner "9. 30 天滚动 + 一键清空（可清）"
echo '$ contextctl log prune --days 30'
"$BIN" log prune --db "$DB" --days 30
echo '$ contextctl log clear   # 一键清空'
"$BIN" log clear --db "$DB"
echo '$ sqlite3 "SELECT COUNT(*) FROM events"'
sqlite3 "$DB" "SELECT COUNT(*) FROM events;"

banner "DEMO: ALL STEPS EXECUTED"
