#!/usr/bin/env bash
# 宿主机原生 llama.cpp llama-server 管理脚本（W13：7B 档原生跑，绕开 Docker VM 内存 blocker；
# W17：launchd 托管 load/unload + serve 前台模式 + 日志轮转）。
#
# 用法：
#   ./run-llama-native.sh load      # launchd 托管（W17）：装 com.mineinput.llama 用户 agent
#                                   #   开机/登录自启 + 崩溃自动拉起 + 日志轮转（推荐常驻形态）
#   ./run-llama-native.sh unload    # 卸载 launchd agent（不再自启；手动形态仍可用）
#   ./run-llama-native.sh start     # 手动后台起（nohup，无守护；默认 7B Q4_K_M，端口 8092）
#   ./run-llama-native.sh stop      # 停手动实例（按 PID 文件，TERM→KILL）
#   ./run-llama-native.sh restart   # stop + start（手动形态）
#   ./run-llama-native.sh status    # 进程/launchd 在否 + /health
#   ./run-llama-native.sh health    # 只打 /health（退出码 0=健康）
#   ./run-llama-native.sh logrotate # 手动轮转日志（launchd 拉起时亦自动轮转）
#   ./run-llama-native.sh serve     # 前台模式（launchd ProgramArguments 专用，勿手跑）
#
# 二进制来源（GitHub Releases 预编译，macOS arm64 + Metal）：
#   https://github.com/ggml-org/llama.cpp/releases/download/b12078/llama-b12078-bin-macos-arm64.tar.gz
#   解压到 models/llama.cpp-b12078/llama-b12078/（本脚本自动探测；也可用 LLAMA_BIN 指定，
#   或 brew install llama.cpp 后用 PATH 里的 llama-server）。
#
# 环境变量（均可覆盖）：
#   MODEL_FILE   GGUF 路径（默认 7B Q4_K_M 第一分片，split 分片喂第一片即自动加载第二片）
#   MODEL_NAME   done 帧 model 字段标注（默认 qwen2.5-7b-instruct-q4_k_m）
#   LLAMA_PORT   服务端口（默认 8092；8091 留给 compose 内 0.5B 降级档，8088=Hub/8080/8000/8090 已占）
#   LLAMA_CTX    上下文长度（默认 2048，与 W10 compose 配置一致）
#   LLAMA_BIN    llama-server 可执行文件（默认自动探测，见上）
#   LLAMA_EXTRA  追加参数（如 --threads 8 --flash-attn）
#   LLAMA_LOG_MAX   日志轮转阈值字节（默认 10MB，超则轮转 .1/.2/.3）
#   LLAMA_LOG_KEEP  轮转保留代数（默认 3）
set -u

cd "$(dirname "$0")"
MODELS_DIR="$PWD"

LLAMA_PORT="${LLAMA_PORT:-8092}"
LLAMA_CTX="${LLAMA_CTX:-2048}"
MODEL_FILE="${MODEL_FILE:-qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf}"
MODEL_NAME="${MODEL_NAME:-qwen2.5-7b-instruct-q4_k_m}"
PID_FILE="$MODELS_DIR/.llama-native.pid"
LOG_FILE="$MODELS_DIR/.llama-native.log"

# ---- launchd 托管（W17）----
PLIST_LABEL="com.mineinput.llama"
PLIST_TEMPLATE="$MODELS_DIR/$PLIST_LABEL.plist"          # 仓库内模板（{{MODELS_DIR}} 占位）
PLIST_INSTALLED="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"  # 机器本地产物
LAUNCHD_LOG="$MODELS_DIR/.llama-native.launchd.log"
LAUNCHD_DOMAIN="gui/$(id -u)"
LLAMA_LOG_MAX="${LLAMA_LOG_MAX:-10485760}"   # 日志轮转阈值：10MB
LLAMA_LOG_KEEP="${LLAMA_LOG_KEEP:-3}"        # 轮转保留代数

# ---- 二进制探测：LLAMA_BIN > 本目录预编译 > brew > PATH ----
find_bin() {
  if [ -n "${LLAMA_BIN:-}" ]; then echo "$LLAMA_BIN"; return; fi
  local cand
  for cand in \
    "$MODELS_DIR"/llama.cpp-b12078/llama-b12078/llama-server \
    "$MODELS_DIR"/llama.cpp-*/llama-*/llama-server \
    /opt/homebrew/bin/llama-server /usr/local/bin/llama-server \
    "$(command -v llama-server 2>/dev/null || true)"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then echo "$cand"; return; fi
  done
  return 1
}

