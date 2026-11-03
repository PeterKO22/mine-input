#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pipeline.py — 可复用离线语音转写管线（W2 PoC 核心抽取，W7 集成用）

管线：PCM(16k mono, 内存) → Silero VAD 流式切段 → SenseVoiceSmall(int8) 转写
      → CT-Transformer(int8) 标点恢复 → hotwords.txt 热词后处理 → 低置信启发式。

与 voice/poc/asr_poc.py 的关系：核心算法同源（VAD 分块喂入 / 0.25s 段边界 pre-roll /
标点去重 / 两级热词纠偏），抽为 AsrPipeline 类供常驻进程与上屏调用；voice/poc/
既有物保持不动。

低置信启发式（"低置信不瞎猜提示重说"）：
  SenseVoice int8 无校准后验置信度，sherpa-onnx OfflineRecognitionResult 亦不吐
  概率。这里用可观测量做启发式（文档如实标注，非模型置信度）：
    - VAD 未检出语音段          → low_confidence（空说/环境噪音）
    - 转写为空 / 无汉字        → low_confidence（不猜，提示重说）
    - 汉字密度 < 0.25 字/秒    → low_confidence（语速与字数明显不匹配）
  confidence = clamp(汉字数 / (4.5 * 语音秒数), 0, 1) 仅作参考值随结果返回。

用法：
    from voice.mic.pipeline import AsrPipeline
    p = AsrPipeline()                     # 模型加载（一次性，之后常驻）
    r = p.transcribe(samples_float32_16k) # samples: np.float32 in [-1, 1]
    print(r["text"], r["low_confidence"])
