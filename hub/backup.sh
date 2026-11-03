#!/usr/bin/env bash
# W17：Hub 数据一键备份（SQLite + secret）。
#
# 用法：./backup.sh [输出目录]        # 默认 ./backups/
# 产物：hub-backup-<时间戳>.tar.gz = { hub.db, hub-secret, manifest.txt, SHA256SUMS }
#
# - SQLite 用容器内 python sqlite3 backup API 在线一致备份（WAL 安全，不打断服务）；
#   容器未运行时退化为 docker cp 直拷（干净停机后 WAL 已合并，仍安全）。
# - hub-secret（token HMAC 签名密钥）一并备份——没有它恢复后所有 token 失效、
#   但用户数据仍在；泄密则可伪造 token，故备份包按 0600 保管、勿入库（.gitignore）。
# - 恢复：./restore.sh <tar.gz|latest>
set -eu

cd "$(dirname "$0")"
OUT_DIR="${1:-$PWD/backups}"
CONTAINER="${HUB_CONTAINER:-mine-input-hub}"
STAMP=$(date +%Y%m%d-%H%M%S)

mkdir -p "$OUT_DIR"
OUT_TAR="$OUT_DIR/hub-backup-$STAMP.tar.gz"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "[error] 容器 $CONTAINER 不存在（先 docker compose up -d）" >&2
  exit 1
fi

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

RUNNING=$(docker inspect -f '{{.State.Running}}' "$CONTAINER")

if [ "$RUNNING" = "true" ]; then
  # 在线一致备份：sqlite3 backup API 合并 WAL 到单文件快照
  echo "[backup] $CONTAINER 运行中 → sqlite3 backup API 在线快照"
  docker exec -i "$CONTAINER" python - <<'PY'
import sqlite3
src = sqlite3.connect("/data/hub.db")
dst = sqlite3.connect("/data/.hub-backup-snapshot.db")
with dst:
    src.backup(dst)
dst.close(); src.close()
print("[ok] sqlite snapshot -> /data/.hub-backup-snapshot.db")
PY
  docker cp "$CONTAINER:/data/.hub-backup-snapshot.db" "$STAGE/hub.db"
  docker exec "$CONTAINER" rm -f /data/.hub-backup-snapshot.db
else
  # 停机退化：干净停机后 WAL 已 checkpoint 合并，直拷即可
  echo "[backup] $CONTAINER 未运行 → docker cp 直拷（干净停机快照）"
  docker cp "$CONTAINER:/data/hub.db" "$STAGE/hub.db"
fi

docker cp "$CONTAINER:/data/hub-secret" "$STAGE/hub-secret"
chmod 600 "$STAGE/hub-secret"

# 便于抽查：用户数/行数清单（备份内容自证）
docker exec -i "$CONTAINER" python - <<'PY' >"$STAGE/counts.txt" 2>/dev/null || \
  echo "(容器未运行，跳过行数清单)" >"$STAGE/counts.txt"
import sqlite3
db = sqlite3.connect("/data/hub.db")
for t in ("users", "userdb", "counters", "hotwords", "pushes", "ingest_events"):
    try:
        n = db.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        print(f"{t}={n}")
    except Exception:
        print(f"{t}=?")
PY

cat >"$STAGE/manifest.txt" <<EOF
# mine-input hub backup manifest
date=$(date +%Y-%m-%dT%H:%M:%S%z)
host=$(hostname)
container=$CONTAINER
format=hub-backup-v1
files=hub.db,hub-secret,counts.txt
EOF

(cd "$STAGE" && shasum -a 256 hub.db hub-secret counts.txt >SHA256SUMS)
tar czf "$OUT_TAR" -C "$STAGE" hub.db hub-secret counts.txt manifest.txt SHA256SUMS
chmod 600 "$OUT_TAR"

echo "[ok] 备份完成：$OUT_TAR"
echo "     包内容：hub.db + hub-secret + counts.txt + manifest.txt + SHA256SUMS"
sed 's/^/     /' "$STAGE/counts.txt"
echo "[next] 恢复演练：./restore.sh $OUT_TAR"
