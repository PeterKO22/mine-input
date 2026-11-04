# W21 安全审计与加固 车道报告

> 车道：W21 security-audit（全仓）｜日期：2026-11-04｜基线：main @ 4b8066c（W20）
> 交付：(a) 网络出口全量审计 + 零遥测断言；(b) 敏感信息扫描（含 git 历史）+ 脱敏提交 + .gitignore 完整性；
> (c) 权限最小化核查；(d) Hub 安全面核查；(e) `SECURITY.md`（威胁模型/无遥测承诺/数据分类/报告渠道/已知限制）。
> 结论：**运行时网络出口 = 本地回环 + 用户自有 Hub，零遥测/零第三方上报（静态全量扫描 0 命中）**；
> 发现并修复：22 文件 375 处个人路径 + 4 处代码硬编码路径 + 5 处机器名泄露 + .gitignore 5 类缺口；
> git 历史残留个人路径/author 主机名（14 commits）为**已知限制**——发布前需 filter-repo（见 §2.4）。

---

## 1. 网络出口全量审计（交付 a）

### 1.1 端点分类表

**A 类｜用户主动下载**（仅显式 fetch/build 脚本触发，非运行时行为）

| # | 端点 | 触发脚本 | 用途 | 完整性校验 |
|---|---|---|---|---|
| A1 | github.com/rime/librime | build/build-librime.sh | 源码克隆 | ⚠️ depth-1，未钉 commit |
| A2 | github.com/rime/squirrel | build/build-squirrel.sh | 源码克隆 | ⚠️ depth-1，未钉 commit |
| A3 | raw.githubusercontent.com | build/fetch-schema-deps.sh | schema 依赖 | ✅ URL 含 commit SHA 钉死 |
| A4 | raw.githubusercontent.com/llvm/llvm-project | engine/build/pathB-build-librime.sh | libcxx filesystem 补丁 | ✅ tag llvmorg-9.0.0 |
| A5 | github.com/k2-fsa/sherpa-onnx/releases | android/fetch-deps.sh、ModelManager.kt | AAR + 语音模型 | ✅ SHA256 钉死（边下边验） |
| A6 | maven.aliyun.com | android/fetch-deps.sh | commons-*.jar | ✅ SHA256 钉死 |
| A7 | mirrors.huaweicloud.com | engine/build/pathB-fetch-ndk.sh | Android NDK | ⚠️ 仅记录 SHA256（TOFU） |
| A8 | archives.boost.io | engine/build/pathB-build-librime.sh | Boost 源码 | ⚠️ 无校验（TOFU） |
| A9 | github.com/osfans/trime/releases | engine/build/fetch-trime-apk.sh | Trime APK（提取 JNI .so） | ⚠️ 仅记录 SHA256（TOFU） |
| A10 | www.modelscope.cn → cdn-lfs-cn-1.modelscope.cn | models/fetch_model.sh | Qwen GGUF 模型 | ✅ SHA256 逐一复核 |
| A11 | github.com/ggml-org/llama.cpp/releases | models/run-llama-native.sh（手动下载提示） | llama-server 预编译 | ⚠️ 无强制校验 |

**B 类｜本地回环**（运行时，数据永不出机）

| 端点 | 组件 | 证据 |
|---|---|---|
| 127.0.0.1:8088 | Hub HTTP 明文回退 | compose 默认 `${HUB_HTTP_BIND:-127.0.0.1}` 绑 loopback（docker-compose.yml:23） |
| localhost:8443 | Hub HTTPS（nginx 边车终结 TLS） | smoke.sh:21 `BASE_URL:-https://localhost:8443` |
| hub:8080 / llama:8091 | compose 内网服务互联 | docker-compose.yml:31/44 |
| host.docker.internal:8092 | 宿主机原生 llama 7B | docker-compose.yml:31 `MODEL_URL` 默认值 |
| 10.0.2.2:8088 | Android 模拟器 → 宿主 Hub（e2e） | android/w11-e2e.py:7 |

**C 类｜用户自有 Hub**（运行时**唯一**数据外发面）

