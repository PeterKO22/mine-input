"""token 签发 / 校验（HMAC-SHA256，无第三方依赖）。

- /v1/auth/register 注册（多用户分区 + 每用户独立密钥分区）
- /v1/auth/token   签发 Bearer token（默认 7 天）
- 其余 /v1/* 接口用 Authorization: Bearer <token> 鉴权，数据按 token 内 user_id 分区。
"""

import base64
import hashlib
import hmac
import secrets
import time

from . import db

SECRET = db.load_secret()
TOKEN_TTL_SEC = 7 * 24 * 3600


def _b64e(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def _b64d(s: str) -> bytes:
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def make_token(user_id: int):
    exp = int(time.time()) + TOKEN_TTL_SEC
    payload = f"{user_id}.{exp}.{secrets.token_hex(8)}".encode()
    sig = hmac.new(SECRET, payload, hashlib.sha256).digest()
    return f"{_b64e(payload)}.{_b64e(sig)}", exp


def verify_token(token: str):
    """合法返回 user_id，否则 None。"""
    try:
        p_b64, s_b64 = token.split(".")
        payload = _b64d(p_b64)
        sig = _b64d(s_b64)
        expect = hmac.new(SECRET, payload, hashlib.sha256).digest()
        if not hmac.compare_digest(sig, expect):
            return None
        uid_s, exp_s, _nonce = payload.decode().split(".")
        if int(exp_s) < time.time():
            return None
        return int(uid_s)
    except (ValueError, TypeError, UnicodeDecodeError):
        return None
