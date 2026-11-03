# W16 android-engine · 混输引擎真接 Android IMS — 交付报告

> 日期：2026-11-04 ｜ 车道：W16 android-engine ｜ 目录所有权：`android/`（engine/ 只读引用）
> 依据：`engine/docs/android-wiring-draft.md`（接线草案，1a 胶水类复刻）、`engine/W15-REPORT.md`（路径 A 实测）、
> `android/W5|W11|W14-REPORT.md`（IMS 骨架/commit 通道/DebugReceiver 钩子）、`build/W1-REPORT.md` + `schema/`（schema 打包）。
> 环境：macOS 27.0.1，emulator-5554（Pixel_6_API_34，arm64-v8a），JAVA_HOME=/opt/homebrew/opt/openjdk@17。

---

## 0. 一句话结论

**W15 验证过的混输引擎已按接线草案 1a 真接进 `MineImeService`：Trime v3.3.13 `librime_jni.so` + 复刻 JNI 胶水（GPLv3），
ping_wubi_mixed schema 随 app 部署、首用设备端编译码表 634ms（≤5s ✅）；候选栏真数据五项断言与 W1 逐项一致
（w→人 / gggg→王 / pinyin→拼音前移 / nihao→你好 / zni 反查注释=五笔码）；选词上屏走 W5 commit 通道
（真输入框 via=input-connection 实证）；L1 词频/造词生效（打过的词二次直达 rank3→rank1，encode_commit_history
造词成句候选）；NFR1 按键→候选实测 avg 0.181ms / p95 0.287ms / max 0.640ms（≤30ms ✅）；
e2e（`python3 android/w16-e2e.py`）**PASS=20 FAIL=0，exit 0**。**

---

## 1. 接线实现（对齐 `engine/docs/android-wiring-draft.md`）

### 1.1 交付形态：1a 胶水类复刻（比 W15 POC 的 1b 引 dex 更干净——**不需要 Trime classes.dex**）

JNI 绑定契约不是猜的，是三重实证后复刻的：
1. **Trime v3.3.13 源码**（codeload tarball 提取 `app/src/main/jni/librime_jni/{jni-utils.h,objconv.h,rime_jni.cc}` +
   `core/{Rime.kt,RimeProto.kt,SchemaItem.kt,RimeKeyEvent.kt}`）——`GlobalRefSingleton` 明列 FindClass/GetMethodID 全部签名；
2. **`librime_jni.so` 字符串面**（`strings` 实证 .so 内嵌的 ctor 签名与源码一致）；
3. **Trime classes.dex dexdump**（28 个 `PUBLIC STATIC FINAL NATIVE` 方法签名逐一核对）。

复刻产物（`android/app/src/main/java/com/osfans/trime/core/`，GPL-3.0-or-later，SPDX 头保留）：

| 文件 | 契约（勿改） | 依据 |
|---|---|---|
| `Rime.kt` | 28 个 `@JvmStatic external`（`startupRime/processRimeKey/getRimeCandidates/selectRimeCandidate/getRimeCommit/…`）+ **静态** `handleRimeMessage(I[Ljava/lang/Object;)V`（JNI 回调，GetStaticMethodID 在 `JNI_OnLoad` 即取，缺失=库加载失败） | rime_jni.cc + jni-utils.h |
| `RimeProto.kt` | `CommitProto(String?)`／`CandidateProto(String,String,String)`／`CompositionProto(IIII,String?,String?)`／`ContextProto(CompositionProto,String,int)`／`StatusProto(String,String,ZZZZZZZ)`／`Candidates$Paged(ZZZI,[])`／`Candidates$Bulk(II,[])`／`RimeResponse(…)`——参数顺序逐一对 RimeProto.kt | objconv.h NewObject 调用点 |
| `SchemaItem.kt` | `SchemaItem(String,String)` | 同上 |
| `RimeKeyEvent.kt` | `RimeKeyEvent(int,int,String)`（JNI_OnLoad 会 GetMethodID 该 ctor，缺则加载失败） | jni-utils.h |

注意点（都已落实）：`CommitProto.text`/`CompositionProto.preedit|commitTextPreview` 必须可空（JNI 可能传 null，
Kotlin 非空参数的 null 检查会炸）；`System.loadLibrary("rime_jni")` 触发 `JNI_OnLoad` → 一次性 FindClass 全部 11 个胶水类，
故胶水类必须先于首次调用存在于 APK（dexdump 已核对 `classes7.dex` 中 `handleRimeMessage` 为 PUBLIC STATIC FINAL、
`startupRime` 为 PUBLIC STATIC FINAL NATIVE，与 Trime dex 完全同形）。

