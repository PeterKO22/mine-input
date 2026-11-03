#!/usr/bin/env bash
# W15 路径 A：构建「外部 IMS 复用 Trime librime_jni.so」最小 demo APK。
# 仅用 Android SDK 命令行工具（javac/d8/aapt2/zipalign/apksigner），不引 Gradle/AGP，可复现。
# 产物：engine/poc/out/w15-rime-poc.apk
#   classes.dex     = 本 demo 的 Activity（反射驱动 JNI 胶水类）
#   classes2.dex    = Trime v3.3.13 的 classes.dex（提供 com.osfans.trime.core.* JNI 胶水类）
#   lib/arm64-v8a/librime_jni.so = Trime 预编译 librime（含 rime_get_api，静态合并全部 deps）
set -euo pipefail

ENGINE="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ENGINE/.." && pwd)"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
BT="$SDK/build-tools/37.0.0"
ANDROID_JAR="$SDK/platforms/android-37/android.jar"
TRIME_DIR="$ENGINE/poc/pathA"
TRIME_APK="$TRIME_DIR"/com.osfans.trime-v3.3.13-*.apk
EXTRACT="$TRIME_DIR/apk_extracted"
HARNESS="$ENGINE/poc/harness"
WORK="$ENGINE/poc/build"
OUT="$ENGINE/poc/out"

for f in "$BT/d8" "$BT/aapt2" "$BT/zipalign" "$BT/apksigner" "$ANDROID_JAR"; do
  [ -e "$f" ] || { echo "missing tool: $f"; exit 1; }
done
ls $TRIME_APK >/dev/null 2>&1 || { echo "missing Trime APK —— 先跑 bash engine/build/fetch-trime-apk.sh"; exit 1; }
[ -d "$EXTRACT/lib/arm64-v8a" ] || { echo "missing $EXTRACT —— 先跑 fetch-trime-apk.sh"; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"/{classes,dex,assets,stage}

echo "== [1/4] 装配 RIME 数据（assets/rime/shared + assets/rime/user） =="
# 与 build/verify-schema.sh 同一套文件：schema + 词库 → shared，custom_phrase → user
cp "$REPO/schema/default.yaml" "$REPO/schema/ping_wubi_mixed.schema.yaml" "$WORK/assets/" 2>/dev/null || true
mkdir -p "$WORK/assets/rime/shared" "$WORK/assets/rime/user"
cp "$REPO/schema/default.yaml" "$REPO/schema/ping_wubi_mixed.schema.yaml" "$WORK/assets/rime/shared/"
cp "$REPO"/schema/deps/*.yaml "$WORK/assets/rime/shared/"
cp "$REPO/schema/custom_phrase.txt" "$WORK/assets/rime/user/"
rm -f "$WORK/assets/default.yaml" "$WORK/assets/ping_wubi_mixed.schema.yaml"  # 清理上面的误拷
ls "$WORK/assets/rime/shared" "$WORK/assets/rime/user"

echo "== [2/4] javac + d8（demo Activity）=="
javac -classpath "$ANDROID_JAR" -d "$WORK/classes" \
  "$HARNESS/src/com/mineinput/engine/rimepoc/RimePocActivity.java"
"$BT/d8" --lib "$ANDROID_JAR" --min-api 29 --output "$WORK/dex" "$WORK/classes/com/mineinput/engine/rimepoc/RimePocActivity.class"
ls -la "$WORK/dex"

echo "== [3/4] aapt2 link + 合入 Trime dex 与 librime_jni.so =="
"$BT/aapt2" link -o "$WORK/base.apk" \
  --manifest "$HARNESS/AndroidManifest.xml" \
  -I "$ANDROID_JAR" \
  --min-sdk-version 29 --target-sdk-version 34 \
  -A "$WORK/assets"
mkdir -p "$WORK/stage/lib/arm64-v8a"
cp "$WORK/dex/classes.dex" "$WORK/stage/classes.dex"
cp "$EXTRACT/classes.dex" "$WORK/stage/classes2.dex"
cp "$EXTRACT/lib/arm64-v8a/librime_jni.so" "$WORK/stage/lib/arm64-v8a/"
cp "$WORK/base.apk" "$WORK/app-unsigned.apk"
(cd "$WORK/stage" && zip -q -X ../app-unsigned.apk classes.dex classes2.dex lib/arm64-v8a/librime_jni.so)

echo "== [4/4] zipalign + debug 签名 =="
"$BT/zipalign" -f -p 4 "$WORK/app-unsigned.apk" "$WORK/app-aligned.apk"
KS="$HOME/.android/debug.keystore"
[ -f "$KS" ] || keytool -genkeypair -keystore "$KS" -storepass android -keypass android \
  -alias androiddebugkey -dname "CN=Android Debug,O=Android,C=US" -keyalg RSA -validity 10000
mkdir -p "$OUT"
"$BT/apksigner" sign --ks "$KS" --ks-pass pass:android --key-pass pass:android \
  --out "$OUT/w15-rime-poc.apk" "$WORK/app-aligned.apk"
"$BT/apksigner" verify "$OUT/w15-rime-poc.apk" && echo "signed OK"
ls -la "$OUT/w15-rime-poc.apk"
echo "== build-poc-apk done =="
