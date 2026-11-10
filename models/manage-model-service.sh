#!/usr/bin/env bash
# ============================================================================
# manage-model-service.sh —— 本地模型（7B）服务唯一开关入口（W30）
# ============================================================================
# 语义（与 ⌥M 管理浮层「本地模型（7B）」开关同源；默认不开、显式开启、随时可关）：
#   不开不加载——默认未加载，只有显式 start（脚本或面板开关确认后）才会加载模型。
#
# 用法（收敛后的全部服务操作就这三条；幂等）：
#   ./manage-model-service.sh start    # 开：启动 llama-server + 健康检查（/v1/models 或
#                                      #   /completion）；已在跑且探活通过 = no-op
#   ./manage-model-service.sh stop     # 关：立即停止服务 + 清扫遗留 launchd 自启；
#                                      #   未在跑 = no-op
#   ./manage-model-service.sh status   # 状态机读行：state=not-loaded|loading|ready + 探活
#
# 封装 models/run-llama-native.sh（start/stop 底层执行，W13/W17 起的宿主原生 7B 脚本）。
# run-llama-native.sh 的 launchd load/unload/serve 已删除（W30 防呆审计：RunAtLoad=登录
# 自启 + KeepAlive=崩溃拉起属「自动加载模型」路径，违反「必须用户打开才加载」硬保证，
# 整条删除；本脚本 stop/status 另清扫任何历史安装的 com.mineinput.llama agent）。
#
# 环境变量：
#   LLAMA_PORT   服务端口（默认 8092，与 run-llama-native.sh 一致）
#   MINE_INPUT_ROOT  仓库根（默认按本脚本位置推导）
# ============================================================================
set -u

MODELS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${MINE_INPUT_ROOT:-$(cd "$MODELS_DIR/.." && pwd)}"
ENGINE="$MODELS_DIR/run-llama-native.sh"
LLAMA_PORT="${LLAMA_PORT:-8092}"
LEGACY_LABEL="com.mineinput.llama"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"

[ -f "$ENGINE" ] || { echo "[error] 找不到 $ENGINE" >&2; exit 1; }

# ---- 健康检查：/v1/models（OpenAI 形态，轻）优先；404/失败回退 /completion（最小推理）----
# 输出探测点（stdout）；返回 0=通过 1=未过。
PROBE_VIA=""
probe() {
  PROBE_VIA=""
  if curl -sf -m 3 "http://127.0.0.1:${LLAMA_PORT}/v1/models" >/dev/null 2>&1; then
    PROBE_VIA="/v1/models"; return 0
  fi
  if curl -sf -m 8 -X POST "http://127.0.0.1:${LLAMA_PORT}/completion" \
       -H 'Content-Type: application/json' \
       -d '{"prompt":" ","n_predict":1,"temperature":0}' >/dev/null 2>&1; then
    PROBE_VIA="/completion"; return 0
  fi
  return 1
}

# ---- 进程在否（PID 文件优先，pgrep 兜底；只认 llama-server）----
service_pid() {
  local pid_file="$MODELS_DIR/.llama-native.pid" pid=""
  if [ -f "$pid_file" ]; then
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then echo "$pid"; return 0; fi
  fi
  pid="$(pgrep -f 'llama-server' 2>/dev/null | head -1 || true)"
  if [ -n "$pid" ]; then echo "$pid"; return 0; fi
  return 1
}

# ---- 遗留 launchd 自启清扫（防呆硬保证：任何形态的登录自启都不允许）----
legacy_loaded() {
  command -v launchctl >/dev/null 2>&1 || return 1
  launchctl print "gui/$(id -u)/$LEGACY_LABEL" >/dev/null 2>&1
}
purge_legacy() {
  if legacy_loaded; then
    launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
    echo "[audit] 已卸载遗留 launchd 自启 agent：$LEGACY_LABEL（RunAtLoad 违反开关硬保证）"
  fi
  if [ -f "$LEGACY_PLIST" ]; then
    rm -f "$LEGACY_PLIST"
    echo "[audit] 已移除遗留 plist：$LEGACY_PLIST"
  fi
}