### 1.2 引擎层（`android/app/src/main/java/com/mineinput/ime/engine/`）

| 文件 | 职责 |
|---|---|
| `MixedInputEngine.kt` | 接线草案 §2 契约（`EngineCandidate/EngineStatus` + `startup/selectSchema/onLetter/onKey/candidates/commit/drainCommit/rawInput/status/clear/shutdown`）。与草案的差异：无 kotlinx-coroutines（工程零第三方依赖），`startup` 为阻塞语义（调用方放 IO 线程） |
| `RimeMixedEngine.kt` | librime 实现：**单线程 executor 串行化全部 native 调用**（草案 §5，librime 无内部锁）；`onLetter`=processRimeKey(字母 keysym)+getRimeCandidates；`commit`=selectRimeCandidate(false)+getRimeCommit（取不到再 commitRimeComposition 兜底）；startup 轮询 selectRimeSchema 至部署完成 |
| `MixedEngine.kt` | 进程级单例（IMS 与钩子共用）：assets/rime 落盘（**只补缺失文件，保护 userdb 学习数据**）→ 首用 `fullCheck=true`（设备端编译码表）/ 二次 `false` → 阻塞至 ready；记录 deploy_ms/deploy 通知 |
| `W16Debug.kt` | (d) 测试钩子：`w16_startup/w16_status/w16_seq/w16_commit/w16_learn/w16_bench`（tag=W16） |

### 1.3 MineImeService 落点（W5 骨架接线点，PTT/W11 不动）

| 落点 | 接线后行为 |
|---|---|
| `onCreate` | IO 线程 `MixedEngine.ensureStarted`（首启部署不阻塞 UI） |
| `onLetter` | `engine.onLetter` → `drainCommit`（自动上屏兜底）→ preedit=rawInput → 候选栏刷新 |
| `onDelete/onEnter/onSpace` | 退格=`processRimeKey(XK_BackSpace)`；回车/空格保持 W5 语义（上屏原始码，空码顶字=关） |
| `onCandidate(i)` | `engine.commit(i)` → **W5 commit 通道** `commitText` → W11 `learnAndReport`（candidate_pick） |
| `candidates()` | 真数据：`engine.candidates(0,8)`，comment 非空显示「text · comment」（如 `你 · wq wqiy`） |

### 1.4 schema 随 app 部署 + .so 落位

- **schema**：`app/build.gradle.kts` 新增 `syncRimeAssets`（Copy，preBuild 依赖）——构建期从仓内 `schema/`（单一事实源）
  同步 `default.yaml + ping_wubi_mixed.schema.yaml + deps/*.yaml` → `assets/rime/shared/`，`custom_phrase.txt` → `assets/rime/user/`，
  共 9 文件（wubi86.dict.yaml 2.2MB + pinyin_simp.dict.yaml 1.2MB）进 APK（unzip 实证）。
  AGP 9 坑：SourceSet API 拒收 Provider（`assets.srcDir(layout.buildDirectory.dir(...))` 报错），须传静态路径 + preBuild 显式携带任务依赖。
- **librime_jni.so**：`bash android/fetch-rime-jni.sh` 从 `engine/poc/pathA/apk_extracted/`（缺失则自动重跑
  `engine/build/fetch-trime-apk.sh`）幂等落位 `app/src/main/jniLibs/arm64-v8a/`，sha256 `46d348441416a6cc51a7a3ed2f123d68af358d761df28d70ba9bbac407e015a2`
  （5,959,312 B，与 W15 一致）；外部预编译产物不进 git（`.gitignore`，同 W14 fetch-deps.sh 惯例）。

---

## 2. 验收实测（assembleDebug + e2e）

### 2.1 构建（`cd android && ./gradlew clean assembleDebug`）

```
BUILD SUCCESSFUL in 2s
38 actionable tasks: 38 executed
```
- APK：`android/app/build/outputs/apk/debug/app-debug.apk`（139,058,748 B）
  含 `lib/arm64-v8a/librime_jni.so`（5,959,312 B）+ `assets/rime/shared/*`（8 文件）+ `assets/rime/user/custom_phrase.txt`（unzip 实证）；
  `versionName=0.4.0-w16`。

### 2.2 e2e（`python3 android/w16-e2e.py`，最终一跑全文；adb 键序列 + DebugReceiver 钩子断言）

