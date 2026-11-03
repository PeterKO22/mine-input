#!/usr/bin/env bash
# mine-input AI Hub 全链路冒烟（W4 验收脚本）
#
# 链路：healthz → 注册(含独立密钥分区) → 鉴权 → push → push 重试(幂等)
#       → push2(userdb 取新 + 计数器累加) → pull 一致性校验 → 多用户分区隔离
#       → ingest(合法/非法) → suggest SSE（含 W10 真模型 case 11b–11e）→ 401 负例
#
# 用法：BASE_URL=http://localhost:8088 ./smoke.sh   （默认与 docker-compose.yml 的 HUB_PORT 一致）
# 真模型 case（11b–11e）需 compose --profile model 起 llama 服务；
# 仅跑桩链路时：SMOKE_MODEL_REQUIRED=0 ./smoke.sh（11b–11e 降级为 SKIP）
set -u

BASE_URL="${BASE_URL:-http://localhost:8088}"
PASS=0
FAIL=0
STAMP=$(date +%s)
USER_A="smoke-a-${STAMP}"
USER_B="smoke-b-${STAMP}"
PW="smoke-pass-123"

say()  { printf '\n=== %s ===\n' "$1"; }
run()  { printf '$ %s\n' "$*" >&2; "$@"; }
compact() { printf '%s' "$1" | tr -d ' \n\t'; }  # JSON 匹配用：抹掉排版空格

json_get() {  # json_get <json> <dotted.path>
  printf '%s' "$1" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) else d[k]
print(json.dumps(d, ensure_ascii=False) if isinstance(d, (dict, list)) else d)
' "$2"
}

check() {  # check <desc> <0=pass/1=fail>
  if [ "$2" -eq 0 ]; then
    PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"
  fi
}

contains() {  # contains <desc> <haystack> <needle>
  case "$2" in *"$3"*) check "$1" 0 ;; *) check "$1  (缺少: $3)" 1 ;; esac
}

# ---------------------------------------------------------------- 1. healthz
say "1. healthz"
RESP=$(run curl -sS "$BASE_URL/healthz") || exit 1
printf '%s\n' "$RESP"
contains "healthz ok=true" "$(compact "$RESP")" '"ok":true'

# ---------------------------------------------------------------- 2. 注册 A
say "2. POST /v1/auth/register (user A: $USER_A)"
BODY=$(printf '{"username":"%s","password":"%s"}' "$USER_A" "$PW")
RESP=$(run curl -sS -X POST "$BASE_URL/v1/auth/register" \
  -H 'Content-Type: application/json' -d "$BODY")
printf '%s\n' "$RESP"
C=$(compact "$RESP")
contains "注册返回 user_id" "$C" '"user_id"'
contains "注册返回每用户独立密钥分区 key_partition" "$C" '"key_partition"'
KP_ID=$(json_get "$RESP" "key_partition.id")
contains "key_partition.id 前缀 kp_" "$KP_ID" "kp_"

# ---------------------------------------------------------------- 3. 鉴权 A
say "3. POST /v1/auth/token (user A)"
RESP=$(run curl -sS -X POST "$BASE_URL/v1/auth/token" \
  -H 'Content-Type: application/json' -d "$BODY")
printf '%s\n' "$RESP"
C=$(compact "$RESP")
contains "签发 access_token" "$C" '"access_token"'
contains "token_type=bearer" "$C" '"token_type":"bearer"'
TOKEN_A=$(json_get "$RESP" "access_token")

say "3b. GET /v1/auth/whoami"
RESP=$(run curl -sS "$BASE_URL/v1/auth/whoami" -H "Authorization: Bearer $TOKEN_A")
printf '%s\n' "$RESP"
contains "whoami 鉴权通过" "$RESP" '"username"'