| 项 | 内容 |
|---|---|
| 端点 | 用户配置的 `base_url`（默认 https://localhost:8443；朋友部署 https://\<用户主机\>:8443） |
| 接口 | `/v1/auth/*`、`/v1/sync/push|pull`、`/v1/ingest`、`/v1/suggest`（sdk/src/client.cpp + android sync/HubApi.kt + macos SuggestClient） |
| 上行数据 | userdb/计数器/热词/AI 配置（同步面）；InteractionEvent（ts/device_id/app_id/kind/text_in/text_out/ocr_digest?/asr_digest?/cadence/suggestion_*）；suggest 的 before_cursor/app_id/context_digest |
| 谁能看到 | Hub 主机管理员（明文落库——已知缺口，见 §5）；传输 TLS（自签 CA） |

**D 类｜上游继承**（macOS Squirrel）

| 端点 | 触发 | 状态 |
|---|---|---|
| https://rime.github.io/release/squirrel/appcast.xml | Sparkle 更新检查 | `SUEnableAutomaticChecks=false`（build/squirrel-dev.patch:162-163）——**自动检查关闭**，仅用户手动「检查更新」才联网 |

### 1.2 运行时数据流图（什么数据离机、去哪、谁能看）

```text
[按键/候选/语音/OCR摘要/记忆]
   │
   ├─(1) 本地落盘：SQLite InteractionStore(30天滚动) + JSONL 记忆
   │      ~/Library/Application Support/mine-input/        ← 设备内，不出机
   │
   ├─(2) 同意分级(C0/C1/C2 默认全关) + 熔断未触发 + 已配对
   │      ──► 用户 Hub /v1/sync/push | /v1/ingest           ← 唯一离机面（TLS）
   │           能看：Hub 主机管理员（hub.db 明文，静态加密预留位）
   │           朋友部署：user_id 分区，互相不可见
   │
   └─(3) suggest：before_cursor ──► Hub /v1/suggest ──► SSE 候选回流
          （AI 开关默认关；审计只记字段长度）

语音音频：内存环形缓冲→转写即弃，不落盘、不上传原始音频
屏幕：截图→Vision OCR→摘要后弃原图，不落盘
模型/依赖下载：只在显式跑 fetch 脚本时（A 类，一次性）
```

### 1.3 零遥测/零第三方上报断言（实证）

```text
$ git grep -niE 'telemetry|analytics|sentry|crashlytics|firebase|appcenter|umeng|bugly' \
    -- ':(exclude)*.svg' ':(exclude)docs/*' ':(exclude)*.md'
TELEMETRY-CLEAN            # 一方代码 0 命中（Ui.kt trackTintList 为 UI 属性，非埋点）
$ git grep -n 'https?://'  # 全量 URL 归因：除 A/B/C/D 四类外无任何端点（§1.1 逐条归类，无剩余）
```
- 一方代码（C++/Swift/Kotlin/Python）网络调用点全部走 `cfg.base_url`（sdk/src/client.cpp）/ `W12HubURL`（macos/w12/src/W12Config.swift:35，默认 `http://localhost:8088`）/ Android `Prefs.Pairing.baseUrl`——**没有任何硬编码外网上报地址**。
- 唯一非回环/非 Hub 的运行期出口（Sparkle）自动检查已关（§1.1 D 类）。
- **断言成立：零遥测、零第三方数据上报、无数据外传通道。**

## 2. 敏感信息扫描（交付 b）

### 2.1 密钥/token/证书

```text
$ git grep -nE 'BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY'      → 0 命中
$ git grep -nE '(password|secret|api_key|access_token)\s*[=:]\s*["''][^"'']{6,}' (代码/配置)
  → 0 真凭据（仅测试演示口令 smoke-pass-123 / w12-demo-pass，公开样例非秘密）
$ git log -p --all | grep -E 'BEGIN .*PRIVATE KEY|api_key\s*=\s*["''][A-Za-z0-9]{16,}' → 0 命中
```
- TLS 私钥：gen-certs.sh 产物落 `hub/tls/certs/`，被 hub/.gitignore 挡住，**不入库**（实证：`git ls-files hub/tls/` 仅 gen-certs.sh/nginx.conf）。
- hub-secret：`db.load_secret()` 首启随机 32B、chmod 0600 落 `hub-data/` 卷，**不入库**。
- 文档中 token 均为截断样例（`Mi4xNz...fdXc`）。