BIN=$(find_bin) || {
  echo "[error] 找不到 llama-server。装法（二选一）：" >&2
  echo "  1) GitHub Releases 预编译：curl -fL -o /tmp/llama.tar.gz \\" >&2
  echo "     https://github.com/ggml-org/llama.cpp/releases/download/b12078/llama-b12078-bin-macos-arm64.tar.gz \\" >&2
  echo "     && tar xzf /tmp/llama.tar.gz -C \"$MODELS_DIR\"" >&2
  echo "  2) brew install llama.cpp" >&2
  exit 1
}

MODEL_PATH="$MODELS_DIR/$MODEL_FILE"
[ -f "$MODEL_PATH" ] || MODEL_PATH="$MODEL_FILE"   # 允许绝对路径
if [ ! -f "$MODEL_PATH" ]; then
  echo "[error] 模型文件不存在: $MODEL_PATH" >&2
  exit 1
fi

health() {
  curl -sf -m 5 "http://localhost:${LLAMA_PORT}/health" >/dev/null 2>&1
}

do_start() {
  if health; then
    echo "[ok] llama-server 已在 :${LLAMA_PORT} 健康运行（勿重复启动）"
    return 0
  fi
  echo "[start] $BIN"
  echo "        model=$MODEL_NAME ($MODEL_FILE)  port=$LLAMA_PORT  ctx=$LLAMA_CTX"
  nohup "$BIN" \
    --host 0.0.0.0 --port "$LLAMA_PORT" \
    -m "$MODEL_PATH" -c "$LLAMA_CTX" \
    ${LLAMA_EXTRA:-} >>"$LOG_FILE" 2>&1 &
  echo $! >"$PID_FILE"
  # 等 /health 健康（7B 权重 ~4.7GB 加载约 10–40s；llama-server 加载期 /health 返回 loading）
  for _ in $(seq 1 120); do
    if health; then
      echo "[ok] llama-server 健康  http://localhost:${LLAMA_PORT}  pid=$(cat "$PID_FILE")  log=$LOG_FILE"
      return 0
    fi
    if ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "[error] 进程启动即退出，日志尾部："; tail -20 "$LOG_FILE"; exit 1
    fi
    sleep 1
  done
  echo "[error] 120s 内未通过 /health，日志尾部："; tail -20 "$LOG_FILE"; exit 1
}

do_stop() {
  if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      kill "$PID" 2>/dev/null
      for _ in $(seq 1 10); do kill -0 "$PID" 2>/dev/null || break; sleep 1; done
      kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null
      echo "[ok] 已停止 pid=$PID"
    else
      echo "[ok] 进程已不在（pid=${PID}）"
    fi
    rm -f "$PID_FILE"
  else
    echo "[ok] 无 PID 文件（未在运行）"
  fi
}

# ---- 日志轮转（W17）：超 LLAMA_LOG_MAX 字节则 .1/.2/.3 滚动 ----
log_rotate() {
  for f in "$LOG_FILE" "$LAUNCHD_LOG"; do
    [ -f "$f" ] || continue
    sz=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
    [ "$sz" -ge "$LLAMA_LOG_MAX" ] || continue
    i=$LLAMA_LOG_KEEP
    while [ "$i" -ge 2 ]; do
      [ -f "$f.$((i-1))" ] && mv -f "$f.$((i-1))" "$f.$i"
      i=$((i-1))
    done
    mv -f "$f" "$f.1"
    : >"$f"
    echo "[rotate] ${f}（${sz}B ≥ ${LLAMA_LOG_MAX}B）→ ${f}.1（保留 ${LLAMA_LOG_KEEP} 代）"
  done
  return 0
}

# ---- serve：前台模式（launchd ProgramArguments 专用）----
# launchd KeepAlive 直接监护 llama-server 本体（exec 顶掉 shell）：崩溃/退出即拉起。
# 每次拉起前按大小轮转日志（launchd 无内建轮转；.launchd.log 同规则）。
do_serve() {
  log_rotate
  echo "[serve] $(date '+%F %T') 拉起 llama-server（launchd 托管，KeepAlive）" >>"$LOG_FILE"
  exec "$BIN" \
    --host 0.0.0.0 --port "$LLAMA_PORT" \
    -m "$MODEL_PATH" -c "$LLAMA_CTX" \
    ${LLAMA_EXTRA:-} >>"$LOG_FILE" 2>&1
}

