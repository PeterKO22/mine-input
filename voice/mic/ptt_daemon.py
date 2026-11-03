#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ptt_daemon.py — PTT 语音常驻守护进程（W7 macos 集成）

设计（对应 W7 任务 (a)：AVAudioEngine 采集 → W2 管线 → commit 上屏）：
  - 常驻：启动后按需加载模型（warmup / 首次 transcribe），此后每轮只做推理，
    松开→出文本的延迟即管线耗时（W2 实测 <0.5s）；
  - 音频不落盘：PCM16 走 base64 JSON 行（stdin/stdout 管道，纯内存），
    进程内解码为 np.float32 数组直接进管线；
  - 协议（JSON line，一行请求 → 一行响应，严格按序）：
      → {"id": 1, "cmd": "ping"}
      ← {"id": 1, "ok": true, "ready": false}
      → {"id": 2, "cmd": "warmup"}
      ← {"id": 2, "ok": true, "load_ms": {...}, "hotwords": N}
      → {"id": 3, "cmd": "transcribe", "sample_rate": 16000, "pcm16_b64": "..."}
      ← {"id": 3, "ok": true, "text": "...", "low_confidence": false,
         "confidence": 0.91, "reason": "ok", "elapsed_ms": 231.5, ...}
      → {"id": 4, "cmd": "quit"}
      ← {"id": 4, "ok": true}
  - 低置信不瞎猜：low_confidence=true 时上屏方应提示重说而不是照抄（启发式见 pipeline.py）。

Swift 侧（macos/w7/W7PttController.swift）实现同协议客户端。
"""
import base64
import json
import sys
import time
import traceback

import numpy as np


def log(msg):
    # 日志走 stderr，stdout 严格保留给 JSON-line 协议
    print(f"[ptt_daemon] {msg}", file=sys.stderr, flush=True)


class Daemon:
    def __init__(self):
        self.pipeline = None

    def ensure_pipeline(self, hotwords=None):
        if self.pipeline is None:
            from voice.mic.pipeline import AsrPipeline  # 延迟导入：启动快
            t0 = time.perf_counter()
            self.pipeline = AsrPipeline(hotwords=hotwords)
            log(f"models loaded in {(time.perf_counter()-t0)*1000:.0f}ms "
                f"({self.pipeline.load_ms})")
        return self.pipeline

    def handle(self, req):
        cmd = req.get("cmd")
        if cmd == "ping":
            return {"ok": True, "ready": self.pipeline is not None}
        if cmd == "warmup":
            p = self.ensure_pipeline(req.get("hotwords"))
            return {"ok": True, "load_ms": {k: round(v, 1) for k, v in p.load_ms.items()},
                    "hotwords": len(p.entries)}
        if cmd == "transcribe":
            t0 = time.perf_counter()
            raw = base64.b64decode(req["pcm16_b64"])
            pcm = np.frombuffer(raw, dtype=np.int16)
            samples = pcm.astype(np.float32) / 32768.0
            sr = int(req.get("sample_rate", 16000))
            if sr != 16000:
                return {"ok": False, "error": f"unsupported sample_rate {sr}"}
            p = self.ensure_pipeline(req.get("hotwords") if self.pipeline is None else None)
            result = p.transcribe(samples, hotwords_path=req.get("hotwords"))
            result["ok"] = True
            result["elapsed_ms"] = round((time.perf_counter() - t0) * 1000, 1)
            return result
        if cmd == "quit":
            return {"ok": True, "quit": True}
        return {"ok": False, "error": f"unknown cmd {cmd!r}"}


def main():
    # 允许 `python voice/mic/ptt_daemon.py` 直接跑（repo 根 cwd 或任意 cwd）
    sys.path.insert(0, __import__("os").path.dirname(
        __import__("os").path.dirname(__import__("os").path.abspath(__file__))))
    daemon = Daemon()
    log("ready (models lazy-loaded)")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            resp = {"ok": False, "error": f"bad json: {e}"}
        else:
            try:
                resp = daemon.handle(req)
                resp["id"] = req.get("id")
            except Exception as e:  # 保活：单轮失败不杀进程
                traceback.print_exc(file=sys.stderr)
                resp = {"ok": False, "id": req.get("id"), "error": f"{type(e).__name__}: {e}"}
        sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
        sys.stdout.flush()
        if resp.get("quit"):
            break
    log("bye")


if __name__ == "__main__":
    main()
