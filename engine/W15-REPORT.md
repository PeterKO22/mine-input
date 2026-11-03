# W15 librime-android-poc 交付报告 — 五笔86+拼音混输引擎 Android 化 POC

> 日期：2026-11-04 ｜ 车道：W15 librime-android-poc ｜ 目录所有权：`engine/`
> 依赖上下文：W1（librime 编译 + ping_wubi_mixed schema 实测，`build/W1-REPORT.md`）、
> W5（Trime 调研 + Kotlin IMS 骨架，`android/W5-REPORT.md`）；工作约定见 `docs/开发任务计划.md` §3。

---

## 0. 一句话结论

**两条路径都实测通过后选路径 A（本阶段）：Trime v3.3.13 预编译 `librime_jni.so` 被外部 APK 复用成功——
最小 JNI demo 在 Android 模拟器（arm64-v8a, API 34）实测：w→人、gggg→王、pinyin→拼音前移、
nihao→你好、zni 反查注释=五笔码，与 W1 console 输出逐项一致（logcat 见 §2.1）；
路径 B（NDK 自编 librime）也已实测打通：华为云镜像取 NDK r21、裁剪 deps 最小构建出 librime.so（BSD-3）、
设备端 CLI demo 同样五项 ALL PASS（§1.2.1）——留作换芯演进线（可解锁 license）。**

---

## 1. 两条路径实测记录

### 1.1 路径 A（快）：Trime 发布 APK → 提取 .so + JNI 绑定 → 外部 IMS 复用验证

**提取（`bash engine/build/fetch-trime-apk.sh`）**：

| 项 | 实测值 |
|---|---|
| 来源 | `github.com/osfans/trime/releases/download/v3.3.13/com.osfans.trime-v3.3.13-0-gb5cad1a4-arm64-v8a-release.apk` |
| sha256 | `e7535ea421a2…de5020`（`engine/poc/pathA/sha256.txt`，脚本每次重算） |
| 原生库 | 仅 1 个：`lib/arm64-v8a/librime_jni.so`（5,959,312 B）——librime + opencc + leveldb + marisa 等 deps **静态合并单 .so** |
| JNI 绑定面 | `llvm-nm` 动态导出：**46 个 `Java_*` 符号**，归属 5 个类：`com.osfans.trime.core.Rime`（28 个，startup/按键/候选/部署全集）、`RimeConfig`（8）、`RimeKeyEvent`（3）、`data.opencc.OpenCCDictManager`（2）、`data.userdict.UserDictManager`（5） |
| **C API 直出** | `rime_get_api`、`RimeFindModule`、`RimeRegisterModule` 均导出 → **不走 Trime JNI 也能用自写 shim 调 librime C API**（路径 B 落地后的换芯通道） |
| 胶水类 | JNI 返回值构造依赖 `com/osfans/trime/core/{CommitProto,CandidateProto,CompositionProto,ContextProto,StatusProto,RimeResponse,Candidates$Bulk/$Paged,SchemaItem}`（.so 内 FindClass 字符串实证），这些类随 APK 的 `classes.dex` 提供 |

**复用验证（真·外部宿主）**：自建 APK `com.mineinput.engine.rimepoc`（与 Trime 无任何包名/清单关系），
仅含：demo Activity（反射驱动，无编译期依赖）+ Trime `classes.dex`（作 classes2.dex）+ `librime_jni.so`
+ 自带 ping_wubi_mixed schema/词库 assets。**装入模拟器即用，引擎全链路（设备端部署→键序列→候选）实测通过**（§2.1）。

**复用结论**：
1. **可复用**，且有两级复用面：① Trime 的 46 个 JNI 符号（照签名声明即可绑）；② `rime_get_api` C API（可自写 JNI shim，摆脱对 Trime 胶水类的依赖）。
2. 约束：JNI 符号绑定的是 Trime 的类名/构造签名（`com.osfans.trime.core.*`），复用方要么照搬这 6 个数据类（约 200 行），要么直接引它的 dex（W15 POC 即此法）；`.so` 与 dex 必须同版本配对（v3.3.13）。
3. 部署能力在 .so 内自带（设备端编译码表实测 2.3–4.5s，见 §3），无需桌面端预编译 bin。

### 1.2 路径 B（正）：镜像获取 NDK + librime-on-Android 最小构建（可裁剪 deps）

**NDK 镜像实测（2026-11-04，curl 逐个实探）**：

