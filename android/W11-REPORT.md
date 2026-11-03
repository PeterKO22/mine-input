# W11 android-phase2 · 设置页/知情同意/Hub 配对同步 — 交付报告

> 范围：`android/`（只动 android）。对齐：design/design-language.md、docs/开发任务计划.md §3（W11 = A4/A5 稿设置页与知情同意 + Hub 配对同步，对齐 W8 语义）。
> 环境：macOS 27.0.1，emulator-5554（Pixel_6_API_34），真 Hub localhost:8088（模拟器内 10.0.2.2:8088，docker `mine-input-hub`），JAVA_HOME=/opt/homebrew/opt/openjdk@17。

## 1. 实现要点

- **知情同意（FR8，A5 稿）**：`ConsentActivity` 逐项显式同意 —— C0 基础上下文 / C2 读屏上下文（高敏）/ 语音热词同步，**默认全关、无默认全开**；首次启动（`MainActivity` 判 `firstLaunchDone`）路由到同意/配对页；`SettingsActivity`「撤回全部同意」随时撤回（`Prefs.Consent.withdrawAll()` + 清离线队列）。
- **设置页（A4 稿）**：`SettingsActivity` + `SectionActivity` 分区（通用 / 输入方案 / 自适应学习 / 隐私 / AI 同步），`Ui.kt`/`DesignTokens.kt` 按 design-language 深色科幻 token 搭建。
- **Hub 配对（真连）**：配对码 → 确定性凭据（同码 = 同 Hub 账号；也接受 `用户名:密码` 直连）→ `register`（409 = 已存在容忍）→ `login` → `whoami` 校验 → 落盘。每用户独立密钥分区 `key_partition` 随登录返回保存。状态存三份 SharedPreferences：`w11-consent` / `w11-pairing` / `w11-settings`。
- **同步对齐 W8 语义**（sdk/W8-REPORT.md 对照）：userdb 时间戳取新、计数器本地攒增量 + push 成功扣除 + 服务端累加、热词集合并、meta 取新、**push_id 幂等**（入队即固化，重试不重复累加）、离线队列断网入队联网 FIFO 补传（失败静默留队）。
- **门控（撤回即停、不上报）**：一键熔断 `fuse` / 未配对 / 无任一同意 → push 与 ingest 全拒；userdb/计数器/meta 上行需 C0；热词上行/合并需热词同意；`ocr_digest`/`asr_digest`（高敏）字段仅 C2 同意时随事件携带，否则出端前剥除。
- **真实事件同路**：`MineImeService`/`KeyboardView` 候选选择等交互事件走 `SyncManager.recordInteraction`（与调试事件同一条门控路径）；`DebugReceiver` 仅 debug 包响应（release 直接忽略），供 e2e 断言（tag=W11 logcat）。

## 2. 怎么验证（实测）

- **构建**：`cd android && ./gradlew assembleDebug` → `BUILD_EXIT=0`，产出 `app-debug.apk`（2,813,313 bytes）。
- **端到端**：`python3 android/w11-e2e.py`（uiautomator 驱动模拟器 UI + 真 Hub docker 日志服务端实证），**最终 PASS=13 FAIL=0，exit 0**。

### e2e 实测输出（最终一跑，全文关键部分）

```
=== 0. 环境：安装 APK + 清数据（首次启动） ===
  [PASS] adb install  Success
  [PASS] 首次启动路由到 A5 同意/配对页
  [PASS] 同意项默认全关（无默认全开）  ... consent(c0=false,c2=false,hotword=false) fuse=false queue=0 ...

=== 1. 界面逐项勾选同意（C0 + 语音热词同步，C2 留空） ===
  [PASS] C0/热词逐项勾选生效、C2 留空  ... consent(c0=true,c2=false,hotword=true) ...

=== 2. 输入配对码 → 配对并继续（真连 Hub 10.0.2.2:8088） ===
  [PASS] 配对真连成功（PAIR_OK）  PAIR_OK hub=http://10.0.2.2:8088 user_id=33 key_partition=kp_ab854cf64f7bff69 device=android-28f2f24b63ab8425

=== 3. seed 演示学习数据 → 设置页「立即同步」 ===
  [PASS] push→pull 往返一致（ROUNDTRIP_OK）  ROUNDTRIP_OK userdb[w11/demo=hello-w11] counters={"w11_clicks":3} hotwords=[W11热词]
  [PASS] 往返内容含 userdb=w11/demo 与计数器

=== 4. 二次同步：计数器增量累加（3+4=7） ===
  [PASS] 二次 ROUNDTRIP_OK
  [PASS] 计数器增量累加 3+4=7  ... server_counters={"w11_clicks":7} hotwords=[W11热词] devices=[android-28f2f24b63ab8425]

=== 5. 撤回全部同意 → 不再上报 ===
  [PASS] 撤回后 ingest 被拦截（UPLOAD_BLOCKED）
  [PASS] 撤回后同步被拦截（SYNC_BLOCKED/SYNC_RESULT blocked）
  [PASS] Hub 侧零新增 push/pull/ingest（服务端实证）  before={'push': 15, 'pull': 15, 'ingest': 6} after={'push': 15, 'pull': 15, 'ingest': 6}

=== 6. 状态位/设置入口自检 ===
  [PASS] STATUS 含 consent 全 false 与队列 0  ... paired=true ... consent(c0=false,c2=false,hotword=false) fuse=false queue=0 ...

=== 结果 ===
PASS=13 FAIL=0
```

