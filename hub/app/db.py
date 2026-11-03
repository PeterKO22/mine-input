"""mine-input AI Hub — 数据层（SQLite）。

表结构（全部按 user_id 分区，朋友数据互不可见 —— 需求文档 FR7/FR8）：
- users          多用户 + 每用户独立密钥分区字段（key_partition_id / key_partition_key）
- userdb         L1 RIME userdb 同步面（合并策略：时间戳取新）
- counters       L2 画像增量计数器（合并策略：增量累加）
- hotwords       L3 热词（合并策略：集合并）
- meta           AI 配置 / 提示词模板 / schema 版本（合并策略：取新）
- pushes         push_id 幂等去重表（失败可重试，不重复累加）
- ingest_events  交互事件上行（技术方案 v0.3 §8.2 InteractionEvent 字段）
"""

import hashlib
import os
import secrets
import sqlite3
import time

DATA_DIR = os.environ.get("HUB_DATA_DIR", "./hub-data")
DB_PATH = os.path.join(DATA_DIR, "hub.db")
SECRET_PATH = os.path.join(DATA_DIR, "hub-secret")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  key_partition_id TEXT NOT NULL,
  key_partition_key TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS userdb(
  user_id INTEGER NOT NULL,
  entry_key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  device_id TEXT,
  PRIMARY KEY(user_id, entry_key)
);
CREATE TABLE IF NOT EXISTS counters(
  user_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  value INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(user_id, name)
);
CREATE TABLE IF NOT EXISTS hotwords(
  user_id INTEGER NOT NULL,
  word TEXT NOT NULL,
  added_at INTEGER NOT NULL,
  PRIMARY KEY(user_id, word)
);
CREATE TABLE IF NOT EXISTS meta(
  user_id INTEGER NOT NULL,
  mkey TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(user_id, mkey)
);
CREATE TABLE IF NOT EXISTS pushes(
  user_id INTEGER NOT NULL,
  push_id TEXT NOT NULL,
  applied_at INTEGER NOT NULL,
  PRIMARY KEY(user_id, push_id)
);
CREATE TABLE IF NOT EXISTS ingest_events(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  ts INTEGER NOT NULL,
  device_id TEXT,
  app_id TEXT,
  kind TEXT NOT NULL,
  text_in TEXT,
  text_out TEXT,
  ocr_digest TEXT,
  asr_digest TEXT,
  keystroke_cadence REAL,
  suggestion_shown INTEGER,
  suggestion_taken INTEGER,
  created_at INTEGER NOT NULL
);
"""

PBKDF2_ITERATIONS = 200_000


# ---------------------------------------------------------------- 连接 / 初始化

def connect() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def init_db() -> None:
    os.makedirs(DATA_DIR, exist_ok=True)
    conn = connect()
    try:
        conn.executescript(_SCHEMA)
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------- 密钥分区 / 口令

def load_secret() -> bytes:
    """Hub 服务签名密钥（token HMAC 用），首次启动生成并落卷（静态加密预留见 README）。"""
    if os.path.exists(SECRET_PATH):
        with open(SECRET_PATH, "rb") as f:
            return f.read()
    secret = secrets.token_bytes(32)
    with open(SECRET_PATH, "wb") as f:
        f.write(secret)
    os.chmod(SECRET_PATH, 0o600)
    return secret


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, PBKDF2_ITERATIONS)
    return f"pbkdf2_sha256${PBKDF2_ITERATIONS}${salt.hex()}${dk.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, iters, salt_hex, dk_hex = stored.split("$")
        if algo != "pbkdf2_sha256":
            return False
        dk = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), bytes.fromhex(salt_hex), int(iters)
        )
        return secrets.compare_digest(dk.hex(), dk_hex)
    except (ValueError, TypeError):
        return False


# ---------------------------------------------------------------- users

def create_user(username: str, password: str) -> dict:
    """注册用户，签发每用户独立密钥分区（FR8：朋友版独立密钥分区）。"""
    now = int(time.time() * 1000)
    key_partition_id = "kp_" + secrets.token_hex(8)
    key_partition_key = secrets.token_urlsafe(32)  # E2E 预留：客户端侧加密密钥材料
    conn = connect()
    try:
        cur = conn.execute(
            "INSERT INTO users(username, password_hash, key_partition_id,"
            " key_partition_key, created_at) VALUES(?,?,?,?,?)",
            (username, hash_password(password), key_partition_id, key_partition_key, now),
        )
        conn.commit()
        return {
            "user_id": cur.lastrowid,
            "username": username,
            "key_partition": {"id": key_partition_id, "key": key_partition_key},
            "created_at": now,
        }
    except sqlite3.IntegrityError:
        raise ValueError(f"username already exists: {username}")
    finally:
        conn.close()


def get_user_by_username(username: str):
    conn = connect()
    try:
        return conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
    finally:
        conn.close()


def get_user_by_id(user_id: int):
    conn = connect()
    try:
        return conn.execute("SELECT * FROM users WHERE id=?", (user_id,)).fetchone()
    finally:
        conn.close()


# ---------------------------------------------------------------- sync

def apply_push(user_id: int, payload: dict) -> dict:
    """一次 push 的全部合并放进单事务；push_id 幂等去重 → 失败重试安全。"""
    push_id = payload["push_id"]
    conn = connect()
    try:
        with conn:
            dup = conn.execute(
                "SELECT 1 FROM pushes WHERE user_id=? AND push_id=?", (user_id, push_id)
            ).fetchone()
            if dup:
                return {"status": "duplicate", "push_id": push_id, "duplicate": True,
                        "applied": {"userdb_upserted": 0, "userdb_kept": 0,
                                    "hotwords_added": 0, "meta_updated": 0}}
            conn.execute(
                "INSERT INTO pushes(user_id, push_id, applied_at) VALUES(?,?,?)",
                (user_id, push_id, int(time.time() * 1000)),
            )

            # L1 userdb：时间戳取新（>= 视为新写入，同刻以本次为准，行为确定可重放）
            upserted = kept = 0
            for e in payload.get("userdb", []):
                row = conn.execute(
                    "SELECT updated_at FROM userdb WHERE user_id=? AND entry_key=?",
                    (user_id, e["key"]),
                ).fetchone()
                if row is None or e["updated_at"] >= row["updated_at"]:
                    conn.execute(
                        "INSERT INTO userdb(user_id, entry_key, value, updated_at, device_id)"
                        " VALUES(?,?,?,?,?)"
                        " ON CONFLICT(user_id, entry_key) DO UPDATE SET"
                        " value=excluded.value, updated_at=excluded.updated_at,"
                        " device_id=excluded.device_id",
                        (user_id, e["key"], e["value"], e["updated_at"], payload.get("device_id")),
                    )
                    upserted += 1
                else:
                    kept += 1

            # L2 计数器：增量累加
            for name, delta in (payload.get("counters") or {}).items():
                conn.execute(
                    "INSERT INTO counters(user_id, name, value) VALUES(?,?,?)"
                    " ON CONFLICT(user_id, name) DO UPDATE SET value=value+excluded.value",
                    (user_id, name, int(delta)),
                )

            # L3 热词：集合并
            hot_added = 0
            now = int(time.time() * 1000)
            for w in payload.get("hotwords", []):
                cur = conn.execute(
                    "INSERT OR IGNORE INTO hotwords(user_id, word, added_at) VALUES(?,?,?)",
                    (user_id, w, now),
                )
                hot_added += cur.rowcount

            # meta（AI 配置 / schema 版本）：取新
            meta_updated = 0
            for mkey in ("ai_config", "schema_version"):
                m = payload.get(mkey)
                if not m:
                    continue
                row = conn.execute(
                    "SELECT updated_at FROM meta WHERE user_id=? AND mkey=?",
                    (user_id, mkey),
                ).fetchone()
                if row is None or m["updated_at"] >= row["updated_at"]:
                    conn.execute(
                        "INSERT INTO meta(user_id, mkey, value, updated_at) VALUES(?,?,?,?)"
                        " ON CONFLICT(user_id, mkey) DO UPDATE SET"
                        " value=excluded.value, updated_at=excluded.updated_at",
                        (user_id, mkey, _dumps(m["value"]), m["updated_at"]),
                    )
                    meta_updated += 1

        counters = {
            r["name"]: r["value"]
            for r in conn.execute(
                "SELECT name, value FROM counters WHERE user_id=?", (user_id,)
            )
        }
        return {
            "status": "merged",
            "push_id": push_id,
            "duplicate": False,
            "applied": {
                "userdb_upserted": upserted,
                "userdb_kept": kept,
                "hotwords_added": hot_added,
                "meta_updated": meta_updated,
                "counters_now": counters,
            },
        }
    finally:
        conn.close()


def pull_state(user_id: int, since=None) -> dict:
    """拉全量合并态（可选 since 增量过滤 userdb/meta）。"""
    conn = connect()
    try:
        u_where, u_args = "user_id=?", [user_id]
        if since is not None:
            u_where += " AND updated_at>=?"
            u_args.append(since)
        userdb = [
            {"key": r["entry_key"], "value": r["value"], "updated_at": r["updated_at"],
             "device_id": r["device_id"]}
            for r in conn.execute(
                f"SELECT entry_key, value, updated_at, device_id FROM userdb"
                f" WHERE {u_where} ORDER BY entry_key", u_args
            )
        ]
        counters = {
            r["name"]: r["value"]
            for r in conn.execute(
                "SELECT name, value FROM counters WHERE user_id=? ORDER BY name", (user_id,)
            )
        }
        hotwords = [
            r["word"]
            for r in conn.execute(
                "SELECT word FROM hotwords WHERE user_id=? ORDER BY word", (user_id,)
            )
        ]
        meta = {}
        for r in conn.execute("SELECT mkey, value, updated_at FROM meta WHERE user_id=?", (user_id,)):
            meta[r["mkey"]] = {"value": _loads(r["value"]), "updated_at": r["updated_at"]}
        return {
            "server_time": int(time.time() * 1000),
            "userdb": userdb,
            "counters": counters,
            "hotwords": hotwords,
            "ai_config": meta.get("ai_config"),
            "schema_version": meta.get("schema_version"),
        }
    finally:
        conn.close()


# ---------------------------------------------------------------- ingest

def insert_event(user_id: int, ev: dict) -> int:
    conn = connect()
    try:
        cur = conn.execute(
            "INSERT INTO ingest_events(user_id, ts, device_id, app_id, kind, text_in,"
            " text_out, ocr_digest, asr_digest, keystroke_cadence, suggestion_shown,"
            " suggestion_taken, created_at)"
            " VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                user_id, ev["ts"], ev.get("device_id"), ev.get("app_id"), ev["kind"],
                ev.get("text_in"), ev.get("text_out"), ev.get("ocr_digest"),
                ev.get("asr_digest"), ev.get("keystroke_cadence"),
                ev.get("suggestion_shown"), ev.get("suggestion_taken"),
                int(time.time() * 1000),
            ),
        )
        conn.commit()
        return cur.lastrowid
    finally:
        conn.close()


# ---------------------------------------------------------------- helpers

def _dumps(v) -> str:
    import json
    return json.dumps(v, ensure_ascii=False)


def _loads(s: str):
    import json
    try:
        return json.loads(s)
    except (ValueError, TypeError):
        return s
