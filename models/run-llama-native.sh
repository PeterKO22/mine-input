#!/usr/bin/env bash
# 宿主机原生 llama.cpp llama-server 管理脚本（W13：7B 档原生跑，绕开 Docker VM 内存 blocker）。
#
# 用法：
#   ./run-llama-native.sh start     # 后台起 llama-server（默认 7B Q4_K_M，端口 8092）
#   ./run-llama-native.sh stop      # 停（按 PID 文件，TERM→KILL）
#   ./run-llama-native.sh restart   # stop + start
#   ./run-llama-native.sh status    # 进程在否 + /health
#   ./run-llama-native.sh health    # 只打 /health（退出码 0=健康）
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
set -u

cd "$(dirname "$0")"
MODELS_DIR="$PWD"

LLAMA_PORT="${LLAMA_PORT:-8092}"
LLAMA_CTX="${LLAMA_CTX:-2048}"
MODEL_FILE="${MODEL_FILE:-qwen2.5-7b-instruct-q4_k_m-00001-of-00002.gguf}"
MODEL_NAME="${MODEL_NAME:-qwen2.5-7b-instruct-q4_k_m}"
PID_FILE="$MODELS_DIR/.llama-native.pid"
LOG_FILE="$MODELS_DIR/.llama-native.log"

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
      echo "[ok] 进程已不在（pid=$PID）"
    fi
    rm -f "$PID_FILE"
  else
    echo "[ok] 无 PID 文件（未在运行）"
  fi
}

case "${1:-status}" in
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  health)
    if health; then echo "[ok] llama-server 健康  http://localhost:${LLAMA_PORT}"; exit 0
    else echo "[down] http://localhost:${LLAMA_PORT} 不健康或不可达"; exit 1; fi ;;
  status)
    if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      echo "[up] pid=$(cat "$PID_FILE")"
    else
      echo "[down] 无运行进程"
    fi
    echo "bin=$BIN"
    echo "model=$MODEL_NAME ($MODEL_FILE)  port=$LLAMA_PORT"
    if health; then echo "[ok] /health 通过"; else echo "[down] /health 未通过"; fi ;;
  *) echo "用法: $0 {start|stop|restart|status|health}"; exit 2 ;;
esac
