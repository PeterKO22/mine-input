#!/usr/bin/env bash
# W17 TLS：自签 CA + Hub HTTPS 终结证书（个人/朋友场景）。
#
# 用法：
#   ./gen-certs.sh                  # 生成 CA + server 证书（已存在则跳过）
#   ./gen-certs.sh hub.lan 192.168.1.10   # 追加 SAN（DNS/IP 自动识别）
#   FORCE=1 ./gen-certs.sh          # 强制重签（旧证书作废，客户端需重装 ca.crt）
#
# 产物（hub/tls/certs/，私钥不入库——.gitignore 挡住整个目录）：
#   ca.crt / ca.key        自签 CA（ca.crt 发给朋友装入客户端信任库即可验证）
#   server.crt / server.key  Hub 侧 HTTPS 证书（SAN 含 localhost/127.0.0.1/hub/
#                            host.docker.internal/本机名，nginx 边车终结 TLS 用）
#
# 依赖：openssl（macOS 自带 LibreSSL 亦可；无 mkcert 时的自签方案）。
set -eu

cd "$(dirname "$0")"
CERTS="$PWD/certs"
mkdir -p "$CERTS"
chmod 700 "$CERTS"

DAYS_CA="${CA_DAYS:-3650}"
DAYS_SERVER="${SERVER_DAYS:-825}"

if [ -f "$CERTS/ca.crt" ] && [ -f "$CERTS/server.crt" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "[skip] 证书已存在（FORCE=1 重签）：$CERTS"
  openssl x509 -noout -fingerprint -sha256 -in "$CERTS/ca.crt" | sed 's/^/       /'
  exit 0
fi

# ---- SAN 列表：默认 + 命令行追加 ----
SAN_LIST="DNS:localhost,DNS:hub,DNS:host.docker.internal,IP:127.0.0.1"
HN=$(hostname -s 2>/dev/null || true)
FQDN=$(hostname 2>/dev/null || true)
[ -n "$HN" ] && SAN_LIST="$SAN_LIST,DNS:$HN"
[ -n "$FQDN" ] && [ "$FQDN" != "$HN" ] && SAN_LIST="$SAN_LIST,DNS:$FQDN"
for a in "$@"; do
  case "$a" in
    DNS:*|IP:*) SAN_LIST="$SAN_LIST,$a" ;;
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) SAN_LIST="$SAN_LIST,IP:$a" ;;
    *) SAN_LIST="$SAN_LIST,DNS:$a" ;;
  esac
done
echo "[gen] SAN=$SAN_LIST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- CA（RSA-2048，自签；CA 私钥仅本机保管）----
# 密钥选型：RSA 而非 EC——实测 macOS 27 系统 curl（LibreSSL 3.3.6）对
# OpenSSL 3.x 服务端的 TLS 1.3 + ECDSA CertificateVerify 报
# `ST_CONNECT:tlsv1 alert decode error`（apple.com 等 TLS 1.3 正常，定位为
# ECDSA leaf 特有；换 RSA leaf 即通，见 W17-REPORT §5）。个人/朋友场景 RSA-2048 足够。
cat >"$TMP/ca.cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
[dn]
O = mine-input
CN = mine-input Local Hub CA
[ca_ext]
basicConstraints = critical, CA:true, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
  -keyout "$CERTS/ca.key" -out "$CERTS/ca.crt" \
  -days "$DAYS_CA" -config "$TMP/ca.cnf" -extensions ca_ext
chmod 600 "$CERTS/ca.key"
chmod 644 "$CERTS/ca.crt"

# ---- server 证书（CA 签发，RSA-2048 leaf）----
cat >"$TMP/server.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
O = mine-input
CN = hub
[req_ext]
subjectAltName = $SAN_LIST
[server_ext]
basicConstraints = CA:false
keyUsage = critical, digitalSignature, keyAgreement
extendedKeyUsage = serverAuth
subjectAltName = $SAN_LIST
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF

openssl req -new -newkey rsa:2048 -sha256 -nodes \
  -keyout "$CERTS/server.key" -out "$TMP/server.csr" \
  -config "$TMP/server.cnf" -reqexts req_ext
openssl x509 -req -in "$TMP/server.csr" \
  -CA "$CERTS/ca.crt" -CAkey "$CERTS/ca.key" -CAcreateserial \
  -out "$CERTS/server.crt" -days "$DAYS_SERVER" -sha256 \
  -extfile "$TMP/server.cnf" -extensions server_ext
chmod 600 "$CERTS/server.key"
chmod 644 "$CERTS/server.crt"

# ---- 自校验：链完整性 + SAN 回读 ----
openssl verify -CAfile "$CERTS/ca.crt" "$CERTS/server.crt"
echo "[ok] CA   $(openssl x509 -noout -fingerprint -sha256 -in "$CERTS/ca.crt")"
SAN_SHOW=$(openssl x509 -noout -text -in "$CERTS/server.crt" \
  | grep -A1 'Subject Alternative Name' | tail -1 | sed 's/^ *//')
echo "[ok] server SAN: $SAN_SHOW"
echo "[ok] 产物：${CERTS}（ca.key/server.key 0600，不入库）"
echo "[next] 客户端信任：把 ca.crt 交给客户端（curl --cacert / SDK ca_bundle）；"
echo "       起 HTTPS 边车：docker compose up -d（tls 服务）"