logcat 断言依据（节选，tag=W11）：

```
PAIR_REGISTER user_id=33 kp=kp_ab854cf64f7bff69
PAIR_OK hub=http://10.0.2.2:8088 user_id=33 key_partition=kp_ab854cf64f7bff69 device=android-28f2f24b63ab8425
SEEDED key=w11/demo value=hello-w11 counter=w11_clicks delta=3 hotword=W11热词
QUEUE_FLUSH sent=1 kept=0 dropped=0 err=
SYNC reason=settings-ui push=sent push_id=w11-87f8d022c0fa41d7 flush_sent=1 pull=true roundtrip=true detail=userdb[w11/demo=hello-w11] counters={"w11_clicks":3} hotwords=[W11热词] queue=0
ROUNDTRIP_OK userdb[w11/demo=hello-w11] counters={"w11_clicks":3} hotwords=[W11热词]
SEEDED key=w11/demo value=hello-w11 counter=w11_clicks delta=4 hotword=W11热词
SYNC reason=debug-cmd push=sent push_id=w11-f165ba0e880d4dc5 pull=true roundtrip=true detail=userdb[w11/demo=hello-w11] counters={"w11_clicks":4} hotwords=[W11热词]
ROUNDTRIP_OK userdb[w11/demo=hello-w11] counters={"w11_clicks":4} hotwords=[W11热词]
STATUS paired=true ... user_id=33 consent(c0=true,c2=false,hotword=true) ... server_counters={"w11_clicks":7} ...
UPLOAD_BLOCKED kind=candidate_pick reason=no-consent
INGEST_RESULT blocked:no-consent
SYNC_BLOCKED reason=no-consent
SYNC_RESULT blocked=no-consent
STATUS paired=true ... consent(c0=false,c2=false,hotword=false) fuse=false queue=0 ...
```

关键实证：push_id 两轮各异（`w11-87f8…`/`w11-f165…`）；计数器服务端累加 3→7（增量语义，非覆盖）；撤回后 ingest/sync 双双被拦且 **Hub docker 日志 push/pull/ingest 计数前后完全不变**（服务端零新增，不是只看客户端日志）。

## 3. 期间发现并修复的问题（首跑 9 PASS / 4 FAIL → 修至 13/0）

1. **e2e 固定配对码不可重入**：Hub 服务端状态跨运行持久，配对码 = 确定性账号 → 计数器跨运行累加（历史 7 + 本次 3 = 10），「3+4=7」断言失效。改为**每次运行随机配对码 = 全新账号**（与 W8 sync-demo 每次随机账号同做法），断言确定性化。
2. **`SyncManager` 往返校验假阴性**：重装/清数据后同账号首同步，本地基线为空而服务端已有历史累计 → `0+3≠10` 误报 FAIL（同步本身成功）。改为基线缺该 key 时仅验下界 `now ≥ delta`（防丢增量；多设备叠加不可判严格相等），基线已知时仍**严格相等**（二同步 `3+4=7` 即严格相等分支实证）。
3. **e2e 诊断取行错误**：STATUS/server_counters 断言详情取的是 logcat **首条**匹配行而非最新（步骤 6 撤回后自检曾错拿步骤 0 的状态行）。改为取最新匹配行，步骤 6 现在真正校验撤回后的状态。
4. **`deviceId` 恒为常量**：`Prefs.Pairing` 把 `Settings.Secure.ANDROID_ID`（列名常量 `"android_id"`）当设备值拼接，所有设备得到同一个 `android-android_id`（多设备场景必撞）。改为经 `contentResolver` 取真实值 → `android-28f2f24b63ab8425`。

## 4. 遗留

1. **多设备并发计数器的严格校验**：基线已知分支用严格相等，若另一设备并发推送增量会误报 FAIL（e2e 为单设备场景，已实证正确）。多设备化时可改为「下界 + 差值核对」或以 pre-pull 为基线。
2. **撤回同意只停新增、不删历史**：Hub 侧已上报数据无删除（服务端删除 API 属 W4 `hub/`，本次未越界）。
3. **ingest 无服务端幂等**（同 W8 遗留 1）：极端情形（服务端已写入但响应丢失）补传可能重复入库；push 有 push_id 无此问题。
4. **TLS 未实测**（同 W8 遗留 2）：本地 Hub 为 HTTP；真机（非模拟器）e2e 未跑。
5. **C2 读屏上下文仅落「同意位 + 高敏字段门控」**：Android 侧 Accessibility 采集器本体未实现（属后续车道），当前 C2 同意位与 `ocr_digest`/`asr_digest` 剥除逻辑已可独立验收。