# ---------------------------------------------------------------- 4. 注册 B + token（分区隔离用）
say "4. 注册 user B: ${USER_B}（多用户分区对照）"
BODY_B=$(printf '{"username":"%s","password":"%s"}' "$USER_B" "$PW")
RESP=$(run curl -sS -X POST "$BASE_URL/v1/auth/register" \
  -H 'Content-Type: application/json' -d "$BODY_B")
printf '%s\n' "$RESP"
RESP=$(curl -sS -X POST "$BASE_URL/v1/auth/token" \
  -H 'Content-Type: application/json' -d "$BODY_B")
TOKEN_B=$(json_get "$RESP" "access_token")
[ -n "$TOKEN_B" ]; check "user B token 签发" $?

# ---------------------------------------------------------------- 5. push #1
say "5. POST /v1/sync/push #1 (push_id=P1-${STAMP})"
PUSH1=$(cat <<EOF
{
  "device_id": "smoke-device",
  "push_id": "P1-${STAMP}",
  "userdb": [
    {"key": "word:你好", "value": "count=1", "updated_at": 1000},
    {"key": "word:世界", "value": "new@1500", "updated_at": 1500}
  ],
  "counters": {"l2_page_depth": 3},
  "hotwords": ["mine-input", "五笔"],
  "ai_config": {"updated_at": 1000, "value": {"model": "7b-q4", "enabled": false}},
  "schema_version": {"updated_at": 1000, "value": "ping_wubi_mixed@1"}
}
EOF
)
RESP=$(run curl -sS -X POST "$BASE_URL/v1/sync/push" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d "$PUSH1")
printf '%s\n' "$RESP"
contains "push #1 merged" "$(compact "$RESP")" '"status":"merged"'

# ---------------------------------------------------------------- 6. push 重试（幂等）
say "6. 同 push_id 重试（模拟失败重发，必须不重复累加）"
RESP=$(run curl -sS -X POST "$BASE_URL/v1/sync/push" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d "$PUSH1")
printf '%s\n' "$RESP"
contains "重试识别为 duplicate" "$(compact "$RESP")" '"duplicate":true'

# ---------------------------------------------------------------- 7. push #2
say "7. POST /v1/sync/push #2 (push_id=P2-${STAMP}：取新 + 计数器增量)"
PUSH2=$(cat <<EOF
{
  "device_id": "smoke-device-2",
  "push_id": "P2-${STAMP}",
  "userdb": [
    {"key": "word:你好", "value": "count=2", "updated_at": 2000},
    {"key": "word:世界", "value": "old@500", "updated_at": 500}
  ],
  "counters": {"l2_page_depth": 5},
  "hotwords": ["热词"],
  "schema_version": {"updated_at": 2000, "value": "ping_wubi_mixed@2"}
}
EOF
)
RESP=$(run curl -sS -X POST "$BASE_URL/v1/sync/push" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d "$PUSH2")
printf '%s\n' "$RESP"
contains "push #2 merged" "$(compact "$RESP")" '"status":"merged"'