```
=== 0. 环境：安装 APK + 清数据（首次启动） + 启用 IME ===
  [PASS] adb install  Success

=== 1. 首用部署：ping_wubi_mixed 设备端编译码表（≤5s） ===
  [PASS] 引擎启动 + schema 可选中（STARTUP ok）  W16 : STARTUP|ok=true|deploy_ms=634|first_run=true|schema=ping_wubi_mixed
  [PASS] 首用部署 ≤5s（NFR 验收项）  deploy_ms=634
  [PASS] 首用口径 first_run=true  STARTUP|ok=true|deploy_ms=634|first_run=true|schema=ping_wubi_mixed
  [PASS] w16_status 引擎就绪（schema=ping_wubi_mixed）  ...|deploy_ms=634|first_run=true|deploy_msgs=3:start 3:success 2:_auto_commit 2:!ascii_mode 1:ping_wubi_mixed/拼音五笔混合·dev

=== 2. 候选真数据断言（w→人 / gggg→王 / pinyin→拼音前移 / nihao→你好 / zni 反查） ===
  [PASS] w → 人  RESULT|seq=w|input=w|n=8|1=人()|2=他(~b)|3=个(~h)|4=会(~f)|5=全(~g)|6=公(~c)|7=代(~a)|8=仍(~e)
  [PASS] gggg → 王  RESULT|seq=gggg|input=gggg|n=8|1=王()|2=五一()|3=琵琶()|4=龶()|5=广告广告()|6=广告()|7=刚刚()|8=哥哥()
  [PASS] pinyin → 拼音  RESULT|seq=pinyin|input=pinyin|n=8|1=拼音()|2=宵憱( ☯ )|3=品()|4=拼()|5=频()|6=贫()|7=聘()|8=嫔()
  [PASS] nihao → 你好  RESULT|seq=nihao|input=nihao|n=8|1=你好()|2=悄虚( ☯ )|3=你()|4=拟()|5=尼()|6=呢()|7=泥()|8=妳()
  [PASS] zni 反查注释含五笔编码  RESULT|seq=zni|input=zni|n=8|1=找你()|2=祝你()|3=阻尼()|4=珍妮()|5=你(wq wqi wqiy)|6=拟(rny rnyw)|7=尼(nx nxv)|8=呢(knx knxn)

=== 3. 真输入框：选词上屏（W5 commit 通道，via=input-connection） ===
  [PASS] 找到可输入框（EditText）
  [PASS] IME 已绑定输入框
  [PASS] gggg 选第 1 候选 → 王（engine.commit）  COMMIT|seq=gggg|index=0|picked=王|text=王|via=input-connection|expect=王|match=true
  [PASS] 经 W5 commit 通道上屏（via=input-connection）  COMMIT|seq=gggg|index=0|picked=王|text=王|via=input-connection|expect=王|match=true
  [PASS] 上屏记录：输入框含「王」

=== 4. L1 词频/造词：打过的词二次直达 + 造词成句候选 ===
  [PASS] 词频学习：点选候选 A 后重打同码 → A 直达首位（LEARN direct）  LEARN|seq=gggg|index=2|picked=琵琶|before_rank=3|after_rank=1|direct=true|after1=琵琶|before=王,五一,琵琶,龶,广告广告,广告,刚刚,哥哥|after=琵琶,王,五一,龶,王琵琶,广告广告,广告,刚刚
  [PASS] 二次造词直达：点选候选 B 后重打同码 → B 直达首位（LEARN2 direct）  LEARN2|seq=gggg|picked=五一|before_rank=3|after_rank=1|direct=true|after1=五一|after=五一,琵琶,王,龶,琵琶五一,王琵琶,广告广告,广告
  [PASS] 造词生效：encode_commit_history 成句候选 A+B 出现在候选栏（PHRASE found）  PHRASE|seq=gggg|text=琵琶五一|found=true|cands=五一,琵琶,王,龶,琵琶五一,王琵琶,广告广告,广告

=== 5. NFR1 性能：按键→候选延迟（w16_bench，全链路含引擎单线程排队） ===
  [PASS] BENCH 通过（pass=true）  BENCH|n=400|seq=gggg|avg_ms=0.181|p50_ms=0.180|p95_ms=0.287|max_ms=0.640|limit_ms=30|pass=true
  [PASS] NFR1 按键→候选 p95 ≤30ms  p95_ms=0.287

=== 结果 ===
PASS=20 FAIL=0
```

对照（与 `build/W1-REPORT.md` §3.1 / W15 §2.1 输出逐项一致）：

| 用例 | 期望 | 实测 | 判定 |
|---|---|---|---|
| `w` | 五笔一级简码→人（形码优先） | `1=人` | ✅ |
| `gggg` | 五笔全码→王 | `1=王`（五一/琵琶/龶…同 W1） | ✅ |
| `pinyin` | 无五笔命中→拼音前移 | `1=拼音`（第 2 位 `宵憱 ☯` 为 W1 遗留句噪音） | ✅ |
| `nihao` | 拼音词组→你好 | `1=你好` | ✅ |
| `zni` | 反查注释=五笔编码 | `你(wq wqi wqiy)`、`拟(rny rnyw)`… | ✅ |

