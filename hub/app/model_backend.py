"""llama.cpp llama-server 后端客户端（W10：/v1/suggest 真模型转发）。

链路：/v1/suggest → 提示词模板（app/prompts.py，版本化）→ llama-server /completion
（stream:true，SSE data: {...} 逐 token）→ Hub 侧组帧（Candidate 契约字段）→ SSE 下发。

帧语义（契约 Candidate := {text, score, source}，逐帧 + 末帧 done）：
  - continuation / voice_correct / teleprompter：增量流式——text 为「当前累积全文」，
    客户端按帧刷新（提词器 300–500ms 刷新节流在客户端，Hub 帧距 ≥150ms 采样）；
  - rescore：模型每输出一完整行即一帧（原样候选文本），score 按重排名次递减。

score 语义（诚实标注）：当前为启发式占位（部分帧 0.5 / 完整帧 0.85 / 重排名次分），
后续接 logits 置信度（llama.cpp n_probs）再换真实分数。

800ms 预算语义（技术方案 §7：超时 800ms 弃本轮，全异步不阻塞）：
  - 弃不弃由**客户端**决定（Hub 不裁剪，budget_ms 随 done 帧下发供对账）；
  - 客户端断开**不影响服务端**：上游消费在独立 task 中全程把 llama.cpp 流读干
    （producer 与 SSE consumer 解耦，consumer 取消不级联取消 producer），
    模型服务不会因客户端弃轮而挂起/中断生成。

若 llama-server 不可达且 SUGGEST_ALLOW_STUB_FALLBACK=1（默认），降级回流式桩，
done 帧 backend 显式标注 "stub-fallback"，绝不冒充真模型。
"""

import asyncio
import json
import os
import time
from typing import AsyncIterator

import httpx

from . import prompts

MODEL_URL = os.environ.get("MODEL_URL", "http://llama:8091").rstrip("/")
MODEL_NAME = os.environ.get("MODEL_NAME", "qwen2.5-7b-instruct-q4_k_m")
ALLOW_STUB_FALLBACK = os.environ.get("SUGGEST_ALLOW_STUB_FALLBACK", "1") == "1"
SUGGEST_BUDGET_MS = int(os.environ.get("SUGGEST_BUDGET_MS", "800"))
FRAME_INTERVAL_S = 0.15  # Hub 侧帧采样间隔下限（客户端另有 300–500ms 防抖）
CONNECT_TIMEOUT_S = 5.0
UPSTREAM_TIMEOUT_S = 120.0

_SOURCE = f"llama.cpp:{MODEL_NAME}"


def backend_info() -> dict:
    return {"model_url": MODEL_URL, "model": MODEL_NAME,
            "prompt_version": prompts.PROMPT_VERSION,
            "stub_fallback": ALLOW_STUB_FALLBACK}


# ---------------------------------------------------------------- SSE 组帧

def _sse(event: str, data: dict) -> str:
    return f"event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n"


def _stub_suggestions(before_cursor: str):
    tail = (before_cursor or "")[-8:]
    return [
        {"text": f"{tail}——好的，我稍后处理", "score": 0.86, "source": "hub-stub"},
        {"text": f"{tail}——请稍等，马上回复", "score": 0.74, "source": "hub-stub"},
        {"text": f"{tail}——谢谢，收到", "score": 0.61, "source": "hub-stub"},
    ]


async def _stub_stream(ctx: dict) -> AsyncIterator[str]:
    items = _stub_suggestions(ctx.get("before_cursor", ""))
    for i, cand in enumerate(items, 1):
        cand["seq"] = i
        yield _sse("suggestion", cand)
        await asyncio.sleep(0.15)
    yield _sse("done", {
        "status": "ok", "backend": "stub-fallback", "suggestions": len(items),
        "context_digest": ctx.get("context_digest", ""),
        "prompt_version": prompts.PROMPT_VERSION, "scene": ctx.get("scene", "continuation"),
        "budget_ms": SUGGEST_BUDGET_MS,
    })


# ---------------------------------------------------------------- llama.cpp producer/consumer

async def _upstream_producer(client: httpx.AsyncClient, payload: dict,
                             queue: asyncio.Queue, state: dict):
    """读干 llama.cpp /completion 流并入队；与 SSE consumer 解耦——
    客户端弃轮（consumer 被取消）时本协程继续跑完，服务端不受影响。"""
    try:
        async with client.stream(
            "POST", f"{MODEL_URL}/completion", json=payload,
            timeout=httpx.Timeout(UPSTREAM_TIMEOUT_S, connect=CONNECT_TIMEOUT_S),
        ) as resp:
            resp.raise_for_status()
            async for line in resp.aiter_lines():
                line = line.strip()
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                try:
                    chunk = json.loads(data)
                except (ValueError, TypeError):
                    continue
                content = chunk.get("content") or ""
                if content:
                    if state.get("first_token_at") is None:
                        state["first_token_at"] = time.perf_counter()
                    state["tokens"] += 1
                    queue.put_nowait(("delta", content))
                if chunk.get("stop"):
                    state["upstream_stats"] = chunk
                    break
        queue.put_nowait(("end", None))
    except Exception as exc:  # noqa: BLE001 —— 上游任何错误都转成 error 事件（带异常对象）
        queue.put_nowait(("error", exc))