# ---------------------------------------------------------------- 8. pull 一致性
say "8. POST /v1/sync/pull —— 一致性校验"
RESP=$(run curl -sS -X POST "$BASE_URL/v1/sync/pull" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{"device_id":"smoke-device","since":null}')
printf '%s\n' "$RESP"
C=$(compact "$RESP")
contains "userdb:你好 取新（count=2 胜出）" "$C" '"value":"count=2"'
contains "userdb:世界 取新（new@1500 胜出，旧的 500 被拒）" "$C" '"value":"new@1500"'
COUNTER=$(json_get "$RESP" "counters.l2_page_depth")
[ "$COUNTER" = "8" ]; check "计数器增量累加 3+5=8（重试未双算，实得 ${COUNTER:-空}）" $?
contains "热词集合并（含 热词）" "$RESP" '热词'
contains "ai_config 取新保留" "$RESP" '7b-q4'
contains "schema_version 取新（@2 胜出）" "$RESP" 'ping_wubi_mixed@2'

# ---------------------------------------------------------------- 9. 多用户分区隔离
say "9. user B pull —— 分区隔离（朋友数据互不可见）"
RESP=$(run curl -sS -X POST "$BASE_URL/v1/sync/pull" \
  -H "Authorization: Bearer $TOKEN_B" -H 'Content-Type: application/json' \
  -d '{"device_id":"smoke-device-b","since":null}')
printf '%s\n' "$RESP"
C=$(compact "$RESP")
contains "B 的 userdb 为空" "$C" '"userdb":[]'
contains "B 的 counters 为空" "$C" '"counters":{}'

# ---------------------------------------------------------------- 10. ingest
say "10. POST /v1/ingest（InteractionEvent 上行）"
EV=$(cat <<EOF
{
  "ts": ${STAMP}000,
  "device_id": "smoke-device",
  "app_id": "com.apple.TextEdit",
  "kind": "candidate_pick",
  "text_in": "ni hao",
  "text_out": "你好",
  "ocr_digest": null,
  "asr_digest": null,
  "keystroke_cadence": 3.2,
  "suggestion_shown": 2,
  "suggestion_taken": 1
}
EOF
)
RESP=$(run curl -sS -X POST "$BASE_URL/v1/ingest" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d "$EV")
printf '%s\n' "$RESP"
C=$(compact "$RESP")
contains "事件落库 stored" "$C" '"status":"stored"'
contains "回显 kind=candidate_pick" "$C" '"kind":"candidate_pick"'

say "10b. ingest 非法 kind（负例，期望 422）"
RESP=$(run curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/v1/ingest" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{"ts":1,"device_id":"d","kind":"bad_kind"}')
printf 'HTTP %s\n' "$RESP"
[ "$RESP" = "422" ]; check "非法 kind 返回 422" $?

# ---------------------------------------------------------------- 11. suggest SSE
say "11. POST /v1/suggest —— SSE 流式桩"
SSE=$(run curl -sN -X POST "$BASE_URL/v1/suggest" \
  -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
  -d '{"before_cursor":"今天开会","app_id":"com.apple.TextEdit","from_voice":false,"context_digest":"ctx-demo"}')
printf '%s\n' "$SSE"
contains "SSE event: suggestion" "$SSE" "event: suggestion"
contains "契约字段 text" "$SSE" '"text"'
contains "契约字段 score" "$SSE" '"score"'
contains "契约字段 source" "$SSE" '"source"'
contains "SSE event: done" "$SSE" "event: done"
N_SUG=$(printf '%s' "$SSE" | grep -c "event: suggestion")
[ "$N_SUG" -ge 2 ]; check "流式多帧（suggestion 帧数=${N_SUG:-0}）" $?

# ------------------------------------------- 11b. suggest 真模型（W10，continuation）
MODEL_REQUIRED="${SMOKE_MODEL_REQUIRED:-1}"
MODEL_HEALTH_URL="${MODEL_HEALTH_URL:-http://localhost:8091/health}"

if [ "$MODEL_REQUIRED" = "0" ]; then
  say "11b–11e. suggest 真模型 case（SMOKE_MODEL_REQUIRED=0 → SKIP）"
  printf '  [SKIP] 真模型 case 已按 SMOKE_MODEL_REQUIRED=0 跳过\n'
else
  say "11b. POST /v1/suggest 真模型后端（scene=continuation）"
  SSE=$(run curl -sN -X POST "$BASE_URL/v1/suggest" \
    -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
    -d '{"before_cursor":"今天开会讨论了第三季度的","app_id":"com.apple.TextEdit","from_voice":false,"context_digest":"ctx-model","scene":"continuation","max_tokens":32}')
  printf '%s\n' "$SSE"
  contains "done 帧 backend=llama.cpp（真模型）" "$SSE" '"backend": "llama.cpp"'
  contains "done 帧带 prompt_version（提示词模板版本化）" "$SSE" '"prompt_version"'
  contains "done 帧带 timings（延迟实测字段）" "$SSE" '"timings"'
  contains "suggestion 帧 source 标注真模型" "$SSE" '"source": "llama.cpp'
  N_SUG=$(printf '%s' "$SSE" | grep -c "event: suggestion")
  [ "$N_SUG" -ge 2 ]; check "真模型流式多帧（suggestion 帧数=${N_SUG:-0}）" $?

  say "11c. POST /v1/suggest 真模型（scene=voice_correct，语音纠错）"
  SSE=$(run curl -sN -X POST "$BASE_URL/v1/suggest" \
    -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
    -d '{"before_cursor":"我今天去了音行办理信用卡业务","app_id":"com.apple.TextEdit","from_voice":true,"context_digest":"ctx-vc","scene":"voice_correct","max_tokens":32}')
  printf '%s\n' "$SSE"
  contains "voice_correct done ok + llama.cpp" "$SSE" '"backend": "llama.cpp"'
  contains "voice_correct scene 回显" "$SSE" '"scene": "voice_correct"'
  N_SUG=$(printf '%s' "$SSE" | grep -c "event: suggestion")
  [ "$N_SUG" -ge 1 ]; check "voice_correct 帧数=${N_SUG:-0}" $?

  say "11d. POST /v1/suggest 真模型（scene=rescore，候选重排）"
  SSE=$(run curl -sN -X POST "$BASE_URL/v1/suggest" \
    -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
    -d '{"before_cursor":"ni hao","app_id":"com.apple.TextEdit","from_voice":false,"context_digest":"ctx-rs","scene":"rescore","candidates":["你好","拟好","泥嚎","倪豪"],"max_tokens":32}')
  printf '%s\n' "$SSE"
  contains "rescore done ok + llama.cpp" "$SSE" '"backend": "llama.cpp"'
  contains "rescore scene 回显" "$SSE" '"scene": "rescore"'
  N_SUG=$(printf '%s' "$SSE" | grep -c "event: suggestion")
  [ "$N_SUG" -ge 2 ]; check "rescore 每行一帧多帧（帧数=${N_SUG:-0}）" $?

  say "11e. 客户端弃一轮不影响服务端（800ms 预算语义，W10）"
  run curl -sN --max-time 2 -X POST "$BASE_URL/v1/suggest" \
    -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
    -d '{"before_cursor":"弃轮测试","app_id":"t","from_voice":false,"context_digest":"ctx-abandon","scene":"continuation","max_tokens":64}' \
    >/dev/null 2>&1
  printf '  （curl --max-time 2 提前断开，exit=$? 属预期）\n'
  sleep 2
  RESP=$(run curl -sS -m 5 "$MODEL_HEALTH_URL") || RESP=""
  printf '%s\n' "$RESP"
  contains "弃轮后 llama-server 仍健康" "$RESP" '"ok"'
  SSE=$(run curl -sN -X POST "$BASE_URL/v1/suggest" \
    -H "Authorization: Bearer $TOKEN_A" -H 'Content-Type: application/json' \
    -d '{"before_cursor":"弃轮后复测","app_id":"t","from_voice":false,"context_digest":"ctx-after","scene":"continuation","max_tokens":16}')
  contains "弃轮后 suggest 链路仍可用" "$SSE" '"backend": "llama.cpp"'
fi

# ---------------------------------------------------------------- 12. 401 负例
say "12. 无效 token（期望 401）"
RESP=$(run curl -sS -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/v1/sync/pull" \
  -H "Authorization: Bearer bad.token" -H 'Content-Type: application/json' \
  -d '{"device_id":"d"}')
printf 'HTTP %s\n' "$RESP"
[ "$RESP" = "401" ]; check "无效 token 返回 401" $?

# ---------------------------------------------------------------- 汇总
say "结果"
printf 'PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -eq 0 ]; then
  printf '\nSMOKE: ALL GREEN\n'
  exit 0
else
  printf '\nSMOKE: FAILED\n'
  exit 1
fi
