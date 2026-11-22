#!/usr/bin/env bash
# W32 稳定签名证书（幂等）：生成自签名代码签名证书「Mine Input Dev」并导入 login keychain。
#
# 用途：dev 装机版（build/install-dev.sh）用证书签名代替 ad-hoc——designated requirement
# 锚定 identifier + certificate（非 cdhash），TCC 录屏/麦克风授权跨重装/重建存活
#（ad-hoc 的 cdhash 每次安装都变 → 「Failed to match existing code requirement」
#  永远弹窗——W27 弹窗风暴事故根因，见 macos/W32-REPORT.md）。
#
# 幂等：签名身份「Mine Input Dev」已在 keychain 中为有效 codesigning 身份 → 直接跳过。
# 证书规格：CN=Mine Input Dev、RSA 2048/SHA-256、extendedKeyUsage=codeSigning、
#           有效期 3650 天（10 年）。
#
# 首次用该证书签名（install-dev.sh）时 macOS 可能弹「codesign 想使用密钥」——
# 点一次「始终允许」即可（见 docs/dev-signing-setup.md）。
#
# 用法：bash scripts/make-dev-cert.sh
set -euo pipefail

CN="Mine Input Dev"
DAYS=3650   # 10 年
KEYCHAIN="${LOGIN_KEYCHAIN:-login.keychain-db}"

# ---- 1) 幂等检查：已有该 codesigning 身份即跳过 ----
# 注意：自签证书在 find-identity 显示 CSSMERR_TP_NOT_TRUSTED（正常，本机既有
# 本地开发签名证书同状态；codesign 签名与 designated requirement 锚定不受影响），
# 因此用全量列表（不带 -v）匹配，带 -v 的「valid identities only」会漏掉。
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CN\""; then
  echo "已有签名身份「${CN}」——跳过生成（幂等）。当前身份："
  security find-identity -p codesigning | grep "\"$CN\"" || true
  exit 0
fi

# ---- 2) openssl 生成自签名证书（codeSigning EKU，10 年）----
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# 扩展走配置文件（兼容 LibreSSL/OpenSSL 各版本；-addext 不通用）
cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CN
[ext]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical,CA:false
subjectKeyIdentifier = hash
EOF
openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days "$DAYS" -config "$WORK/openssl.cnf"
echo "已生成自签名证书：CN=$CN codeSigning EKU 有效期 ${DAYS} 天"

# ---- 3) 打包 PKCS#12 → 导入 login keychain（-T /usr/bin/codesign 允许 codesign 用该密钥）----
# p12 用一次性口令（macOS security import 对空口令 p12 报
# "The user name or passphrase you entered is not correct"——实测坑）；口令随临时目录即弃。
P12_PASS="w32-import-$$"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -out "$WORK/dev-cert.p12" -passout "pass:$P12_PASS" -name "$CN"
security import "$WORK/dev-cert.p12" -k "$KEYCHAIN" -T /usr/bin/codesign -f pkcs12 -P "$P12_PASS"
echo "已导入 keychain：$KEYCHAIN（codesign 授权 -T /usr/bin/codesign）"

# ---- 4) 验证 ----
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$CN\""; then
  echo "OK: 签名身份「${CN}」就绪："
  security find-identity -p codesigning | grep "\"$CN\"" || true
  echo "下一步：bash build/install-dev.sh（将以「${CN}」签名装机副本；首次签名若弹"
  echo "  「codesign 想使用密钥」→ 点一次「始终允许」）"
else
  echo "ERROR: 导入后未找到签名身份「${CN}」——请检查 keychain（钥匙串访问 → 登录 → 证书）" >&2
  exit 1
fi
