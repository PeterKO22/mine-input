#!/usr/bin/env python3
"""W10 延迟实测：/v1/suggest 真模型后端（llama.cpp llama-server）。

指标（每场景 N 轮）：
  ttft_ms        首 token 延迟——服务端实测（done 帧 timings.ttft_ms：请求进 Hub 到上游首个 token）
  first_frame_ms 首帧到达——客户端实测（请求发出到首个 suggestion 帧落地）
  inter_ms       每帧间隔——客户端 suggestion 帧间隔均值
  total_ms       总耗时——客户端请求发出到 done 帧
输出 markdown 表，可直接贴进 W10-REPORT.md。

用法：BASE_URL=http://localhost:8088 BENCH_ROUNDS=3 python3 bench_latency.py
（stdlib-only，宿主机直接跑；需 compose --profile model 的真后端在线）
"""
import json
import os
import statistics
import sys
import time
import urllib.request

BASE = os.environ.get("BASE_URL", "http://localhost:8088").rstrip("/")
ROUNDS = int(os.environ.get("BENCH_ROUNDS", "3"))

SCENES = [
    ("continuation", {"before_cursor": "今天开会讨论了第三季度的", "max_tokens": 32}),
    ("voice_correct", {"before_cursor": "我今天去了音行办理信用卡业务", "max_tokens": 32,
                       "from_voice": True}),
    ("rescore", {"before_cursor": "ni hao", "max_tokens": 32,
                 "candidates": ["你好", "拟好", "泥嚎", "倪豪"]}),
    ("teleprompter", {"before_cursor": "周末我们一起去", "max_tokens": 32}),
]


def api(path, payload, token=None, timeout=30):
    req = urllib.request.Request(
        BASE + path, data=json.dumps(payload, ensure_ascii=False).encode(),
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {token}"} if token else {})})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def make_token():
    stamp = str(int(time.time() * 1000))
    body = {"username": f"bench-{stamp}", "password": "bench-pass-123"}
    api("/v1/auth/register", body)
    return api("/v1/auth/token", body)["access_token"]


def run_suggest(token, scene, params, timeout=120):
    """POST /v1/suggest，逐帧打时间戳，返回 (metrics, done_json, sample_text)."""
    payload = {"before_cursor": params.get("before_cursor", ""),
               "app_id": "bench", "from_voice": params.get("from_voice", False),
               "context_digest": f"bench-{scene}", "scene": scene,
               "candidates": params.get("candidates", []),
               "max_tokens": params.get("max_tokens", 32)}
    req = urllib.request.Request(
        BASE + "/v1/suggest", data=json.dumps(payload, ensure_ascii=False).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"})
    t_req = time.perf_counter()
    frame_ts = []
    done = None
    sample = ""
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        event, data = None, []
        for raw in resp:
            line = raw.decode("utf-8", "replace").rstrip("\n")
            if line.startswith("event:"):
                event = line[6:].strip()
            elif line.startswith("data:"):
                data.append(line[5:].strip())
            elif line == "":
                if event and data:
                    obj = json.loads("\n".join(data))
                    now = (time.perf_counter() - t_req) * 1000
                    if event == "suggestion":
                        frame_ts.append(now)
                        sample = obj.get("text", "")
                    elif event == "done":
                        done = obj
                        break
                event, data = None, []
    total_ms = (time.perf_counter() - t_req) * 1000
    first_frame_ms = frame_ts[0] if frame_ts else None
    gaps = [b - a for a, b in zip(frame_ts, frame_ts[1:])]
    inter_ms = statistics.mean(gaps) if gaps else None
    server = (done or {}).get("timings") or {}
    return {
        "ttft_ms": server.get("ttft_ms"),
        "first_frame_ms": round(first_frame_ms, 1) if first_frame_ms else None,
        "inter_ms": round(inter_ms, 1) if inter_ms else None,
        "total_ms": round(total_ms, 1),
        "frames": (done or {}).get("suggestions", len(frame_ts)),
        "tokens": server.get("tokens"),
    }, done, sample


def main():
    token = make_token()
    print(f"# /v1/suggest 真模型延迟实测（BASE={BASE}，每场景 {ROUNDS} 轮）\n")
    all_rows = []
    model_seen = None
    for scene, params in SCENES:
        rows = []
        for i in range(ROUNDS):
            m, done, sample = run_suggest(token, scene, params)
            rows.append(m)
            model_seen = (done or {}).get("model", model_seen)
            print(f"[{scene} #{i+1}] {m}  sample={sample[:40]!r}", file=sys.stderr)
            if i == 0 and done:
                print(f"[{scene}] done={json.dumps(done, ensure_ascii=False)}",
                      file=sys.stderr)
        agg = {k: (statistics.mean([r[k] for r in rows if r[k] is not None])
                   if any(r[k] is not None for r in rows) else None)
               for k in ("ttft_ms", "first_frame_ms", "inter_ms", "total_ms")}
        frames = statistics.mean([r["frames"] for r in rows])
        tokens = statistics.mean([r["tokens"] or 0 for r in rows])
        all_rows.append((scene, agg, frames, tokens))

    print("| 场景 | 首token延迟 ttft_ms(服务端) | 首帧到达 ms(客户端) | 每帧间隔 ms | 总耗时 ms | 帧数 | token数 |")
    print("|---|---|---|---|---|---|---|")
    for scene, agg, frames, tokens in all_rows:
        def fmt(v):
            return f"{v:.1f}" if v is not None else "—"
        print(f"| {scene} | {fmt(agg['ttft_ms'])} | {fmt(agg['first_frame_ms'])} | "
              f"{fmt(agg['inter_ms'])} | {fmt(agg['total_ms'])} | {frames:.1f} | {tokens:.1f} |")
    print(f"\n（{ROUNDS} 轮均值；ttft=请求进 Hub→上游首 token；"
          f"首帧/间隔/总耗时为客户端墙钟；模型 {model_seen}（以 done 帧 model 字段为准）on llama.cpp）")


if __name__ == "__main__":
    main()
