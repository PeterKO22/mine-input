#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ptt_client.py — ptt_daemon.py 的 Python 客户端（与 Swift 侧 W7PttController 同协议）

用途：测试脚本 / 降级小工具复用；也作为协议的参考实现。
音频始终在内存（bytes → base64 → 管道），不落盘。
"""
import base64
import json
import os
import subprocess
import sys
import threading

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_PYTHON = os.environ.get("MINE_VOICE_PYTHON", os.path.join(REPO_ROOT, "voice", ".venv", "bin", "python"))
DEFAULT_DAEMON = os.path.join(REPO_ROOT, "voice", "mic", "ptt_daemon.py")


class PttDaemonClient:
    def __init__(self, python=DEFAULT_PYTHON, daemon=DEFAULT_DAEMON, hotwords=None):
        env = dict(os.environ)
        env["PYTHONPATH"] = REPO_ROOT + os.pathsep + env.get("PYTHONPATH", "")
        self.proc = subprocess.Popen(
            [python, daemon],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr,
            env=env, text=True, bufsize=1,
        )
        self._id = 0
        self._lock = threading.Lock()
        self._hotwords = hotwords

    def call(self, req):
        with self._lock:
            self._id += 1
            req["id"] = self._id
            self.proc.stdin.write(json.dumps(req, ensure_ascii=False) + "\n")
            self.proc.stdin.flush()
            line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError("daemon closed stdout (crashed?)")
        return json.loads(line)

    def ping(self):
        return self.call({"cmd": "ping"})

    def warmup(self):
        req = {"cmd": "warmup"}
        if self._hotwords:
            req["hotwords"] = self._hotwords
        return self.call(req)

    def transcribe(self, pcm16_bytes, sample_rate=16000):
        """pcm16_bytes: 16k mono 16bit PCM（内存 bytes）。"""
        req = {"cmd": "transcribe", "sample_rate": sample_rate,
               "pcm16_b64": base64.b64encode(pcm16_bytes).decode("ascii")}
        if self._hotwords:
            req["hotwords"] = self._hotwords
        return self.call(req)

    def close(self):
        try:
            self.call({"cmd": "quit"})
        except Exception:
            pass
        try:
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