### 2.3 真键盘 UI 冒烟（uiautomator 真点键 + 截图核对，非钩子路径）

通讯录「新建联系人」输入框 + 真点 IMS 键帽（坐标按 KeyboardView 布局换算）：
- 点 `j` → 候选栏真数据 `1 日 2 斤斤计较 3 解决…`，状态条 `j · 候选 8`（截图 OCR 核对）；
- 点 `g`×4 → 候选栏为 gggg 真数据，且 **L1 学过的一词已排首位**（此前 e2e 学过 五一，此刻 `1 五一 2 琵琶 3 王…`——词频直达在真键盘生效）；
- 点候选① → 上屏文本经 W5 commit 通道进入真输入框（uiautomator 读回字段 text=五一 / 曡王 两轮实证）。

### 2.4 性能（(c) NFR1 按键→候选 ≤30ms，实测）

| 指标 | 实测（emulator-5554 arm64，n=400 次按键，seq=gggg） |
|---|---|
| avg | **0.181 ms** |
| p50 | 0.180 ms |
| **p95** | **0.287 ms**（NFR1 上限 30ms 的 ~1%） |
| max | 0.640 ms |

口径：`w16_bench` 每次按键测 `engine.onLetter` 全链路（**含引擎单线程 executor 排队 + processRimeKey + getRimeCandidates + 候选对象构造**），即「按键→候选栏拿到数据」的完整延迟；UI 重绘未含（自绘 View 一帧 <16ms，不构成瓶颈）。部署耗时另计：首用 `deploy_ms=634`（≤5s 验收 ✅，另两轮 667/847ms 同量级），二次启动（增量）`deploy_ms=59`。

---

## 3. L1 词频 / 造词（(b) 打过的词二次直达）

- **词频**：librime wubi86 table_translator 自带 userdb（schema `disable_user_dict_for_patterns: ^z.*$` 佐证开着），
  `selectRimeCandidate`+commit 即学习。实测（w16_learn 两段式）：点选 rank3 的「琵琶」上屏 → 重打 `gggg` → **rank1 直达**
  （`LEARN|before_rank=3|after_rank=1|direct=true`）；再点选 rank3 的「五一」→ 重打 → **again rank1**
  （`LEARN2|before_rank=3|after_rank=1|direct=true`）。
- **造词**：schema `enable_encoder + encode_commit_history` 生效——连打两词后，成句候选 `琵琶五一` 出现在同码候选栏
  （`PHRASE|text=琵琶五一|found=true`），二次运行还会继续长出新的成句候选（王琵琶 等）。
- e2e 断言为**相对名次**（点选第 index 位 → 断言其变首位），跨运行可重入（重复运行均 PASS）。
- 顺带发现（W1 遗留句噪音的另一面）：同一码下句子候选会以「生造词」形态混入（如 `ggg` 下的 `曡王`），schema 级可调，不在本车道范围。

---

## 4. 测试钩子（(d) 复用/扩展 DebugReceiver，仅 debug 包）

```
adb shell am broadcast -n com.mineinput.ime/.DebugReceiver -a com.mineinput.ime.DEBUG_ACTION --es cmd w16_startup
… --es cmd w16_status
… --es cmd w16_seq    --es seq w [--es expect 人]        → RESULT|SEQ_MS|EXPECT
… --es cmd w16_commit --es seq gggg --es index 0 [--es expect 王]  → COMMIT|via=input-connection
… --es cmd w16_learn  [--es seq gggg --es index 2]       → LEARN|LEARN2|PHRASE（词频/造词）
… --es cmd w16_bench  [--es n 100 --es seq gggg]         → BENCH|avg/p50/p95/max
```
与 W14 钩子同法：显式组件广播（API 34 隐式会被丢）、logcat tag=W16、先 `-c` 再触发防旧日志假阳性；
`w16_commit/w16_learn` 的上屏与键盘点选走**同一条** `engine.commit` + W5 `commitText` 路径。

---

## 5. License 合规（GPLv3 注明）

复用 Trime 产物 → **android/ 端衍生部分为 GPL-3.0-or-later**（W5 §1.4 预告、W15 §6 选型结论；个人分发可接受）。
明细见新增 `android/LICENSE.md`：`librime_jni.so`（Trime JNI GPL-3.0-or-later，内含 librime BSD-3/opencc Apache-2.0 等）
+ 复刻胶水类 4 文件（SPDX GPL-3.0-or-later 头保留）+ schema 数据（上游 RIME 数据许可随包保留署名）。
换芯路线不变：1c 自写 JNI shim + W15 路径 B 自编 librime（BSD-3）可原位解锁许可。

