#!/usr/bin/env bash
# W17：Hub 数据一键恢复（SQLite + secret），backup.sh 的对偶。
#
# 用法：./restore.sh [备份包|latest]    # 默认 latest = ./backups/ 最新包
#
# 流程：校验 SHA256SUMS → 停 hub → 换入 hub.db/hub-secret（清 WAL 残留）→
#       起 hub → /healthz 就绪 → 抽样核对行数。
# ⚠️ 恢复会整体覆盖当前 /data/hub.db 与 hub-secret（当前数据丢失、token 全失效）。
set -eu

cd "$(dirname "$0")"
CONTAINER="${HUB_CONTAINER:-mine-input-hub}"
BACKUP_DIR="$PWD/backups"

SRC="${1:-latest}"
if [ "$SRC" = "latest" ]; then
  SRC=$(ls -t "$BACKUP_DIR"/hub-backup-*.tar.gz 2>/dev/null | head -1 || true)
  if [ -z "$SRC" ]; then
    echo "[error] $BACKUP_DIR 下无备份包（先 ./backup.sh）" >&2
    exit 1
  fi
fi
[ -f "$SRC" ] || { echo "[error] 备份包不存在: $SRC" >&2; exit 1; }
echo "[restore] 备份包：$SRC"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "[error] 容器 $CONTAINER 不存在（先 docker compose up -d）" >&2
  exit 1
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
tar xzf "$SRC" -C "$STAGE"
for f in hub.db hub-secret SHA256SUMS; do
  [ -f "$STAGE/$f" ] || { echo "[error] 备份包缺 $f" >&2; exit 1; }
done

# ---- 1. 完整性校验 ----
echo "[check] SHA256SUMS 校验"
if command -v shasum >/dev/null 2>&1; then
  (cd "$STAGE" && shasum -a 256 -c SHA256SUMS)
elif command -v sha256sum >/dev/null 2>&1; then
  (cd "$STAGE" && sha256sum -c SHA256SUMS)
else
  echo "  [warn] 无 shasum/sha256sum，跳过校验"
fi
[ -f "$STAGE/manifest.txt" ] && sed 's/^/  /' "$STAGE/manifest.txt"

# ---- 2. 停 hub ----
WAS_RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER")
if [ "$WAS_RUNNING" = "true" ]; then
  echo "[stop] 停 $CONTAINER"
  docker stop "$CONTAINER" >/dev/null
fi

# ---- 3. 换入数据（经一次性容器写卷；清 WAL/SHM 残留防混写）----
echo "[swap] hub.db + hub-secret → /data（清 hub.db-wal/hub.db-shm）"
chmod 600 "$STAGE/hub-secret"
docker run --rm --volumes-from "$CONTAINER" \
  -v "$STAGE:/backup:ro" --entrypoint /bin/sh mine-input-hub:latest -c '
    set -e
    rm -f /data/hub.db /data/hub.db-wal /data/hub.db-shm /data/hub-secret
    cp /backup/hub.db /data/hub.db
    cp /backup/hub-secret /data/hub-secret
    chmod 600 /data/hub-secret
    ls -la /data
  '

# ---- 4. 起 hub + 就绪等待 ----
if [ "$WAS_RUNNING" = "true" ]; then
  echo "[start] 起 $CONTAINER"
  docker start "$CONTAINER" >/dev/null
fi
echo "[wait] /healthz 就绪"
OK=0
for _ in $(seq 1 30); do
  if docker exec "$CONTAINER" python -c \
      "import urllib.request; urllib.request.urlopen('http://localhost:8080/healthz', timeout=3)" \
      >/dev/null 2>&1; then OK=1; break; fi
  sleep 1
done
[ "$OK" = "1" ] || { echo "[error] 30s 内 /healthz 未就绪" >&2; exit 1; }
echo "[ok] /healthz 就绪"

# ---- 5. 抽样核对 ----
echo "[verify] 恢复后行数（对照备份包 counts.txt）："
docker exec -i "$CONTAINER" python - <<'PY'
import sqlite3
db = sqlite3.connect("/data/hub.db")
for t in ("users", "userdb", "counters", "hotwords", "pushes", "ingest_events"):
    try:
        n = db.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        print(f"  {t}={n}")
    except Exception:
        print(f"  {t}=?")
PY
[ -f "$STAGE/counts.txt" ] && sed 's/^/  备份时: /' "$STAGE/counts.txt"
echo "[ok] 恢复完成（token 密钥已换回备份时的 hub-secret，旧 token 仍有效）"