### 2.2 docs/技术方案-v0.2.md 疑似密钥命中——已澄清非凭据

```text
$ grep -n -iE '(token|secret|api_key|password|BEGIN.*PRIVATE|Bearer)' docs/技术方案-v0.2.md
212:| ② 可选 | OpenAI 兼容 HTTP | base_url + api_key + model 三元组配置，接任意兼容服务 |
```
→ prose 中的配置项名 `api_key`，非真实凭据，无需修复。

### 2.3 个人路径脱敏（已提交修复）

扫描：`$ git grep -l '/Users/<用户名>' | wc -l` → **22 个入库文件**（与预侦察一致）。
处置：
- **18 个报告/日志/文本**：机械替换 `/Users/<用户名>` → `/Users/you`（375 处，ai/W3、android/W5、build/W1、build/logs×7、hub/W13、hub/W17、macos/W12、macos/W18、voice/W2、voice/poc/run_*×3）。
- **4 个可执行代码改为动态解析**（比字面替换更稳，不破坏脚本可用性）：
  - android/w11-e2e.py、w14-e2e.py、w16-e2e.py：`ADB = os.environ.get("ADB") or os.path.expanduser("~/Library/Android/sdk/platform-tools/adb")`；APK 路径改 `__file__` 相对定位。
  - schema/tests/ascii_shift_probe.c：RIME 用户目录取 `getenv("HOME")` 拼接。
- 复扫（命令模板）：`$ git grep -q '<个人用户名>|<主机名>|<示意主机名>'; echo $?` → `1`（**0 命中**）。
- 语法验证：`python3 -m py_compile` 三脚本 OK；`clang -fsyntax-only -I core/librime/src schema/tests/ascii_shift_probe.c` OK。

### 2.4 git 历史扫描（如实：历史仍有残留）

```text
$ git log --oneline -S'/Users/<用户名>' --all | wc -l        → 14
$ git log -p --all | grep -c '/Users/<用户名>'               → 2465
$ git log --format='%an <%ae>' | sort -u
<个人用户名> <<个人用户名>@<主机名>.local>
Ping <ping@mine-input.local>
```
- 历史内**无**密钥/凭据（§2.1 命令实证 0）；但个人路径 + author email 含用户名/主机名残留。
- **处置**：本次不重写历史（W22 车道并行作业中，filter-repo 会冲突）；列入 SECURITY.md §7 已知限制，**发布仓库前必须 `git filter-repo` 清洗**。

### 2.5 机器名扫描（附修复）

| 发现 | 位置 | 处置 |
|---|---|---|
| `mac-<主机名派生>`（device_id，实机主机名小写去连字符派生）×14 | context/W9-REPORT.md | → `mac-you` |
| `<实机主机名>`（SAN 输出实录）×2 | hub/W17-REPORT.md:157 | → `your-mac` |
| `mac-<开发机名>`（测试 fixture）×2 | context/Tests/MemoryCoreTests.swift:366,371 | → `mac-you`（同测试内字符串一致，回归通过） |
| `<示意主机名>.local`（设计稿示意主机名）×2 | design/generate_svg.py:300、design/svg/M7-*.svg | → `your-hub.local` |
| `<个人用户名>`（ls 属主行）×1 | build/logs/w7-build-rerun.log:83 | → `you` |

复扫：实机主机名 / 个人用户名 / `<示意主机名>` 模式全仓 **0 命中**（§2.3 命令模板；本报告引用样例已一并脱敏）。

## 3. .gitignore 完整性核查

