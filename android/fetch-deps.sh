#!/usr/bin/env bash
# W14: 拉取 sherpa-onnx Android 预编译 AAR + tar.bz2 解压用 jar（全部 SHA256 钉死）
# 产物均为外部预编译二进制，不进 git；本脚本可复现获取。
set -euo pipefail
cd "$(dirname "$0")"

AAR=local-repo/com/k2fsa/sherpa/sherpa-onnx/2.0.1/sherpa-onnx-2.0.1.aar
mkdir -p "$(dirname "$AAR")" app/libs

curl -L --retry 3 -o "$AAR" \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-2.0.1.aar
echo "a8d09d1d32f3eb8520482c6d3d43fae674681c5b050385967c70a3c2c9bf0ee7  $AAR" | shasum -a 256 -c -

curl -L --retry 3 -o app/libs/commons-compress-1.26.2.jar \
  https://maven.aliyun.com/repository/central/org/apache/commons/commons-compress/1.26.2/commons-compress-1.26.2.jar
echo "9168a03141d8fc7eda21a2360d83cc0412bcbb1d6204d992bd48c2573cb3c6b8  app/libs/commons-compress-1.26.2.jar" | shasum -a 256 -c -

curl -L --retry 3 -o app/libs/commons-io-2.16.1.jar \
  https://maven.aliyun.com/repository/central/commons-io/commons-io/2.16.1/commons-io-2.16.1.jar
echo "f41f7baacd716896447ace9758621f62c1c6b0a91d89acee488da26fc477c84f  app/libs/commons-io-2.16.1.jar" | shasum -a 256 -c -

echo "W14 deps OK"
