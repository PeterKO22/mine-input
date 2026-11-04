# W24 报告 · android-sync：macOS 设计同步 Android，英文/数字/符号直输落地

> 日期：2026-11-04 ｜ 范围：仅 android/（+ docs/ 平价表）｜ 验收：w11/w14/w16/w24 e2e + 重建 app-debug.apk
> 症状（用户确认）：「只能输入中文，应该可以切到英文模式，方便输入账号密码等内容」。
> 设计口径（用户确认）：中/EN 为**持久状态**；英文态完整直输字母/数字/符号（含账号密码）；
> 同步 Mac 隐私设计 C1——密码框自动 EN + 停一切采集 + 不调 AI/云端，离开恢复。

---

## 1. 功能平价审计表（Mac 基准 ↔ Android 现状）

| # | 功能 | macOS（基准） | Android W24 后 | 差距 / 动作 | 状态 |
|---|------|---------------|----------------|-------------|------|
| 1 | 英文输入 / 中英切换 | Shift 一键切换（schema/default.yaml `Shift_L/R: commit_code`：无编码=纯切换、有编码=原样上屏编码再切西文、再按切回，搜狗式） | **W24 落地**：工具栏「中/EN」键（持久，commit() 落盘跨重启）；EN 态字母/数字/符号直接上屏 ASCII（commit_code 语义，不过引擎不等部署）；中文态打码未选词→切英=原码上屏；混合场景中文串插英文；中文态数字键 1-9 选候选（搜狗式）；?123 符号面板（数字+常用符号） | W24 前=无英文模式（=用户症状）；现语义对齐，形态按平台习惯（工具栏键 vs Shift） | ✅ 平 |
| 2 | 横向候选 | candidate_list_layout: linear（squirrel-linear.patch 幂等） | W5 起即横排（M1：序号 gold mono / 当前候选金填充；单行 ≤6） | 基本平；>6 候选翻页 → TODO-E | ✅ 平（小尾巴） |
| 3 | AI 智能候选组 | 「AI 智能列」cyan 描边玻璃卡与五笔/拼音组区分（design-language M1）；来源 SuggestClient（Hub SPI suggest） | **W24 快速落地**：标记管道 + 渲染（候选 ai 标志 → cyan 玻璃卡 + 「AI」角标）；w24_aimark 演示位验证 | 标记已平；真实 AI 来源（Hub SPI/端侧 GGUF）→ TODO-C | 🟡 部分 |
| 4 | PTT 语音 | 全管线（VAD→SenseVoice→标点→热词；按住即说） | W14 全管线（PTT 大键：按住即说/滑出取消/返回取消/低置信重说/滚动转写） | 基本平；语音中 AI 提词依赖 TODO-C | ✅ 平 |
| 5 | 提案卡 | W20 SPI v2（propose/confirm/observe）+「未 confirm 不得执行」红线 + 卡片 UI | 无 | 深水区 → TODO-A（不展开） | ❌ TODO-A |
| 6 | 记忆管理 | W20 ⌥M 浮层（时间线/编辑/删除/搜索/导出 + 熔断同源） | 部分等价（设置页撤回同意/熔断/导出，W11）；无时间线管理 UI | 深水区 → TODO-B（不展开） | ❌ TODO-B |
| 7 | 产品名 | W18「提炼输入法」/"Mine Input"（TIS + 菜单栏本地化） | W18 同名（values/values-en app_name、ime_name；aapt badging ALL PASS） | 无 | ✅ 平 |
| 8 | 密码框隐私（C1，用户新增口径） | 需求文档 v1.0：「密码框/支付场景（Secure Input）自动暂停、不可关闭」；ContextCore `secureInput → refused(.secureInputPaused)` | **W24 落地**：textPassword/textVisiblePassword/webPassword/numberPassword 检测 → 自动 EN（强制不可切）+ 采集闸关死（SyncManager.collectionPaused：candidate_pick/voice_session 一律 COLLECT_BLOCKED，不调 AI/云端）+ 离开恢复原模式 | 支付场景/敏感应用黑名单 → TODO-D | ✅ 平（扩展自动 EN） |

### 深水区 TODO 卡（本期不展开）

- **TODO-A 提案卡 Android 版**：SPI v2 propose/confirm/observe 移植 + 显式确认红线 + 卡片状态机（queued→running→done）。
- **TODO-B 记忆管理 Android 版**：时间线/编辑/删除/搜索/导出 + 采集状态常显 + 熔断联动（⌥M 浮层同构）。
- **TODO-C AI 智能候选真实来源**：Hub SPI suggest（SuggestClient 同契约）/ 端侧 GGUF；候选进 W24 标记管道即可渲染。
- **TODO-D 敏感应用黑名单 + 支付场景**：「自动暂停不可关」扩展到应用维度（Mac 同款）。
- **TODO-E 候选翻页**：>6 候选滑动/Tab 轮换（Mac rotate_candidate_with_tab 对齐）。

