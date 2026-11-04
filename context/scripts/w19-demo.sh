#!/usr/bin/env bash
# mine-input · W19 脚本化演示（验收序列）：
#   注入会话事件 → 生成记忆（配对）→ query 命中 → 编辑/删除 → 清空
# 另含：样例 JSONL 行、recent（suggest 注入接口）、同步挂钩（W8 同构事件体→ingest 队列）、
#       熔断停记、配对幂等（session_id 去重）。
# 用法：bash scripts/w19-demo.sh 2>&1 | tee .demo/w19-demo-output.txt
set -uo pipefail
cd "$(dirname "$0")/.."

CTX=.build/release/contextctl
MEM=.build/release/memoryctl
W=.demo/w19
DB=$W/interaction.db
MEMDIR=$W/memory
QUEUE=$W/ingest-queue.jsonl
mkdir -p "$W" && rm -rf "$MEMDIR" "$DB" "$QUEUE"

banner() { printf '\n=== %s ===\n' "$1"; }

banner "0. 构建与测试（swift build / swift test）"
swift build -c release 2>&1 | tail -1
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | sort -u

banner "1. 注入会话事件（W9 事件流；--ts 控时标，会话边界确定）"
BASE=$(( $(date +%s) * 1000 - 240000 ))
# 会话 1：打字上屏（TextEdit）
"$CTX" --commit-retention collect inject --db "$DB" --kind key_session \
  --ts $((BASE)) --text-in "明天的会改到10点" --text-out "收到，我会准时到" --app-id com.apple.TextEdit
# 会话 2：语音增量 + 提词建议采纳上屏（同一输入会话的两个事件）
"$CTX" --commit-retention collect inject --db "$DB" --kind voice_session \
  --ts $((BASE+60000)) --text-in "今天下午有空吗" --app-id com.apple.TextEdit
"$CTX" --commit-retention collect inject --db "$DB" --kind suggestion_feedback \
  --ts $((BASE+61000)) --text-in "今天下午" --text-out "今天下午有空，我们见一面" --shown 3 --taken 1 --app-id com.apple.TextEdit
# 会话 3：取消（无上屏）→ 不记
"$CTX" --commit-retention collect inject --db "$DB" --kind key_session \
  --ts $((BASE+120000)) --text-in "这句取消了" --app-id com.apple.TextEdit
# 会话 4：微信打字上屏
"$CTX" --commit-retention collect inject --db "$DB" --kind key_session \
  --ts $((BASE+180000)) --text-in "晚上一起吃饭" --text-out "好的晚上见" --app-id com.tencent.xinWeChat
sqlite3 "$DB" "SELECT COUNT(*) || ' events' FROM events;"

banner "2. 生成记忆（配对：一次输入会话=一条记忆，取消不记）"
echo '$ memoryctl pair'
"$MEM" pair --db "$DB" --memory-dir "$MEMDIR"
echo '$ memoryctl pair  # 重放（session_id 确定性 → 幂等去重）'
"$MEM" pair --db "$DB" --memory-dir "$MEMDIR"
echo '$ cat 当日 JSONL（样例，一行一条记忆）'
cat "$MEMDIR"/*.jsonl

banner "3. 检索 query（回忆：--keyword / --app / --since）"
echo '$ memoryctl query --keyword 准时'
"$MEM" query --db "$DB" --memory-dir "$MEMDIR" --keyword "准时"
echo '$ memoryctl query --app xinWeChat --jsonl'
"$MEM" query --db "$DB" --memory-dir "$MEMDIR" --app "xinWeChat" --jsonl
echo '$ memoryctl query --since 7d --limit 10'
"$MEM" query --db "$DB" --memory-dir "$MEMDIR" --since 7d --limit 10

banner "4. recent（供 suggest 上下文注入的接口）"
echo '$ memoryctl recent --limit 3 --for-suggest'
"$MEM" recent --db "$DB" --memory-dir "$MEMDIR" --limit 3 --for-suggest

banner "5. 手工编辑（重写当日文件，N8）"
ID=$( "$MEM" query --db "$DB" --memory-dir "$MEMDIR" --keyword "准时" --jsonl \
      | head -1 | sed -E 's/.*"id":"([^"]+)".*/\1/' )
echo '$ memoryctl edit --id '"$ID"' --reply 收到，我会准时到（改后）'
"$MEM" edit --db "$DB" --memory-dir "$MEMDIR" --id "$ID" --reply "收到，我会准时到（改后）"
echo '$ memoryctl query --keyword 改后'
"$MEM" query --db "$DB" --memory-dir "$MEMDIR" --keyword "改后"

banner "6. 删除（物理移除该行，无 tombstone；撤回停传）"
ID2=$( "$MEM" query --db "$DB" --memory-dir "$MEMDIR" --keyword "改后" --jsonl \
       | head -1 | sed -E 's/.*"id":"([^"]+)".*/\1/' )
echo "行数（删除前）: $(cat "$MEMDIR"/*.jsonl | wc -l | tr -d ' ')"
echo '$ memoryctl delete --id '"$ID2"
"$MEM" delete --db "$DB" --memory-dir "$MEMDIR" --id "$ID2"
echo "行数（删除后）: $(cat "$MEMDIR"/*.jsonl | wc -l | tr -d ' ')（物理移除）"
echo '$ memoryctl query --keyword 改后   # 应无命中'
"$MEM" query --db "$DB" --memory-dir "$MEMDIR" --keyword "改后"

banner "7. 同步挂钩：W8 同构事件体（JSONL 直进 ingest 队列）"
echo '$ memoryctl sync export'
"$MEM" sync export --db "$DB" --memory-dir "$MEMDIR" --device mac-demo
echo '$ memoryctl sync enqueue --queue-file '"$QUEUE"
"$MEM" sync enqueue --db "$DB" --memory-dir "$MEMDIR" --device mac-demo --queue-file "$QUEUE"
echo '$ cat ingest 队列文件（一行一个 /v1/ingest 事件体）'
cat "$QUEUE"

banner "8. 熔断停记（breaker trip 后记忆保留不新增）"
"$CTX" --commit-retention collect inject --db "$DB" --kind key_session \
  --ts $((BASE+240000)) --text-in "熔断后的新会话" --text-out "不应被记住" --app-id com.apple.TextEdit
"$CTX" breaker trip --db "$DB"
echo '$ memoryctl pair   # 熔断后落盘 → 期望拒收'
"$MEM" pair --db "$DB" --memory-dir "$MEMDIR" || echo "  (exit=$? 按预期拒收)"
echo '$ memoryctl status'
"$MEM" status --db "$DB" --memory-dir "$MEMDIR"
"$CTX" breaker reset --db "$DB"
echo '$ memoryctl pair   # 熔断恢复后补记（事件仍在事件流）'
"$MEM" pair --db "$DB" --memory-dir "$MEMDIR"

banner "9. 一键清空（事件层 + 记忆层同清）"
echo '$ memoryctl status   # 清空前'
"$MEM" status --db "$DB" --memory-dir "$MEMDIR"
echo '$ memoryctl clear'
"$MEM" clear --db "$DB" --memory-dir "$MEMDIR"
echo '$ memoryctl status   # 清空后'
"$MEM" status --db "$DB" --memory-dir "$MEMDIR"
echo '$ ls '"$MEMDIR"'（记忆文件已全删）'
ls "$MEMDIR" 2>/dev/null || echo "(empty)"

banner "DEMO: ALL STEPS EXECUTED"
