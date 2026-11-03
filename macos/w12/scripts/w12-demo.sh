#!/usr/bin/env bash
# W12 验收序列（脚本化实测，输出全文贴 macos/W12-REPORT.md）：
#   触发采集（防抖）→ OCR 摘要入库 → sqlite3 可查 → 熔断后停止 → 提词浮层流式刷新演示
# 同时覆盖：ASR 摘要（W2 管线）、隐私负例（密码框/黑名单/C1 关）、W7×W9 三事件上报。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
W12_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$(cd "$W12_DIR/../.." && pwd)"
DB="${MINE_W12_DEMO_DB:-$W12_DIR/.demo/w12-interaction.db}"
BIN="$W12_DIR/.build/release/w12ctl"
SHOT="/tmp/w12-shot.png"

mkdir -p "$(dirname "$DB")"
rm -f "$DB"
cd "$W12_DIR"

echo "=== 0. 构建与测试（swift build / swift test，W12Core 8 用例） ==="
swift build -c release 2>&1 | grep -E "error|Build complete"
swift test 2>&1 | grep -E "error:|Executed [0-9]+ tests"
echo "db: $DB"

echo
echo "=== 1. 隐私设置：C1 默认关 → 显式开启（开关显式，隐私红线） ==="
"$BIN" privacy status --db "$DB"
"$BIN" privacy c1 on --db "$DB"

echo
echo "=== 2. 触发采集：仅输入时（按键触发窗）+ 防抖 2s ==="
"$BIN" c1 gen-image "$SHOT" --image "$SHOT"
"$BIN" c1 trigger --keys 4 --image "$SHOT" --db "$DB"

echo
echo "=== 3. OCR 摘要入库（ScreenCaptureKit 帧→Vision OCR→摘要；sqlite3 可查） ==="
"$BIN" c1 ocr --image "$SHOT" --app-id com.apple.TextEdit --db "$DB"
echo '$ sqlite3 -header -column ... "SELECT id,kind,ocr_digest,asr_digest,text_in,text_out FROM events ORDER BY id"'
sqlite3 -header -column "$DB" "SELECT id,kind,ocr_digest,asr_digest,text_in,text_out FROM events ORDER BY id;"
echo "-- 隐私红线验证：OCR 全文/原图不落库（数据库中检索测试文本应为 0 命中）"
HITS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE text_in LIKE '%W12 摘要%' OR text_out LIKE '%W12 摘要%' OR ocr_digest LIKE '%摘要入库%';")
echo "plaintext hits in db: ${HITS}（期望 0）"

echo
echo "=== 4. 真屏幕快照（ScreenCaptureKit，需屏幕录制 TCC） ==="
"$BIN" c1 capture --source screen --app-id com.apple.TextEdit --db "$DB" || \
  echo "  ↑ 本会话 TCC 未授权（诚实 blocker，见 W12-REPORT §7）；授权后同命令即入库"

echo
echo "=== 5. ASR 摘要入库（音频→W2 管线 voice/mic/ptt_daemon→asr_digest，仅摘要/长度） ==="
"$BIN" c1 asr --wav "$ROOT/voice/audio/s1.wav" --app-id com.apple.TextEdit --db "$DB"
echo '$ sqlite3 ... "SELECT id,kind,asr_digest FROM events WHERE asr_digest IS NOT NULL"'
sqlite3 -header -column "$DB" "SELECT id,kind,asr_digest FROM events WHERE asr_digest IS NOT NULL;"

echo
echo "=== 6. 隐私负例：密码框自动停 / 黑名单跳过 / C1 关拒绝 ==="
echo "-- 密码框（secure input）自动停不可关："
"$BIN" c1 ocr --image "$SHOT" --secure-input --db "$DB"
echo "-- 敏感应用黑名单（keychain）跳过："
"$BIN" c1 ocr --image "$SHOT" --app-id com.apple.keychainaccess --db "$DB"
echo "-- C1 关（默认）拒绝采集："
"$BIN" privacy c1 off --db "$DB" | tail -1
"$BIN" c1 ocr --image "$SHOT" --db "$DB"
"$BIN" privacy c1 on --db "$DB" | tail -1

echo
echo "=== 7. 熔断开关：trip 后一切采集立即停（日志保留不新增） ==="
BEFORE=$(sqlite3 "$DB" "SELECT COUNT(*) FROM events;")
echo "events before trip: ${BEFORE}"
"$BIN" breaker trip --db "$DB"
"$BIN" c1 ocr --image "$SHOT" --db "$DB"
"$BIN" c1 asr --wav "$ROOT/voice/audio/s1.wav" --db "$DB"
AFTER=$(sqlite3 "$DB" "SELECT COUNT(*) FROM events;")
echo "events after trip: ${AFTER}（期望 == ${BEFORE}）"
"$BIN" breaker reset --db "$DB"

echo
echo "=== 8. W7×W9 接线：输入会话/语音会话/候选选择 → InteractionStore（同一入库 API） ==="
"$BIN" bridge demo --app-id com.apple.TextEdit --db "$DB"
echo '$ sqlite3 ... "SELECT id,kind,text_in,text_out FROM events WHERE id > '"$AFTER"' ORDER BY id"'
sqlite3 -header -column "$DB" "SELECT id,kind,text_in,text_out FROM events WHERE id > $AFTER ORDER BY id;"

echo
echo "=== 9. ⌥Esc 提词浮层：SSE 流式建议→实时刷新→Tab 采纳（Hub/Null 双模） ==="
echo "-- Null 离线兜底："
"$BIN" prompter --backend null --text "语音转写" --app-id com.apple.TextEdit --db "$DB"
echo "-- Hub SSE 流式（localhost:8088）："
TOKEN=$("$BIN" hub-token --username w12-demo --password w12-demo-pass --url http://localhost:8088 || true)
echo "hub-token: len=${#TOKEN}（register 忽略 409 → token）"
# Hub 模型后端（W10 llama）偶发 503 → SSE error 帧（客户端如实上报 kError）；重试取健康窗口
for TRY in 1 2 3 4 5; do
  OUT=$("$BIN" prompter --backend hub --token "$TOKEN" --text "今天开会" --app-id com.apple.TextEdit --db "$DB" 2>&1)
  echo "$OUT"
  if echo "$OUT" | grep -q "Δ +"; then break; fi
  echo "  （hub 本轮异常（llama 后端 503/无帧），重试 ${TRY}/5）"
  sleep 2
done
echo '$ sqlite3 ... "SELECT id,kind,suggestion_shown,suggestion_taken FROM events WHERE kind='"'"'suggestion_feedback'"'"'"'
sqlite3 -header -column "$DB" "SELECT id,kind,suggestion_shown,suggestion_taken FROM events WHERE kind='suggestion_feedback';"

echo
echo "=== 10. 汇总（sqlite3 全量计数） ==="
echo '$ sqlite3 ... "SELECT kind, COUNT(*) FROM events GROUP BY kind"'
sqlite3 -header -column "$DB" "SELECT kind, COUNT(*) FROM events GROUP BY kind;"
echo '$ sqlite3 ... "SELECT COUNT(*) FROM events"'
sqlite3 "$DB" "SELECT COUNT(*) FROM events;"

echo
echo "=== W12 DEMO: ALL STEPS EXECUTED ==="