（同一表格亦存 docs/平价表-macos-android.md，随后续轮次维护。）

---

## 2. 落地清单（android/）

| 文件 | 变更 |
|------|------|
| `KeyboardView.kt` | 工具栏「中/EN」切换键（modeChip，EN 态金实心）；?123 符号面板（Kind.DIRECT 数字/符号直输，ABC 返回，4 行几何不变——W14 手势坐标依赖不动）；AI 候选组标记渲染（cyan 描边玻璃卡 + 「AI」角标）；`modeChipScreenBounds()` 供 e2e 真实点按 |
| `MineImeService.kt` | EN 态 onLetter/onSpace/onDelete 直上屏 ASCII（toAscii 标点归一；不过引擎）；onDirect（EN 直输；CN 数字键选词搜狗式/符号先上屏原码）；toggleMode（commit_code 语义：有编码原码上屏再切；持久落盘）；applyFieldPrivacy（密码框自动 EN + 采集闸 + PRIVACY 日志）；learnAndReport 密码框拦截；commitCandidate 返回文本供钩子断言 |
| `Prefs.kt` | `imeMode` 持久键（**commit() 同步落盘**——force-stop 硬杀丢 apply() 异步写的实测教训） |
| `sync/SyncManager.kt` | `collectionPaused` 采集闸（密码框：recordInteraction 一律 COLLECT_BLOCKED，覆盖 candidate_pick/voice_session） |
| `W24ProbeActivity.kt`（新） | e2e 探针：真实普通框 + textPassword + textVisiblePassword（debug 包 only，release finish()） |
| `W24Debug.kt`（新） | w24_status/w24_mode/w24_type/w24_pick/w24_fieldtext/w24_layout/w24_collect_probe/w24_aimark 钩子（主线程派发走真实按键路径，tag=W24） |
| `DebugReceiver.kt` / `AndroidManifest.xml` | w24_* 路由 + 探针 Activity 注册 |
| `w24-e2e.py`（新） | 45 断言（见 §3.4）；`ensure_ime()` 防系统回落 LatinIME；密码框段单观察窗零清窗防假阴性 |

---

## 3. e2e 实测输出

### 3.1 w24-e2e.py（新增，英文输入 + 中英切换 + 密码框隐私）—— PASS=45 FAIL=0