launchd_loaded() {
  launchctl print "$LAUNCHD_DOMAIN/$PLIST_LABEL" >/dev/null 2>&1
}

# ---- load：装 com.mineinput.llama 用户 agent（开机/登录自启 + 崩溃拉起）----
do_load() {
  command -v launchctl >/dev/null 2>&1 || {
    echo "[error] launchctl 不可用（load/unload 仅 macOS）" >&2; exit 1; }
  [ -f "$PLIST_TEMPLATE" ] || { echo "[error] 模板不存在: $PLIST_TEMPLATE" >&2; exit 1; }
  mkdir -p "$HOME/Library/LaunchAgents"
  # 渲染模板：{{MODELS_DIR}} → 绝对路径（机器本地产物，勿提交）
  sed "s|{{MODELS_DIR}}|$MODELS_DIR|g" "$PLIST_TEMPLATE" >"$PLIST_INSTALLED"
  chmod 644 "$PLIST_INSTALLED"
  echo "[ok] 已安装 $PLIST_INSTALLED"
  # 手动 nohup 实例与 launchd 互斥：先停；再卸旧 job（重复 load 可重入）
  do_stop >/dev/null 2>&1 || true
  launchctl bootout "$LAUNCHD_DOMAIN/$PLIST_LABEL" 2>/dev/null || true
  launchctl bootstrap "$LAUNCHD_DOMAIN" "$PLIST_INSTALLED" || {
    echo "[error] launchctl bootstrap 失败，诊断：" >&2
    launchctl print "$LAUNCHD_DOMAIN/$PLIST_LABEL" 2>&1 | head -20 >&2 || true
    exit 1; }
  echo "[ok] launchctl bootstrap 完成（RunAtLoad + KeepAlive）"
  echo "[wait] /health 就绪（7B 加载约 10–40s）"
  for _ in $(seq 1 120); do
    if health; then
      echo "[ok] launchd 托管健康  http://localhost:${LLAMA_PORT}  label=$PLIST_LABEL"
      echo "     日志 ${LOG_FILE}（超 ${LLAMA_LOG_MAX}B 自动轮转）；诊断: launchctl print $LAUNCHD_DOMAIN/$PLIST_LABEL"
      return 0
    fi
    sleep 1
  done
  echo "[error] 120s 内未通过 /health，$LAUNCHD_LOG 尾部：" >&2
  tail -20 "$LAUNCHD_LOG" 2>/dev/null >&2 || true
  exit 1
}

# ---- unload：卸载 agent（不再自启/拉起）----
do_unload() {
  command -v launchctl >/dev/null 2>&1 || {
    echo "[error] launchctl 不可用（load/unload 仅 macOS）" >&2; exit 1; }
  if launchd_loaded; then
    launchctl bootout "$LAUNCHD_DOMAIN/$PLIST_LABEL" 2>/dev/null || true
    echo "[ok] 已 bootout ${PLIST_LABEL}（进程已停）"
  else
    echo "[ok] $PLIST_LABEL 未加载"
  fi
  rm -f "$PLIST_INSTALLED"
  echo "[ok] 已移除 ${PLIST_INSTALLED}（开机不再自启）"
}

case "${1:-status}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  load)    do_load ;;
  unload)  do_unload ;;
  logrotate) log_rotate; echo "[ok] 轮转完成（未超阈值的不动）" ;;
  serve)   do_serve ;;
  health)
    if health; then echo "[ok] llama-server 健康  http://localhost:${LLAMA_PORT}"; exit 0
    else echo "[down] http://localhost:${LLAMA_PORT} 不健康或不可达"; exit 1; fi ;;
  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "[up] 手动实例 pid=$(cat "$PID_FILE")"
    else
      echo "[down] 无手动实例（PID 文件）"
    fi
    if command -v launchctl >/dev/null 2>&1 && launchd_loaded; then
      echo "[up] launchd: $PLIST_LABEL 已加载（RunAtLoad + KeepAlive）"
    else
      echo "[down] launchd: $PLIST_LABEL 未加载（load 托管，或 start 手动起）"
    fi
    echo "bin=$BIN"
    echo "model=$MODEL_NAME ($MODEL_FILE)  port=$LLAMA_PORT"
    if health; then echo "[ok] /health 通过"; else echo "[down] /health 未通过"; fi ;;
  *) echo "用法: $0 {load|unload|start|stop|restart|status|health|logrotate|serve}"; exit 2 ;;
esac
