# mine-input Android 端许可说明（W16 起）

自 W16 接入 Trime v3.3.13 预编译 `librime_jni.so`（含其 JNI 胶水层的复刻类）后，
**本 android/ 目录的衍生部分按 GPL-3.0-or-later 发布**（个人分发可接受；W5 §1.4 已预告、
W15 §6 选型结论明确）。

## 复用产物与上游许可

| 产物 | 上游 | 许可 |
|---|---|---|
| `app/src/main/jniLibs/arm64-v8a/librime_jni.so`（fetch-rime-jni.sh 提取，不进 git） | osfans/trime v3.3.13 release APK | Trime JNI 层 **GPL-3.0-or-later**；内含 librime（BSD-3-Clause）、opencc（Apache-2.0）、leveldb/marisa/yaml-cpp（BSD/MIT）等 |
| `app/src/main/java/com/osfans/trime/core/*.kt`（W16 胶水类复刻） | Trime v3.3.13 `core/Rime.kt`、`RimeProto.kt`、`SchemaItem.kt`、`RimeKeyEvent.kt` | **GPL-3.0-or-later**（SPDX 头保留） |
| `app/src/main/assets/rime/*`（构建期同步自仓内 `schema/`） | rime-wubi / rime-pinyin-simp / rime-prelude | 上游 RIME 数据许可（见 schema/ 各文件头），随包分发保留署名 |

## 换芯路线（保留闭源选择权）

`librime_jni.so` 直出 `rime_get_api` C 符号；接线草案 1c（自写 JNI shim）+ W15 路径 B
自编 librime（BSD-3-Clause，`engine/build/pathB-*.sh` 构建链已固化）可**原位换芯**，
届时 android/ 可不背 GPL（见 `engine/docs/android-wiring-draft.md` §1）。

完整 GPL-3.0 文本：https://www.gnu.org/licenses/gpl-3.0.html