| 镜像 | 结果 |
|---|---|
| `dl.google.com`（官方） | 不可达（既知被墙） |
| `mirrors.cloud.tencent.com/AndroidSDK/` | **567 被 EdgeOne WAF 拦截**（GET/HEAD、带浏览器 UA 均拦，页面明示"请求已被站点的安全策略拦截"） |
| `mirrors.aliyun.com/android{-sdk,go}/…` | 404（无 android repository 镜像） |
| tuna / ustc / nju / bfsu `android/repository` | 404 / 403（无此镜像） |
| `github.com/android/ndk` releases | 只有源码 tag（r30），无预编译包 |
| **`mirrors.huaweicloud.com/android/repository/`** | ✅ 可用（dl.google.com 全量镜像），但 **NDK 封顶 r21**（2020，darwin 仅 x86_64） |

**实际获取**：`android-ndk-r21-darwin-x86_64.zip`（华为云，sha256 `b82a49ec…`）→
`bash engine/build/pathB-fetch-ndk.sh` 提取，clang 9.0.8 可运行（**需 Rosetta 2**，见 §5 环境说明）。

**最小构建脚本**：`bash engine/build/pathB-build-librime.sh`（可复现，日志 `engine/poc/pathB/logs/build-librime.log`），
裁剪面：无 glog（`-DENABLE_LOGGING=OFF`）、无 gtest（`-DBUILD_TEST=OFF`）、无插件；
交叉编译 leveldb / yaml-cpp / marisa-trie / opencc + boost::regex（librime 仅 regex 需编译库，
其余 boost 用法全是 header-only：algorithm/range/uuid/signals2/interprocess… 由源码 grep 实证）；
librime pin `e930f57b`（与 W1 同 commit）。

**实测结果（§1.2.1）**：**最小构建成功**——librime.so（ELF aarch64）+ 6 个 CLI 工具产出，
并推到模拟器（arm64-v8a, API 34）跑了 CLI demo：**w→人、gggg→王、pinyin→拼音前移、
nihao→你好、zni→反查注释=五笔码，五项断言 ALL PASS**（与路径 A / W1 输出一致）。

#### 1.2.1 路径 B 构建与设备端实测记录

**构建产物（`bash engine/build/pathB-build-librime.sh`，日志 `engine/poc/pathB/logs/build-librime.log`）**：
- 依赖裁剪实况：boost::regex（源码 tarball 自编静态库）+ leveldb + yaml-cpp + marisa-trie + opencc（仅库）
  + `libcpfs.a`（libc++ filesystem 补库，见坑 3）；glog/gtest/插件全裁。
- 产物（`file` 实证）：`librime.so`（ELF 64-bit ARM aarch64）、`rime_api_console`、`rime_deployer`、
  `rime_console`、`rime_dict_manager`、`rime_patch`、`rime_table_decompiler`（均为 Android 可执行）。
- librime pin `e930f57b`（与 W1 同 commit），`-DENABLE_LOGGING=OFF -DBUILD_TEST=OFF`，API=29，STL=c++_static。

**踩坑清单（全部已在脚本内修复，重跑可过）**：
1. **NDK r21 的 `aarch64-linux-android-ar/ranlib` 包装器在 Rosetta 2 下必崩**（`libc++abi: typed operator new… Subprocess aborted`），同套件 `llvm-ar/llvm-ranlib` 正常 → `engine/build/android-arfix.toolchain.cmake` 在官方 toolchain include 后强制改写两个工具路径。
2. **yaml-cpp（librime pin 版）的 dragonbox.h 在 clang 9 下报模板重定义**（`redefinition of 'cache' with a different type`）→ 统一 `-DCMAKE_CXX_STANDARD=17`（启用 inline variables，跳过有 bug 的类外定义）。
3. **NDK r21 的 `libc++_static.a` 不含任何 `std::filesystem` 符号**（`llvm-nm` 计数=0），而 librime 需要 → 编译 LLVM 9（与 r21 clang 匹配）`libcxx/src/filesystem/{operations,directory_iterator,int128_builtins}.cpp` 成 `libcpfs.a` 随链接。
4. **opencc 的 `data/*.ocd2` 构建需要宿主工具 `opencc_dict`**（交叉产物是 ARM 二进制，macOS 跑不了）→ 只建 `libopencc.a`+头文件；本 schema 不挂 simplifier，运行期不需要 opencc 数据。
5. Rosetta 偶发 `Subprocess aborted`（llvm-ar 竞态）→ `build_retry` 重试包装（实测 1–2 次重试即过）。
6. 小坑：bash 的 `$var（` 全角括号会吞进变量名（`unbound variable`）→ 全部 `${var}` 花括号化。

