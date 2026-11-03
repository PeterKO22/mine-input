#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
replay_test.py — W7 (a) 采集→管线的脚本化回放验证

把 W2 样音按「采集侧同款形态」（16k mono PCM16 bytes，全程内存）喂给
voice/mic/ptt_daemon.py 的 JSON-line 协议（= Swift IMK 侧走的同一条链路），
断言：

  1. 转写正确性：s1–s5 与 benchmark_multi 逐字命中期望（期望值来自 W2-REPORT §5）；
  2. 低置信不瞎猜：静音 / 空音频 / 无语音 → low_confidence=true 且文本为空；
  3. 热词纠偏：s3「可送→可颂」在热词开启时纠正；
  4. 音频不落盘：运行前后 voice/audio、TMPDIR、cwd 文件清单零增长（音频只在内存）；
  5. 常驻语义：warmup 后多轮串行 transcribe 正确（VAD 轮间 reset）。

用法（仓库根目录）：
  voice/.venv/bin/python voice/mic/replay_test.py
"""
import os
import sys
import tempfile
import wave

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, REPO_ROOT)

from voice.mic.ptt_client import PttDaemonClient  # noqa: E402

AUDIO_DIR = os.path.join(REPO_ROOT, "voice", "audio")

# 期望转写（W2-REPORT §5 实测值，热词开启）
EXPECTED = {
    "s1.wav": "今天天气不错，我们下午去公园散步吧。",
    "s2.wav": "请帮我打开语音输入功能，按住右上角的命令键就可以了。",
    "s3.wav": "我在星巴克点了一杯拿铁和一个可颂面包。",
    "s4.wav": "请把这份文件发送给张伟和李娜，谢谢。",
    "s5.wav": "昨天看新闻说，嫦娥探测器又传回了新的月面照片。",
}
EXPECTED["benchmark_multi.wav"] = "".join(EXPECTED[f"s{i}.wav"] for i in range(1, 6))


def read_wav_pcm16(path):
    with wave.open(path, "rb") as f:
        assert f.getnchannels() == 1 and f.getsampwidth() == 2 and f.getframerate() == 16000, \
            f"{path}: 需要 16k mono 16bit"
        return f.readframes(f.getnframes())


def snapshot_dirs():
    snap = {}
    for label, d in [("audio", AUDIO_DIR), ("tmp", tempfile.gettempdir()), ("cwd", os.getcwd())]:
        try:
            snap[label] = set(os.listdir(d))
        except OSError:
            snap[label] = set()
    return snap


def main():
    before = snapshot_dirs()
    client = PttDaemonClient()
    passed, failed = [], []

    def check(name, cond, detail=""):
        (passed if cond else failed).append(name)
        print(f"  [{'PASS' if cond else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))

    try:
        print("== W7 (a) 采集→管线 回放验证（daemon 协议，音频全程内存） ==")
        r = client.ping()
        check("daemon ping", r.get("ok") is True, f"ready={r.get('ready')}")

        r = client.warmup()
        check("warmup 模型常驻", r.get("ok") is True,
              f"load_ms={r.get('load_ms')} hotwords={r.get('hotwords')}")

        print("\n-- 1) 转写正确性（期望 = W2-REPORT §5） --")
        timings = []
        for fname, expect in EXPECTED.items():
            path = os.path.join(AUDIO_DIR, fname)
            pcm = read_wav_pcm16(path)
            r = client.transcribe(pcm)
            ok = r.get("ok") and r["text"] == expect
            check(f"{fname} 逐字命中", ok,
                  f"elapsed={r.get('elapsed_ms')}ms segs={r.get('num_segments')}"
                  if ok else f"got={r.get('text')!r}")
            timings.append((fname, len(pcm) / 2 / 16000, r.get("num_segments"),
                            r.get("vad_ms"), r.get("asr_ms"), r.get("punct_ms"),
                            r.get("hotword_ms"), r.get("elapsed_ms")))

        print("\n-- 2) 低置信不瞎猜（静音 / 空音频 / 噪音） --")
        import numpy as np
        cases = [
            ("1s 静音", np.zeros(16000, dtype=np.int16).tobytes()),
            ("空音频", b""),
            ("0.3s 极短杂音", (np.random.default_rng(7).integers(-400, 400, 4800)).astype(np.int16).tobytes()),
        ]
        for name, pcm in cases:
            r = client.transcribe(pcm)
            ok = r.get("ok") and r.get("low_confidence") is True and not any(
                "\u4e00" <= c <= "\u9fff" for c in r.get("text", ""))
            check(f"{name} → low_confidence 且不瞎猜", ok,
                  f"reason={r.get('reason')} text={r.get('text')!r}")

        print("\n-- 3) 热词纠偏（s3：可送→可颂） --")
        pcm = read_wav_pcm16(os.path.join(AUDIO_DIR, "s3.wav"))
        r_off = client.call({"cmd": "transcribe", "sample_rate": 16000,
                             "pcm16_b64": __import__("base64").b64encode(pcm).decode(),
                             "hotwords": os.devnull})  # 不存在的热词表 = 关闭
        check("热词关 → 「可送」原样", "可送" in r_off.get("text", ""), f"text={r_off.get('text')!r}")
        r_on = client.transcribe(pcm)
        check("热词开 → 纠正为「可颂」", "可颂" in r_on.get("text", ""), f"text={r_on.get('text')!r}")

        print("\n-- 4) 音频不落盘（前后文件清单零增长） --")
        after = snapshot_dirs()
        for label in before:
            grown = after[label] - before[label]
            check(f"{label} 目录无新文件", not grown, f"新增={sorted(grown)}" if grown else "")

        print("\n-- 5) 常驻多轮（VAD 轮间 reset） --")
        r1 = client.transcribe(read_wav_pcm16(os.path.join(AUDIO_DIR, "s1.wav")))
        r2 = client.transcribe(read_wav_pcm16(os.path.join(AUDIO_DIR, "s4.wav")))
        ok = r1.get("text") == EXPECTED["s1.wav"] and r2.get("text") == EXPECTED["s4.wav"]
        check("连续两轮互不串扰", ok, f"r2={r2.get('text')!r}")

        print("\n== 延迟（daemon 协议回放，模型常驻后） ==")
        print(f"{'文件':<22}{'音频s':>7}{'段数':>5}{'VADms':>8}{'ASRms':>8}{'标点ms':>8}{'热词ms':>8}{'总ms':>8}")
        for fname, dur, segs, v, a, p, h, tot in timings:
            print(f"{fname:<22}{dur:>7.2f}{segs:>5}{v:>8.1f}{a:>8.1f}{p:>8.1f}{h:>8.1f}{tot:>8.1f}")
    finally:
        client.close()

    print(f"\n== 汇总: PASS {len(passed)} / FAIL {len(failed)} ==")
    if failed:
        print("失败项: " + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