| 检查项 | 状态 | 证据 |
|---|---|---|
| models/（*.gguf/*.bin/llama 产物） | ✅ 原有 | models/.gitignore |
| 语音模型（~550MB） | ✅ 原有 | voice/.gitignore `models/` |
| android 外部产物（aar/jniLibs/local.properties） | ✅ 原有 | android/.gitignore |
| 构建产物（cmake/swift/.build） | ✅ 大部原有 | build/ sdk/ context/ macos/w12 各 .gitignore |
| TLS 私钥/证书、备份 | ✅ 原有 | hub/.gitignore `tls/certs/` `backups/` |
| **缺口1 `*.key`/`*.pem`/`*.p12` 全局** | 🔧 已补 | 新建根 .gitignore |
| **缺口2 keystore（*.keystore/*.jks）** | 🔧 已补 | 根 .gitignore |
| **缺口3 hub-secret / hub-data/（运行数据）** | 🔧 已补 | 根 .gitignore + hub/.gitignore `hub-data/` |
| **缺口4 外部克隆 core/、macos/squirrel/** | 🔧 已补 | 根 .gitignore（此前 `git status` 显示未跟踪待误提交） |
| **缺口5 macos/w20/.build/.demo、macos/w18/tis-probe 二进制** | 🔧 已补 | 根 .gitignore |
| 记忆数据 | ✅ 仓外 | 落 `~/Library/Application Support/mine-input/memory/`（MemoryStore.swift:5），demo 导出 `.demo/` 已挡 |

补后实证：`git status` 不再出现 `?? core/ ?? macos/squirrel/ ?? macos/w20/.build/ ?? macos/w18/tis-probe`。

## 4. 权限最小化（交付 c）

### 4.1 Android Manifest 逐条正当性

| 权限/属性 | 正当性 | 结论 |
|---|---|---|
| `INTERNET` | 用户 Hub 同步（FR7）+ 模型首用下载（W14）；运行时出口仅用户 Hub/回环 | ✅ 保留，最小 |
| `RECORD_AUDIO` | PTT 语音输入（FR3）；长按触发、16k mono 内存缓冲**不落盘**、Android 13+ runtime 授权 | ✅ 保留，最小 |
| 存储/定位/通讯录/相机等 | 未声明 | ✅ 面最小 |
| `allowBackup=false` | 防数据经 adb backup 外流 | ✅ |
| `usesCleartextTraffic=true` | W11 明示：LAN 明文 Hub 模式 | ⚠️ 已知缺口：远程部署前换 network security config（SECURITY.md §5/§9） |
| Activity exported（Main/Consent/Settings/Section） | Main=launcher 必须；其余供 e2e `am start`（w11-e2e.py:165,188 实证依赖） | ⚠️ 低风险残留，建议 release 收敛 exported=false |

### 4.2 DebugReceiver release 关闭验证

```text
DebugReceiver.kt:29  if (ctx.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
                         return // release 包不响应 }
```
- 所有调试钩子（W11 status/consent/seed/sync/ingest、W14 语音、W16 引擎）**唯一入口** DebugReceiver.onReceive，门在首行——release 包（非 debuggable）收到广播立即 return，钩子全部失效。
- W14Debug/W16Debug 自身无独立接收器（Manifest 仅一个 receiver），出口收敛 ✅。
- 验证方式：代码级门 + debug 包 e2e 正常（w11/w14/w16-e2e 全绿为前置基线）；**未**做 release APK 动态注入验证（诚实标注：静态证据充分，动态验证留待发布流水线）。

### 4.3 macOS 敏感能力与同意门绑定

| 能力 | 门控链 | 证据 |
|---|---|---|
| 屏幕采集（C1） | C1 总开关（**默认关**）→ `c1Screen` 子开关 → 密码框 `secureInput` 自动停（不可关）→ 黑名单跳过 → 熔断即时停 | W12C1Collector.swift:97-101,210-215；截图 OCR 后弃原图不落盘 |
| C1 音频 | `c1Audio` 子开关 → C1 总开关 → 同上 | W12C1Collector.swift:185-187 |
| PTT 麦克风 | 用户按住热键=显式动作同意 + 系统 TCC 弹窗；音频纯内存环形缓冲不落盘 | W7PttController.swift:8-14 |
| 采集触发时机 | 仅输入时触发 + 防抖 2s | W12 设计（W12-REPORT） |
| 一键熔断 | 全局持久，触发即停全部采集/记忆（CircuitBreaker） | CircuitBreaker.swift + MemoryCoreTests 13/13 ✅ |

## 5. Hub 安全面核查（交付 d）

| 项 | 状态 | 实证 |
|---|---|---|
| TLS 默认开 | ✅ | smoke.sh:21 默认 `https://localhost:8443` + CA 验证；无 CA 负例拒绝（W17-REPORT §6）；nginx `ssl_protocols TLSv1.2 TLSv1.3`；证书固定 RSA-2048 |
| token 鉴权 | ✅ | auth.py：HMAC-SHA256、TTL 7 天、`hmac.compare_digest`；main.py 全部 `/v1/*` 经 `Depends(current_user)` 401 强制 |
| 口令存储 | ✅ | PBKDF2-SHA256 200k 迭代 + 随机盐（db.py:83,122） |
| 多用户隔离 | ✅ | 全部 SQL `WHERE user_id=?`（db.py 191/206/247/262/300/306/310）；W4 双用户互不可见实测 |
| hub-secret | ✅ | 32B 随机、0600、不入库（db.py:108-117 + .gitignore） |
| 审计日志 | ✅ | suggest 只记字段长度（main.py:188-192） |
| 静态加密 | ❌ 预留位 | hub.db 明文落卷（W17-REPORT:254 自认） |
| E2E 零知识 | ❌ 未启用 | key_partition 已签发（DEPLOY-FRIENDS §4） |
| 速率限制/锁定 | ❌ 无 | `git grep rate.?limit\|lockout` 0 命中；口令最短 4 位 |
| token 吊销 | ❌ 无 | 仅 TTL 过期 |
| 证书轮换 | ❌ 手动 | 825 天过期，FORCE=1 重签 |

## 6. 修复项清单（本次提交）

| 文件 | 改动 |
|---|---|
| 18 个报告/日志/文本 | 个人路径脱敏 ×375（`/Users/<用户名>`→`/Users/you`） |
| android/w11-e2e.py、w14-e2e.py、w16-e2e.py | ADB/APK 路径改 env/动态解析 |
| schema/tests/ascii_shift_probe.c | RIME 目录改 `$HOME` 动态解析（clang 语法过） |
| context/W9-REPORT.md、hub/W17-REPORT.md、MemoryCoreTests.swift、design/generate_svg.py、design/svg/M7-*.svg | 机器名脱敏（§2.5） |
| .gitignore（新建）、hub/.gitignore | §3 五类缺口补齐 |
| SECURITY.md（新建） | 威胁模型/无遥测承诺/数据分类表/端点清单/漏洞报告渠道/已知限制 |
| macos/W21-REPORT.md（新建） | 本台账 |

回归验证：context `swift test` **MemoryCoreTests 13/13 + ContextCoreTests 11/11 全绿**（fixture 改名后复测）；三个 e2e 脚本 `py_compile` 过；`clang -fsyntax-only` 过。

## 7. 已知缺口与风险（不粉饰）

1. **git 历史残留**：14 commits / 2465 行个人路径 + author email 含主机名——发布前必须 `git filter-repo`（并行车道期不宜执行）。
2. **Hub 静态加密/E2E 为预留位**：Hub 管理员可读库文件（技术方案 FR8 的「静态加密」尚未实现）。
3. **下载供应链 TOFU**：A1/A2（git clone 未钉 commit）、A7/A8/A9/A11（记录或无校验）——建议补钉 SHA256/commit。
4. **Android 明文流量开关**保留（LAN 模式）；**Hub 无速率限制**、口令最短 4 位、token 不可吊销。
5. DebugReceiver release 关闭为**静态**验证（FLAG_DEBUGGABLE 门），未跑 release APK 动态注入测试。
6. exported Settings/Section/Consent Activity 收敛为建议项未改（会破坏 w11-e2e 的 `am start` 断言链，留待 Android 车道配合）。
7. 上游 Squirrel 的 `SUFeedURL` 仍在 Info.plist（自动检查已关；若用户手动「检查更新」会访问 rime.github.io）。