**设备端 CLI demo 实测（`bash engine/build/pathB-run-cli-demo.sh`，模拟器 Pixel_6_API_34 arm64-v8a）**：
```
$ adb push librime.so rime_deployer rime_api_console + schema/* → /data/local/tmp/w15pathb
$ LD_LIBRARY_PATH=. ./rime_deployer --build .        # 设备端编译 wubi86/pinyin_simp 码表
message: [0] [deploy] start / success
$ ./rime_api_console（键序列与 build/verify-schema.sh 相同）
[w]|            → 1. [人]   2.  他 ~b  3.  个 ~h …（五笔一级简码，形码优先）
[gggg]|         → 1. [王]   2.  五一  3.  琵琶  4.  龶 …（五笔全码）
[pin yin]|      → 1. [拼音] 2.  宵憱 ☯ 3.  品 …（无五笔命中→拼音前移）
[ni hao]|       → 1. [你好] 2.  悄虚 ☯ 3.  你 …（拼音词组）
[z ni]|〔反查〕 → …5.  你 wq wqi wqiy  6.  拟 rny rnyw  7.  尼 nx nxv  8.  呢 knx knxn
```
断言脚本重跑：**ALL PASS**（完整输出存档 `engine/poc/logs/pathb-cli-demo.log`）。

### 1.3 选型结论：**路径 A**（本期接线），路径 B 已打通、留作换芯演进线

两条路径的验收输出都实测达成（A=JNI/logcat，B=CLI），差异在交付面与许可：

| 维度 | 路径 A | 路径 B |
|---|---|---|
| demo 实测 | ✅ 五项验收全过（JNI→logcat） | ✅ 五项验收全过（C API→CLI） |
| JNI 面 | ✅ 46 个现成 JNI 符号，可直接接 android/ | ⚠️ 尚无 JNI shim（需自写 ~100 行 C，NDK 构建链已就绪） |
| 工期/成本 | 分钟级（9MB APK + 打包脚本） | 小时级（NDK 1GB + boost/deps/librime 交叉编译，一次性） |
| 可维护性 | 受 Trime 版本绑定（.so+dex 同版本配对） | 自持构建链，可 pin、可裁剪、可复现 |
| 许可 | **GPLv3**（衍生须同权开源） | librime BSD-3 + deps 全宽松许可 → android/ 可保留闭源选择权 |

**选 A 的理由**：① W5 落点（`MineImeService.candidates()/onLetter`）需要的是现成 JNI 面，A 直接可接、demo 已用真 JNI 验收；② GPLv3 在本项目个人分发场景可接受（§6）；③ A 不堵死 B——`librime_jni.so` 直出 `rime_get_api`，且 B 的自编 `librime.so` 已在设备实测通过，日后按接线草案 1c 写 shim 即可**原位换芯**解锁许可。
**B 的定位**：构建链已固化为可复现脚本（`pathB-*.sh`），是 license/自主可控诉求落地时的既定路线，不是实验。

---

## 2. 最小 JNI demo（engine/poc/harness/）

- **形态**：Android APK `com.mineinput.engine.rimepoc`（minSdk 29，无任何 Trime 清单/组件），
  `RimePocActivity` 以反射驱动 `com.osfans.trime.core.Rime` 的静态 JNI 方法——
  证明外部 IMS 只需认这套签名，无需链接 Trime 工程。
- **数据流**：assets 里的 `ping_wubi_mixed.schema.yaml` + `wubi86.dict.yaml` + `pinyin_simp.{schema,dict}.yaml`
  + `default.yaml`/`key_bindings`/`punctuation`/`symbols`/`custom_phrase.txt`（与 `build/verify-schema.sh` 同一套）
  → 拷入应用私有目录 → `startupRime(shared, user, "w15-poc", fullCheck=true)` 设备端部署 →
  `selectRimeSchema("ping_wubi_mixed")` → `simulateRimeKeySequence(seq)` → `getRimeCandidates(0,8)` → logcat。
- **设备端部署实证**（run-as 读回）：`files/rime_user/build/` 内含
  `wubi86.{table,prism,reverse}.bin`、`pinyin_simp.{table,prism,reverse}.bin`——码表是 **Android 端编译**的，
  与 W1 桌面产物无关；userdb（`wubi86.userdb` 等）亦在设备生成。

### 2.1 demo 实测输出（模拟器 Pixel_6_API_34 arm64-v8a，logcat tag=W15POC）