async def _model_stream(ctx: dict) -> AsyncIterator[str]:
    scene = ctx.get("scene", "continuation")
    prompt = prompts.render_prompt(scene, ctx.get("before_cursor", ""),
                                   ctx.get("candidates") or ())
    max_tokens = int(ctx.get("max_tokens") or 48)
    payload = {
        "prompt": prompt,
        "n_predict": max_tokens,
        "top_p": 0.9,
        "stop": prompts.STOP_SEQUENCES,
        "stream": True,
        "cache_prompt": True,
        **prompts.SCENE_GEN_PARAMS.get(scene, {}),
    }

    t0 = time.perf_counter()
    queue: asyncio.Queue = asyncio.Queue()
    state = {"first_token_at": None, "tokens": 0, "upstream_stats": None}

    async with httpx.AsyncClient() as client:
        producer = asyncio.create_task(
            _upstream_producer(client, payload, queue, state))
        # consumer 异常/取消不级联到 producer（客户端弃一轮不影响服务端）；
        # producer 自然读完上游即结束，内存由 max_tokens 上界约束。
        producer.add_done_callback(
            lambda t: t.exception() and print(f"[warn] suggest producer: {t.exception()}",
                                              flush=True))

        seq = 0
        frames = 0
        accum = ""
        line_buf = ""
        last_emit = 0.0
        errored = None
        try:
            while True:
                try:
                    kind, data = await asyncio.wait_for(queue.get(), UPSTREAM_TIMEOUT_S)
                except asyncio.TimeoutError:
                    kind, data = "error", TimeoutError("upstream timeout")
                if kind == "delta":
                    text = str(data)
                    accum += text
                    now = time.perf_counter()
                    if scene == "rescore":
                        # 每完整行一帧（候选原样文本，score=名次分）
                        line_buf += text
                        while "\n" in line_buf:
                            line, line_buf = line_buf.split("\n", 1)
                            line = line.strip()
                            if not line:
                                continue
                            seq += 1
                            frames += 1
                            yield _sse("suggestion", {
                                "text": line,
                                "score": round(max(0.05, 0.9 - 0.1 * (seq - 1)), 2),
                                "source": _SOURCE, "seq": seq,
                            })
                    elif now - last_emit >= FRAME_INTERVAL_S:
                        last_emit = now
                        seq += 1
                        frames += 1
                        yield _sse("suggestion", {
                            "text": accum, "score": 0.5,
                            "source": _SOURCE, "seq": seq,
                        })
                elif kind == "end":
                    break
                else:  # error
                    errored = data
                    break

            if errored is not None:
                # 连接级失败且一帧未出 → 可降级桩；否则如实报错
                if (isinstance(errored, (httpx.ConnectError, httpx.ConnectTimeout))
                        and frames == 0 and ALLOW_STUB_FALLBACK):
                    print(f"[warn] llama-server unreachable at {MODEL_URL}; "
                          f"stub fallback", flush=True)
                    async for frame in _stub_stream(ctx):
                        yield frame
                    return
                yield _sse("error", {"status": "error",
                                     "detail": f"{type(errored).__name__}: {errored}"})
                yield _sse("done", {
                    "status": "error", "backend": "llama.cpp", "model": MODEL_NAME,
                    "suggestions": frames,
                    "context_digest": ctx.get("context_digest", ""),
                    "prompt_version": prompts.PROMPT_VERSION, "scene": scene,
                })
                return

            # 尾帧：rescore 补最后一行；其余场景补完整文本
            if scene == "rescore":
                tail_line = line_buf.strip()
                if tail_line:
                    seq += 1
                    frames += 1
                    yield _sse("suggestion", {
                        "text": tail_line,
                        "score": round(max(0.05, 0.9 - 0.1 * (seq - 1)), 2),
                        "source": _SOURCE, "seq": seq,
                    })
            elif accum.strip():
                seq += 1
                frames += 1
                yield _sse("suggestion", {
                    "text": accum, "score": 0.85,
                    "source": _SOURCE, "seq": seq,
                })

            total_ms = (time.perf_counter() - t0) * 1000
            ttft_ms = ((state["first_token_at"] - t0) * 1000
                       if state["first_token_at"] else None)
            inter = ((total_ms - (ttft_ms or 0)) / max(1, frames - 1)) if frames > 1 else None
            yield _sse("done", {
                "status": "ok", "backend": "llama.cpp", "model": MODEL_NAME,
                "suggestions": frames,
                "context_digest": ctx.get("context_digest", ""),
                "prompt_version": prompts.PROMPT_VERSION, "scene": scene,
                "budget_ms": SUGGEST_BUDGET_MS,
                "timings": {
                    "ttft_ms": round(ttft_ms, 1) if ttft_ms is not None else None,
                    "total_ms": round(total_ms, 1),
                    "frames": frames,
                    "tokens": state["tokens"],
                    "inter_frame_avg_ms": round(inter, 1) if inter else None,
                },
            })
        except (asyncio.CancelledError, GeneratorExit):
            # 客户端弃本轮：仅停发帧；producer 继续读干上游（见上）
            print("[audit] suggest client abandoned; upstream kept draining", flush=True)
            raise


async def suggest_sse(ctx: dict) -> AsyncIterator[str]:
    """按 ctx 产出 SSE 帧流（suggestion* + done）。"""
    async for frame in _model_stream(ctx):
        yield frame
