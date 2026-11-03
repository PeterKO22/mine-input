#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
W2 voice 离线 ASR PoC
管线：WAV(16k mono) → Silero VAD 切段 → SenseVoiceSmall(int8) 流式转写
      → CT-Transformer(int8) 标点恢复 → hotwords.txt 热词后处理

用法（仓库根目录）：
  voice/.venv/bin/python voice/poc/asr_poc.py voice/audio/benchmark.wav
  voice/.venv/bin/python voice/poc/asr_poc.py voice/audio/s3.wav --no-hotwords
  voice/.venv/bin/python voice/poc/asr_poc.py voice/audio/*.wav   # 多文件逐句核对

输出：每段（VAD 切出的语音段）打印起止时间、耗时与转写；结尾打印延迟表与
热词开/关对比；同时把 JSON 结果写到 voice/poc/last_run.json。
"""
import argparse
import glob
import json
import os
import re
import sys
import time
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
VOICE_DIR = os.path.dirname(HERE)
MODEL_DIR = os.path.join(VOICE_DIR, "models")

SENSE_DIR = os.path.join(MODEL_DIR, "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17")
PUNCT_DIR = os.path.join(MODEL_DIR, "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8")
VAD_MODEL = os.path.join(MODEL_DIR, "silero_vad.onnx")

DEFAULT_HOTWORDS = os.path.join(HERE, "hotwords.txt")


# ---------- 读取 WAV（stdlib，16k 单声道 16bit） ----------
def read_wav(path):
    with wave.open(path, "rb") as f:
        assert f.getnchannels() == 1, f"{path}: 需要单声道"
        assert f.getsampwidth() == 2, f"{path}: 需要 16bit PCM"
        sr = f.getframerate()
        raw = f.readframes(f.getnframes())
    samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    return samples, sr


# ---------- 后处理：标点去重 + 热词 ----------
_PUNCT_RUN = re.compile(r"([，。！？；、,.!?;:]){2,}")


def _collapse_run(m):
    run = m.group(0)
    for c in "。！？.!?":
        if c in run:
            return c
    return run[0]


def normalize_punct(text):
    """SenseVoice(use_itn) 自带标点，CT-Transformer 会再补一次，这里合并重复标点：
    连续标点串只保留一个（优先句末标点 。！？）。"""
    return _PUNCT_RUN.sub(_collapse_run, text)


def parse_hotwords(path):
    """hotwords.txt 格式：每行 `正词 [别名1 别名2 ...]`，# 开头为注释。
    别名是显式替换项；此外自动做同音（无声调拼音）窗口匹配。"""
    entries = []  # (canonical, set(alias))
    if not os.path.exists(path):
        return entries
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            toks = line.split()
            entries.append((toks[0], set(toks[1:])))
    return entries


def _is_han(ch):
    return "\u4e00" <= ch <= "\u9fff"


def apply_hotwords(text, entries, use_homophone=True):
    """1) 显式别名替换（长别名优先）；2) 同音窗口匹配替换为正词。"""
    from pypinyin import lazy_pinyin

    edits = []
    # 显式别名替换
    for canonical, aliases in entries:
        for alias in sorted(aliases, key=len, reverse=True):
            if alias and alias != canonical and alias in text:
                text = text.replace(alias, canonical)
                edits.append(f"别名替换: {alias}→{canonical}")

    if not use_homophone:
        return text, edits

    # 同音窗口匹配：按连续汉字段扫描，拼音相同但字形不同的窗口替换为正词
    for canonical, _aliases in entries:
        if not _is_han(canonical[0]):
            continue
        want = lazy_pinyin(canonical)
        L = len(want)
        if L == 0:
            continue
        out = []
        i = 0
        while i < len(text):
            if _is_han(text[i]) and i + L <= len(text) and all(_is_han(c) for c in text[i:i + L]):
                window = text[i:i + L]
                if window != canonical and lazy_pinyin(window) == want:
                    out.append(canonical)
                    edits.append(f"同音替换: {window}→{canonical}")
                    i += L
                    continue
            out.append(text[i])
            i += 1
        text = "".join(out)
    return text, edits


# ---------- 主管线 ----------
def build_models(num_threads=4, min_silence=0.5):
    import sherpa_onnx

    t0 = time.perf_counter()
    vad_cfg = sherpa_onnx.VadModelConfig()
    vad_cfg.silero_vad.model = VAD_MODEL
    vad_cfg.silero_vad.threshold = 0.5
    vad_cfg.silero_vad.min_silence_duration = min_silence
    vad_cfg.silero_vad.min_speech_duration = 0.3
    vad_cfg.silero_vad.window_size = 512
    vad_cfg.sample_rate = 16000
    vad = sherpa_onnx.VoiceActivityDetector(vad_cfg, buffer_size_in_seconds=120)
    t_vad = time.perf_counter() - t0

    t0 = time.perf_counter()
    asr = sherpa_onnx.OfflineRecognizer.from_sense_voice(
        model=os.path.join(SENSE_DIR, "model.int8.onnx"),
        tokens=os.path.join(SENSE_DIR, "tokens.txt"),
        language="zh",
        use_itn=True,
        num_threads=num_threads,
    )
    t_asr = time.perf_counter() - t0

    t0 = time.perf_counter()
    punct_cfg = sherpa_onnx.OfflinePunctuationConfig()
    punct_cfg.model.ct_transformer = os.path.join(PUNCT_DIR, "model.int8.onnx")
    punct_cfg.model.num_threads = num_threads
    punct = sherpa_onnx.OfflinePunctuation(punct_cfg)
    t_punct = time.perf_counter() - t0

    return vad, asr, punct, {"vad_s": t_vad, "asr_s": t_asr, "punct_s": t_punct}


def vad_segments(vad, samples, sr):
    """流式喂入 0.5s 音频块并即时取段（对应 PTT 边说边切段）。
    注：一次性喂入整条音频会让该版本 VoiceActivityDetector 丢失早前段，必须分块。
    VAD 触发点晚于真实语音起点，段边界前后各扩 0.25s 防止丢字头/字尾。"""
    assert sr == 16000, f"需要 16k 采样，实际 {sr}"
    t0 = time.perf_counter()
    raw_segs = []
    chunk = sr // 2
    for i in range(0, len(samples), chunk):
        vad.accept_waveform(samples[i:i + chunk])
        while not vad.empty():
            s = vad.front
            raw_segs.append((s.start, len(s.samples)))
            vad.pop()
    vad.flush()
    while not vad.empty():
        s = vad.front
        raw_segs.append((s.start, len(s.samples)))
        vad.pop()

    pad = int(0.25 * sr)
    segs = []
    for start, n in raw_segs:
        a = max(0, start - pad)
        b = min(len(samples), start + n + pad)
        segs.append((a / sr, samples[a:b].copy()))
    return segs, time.perf_counter() - t0


def run_file(path, vad, asr, punct, entries, use_hotwords=True):
    samples, sr = read_wav(path)
    audio_dur = len(samples) / sr
    vad.reset()  # 多文件跑批时清空 VAD 内部状态（时间轴/残留段）
    segs, t_vad = vad_segments(vad, samples, sr)

    rows = []
    raw_texts, final_texts = [], []
    t_asr_total = t_punct_total = t_hw_total = 0.0

    for idx, (start, seg) in enumerate(segs, 1):
        seg_dur = len(seg) / sr

        t0 = time.perf_counter()
        stream = asr.create_stream()
        stream.accept_waveform(sr, seg)
        asr.decode_stream(stream)
        raw = stream.result.text.strip()
        t_asr = time.perf_counter() - t0

        t0 = time.perf_counter()
        punced = normalize_punct(punct.add_punctuation(raw)) if raw else ""
        t_punct = time.perf_counter() - t0

        t0 = time.perf_counter()
        final, edits = apply_hotwords(punced, entries) if use_hotwords else (punced, [])
        t_hw = time.perf_counter() - t0

        t_asr_total += t_asr
        t_punct_total += t_punct
        t_hw_total += t_hw

        rows.append({
            "seg": idx,
            "start_s": round(start, 3),
            "seg_dur_s": round(seg_dur, 3),
            "asr_ms": round(t_asr * 1000, 1),
            "punct_ms": round(t_punct * 1000, 1),
            "hotword_ms": round(t_hw * 1000, 1),
            "raw": raw,
            "punctuated": punced,
            "final": final,
            "edits": edits,
        })
        raw_texts.append(raw)
        final_texts.append(final)
        print(f"  [{idx}/{len(segs)}] t={start:6.2f}s dur={seg_dur:5.2f}s "
              f"asr={t_asr*1000:6.1f}ms → {final}")

    pipeline_wall = t_vad + t_asr_total + t_punct_total + t_hw_total
    return {
        "file": os.path.basename(path),
        "audio_dur_s": round(audio_dur, 3),
        "num_segments": len(segs),
        "vad_ms": round(t_vad * 1000, 1),
        "asr_ms_total": round(t_asr_total * 1000, 1),
        "punct_ms_total": round(t_punct_total * 1000, 1),
        "hotword_ms_total": round(t_hw_total * 1000, 1),
        "pipeline_wall_ms": round(pipeline_wall * 1000, 1),
        "rtf": round(pipeline_wall / audio_dur, 4) if audio_dur else None,
        "segments": rows,
        "raw_full": "".join(raw_texts),
        "final_full": "".join(final_texts),
    }


def main():
    ap = argparse.ArgumentParser(description="W2 voice 离线 ASR PoC")
    ap.add_argument("wavs", nargs="+", help="WAV 文件（16k mono）")
    ap.add_argument("--hotwords", default=DEFAULT_HOTWORDS, help="热词表路径")
    ap.add_argument("--no-hotwords", action="store_true", help="关闭热词后处理（对照组）")
    ap.add_argument("--threads", type=int, default=4)
    ap.add_argument("--min-silence", type=float, default=0.5,
                    help="VAD 判定句间静音的最短时长（秒），调小可切出更多段")
    args = ap.parse_args()

    files = []
    for w in args.wavs:
        files.extend(sorted(glob.glob(w)) if any(c in w for c in "*?[") else [w])

    entries = parse_hotwords(args.hotwords)
    print(f"== W2 voice PoC | 热词表: {args.hotwords} ({len(entries)} 条, "
          f"{'关闭' if args.no_hotwords else '开启'}) ==")

    vad, asr, punct, load = build_models(args.threads, min_silence=args.min_silence)
    print(f"模型加载: VAD {load['vad_s']*1000:.0f}ms | ASR {load['asr_s']*1000:.0f}ms | "
          f"标点 {load['punct_s']*1000:.0f}ms (合计 {sum(load.values()):.2f}s)")

    results = []
    for path in files:
        print(f"\n-- {os.path.basename(path)}")
        results.append(run_file(path, vad, asr, punct, entries,
                                use_hotwords=not args.no_hotwords))

    # 热词开/关对比（对最终文本离线重放后处理，不重复跑 ASR）
    if not args.no_hotwords:
        print("\n== 热词开/关转写对比 ==")
        for r in results:
            # 以标点后全文为基线分别重放开/关
            base = "".join(s["punctuated"] for s in r["segments"])
            off = base
            on, on_edits = apply_hotwords(base, entries)
            same = "无差异" if off == on else "有差异"
            print(f"  {r['file']}: {same}")
            print(f"    关: {off}")
            print(f"    开: {on}")
            for e in on_edits:
                print(f"    · {e}")
            r["hotword_diff"] = {"off": off, "on": on, "edits": on_edits,
                                 "changed": off != on}

    # 延迟汇总表
    print("\n== 延迟数据 ==")
    print(f"{'文件':<16}{'音频s':>7}{'段数':>5}{'VADms':>8}{'ASRms':>9}{'标点ms':>8}{'热词ms':>8}{'总耗时ms':>10}{'RTF':>8}")
    for r in results:
        print(f"{r['file']:<16}{r['audio_dur_s']:>7.2f}{r['num_segments']:>5}"
              f"{r['vad_ms']:>8.1f}{r['asr_ms_total']:>9.1f}{r['punct_ms_total']:>8.1f}"
              f"{r['hotword_ms_total']:>8.1f}{r['pipeline_wall_ms']:>10.1f}{r['rtf']:>8.4f}")

    out = {"model_load_s": load, "results": results}
    out_path = os.path.join(HERE, "last_run.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"\nJSON 结果: {out_path}")


if __name__ == "__main__":
    main()