```
W15POC: startupRime returned in 211ms (deploy may be async)
W15POC: selectRimeSchema(ping_wubi_mixed)=true current=ping_wubi_mixed deployTotal=2287ms
W15POC: RESULT|seq=w|input=w|n=8|1=人()|2=他(~b)|3=个(~h)|4=会(~f)|5=全(~g)|6=公(~c)|7=代(~a)|8=仍(~e)
W15POC: RESULT|seq=gggg|input=gggg|n=8|1=王()|2=五一()|3=琵琶()|4=龶()|5=广告广告()|6=广告()|7=刚刚()|8=哥哥()
W15POC: RESULT|seq=pinyin|input=pinyin|n=8|1=拼音()|2=宵憱( ☯ )|3=品()|4=拼()|5=频()|6=贫()|7=聘()|8=嫔()
W15POC: RESULT|seq=nihao|input=nihao|n=8|1=你好()|2=悄虚( ☯ )|3=你()|4=拟()|5=尼()|6=呢()|7=泥()|8=妳()
W15POC: RESULT|seq=zni|input=zni|n=8|1=找你()|2=祝你()|3=阻尼()|4=珍妮()|5=你(wq wqi wqiy)|6=拟(rny rnyw)|7=尼(nx nxv)|8=呢(knx knxn)
W15POC: DONE all cases ok, total=2299ms
```

验收对照（与 `build/W1-REPORT.md` §3.1 console 输出逐项一致）：

| 用例 | 期望 | 实测 | 判定 |
|---|---|---|---|
| `w` | 五笔一级简码→**人**（形码优先） | `1=人` | ✅ |
| `gggg` | 五笔全码→**王** | `1=王`（五一/琵琶/龶…同 W1） | ✅ |
| `pinyin` | 无五笔命中→**拼音**前移 | `1=拼音`（第 2 位 `宵憱 ☯` 为 wubi 生造句噪音，同 W1 遗留 1） | ✅ |
| `nihao` | 拼音词组→**你好** | `1=你好` | ✅ |
| `zni` | 反查注释=五笔编码 | `你(wq wqi wqiy)`、`拟(rny rnyw)`… | ✅ |

断言脚本 `bash engine/build/run-poc-demo.sh` 重跑：**ALL PASS**（完整 logcat 存档
`engine/poc/logs/demo-logcat.txt`）。首跑（冷部署）实测：`deployTotal=4485ms`，其后增量 ~2.3s。

---

## 3. 构建脚本一览（engine/build/，全部可复现重跑）

| 脚本 | 作用 | 重跑 |
|---|---|---|
| `fetch-trime-apk.sh` | 下载 pin v3.3.13 APK + sha256 + 提取 .so + `llvm-nm` JNI 符号清单 | ✓（幂等） |
| `build-poc-apk.sh` | 组装 demo APK（javac+d8+aapt2+zipalign+apksigner，零 Gradle；合入 Trime dex/.so + schema assets） | ✓ |
| `run-poc-demo.sh` | 安装→运行→收 logcat→五项断言（w/gggg/pinyin/nihao/zni） | ✓ |
| `pathB-fetch-ndk.sh` | 镜像获取 NDK r21（华为云）+ sha256 + 解压 | ✓ |
| `pathB-build-librime.sh` | librime-on-Android 最小构建（boost::regex + 4 deps + libcpfs + librime，裁剪 glog/gtest/插件） | ✓（日志 `poc/pathB/logs/`） |
| `pathB-run-cli-demo.sh` | 自编 librime 推设备 + 设备端部署 + CLI 五项断言 | ✓ |
| `android-arfix.toolchain.cmake` | NDK r21 AR/RANLIB 崩溃修复的 toolchain 包装（被 pathB-build 引用） | — |

不入仓（`.gitignore`，脚本可再生）：`poc/pathA/`（APK/提取物）、`poc/pathB/`（NDK/boost/源码/产物）、
`poc/build/`、`poc/out/`。入仓：`poc/harness/`（demo 源码+清单）、`poc/logs/demo-logcat.txt`（验收证据）。

---

## 4. android/ 骨架接线草案（仅草案，不实施）

完整版：**`engine/docs/android-wiring-draft.md`**。要点：

- **接口**：`MixedInputEngine` 契约（`startup/selectSchema/onLetter/onKey/candidates/commit/clear/shutdown`），
  W5 的 `MineImeService.candidates()/onLetter` 落点直接对接；PTT（FR2）不动。
- **实现体**：`TrimeRimeBridge`（32 个 `external` 静态方法签名 + 6 个 Proto 数据类，类名须与
  `com.osfans.trime.core.*` 严格一致以绑定 JNI 符号）。