```
=== 0. 环境：安装 APK + 清数据 + 启用 IME + 探针 Activity + 引擎部署 ===
  [PASS] adb install  Success
  [PASS] 选中本 IME（ime set 生效）
  [PASS] 混输引擎就绪（w16_startup STARTUP ok）  STARTUP|ok=true|deploy_ms=2361|first_run=true|schema=ping_wubi_mixed
  [PASS] 探针普通框聚焦 + IME 绑定（服务拉起）
  [PASS] 默认中文模式（mode=cn）  STATUS|mode=cn|password_field=false|collection=on|raw=|demo_ai=0|keyboard=true

=== 1. 英文态直输 hello（不过引擎，直接上屏） ===
  [PASS] 探针普通框聚焦 + IME 绑定
  [PASS] 切 EN（持久状态 persisted=en）  MODE|mode=en|persisted=en|ok=true|want=en
  [PASS] hello 逐键走真实按键路径（dispatched=5）  TYPE|text=hello|dispatched=5|mode=en|password_field=false|via=input-connection
  [PASS] 英文态直接上屏 hello（字段=hello）  field=hello
  [PASS] 引擎零介入（raw 恒空）  STATUS|mode=en|…|raw=|…
  [PASS] UI 实证：输入框含 hello

=== 2. 英文态账号密码串完整上屏（数字/符号直输） ===
  [PASS] 密码串逐键直输（14 键 dispatched）  TYPE|text=User_2026!p@ss|dispatched=14|mode=en|…|via=input-connection
  [PASS] 账号密码串完整上屏（含数字 _ ! @）  field=helloUser_2026!p@ss

=== 3. 切中文出候选（nihao→你好）+ 中文串中插英文 ===
  [PASS] 切回中文（mode=cn）  MODE|mode=cn|persisted=cn|ok=true|want=cn
  [PASS] 中文候选真数据（CANDS 含 你好）  CANDS|n=8|1=你好|2=悄虚|3=你|4=拟|5=尼|6=呢|7=泥|8=妳
  [PASS] 选词上屏 你好（via=input-connection）  PICK|index=0|text=你好|via=input-connection|ok=true
  [PASS] 中文态继续打码（composing=pinyin）  TYPE|text=pinyin|dispatched=6|mode=cn|…
  [PASS] 切英文时原码上屏（commit_code 语义）  MODE|mode=en|persisted=en|ok=true|want=en
  [PASS] 混合场景文本正确（…你好pinyin）  field=helloUser_2026!p@ss你好pinyin
  [PASS] 英文段紧随中文段（…pinyinabc）  field=helloUser_2026!p@ss你好pinyinabc

=== 4. 中英往返 3 轮稳定（切中→w→人→切英→X<i>d） ===
  [PASS] 3 轮往返全部命中（w→人 + X<i>d 直输）  expected=helloUser_2026!p@ss你好pinyinabc人X1d人X2d人X3d
  [PASS] 往返后模式稳定（mode=en）

=== 5. 真实点按工具栏「中/EN」切换键（MODE_CHIP 坐标） ===
  [PASS] 解析到切换键坐标  MODE_CHIP|ready=true|x=822.75|y=1720.625|w=126.0|h=57.75
  [PASS] 点按 → EN 切回中文（mode=cn）  MODE|mode=cn|persisted=cn|ok=true|source=toggle
  [PASS] 再点按 → 切回英文（mode=en）  MODE|mode=en|persisted=en|ok=true|source=toggle

=== 6. 密码框自动 EN + 采集闸（进密码框→EN 直输且零采集日志） ===
  [PASS] 探针密码框聚焦 + IME 绑定
  [PASS] 进密码框自动 EN + 采集暂停（PRIVACY 日志）  PRIVACY|field=password|mode=en|collection=paused|ai=off
  [PASS] 密码框态：mode=en + collection=paused  STATUS|mode=en|password_field=true|collection=paused|…
  [PASS] 密码框强制 EN 不可切（ok=false）  MODE|mode=en|persisted=cn|ok=false|want=cn
  [PASS] 采集探针被拦（COLLECT_BLOCKED password_field）  COLLECT_BLOCKED|reason=password_field|kind=candidate_pick
  [PASS] 密码框 EN 直输密码串（dispatched=6）  TYPE|text=Pw123!|dispatched=6|mode=en|password_field=true|…
  [PASS] 密码完整上屏（进程内读回）  field=Pw123!
  [PASS] W11 零采集日志（无 INGEST_ENQUEUED/UPLOAD_BLOCKED）  w11_lines=0
  [PASS] 探针密码框聚焦 + IME 绑定（明文密码框）
  [PASS] 明文密码框同口径（password_field=true）
  [PASS] 明文密码框 EN 直输完整上屏  field=Vis!ble2

=== 7. 离开密码框：恢复原模式 + 采集恢复 ===
  [PASS] 回到普通框
  [PASS] 离开恢复 cn + 采集恢复（PRIVACY 日志）  PRIVACY|field=normal|mode=cn|collection=resumed|ai=auto
  [PASS] 采集恢复实证（探针走通 W11 上报链路）  W11: UPLOAD_BLOCKED kind=candidate_pick reason=not-paired

=== 8. 中/EN 持久状态跨进程重启保留 ===
  [PASS] 设 EN（persisted=en）  MODE|mode=en|persisted=en|ok=true|want=en
  [PASS] 重启后选中本 IME
  [PASS] 重启后探针普通框聚焦
  [PASS] 重启后仍 EN（持久状态）  STATUS|mode=en|password_field=false|collection=on|…（新进程 pid 变）

=== 9. AI 智能候选组标记（cyan 玻璃卡 + AI 角标渲染管道） ===
  [PASS] AI 组标记演示位生效（AI_MARK applied）  AI_MARK|n=2|applied=true
  [PASS] 候选带 AI 标记（demo_ai=2）  STATUS|mode=cn|…|raw=w|demo_ai=2|…

=== 结果 ===
PASS=45 FAIL=0
```

### 3.2 w16-e2e.py（混输引擎回归）—— PASS=20 FAIL=0

关键实测：`STARTUP deploy_ms=2585 first_run=true`（≤5s ✓）；w→人 / gggg→王 / pinyin→拼音 / nihao→你好 / zni 反查（`5=你(wq wqi wqiy)`）；gggg 选词→王 via=input-connection；LEARN/LEARN2 direct=true；PHRASE「琵琶五一」found=true；`BENCH p95_ms=1.001 ≤30`。**PASS=20 FAIL=0**。

### 3.3 w14-e2e.py（语音回归）—— PASS=32 FAIL=0