# ---- 模型体积 → 资源提示（确认弹窗「约 X GB 内存」同源）----
mem_hint_gb() {
  local bytes
  bytes="$(cat "$MODELS_DIR"/qwen2.5-7b-instruct-q4_k_m-*.gguf 2>/dev/null | wc -c | tr -d ' ')"
  if [ -z "$bytes" ] || [ "$bytes" -le 0 ] 2>/dev/null; then echo 5; return; fi
  echo $(( (bytes + 999999999) / 1000000000 ))
}

# ---- status：机器可读行（state= / probe= / …）+ 人读行 ----
do_status() {
  local pid state probe_via probe_ok="0"
  pid="$(service_pid || true)"
  if probe; then
    state="ready"; probe_via="$PROBE_VIA"; probe_ok="1"
  elif [ -n "$pid" ]; then
    state="loading"; probe_via="none"
  else
    state="not-loaded"; probe_via="none"
  fi
  echo "state=$state"
  echo "probe=$probe_via"
  echo "probe_ok=$probe_ok"
  echo "pid=${pid:-none}"
  echo "port=$LLAMA_PORT"
  echo "model=qwen2.5-7b-instruct-q4_k_m"
  echo "mem_hint_gb=$(mem_hint_gb)"
  echo "config=$ROOT/config/ai.yaml"
  echo "config_exists=$([ -f "$ROOT/config/ai.yaml" ] && echo 1 || echo 0)"
  if legacy_loaded || [ -f "$LEGACY_PLIST" ]; then
    echo "legacy_launchd=present"
  else
    echo "legacy_launchd=absent"
  fi
  case "$state" in
    ready)      echo "本地模型：就绪（探活 $probe_via 通过 · :$LLAMA_PORT · pid=${pid:-?}）" ;;
    loading)    echo "本地模型：加载中（进程在，探活未过——仍在加载权重或无响应）" ;;
    not-loaded) echo "本地模型：未加载（默认；探活：未运行）" ;;
  esac
  return 0
}

# ---- start：幂等（已在跑且探活通过 = no-op）----
do_start() {
  if probe; then
    echo "[ok] 本地模型已在跑（探活 $PROBE_VIA 通过，幂等 no-op，不重复加载）"
    do_status
    return 0
  fi
  echo "[start] 显式开启 → 启动 llama-server（run-llama-native.sh start）"
  bash "$ENGINE" start || { echo "[error] 启动失败（见上）" >&2; exit 1; }
  # 引擎已等 /health；再用约定探活（/v1/models 或 /completion）复核
  if probe; then
    echo "[ok] 健康检查通过：探活 $PROBE_VIA · http://127.0.0.1:$LLAMA_PORT"
    do_status
    return 0
  fi
  echo "[error] 服务已起但探活（/v1/models 与 /completion）均未过" >&2
  do_status
  exit 1
}

# ---- stop：立即停止 + 清扫遗留自启；幂等 ----
do_stop() {
  bash "$ENGINE" stop >/dev/null 2>&1 || true
  purge_legacy
  # 引擎只认 PID 文件；兜底再确认无 llama-server 残留（不误伤其他机器进程名）
  local pid
  pid="$(service_pid || true)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  fi
  if service_pid >/dev/null 2>&1; then
    echo "[error] 仍有 llama-server 进程残留：$(service_pid)" >&2
    exit 1
  fi
  echo "[ok] 本地模型已停止（幂等：未在跑也是 ok）"
  do_status
  return 0
}

case "${1:-status}" in
  start)  do_start ;;
  stop)   do_stop ;;
  status) do_status ;;
  *) echo "用法: $0 {start|stop|status}" >&2; exit 2 ;;
esac
