#!/bin/bash
# W2 voice PoC — 基准样音生成（macOS say -v Tingting，16k 单声道 WAV）
# 用法：bash voice/poc/gen_audio.sh   （在仓库根目录或任意位置执行均可）
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)/audio"
mkdir -p "$DIR"

VOICE="Tingting"
FMT="LEI16@16000"   # 16-bit little-endian PCM, 16kHz → 满足管线 16k mono 要求

# 多句中文样音（含专有名词句，用于热词后处理演示）
declare -a TEXTS=(
  "今天天气不错，我们下午去公园散步吧。"
  "请帮我打开语音输入功能，按住右上角的命令键就可以了。"
  "我在星巴克点了一杯拿铁和一个可颂面包。"
  "请把这份文件发送给张伟和李娜，谢谢。"
  "昨天看新闻说嫦娥探测器又传回了新的月面照片。"
)

# 单句逐条生成（每句一个文件，便于逐句核对准确率）
i=1
for t in "${TEXTS[@]}"; do
  say -v "$VOICE" --data-format="$FMT" -o "$DIR/s$i.wav" "$t"
  echo "s$i.wav: $t"
  i=$((i+1))
done

# 整段基准：全部句子连读为一个 WAV（VAD 将负责切段，用于延迟/RTF 测量）
ALL="${TEXTS[*]}"
say -v "$VOICE" --data-format="$FMT" -o "$DIR/benchmark.wav" "$ALL"
echo "benchmark.wav: ${#TEXTS[@]} 句连读"

# 多段基准：s1..s5 按 0.8s 换气间隔拼接（VAD 切段 + 逐段延迟测量）
"$DIR/../.venv/bin/python" "$(dirname "$0")/make_multi.py"

# 校验输出确为 16k 单声道 WAV
for f in "$DIR"/s*.wav "$DIR/benchmark.wav"; do
  afinfo "$f" | grep -E 'File:|estimated duration|data format' | tr '\n' ' ' | sed "s|^|$(basename "$f"): |"
  echo
done