关键实测：`MODEL_OK installed=true`（SenseVoice int8 归档 + VAD，SHA256 钉死校验）；`ENGINE_LOADED load_ms=2543`；s1 逐字断言 `ASR_EXPECT match=true`（NFR2 elapsed_ms=309 ≤1500）；s3 热词纠偏「可颂」开/关对照组成立；多段分段转写（4 段）+ 候选区滚动 4 级 + 滚动文本==上屏文本；真输入框 commit 通道（`COMMIT_OK via=input-connection`）；真实 PTT 手势长按（静音失败兜底「请重说」不瞎猜）+ 滑出/返回取消不上屏；REC_OK 16k mono 内存缓冲不落盘。**PASS=32 FAIL=0**。
（注意：本套件第 5-6 步按键盘固定坐标做 PTT 手势——W24 键帽几何刻意未动，回归即为证明。）

### 3.4 w11-e2e.py（同步/同意回归）—— PASS=13 FAIL=0

关键实测：同意项默认全关（无默认全开）✓；C0/热词勾选生效、C2 留空 ✓；`PAIR_OK user_id=55` 真连 Hub（10.0.2.2:8088）✓；`ROUNDTRIP_OK userdb[w11/demo=hello-w11] counters={"w11_clicks":3}`；二次同步计数器增量累加 `server_counters={"w11_clicks":7}` ✓；撤回后 `UPLOAD_BLOCKED` + `SYNC_BLOCKED` 拦截 ✓；Hub 服务端零新增 push/pull/ingest（docker logs 计数前后一致）✓；**PASS=13 FAIL=0**。
（含 W24 采集闸共存验证：SyncManager.collectionPaused 默认关，W11 上报链路不受影响。）

---

## 4. 构建

- `./gradlew assembleDebug` EXIT=0；`android/app/build/outputs/apk/debug/app-debug.apk` 重建（139MB，含全部 W24 改动；e2e 四套均基于该 APK 实测）。

## 5. e2e 汇总

| 套件 | 断言数 | 结果 | 覆盖 |
|------|--------|------|------|
| w24-e2e.py（新增） | 45 | **PASS=45 FAIL=0** | EN 直输 hello / 账号密码串（大小写+数字+符号）/ 中文候选 nihao→你好 / 混合场景 / commit_code 切换 / 中英往返 3 轮 / 真实点按「中/EN」键 / 密码框自动 EN+采集闸+零采集日志 / 离开恢复 / 持久化跨重启 / AI 组标记管道 |
| w16-e2e.py | 20 | **PASS=20 FAIL=0** | 混输引擎回归（部署≤5s、候选真数据、选词上屏、L1 词频/造词、NFR1 p95=1.0ms） |
| w14-e2e.py | 32 | **PASS=32 FAIL=0** | 语音回归（模型安装、ASR 逐字、热词对照、PTT 手势/取消/兜底、NFR2、录音探针） |
| w11-e2e.py | 13 | **PASS=13 FAIL=0** | 同步/同意回归（默认全关、配对、push/pull 往返、计数器累加、撤回拦截、Hub 零新增） |

## 6. 实测教训（进 skill 级记忆的候选）

1. **SharedPreferences apply() 会被 force-stop 硬杀丢写**：持久状态（imeMode）改 commit() 同步落盘，e2e 跨重启断言才稳。
2. **e2e 断言勿把多行日志当一行看**：CANDS 与 TYPE 是两条日志，钩子行为切面要按行断言。
3. **toggle 路径要自带日志**：真实点按（非钩子）触发的切换也要打日志，否则 e2e 无法区分「没点到」与「没日志」。
4. **e2e 需 assert ime set 生效**：install/pm clear/force-stop 后系统可能回落 LatinIME，`ensure_ime()` 重试 + dumpsys 断言先行。
5. **密码段断言要单观察窗**：logcat -c 清窗会把「零采集日志」窗口清小，全程 clear=False 才是真阴性。
6. **GitHub release CDN 会断流**：模拟器内下载 163MB 模型 16MB 处停摆；host `curl -C -` 续传拿全（SHA256=7d1efa21… 与钉死值一致）→ push + run-as 落进 `cache/voice-model-dl/` 即被 install() 的 verifyFile 复用、跳过下载——SHA 钉死前提下的合法测试基建旁路，不是绕校验。

## 7. 已知限制 / 未尽项

- 用户报告「安卓版还是有问题」的具体症状未收到补充（本次按确认症状「只能输入中文」落地）；如有其它症状请转告再修。
- AI 智能候选组当前仅标记管道 + 渲染（demo 位），真实候选来源（Hub SPI suggest / 端侧 GGUF）= TODO-C。
- 提案卡 / 记忆管理 Android 版 = TODO-A / TODO-B（深水区，本报告只列卡）。
- 候选 >6 翻页 = TODO-E。
