#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 say 生成的 s1..s5.wav 用 0.8s 静音拼成 benchmark_multi.wav（模拟句间换气停顿），
用于 VAD 多段切分与逐段延迟测量。"""
import os
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
AUD = os.path.join(os.path.dirname(HERE), "audio")
SR = 16000


def read(p):
    with wave.open(p, "rb") as f:
        assert f.getframerate() == SR and f.getnchannels() == 1
        return np.frombuffer(f.readframes(f.getnframes()), dtype=np.int16)


gap = np.zeros(int(SR * 0.8), dtype=np.int16)
parts = []
for i in range(1, 6):
    parts.append(read(os.path.join(AUD, f"s{i}.wav")))
    parts.append(gap)
audio = np.concatenate(parts)

out = os.path.join(AUD, "benchmark_multi.wav")
with wave.open(out, "wb") as f:
    f.setnchannels(1)
    f.setsampwidth(2)
    f.setframerate(SR)
    f.writeframes(audio.tobytes())
print(f"{out}: {len(audio)/SR:.2f}s, 5 句 + 0.8s 间隔")