"""
import os
import re
import time

import numpy as np

VOICE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL_DIR = os.environ.get("MINE_VOICE_MODEL_DIR", os.path.join(VOICE_DIR, "models"))

SENSE_DIR = os.path.join(MODEL_DIR, "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17")
PUNCT_DIR = os.path.join(MODEL_DIR, "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8")
VAD_MODEL = os.path.join(MODEL_DIR, "silero_vad.onnx")

# 热词表默认复用 W2 PoC 的（只读）；可用 MINE_HOTWORDS 或构造参数覆盖
DEFAULT_HOTWORDS = os.environ.get(
    "MINE_HOTWORDS", os.path.join(os.path.dirname(VOICE_DIR), "voice", "poc", "hotwords.txt")
)

SAMPLE_RATE = 16000

# ---------- 后处理：标点去重 + 热词（与 asr_poc.py 同源） ----------
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
    entries = []
    if not path or not os.path.exists(path):
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
    for canonical, aliases in entries:
        for alias in sorted(aliases, key=len, reverse=True):
            if alias and alias != canonical and alias in text:
                text = text.replace(alias, canonical)
                edits.append(f"别名替换: {alias}→{canonical}")

    if not use_homophone:
        return text, edits

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


def estimate_confidence(text, speech_seconds):
    """启发式置信参考值（非模型后验）：汉字密度 / 4.5字每秒，clamp 到 [0,1]。"""
    if speech_seconds <= 0:
        return 0.0
    han = sum(1 for c in text if _is_han(c))
    return max(0.0, min(1.0, han / (4.5 * speech_seconds)))


class AsrPipeline:
    """全离线转写管线。模型加载一次后常驻；transcribe() 线程不安全（串行调用）。

    音频输入是内存中的 np.float32 数组（16k mono，[-1,1]）——API 形态决定音频
    无处落盘（W7 约束「音频不落盘」）。
    """

    def __init__(self, model_dir=None, hotwords=None, num_threads=4,
                 min_silence=0.5, use_hotwords=True):
        if model_dir:
            global SENSE_DIR, PUNCT_DIR, VAD_MODEL
            SENSE_DIR = os.path.join(model_dir, "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17")
            PUNCT_DIR = os.path.join(model_dir, "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8")
            VAD_MODEL = os.path.join(model_dir, "silero_vad.onnx")
        self.hotwords_path = hotwords or DEFAULT_HOTWORDS
        self.use_hotwords = use_hotwords
        self.entries = parse_hotwords(self.hotwords_path)
        self.load_ms = {}
        self._build(num_threads, min_silence)

    def _build(self, num_threads, min_silence):
        import sherpa_onnx

        t0 = time.perf_counter()
        vad_cfg = sherpa_onnx.VadModelConfig()
        vad_cfg.silero_vad.model = VAD_MODEL
        vad_cfg.silero_vad.threshold = 0.5
        vad_cfg.silero_vad.min_silence_duration = min_silence
        vad_cfg.silero_vad.min_speech_duration = 0.3
        vad_cfg.silero_vad.window_size = 512
        vad_cfg.sample_rate = SAMPLE_RATE
        self.vad = sherpa_onnx.VoiceActivityDetector(vad_cfg, buffer_size_in_seconds=120)
        self.load_ms["vad"] = (time.perf_counter() - t0) * 1000

        t0 = time.perf_counter()
        self.asr = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=os.path.join(SENSE_DIR, "model.int8.onnx"),
            tokens=os.path.join(SENSE_DIR, "tokens.txt"),
            language="zh",
            use_itn=True,
            num_threads=num_threads,
        )
        self.load_ms["asr"] = (time.perf_counter() - t0) * 1000

        t0 = time.perf_counter()
        punct_cfg = sherpa_onnx.OfflinePunctuationConfig()
        punct_cfg.model.ct_transformer = os.path.join(PUNCT_DIR, "model.int8.onnx")
        punct_cfg.model.num_threads = num_threads
        self.punct = sherpa_onnx.OfflinePunctuation(punct_cfg)
        self.load_ms["punct"] = (time.perf_counter() - t0) * 1000

    def vad_segments(self, samples):
        """流式喂入 0.5s 音频块并即时取段（对应 PTT 边说边切段）。
        注：一次性喂入整条音频会丢早前段（sherpa-onnx 2.0.1 实测），必须分块。
        VAD 触发点晚于真实语音起点，段边界前后各扩 0.25s pre-roll 防止丢字头/字尾。"""
        t0 = time.perf_counter()
        self.vad.reset()
        raw_segs = []
        chunk = SAMPLE_RATE // 2
        for i in range(0, len(samples), chunk):
            self.vad.accept_waveform(samples[i:i + chunk])
            while not self.vad.empty():
                s = self.vad.front
                raw_segs.append((s.start, len(s.samples)))
                self.vad.pop()
        self.vad.flush()
        while not self.vad.empty():
            s = self.vad.front
            raw_segs.append((s.start, len(s.samples)))
            self.vad.pop()

        pad = int(0.25 * SAMPLE_RATE)
        segs = []
        for start, n in raw_segs:
            a = max(0, start - pad)
            b = min(len(samples), start + n + pad)
            segs.append((a / SAMPLE_RATE, samples[a:b].copy()))
        return segs, (time.perf_counter() - t0) * 1000

    def transcribe(self, samples, hotwords_path=None):
        """samples: np.float32 16k mono in [-1,1]（内存数组，不落盘）。
        hotwords_path: 本轮热词表覆盖（None=用构造时的默认表）。
        返回 dict：text / low_confidence / confidence / reason / segments / 各级耗时 ms。"""
        entries = self.entries if hotwords_path is None else parse_hotwords(hotwords_path)
        samples = np.asarray(samples, dtype=np.float32)
        assert samples.ndim == 1, "需要一维 mono 采样"
        audio_dur = len(samples) / SAMPLE_RATE

        segs, t_vad = self.vad_segments(samples)
        speech_seconds = sum(len(seg) / SAMPLE_RATE for _, seg in segs)

        raw_texts, final_texts, rows = [], [], []
        t_asr = t_punct = t_hw = 0.0
        for idx, (start, seg) in enumerate(segs, 1):
            t0 = time.perf_counter()
            stream = self.asr.create_stream()
            stream.accept_waveform(SAMPLE_RATE, seg)
            self.asr.decode_stream(stream)
            raw = stream.result.text.strip()
            t_asr += (time.perf_counter() - t0) * 1000

            t0 = time.perf_counter()
            punced = normalize_punct(self.punct.add_punctuation(raw)) if raw else ""
            t_punct += (time.perf_counter() - t0) * 1000

            t0 = time.perf_counter()
            if self.use_hotwords:
                final, edits = apply_hotwords(punced, entries)
            else:
                final, edits = punced, []
            t_hw += (time.perf_counter() - t0) * 1000

            rows.append({"start_s": round(start, 3), "seg_dur_s": round(len(seg) / SAMPLE_RATE, 3),
                         "raw": raw, "punctuated": punced, "final": final, "edits": edits})
            raw_texts.append(raw)
            final_texts.append(final)

        text = "".join(final_texts)
        confidence = estimate_confidence(text, speech_seconds)

        # 低置信启发式（不瞎猜，提示重说）
        if not segs:
            low, reason = True, "no_speech_detected"
        elif not text:
            low, reason = True, "empty_transcription"
        elif not any(_is_han(c) for c in text):
            low, reason = True, "no_han_characters"
        elif speech_seconds > 0 and sum(1 for c in text if _is_han(c)) / speech_seconds < 0.25:
            low, reason = True, "low_char_density"
        else:
            low, reason = False, "ok"

        return {
            "text": text,
            "low_confidence": low,
            "confidence": round(confidence, 3),
            "reason": reason,
            "audio_dur_s": round(audio_dur, 3),
            "speech_dur_s": round(speech_seconds, 3),
            "num_segments": len(segs),
            "vad_ms": round(t_vad, 1),
            "asr_ms": round(t_asr, 1),
            "punct_ms": round(t_punct, 1),
            "hotword_ms": round(t_hw, 1),
            "pipeline_ms": round(t_vad + t_asr + t_punct + t_hw, 1),
            "segments": rows,
        }
