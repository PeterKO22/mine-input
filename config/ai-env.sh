#!/usr/bin/env bash
# ============================================================================
# config/ai-env.sh — 把 config/ai.yaml 的用户配置映射为 Hub 环境变量（W22 最小支持）
# ============================================================================
# 用法：
#   cp config/ai.example.yaml config/ai.yaml     # 首次：复制并按需修改
#   eval "$(config/ai-env.sh)"                    # 映射到当前 shell（不覆盖已有环境变量）
#   docker compose -f hub/docker-compose.yml -f config/ai-compose.override.yml up -d
#
# 自定义路径：MINE_AI_CONFIG=/path/to/my-ai.yaml config/ai-env.sh
#
# 映射规则（详见 config/ai.example.yaml 尾部「env 映射」）：
#   ai.model               → MODEL_NAME
#   ai.endpoint            → MODEL_URL
#   ai.budget_ms           → SUGGEST_BUDGET_MS
#   ai.allow_stub_fallback → SUGGEST_ALLOW_STUB_FALLBACK (true→1 / false→0)
# 语义：显式环境变量优先（脚本不覆盖已 export 的值）；文件缺键则保持默认不动。
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="${MINE_AI_CONFIG:-$ROOT/config/ai.yaml}"

if [ ! -f "$CFG" ]; then
  echo "ai-env.sh: 找不到配置文件 $CFG" >&2
  echo "  首次使用：cp config/ai.example.yaml config/ai.yaml 然后按需修改" >&2
  exit 1
fi

# 极简 YAML 取值：匹配 ai: 块下两个空格缩进的目标键，剥掉引号与行内注释。
get() {
  local key="$1"
  sed -n "s/^  ${key}:[[:space:]]*//p" "$CFG" | head -1 \
    | sed -e 's/[[:space:]]*#.*$//' -e 's/^["'\'']//' -e 's/["'\'']$//' -e 's/[[:space:]]*$//'
}

emit() { # emit <VAR> <value>：已设环境变量优先
  local var="$1" val="$2"
  [ -n "$val" ] || return 0
  if [ -z "${!var:-}" ]; then
    printf 'export %s=%q\n' "$var" "$val"
  fi
}

MODEL="$(get model)"
ENDPOINT="$(get endpoint)"
BUDGET="$(get budget_ms)"
STUB="$(get allow_stub_fallback)"
BACKEND="$(get backend)"

# backend 仅影响 endpoint 语义（见 ai.example.yaml）；openai_compatible/hub 形态下
# MODEL_URL 仍透传（供代理层使用），不在此裁决——裁决留给服务端配置。
case "$STUB" in
  true|True|TRUE|yes|on|1) STUB=1 ;;
  false|False|FALSE|no|off|0) STUB=0 ;;
  "") STUB="" ;;
  *) echo "ai-env.sh: allow_stub_fallback 取值无法识别：$STUB（用 true/false）" >&2; exit 1 ;;
esac

emit MODEL_NAME "$MODEL"
emit MODEL_URL "$ENDPOINT"
emit SUGGEST_BUDGET_MS "$BUDGET"
emit SUGGEST_ALLOW_STUB_FALLBACK "$STUB"

# 供调试：以注释形式回显当前生效的 backend（不进入环境）
[ -n "$BACKEND" ] && echo "# ai.backend = $BACKEND (来自 $CFG)"
exit 0