- **步骤**：`.so` 入 `jniLibs/arm64-v8a` → 胶水层复刻（或引 dex）→ 首启 IO 线程部署（`assets/rime/*`）
  → 候选/上屏/退格接线 → **单线程 executor 串行化所有 native 调用**（librime 无内部锁）→ 回归用例复用 W15 断言。
- **许可**：接线后 android/ 端衍生部分转 **GPLv3**（W5 §1.4 已预告；个人分发可接受）；闭源路线=自写 JNI shim + 自编 BSD-3 librime。

---

## 5. 环境说明（按工作约定 §3-5 注明）

- **全局安装（本车道唯一）**：**Rosetta 2**（`softwareupdate --install-rosetta --agree-to-license`）——
  NDK r21 darwin 包仅 x86_64，本机（Apple Silicon）此前未装 Rosetta 无法执行；安装后 x86_64 工具链经
  Rosetta 2 正常运行。卸载方式：`sudo rm -rf /Library/Apple/usr/libexec/oah`（一般无需）。
- **未动**：`android/`、`core/`、`schema/`、`build/` 均未修改（只读引用 W1 产物与 schema 文件）；
  模拟器复用 W5 已有 Pixel_6_API_34（adb install / am start / logcat，未用 computer_use）。
- **网络**：GitHub release 下载、archives.boost.io、mirrors.huaweicloud.com 实测可达；
  `dl.google.com` 不可达、腾讯镜像被 WAF 拦（§1.2 表）。

---

## 6. License 合规

| 产物 | 上游许可 | 对本项目的影响 |
|---|---|---|
| `librime_jni.so`（Trime 预编译，含 librime+deps） | Trime JNI 层 **GPL-3.0-or-later**；librime 本体 BSD-3-Clause；opencc Apache-2.0；leveldb/marisa/yaml-cpp BSD/MIT 等 | **复用 Trime 产物 → 本项目衍生部分须 GPLv3**（含 android/ 端、demo、接线后的 IMS）；个人分发可接受，报告在此明示 |
| Trime `classes.dex`（胶水类） | GPL-3.0-or-later（源码 SPDX 头实证） | 同上；1a 复刻方案=衍生，仍须 GPLv3 |
| `ping_wubi_mixed` schema + 词库（rime-wubi / rime-pinyin-simp / rime-prelude） | 上游 RIME 数据许可（W1 已 pin commit） | 随 GPLv3 包一并分发，保留署名 |
| 路径 B 自编 librime（演进线） | librime BSD-3-Clause | 自写 JNI shim 后 android/ 可不背 GPL——**唯一保留闭源选择权的路线** |

## 7. 遗留与 blocker

1. **路径 B 的 JNI shim 未实施**（本期只验到 CLI）：自写 ~100 行 C shim 调 `rime_get_api`（NDK 构建链已就绪、librime.so 已设备实测）是换芯解锁许可的最后一步；接口签名见接线草案 1c。
2. **路径 A 的版本绑定**：`librime_jni.so` + Trime `classes.dex` 必须同版本配对（v3.3.13）；升级 Trime 需重跑 `fetch-trime-apk.sh` + 回归 `run-poc-demo.sh`。
3. **NDK 只能拿到 r21（2020）**：国内镜像封顶（腾讯被 WAF 拦、阿里无镜像、华为只有 ≤r21）；r21 的三个坑（AR 包装器崩溃 / libc++ 无 filesystem / yaml-cpp 需 C++17）已绕过并写进脚本，但若能拿到 r23+ 可删掉 libcpfs 与 arfix。需要什么：一个可达的 dl.google.com 代理或新版 NDK 镜像源。
4. **路径 B 产物未 strip**（`librime.so` 78MB 含 debug_info）：接线前 `llvm-strip` 一下即可（预计 <5MB）。
5. **opencc 数据未交叉构建**（`data/*.ocd2` 需宿主 `opencc_dict`）：本 schema 不用 simplifier 无影响；未来要用时从 Trime assets 取 opencc 数据（W15 已验证该来源）或宿主机先编一份 opencc 工具。
6. **wubi 句子噪音与 z 反查重叠**：沿袭 W1 遗留 1/2（`pinyin` 第 2 位 `宵憱 ☯`、`zni` 混入拼音缩写短语），schema 级可热调，不在本车道范围。
7. **未动 android/ 与 core/**：接线草案（`engine/docs/android-wiring-draft.md`）仅文档，未实施；android/ 接线后按 §6 转 GPLv3。
8. **全局安装（工作约定 §3-5）**：Rosetta 2（见 §5）；另 brew boost 1.92 为 W1 遗留全局安装（本车道未新装 brew 包）。
