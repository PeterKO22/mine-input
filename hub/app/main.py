"""mine-input AI Hub — FastAPI 服务（W4 骨架）。

HTTP 字段以 docs/技术方案-v0.4.md 文本为准；SPI 契约字段对齐
技术方案 v0.3 §7.2（v0.4 §7 引用同一契约，「契约即协议」）：
  Candidate    := { text, score, source }
  AiContext    := { before_cursor, app_id, from_voice, context_digest }
  InteractionEvent := { ts, device_id, app_id, kind, text_in, text_out,
                        ocr_digest?, asr_digest?, keystroke_cadence,
                        suggestion_shown, suggestion_taken }

接口：
  POST /v1/auth/register  注册（多用户分区 + 每用户独立密钥分区字段）
  POST /v1/auth/token     签发 Bearer token
  GET  /v1/auth/whoami    当前用户与密钥分区 id
  POST /v1/sync/push      增量上行（userdb 取新 / 计数器增量累加，push_id 幂等可重试）
  POST /v1/sync/pull      拉合并态（可选 since 增量）
  POST /v1/ingest         交互事件上行（InteractionEvent）
  POST /v1/suggest        SSE 流式建议桩（Candidate 字段逐条下发 + done 事件）
  GET  /healthz           健康检查（免鉴权，给 compose healthcheck 用）
"""

import asyncio
import json
import secrets
import time
from typing import Dict, List, Literal, Optional

from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from . import auth, db

app = FastAPI(title="mine-input AI Hub", version="0.4-w4-skeleton")
db.init_db()

EventKind = Literal["key_session", "voice_session", "candidate_pick", "suggestion_feedback"]


# ---------------------------------------------------------------- schemas

class RegisterIn(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    password: str = Field(min_length=4, max_length=256)


class TokenIn(BaseModel):
    username: str
    password: str


class UserdbEntry(BaseModel):
    key: str = Field(min_length=1, max_length=256)
    value: str = Field(max_length=65536)
    updated_at: int  # epoch ms，合并取新


class MetaIn(BaseModel):
    updated_at: int
    value: object


class PushIn(BaseModel):
    device_id: str = Field(min_length=1, max_length=128)
    push_id: str = Field(min_length=1, max_length=128)  # 幂等键：失败可重试
    userdb: List[UserdbEntry] = []
    counters: Dict[str, int] = {}
    hotwords: List[str] = []
    ai_config: Optional[MetaIn] = None
    schema_version: Optional[MetaIn] = None


class PullIn(BaseModel):
    device_id: str = Field(min_length=1, max_length=128)
    since: Optional[int] = None  # epoch ms，可选增量


class IngestIn(BaseModel):
    ts: int
    device_id: str = Field(min_length=1, max_length=128)
    app_id: str = ""
    kind: EventKind
    text_in: str = ""
    text_out: str = ""
    ocr_digest: Optional[str] = None
    asr_digest: Optional[str] = None
    keystroke_cadence: Optional[float] = None
    suggestion_shown: Optional[int] = None
    suggestion_taken: Optional[int] = None


class SuggestIn(BaseModel):
    before_cursor: str = ""
    app_id: str = ""
    from_voice: bool = False
    context_digest: str = ""


# ---------------------------------------------------------------- auth dep

def current_user(authorization: str = Header(default="")):
    if not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    uid = auth.verify_token(authorization[len("Bearer "):].strip())
    if uid is None:
        raise HTTPException(status_code=401, detail="invalid or expired token")
    user = db.get_user_by_id(uid)
    if user is None:
        raise HTTPException(status_code=401, detail="unknown user")
    return user


# ---------------------------------------------------------------- health

@app.get("/healthz")
def healthz():
    return {"ok": True, "service": "mine-input-hub", "time": int(time.time() * 1000)}


# ---------------------------------------------------------------- /v1/auth

@app.post("/v1/auth/register", status_code=201)
def register(body: RegisterIn):
    try:
        user = db.create_user(body.username, body.password)
    except ValueError:
        raise HTTPException(status_code=409, detail="username already exists")
    return user  # 含 key_partition: {id, key} —— 每用户独立密钥分区（FR8）


@app.post("/v1/auth/token")
def issue_token(body: TokenIn):
    row = db.get_user_by_username(body.username)
    if row is None or not db.verify_password(body.password, row["password_hash"]):
        raise HTTPException(status_code=401, detail="bad username or password")
    token, exp = auth.make_token(row["id"])
    return {
        "access_token": token,
        "token_type": "bearer",
        "expires_at": exp,
        "user_id": row["id"],
        "key_partition_id": row["key_partition_id"],
    }


@app.get("/v1/auth/whoami")
def whoami(user=Depends(current_user)):
    return {
        "user_id": user["id"],
        "username": user["username"],
        "key_partition_id": user["key_partition_id"],
        "created_at": user["created_at"],
    }


# ---------------------------------------------------------------- /v1/sync

@app.post("/v1/sync/push")
def sync_push(body: PushIn, user=Depends(current_user)):
    payload = body.model_dump()
    return db.apply_push(user["id"], payload)


@app.post("/v1/sync/pull")
def sync_pull(body: PullIn, user=Depends(current_user)):
    return db.pull_state(user["id"], body.since)


# ---------------------------------------------------------------- /v1/ingest

@app.post("/v1/ingest", status_code=201)
def ingest(body: IngestIn, user=Depends(current_user)):
    ev = body.model_dump()
    ev_id = db.insert_event(user["id"], ev)
    return {"status": "stored", "event_id": ev_id, "kind": ev["kind"], "ts": ev["ts"]}


# ---------------------------------------------------------------- /v1/suggest

def _stub_suggestions(before_cursor: str):
    """流式桩：真实后端为 llama.cpp 7B Q4（T2 已定，占位未部署）。"""
    tail = (before_cursor or "")[-8:]
    return [
        {"text": f"{tail}——好的，我稍后处理", "score": 0.86, "source": "hub-stub"},
        {"text": f"{tail}——请稍等，马上回复", "score": 0.74, "source": "hub-stub"},
        {"text": f"{tail}——谢谢，收到", "score": 0.61, "source": "hub-stub"},
    ]


async def _sse_stream(ctx: SuggestIn):
    items = _stub_suggestions(ctx.before_cursor)
    for i, cand in enumerate(items, 1):
        cand["seq"] = i
        yield f"event: suggestion\ndata: {json.dumps(cand, ensure_ascii=False)}\n\n"
        await asyncio.sleep(0.15)  # 模拟增量到达（300–500ms 刷新由客户端防抖）
    done = {
        "status": "ok",
        "backend": "stub",           # TODO(M4 后续): llama.cpp 7B Q4
        "suggestions": len(items),
        "context_digest": ctx.context_digest,
    }
    yield f"event: done\ndata: {json.dumps(done, ensure_ascii=False)}\n\n"


@app.post("/v1/suggest")
def suggest(body: SuggestIn, user=Depends(current_user)):
    # 审计日志只记字段（技术方案 v0.4 §7）：user_id / app_id / from_voice / 长度
    print(
        f"[audit] suggest user={user['id']} app={body.app_id!r} "
        f"from_voice={body.from_voice} before_len={len(body.before_cursor)}",
        flush=True,
    )
    return StreamingResponse(
        _sse_stream(body),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# 本地直跑入口：uvicorn app.main:app --port 8080
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