---

## 6. 期间踩坑（已解决）

1. **Kotlin 块注释嵌套**：类注释里写 `assets/rime/*` 直接把 `/*` 当嵌套注释打开 → `Syntax error: Unclosed comment`（编译失败）；注释里的 glob 写法避开 `/*`。
2. **AGP 9 SourceSet 拒收 Provider**：`assets.srcDir(layout.buildDirectory.dir(...))` 报 `You cannot add Provider instances to the Android SourceSet API` → 改静态路径 `"build/generated/rimeAssets"` + `preBuild.dependsOn(syncRimeAssets)` 显式携带任务依赖。
3. **胶水类缺一不可**：`JNI_OnLoad` 构造 `GlobalRefSingleton` 时 FindClass 全部 11 个类并 GetMethodID 全部 ctor——连不会调用的 `RimeKeyEvent(int,int,String)` 也必须在（缺= .so 加载即失败）；`handleRimeMessage` 必须是 Rime 的**静态**方法（GetStaticMethodID）。
4. **单线程 executor 自锁**：公开方法都包 `onEngineThread`（submit+get）后，方法内部再互相调用会自锁死等（30s 超时）→ 引擎线程内只准调 `*Inner`；超时上限提到 60s 以覆盖部署等待。
5. **JNI 传 null**：`CommitProto.text` 等在 librime 无内容时 JNI 传 null，Kotlin 非空参数的隐式 null 检查会抛 → 契约里如实保留可空。
6. **e2e 毫秒整数粒度把亚毫秒延迟记成 0**（首版 SEQ_MS=0）→ 延迟探针改 ns 计时、小数 ms 输出（`%.3f`）。
7. **模拟器 `input tap` 偶发丢键**（4 连点落 3 字符）→ UI 冒烟按截图核对实际 composing 再点选；e2e 断言走钩子路径不受影响。

---

## 7. 交付物清单（本次新增/修改，全在 android/）

| 文件 | 状态 | 作用 |
|---|---|---|
| `app/src/main/java/com/osfans/trime/core/{Rime,RimeProto,SchemaItem,RimeKeyEvent}.kt` | 新增 | JNI 胶水复刻（1a，GPLv3） |
| `app/src/main/java/com/mineinput/ime/engine/{MixedInputEngine,RimeMixedEngine,MixedEngine,W16Debug}.kt` | 新增 | 引擎契约/实现/进程入口/测试钩子 |
| `app/src/main/java/com/mineinput/ime/MineImeService.kt` | 修改 | IMS 落点接真引擎（候选栏真数据 + W5 commit 通道） |
| `app/src/main/java/com/mineinput/ime/DebugReceiver.kt` | 修改 | w16_* 路由 |
| `app/build.gradle.kts` | 修改 | versionName 0.4.0-w16 + syncRimeAssets（schema 随 app 部署） |
| `fetch-rime-jni.sh` | 新增 | librime_jni.so 幂等落位 + sha256 |
| `w16-e2e.py` | 新增 | e2e 验收脚本（20 项断言） |
| `LICENSE.md` | 新增 | GPLv3 合规说明 |
| `.gitignore` | 修改 | jniLibs 外部产物不进 git |

## 8. 遗留

1. **`.so` 版本绑定**：librime_jni.so pin Trime v3.3.13；升级需重跑 `fetch-rime-jni.sh` + `w16-e2e.py` 回归（1a 复刻不再依赖 Trime dex，绑定面比 W15 POC 少一半）。
2. **中/西文切换 UI 未接**：`setRimeOption("ascii_mode",…)` 通道在（`MixedInputEngine` 契约内），W5 骨架的切换 UI 未做；`getRimeStatus().isAsciiMode` 已可用。
3. **候选翻页/删词/符号面板**：引擎面齐（changeRimeCandidatePage/deleteRimeCandidate 已声明），键盘交互未做（W5 遗留 3 同口径）。
4. **真机未测**：emulator-5554（arm64）唯一实测设备；NFR1 数字为模拟器口径，真机待 T1。
5. **release 包未出**（D12 侧载收口时）；DebugReceiver 在 release 直接忽略（既有语义）。
6. **W1 遗留句噪音仍在**（`pinyin` 第 2 位 `宵憱 ☯`、`ggg` 下生造句候选），schema 级可热调，非本车道范围。
