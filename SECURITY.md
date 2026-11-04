# SECURITY.md — mine-input 安全白皮书

> 维护：W21 发布前安全审计（台账见 `macos/W21-REPORT.md`，逐项附命令与实证输出）。
> 承诺底线：**零遥测、零第三方数据上报、不存在任何数据外传通道**——你的数据只去两个地方：
> 你的设备、你自己部署的 Hub。

---

## 1. 「无遥测」承诺

- 本项目**不含**任何遥测/统计/崩溃上报/埋点 SDK（审计实证：`git grep -iE 'telemetry|analytics|sentry|crashlytics|firebase|appcenter|umeng|bugly'` 一方代码 0 命中，见 W21-REPORT §1.3）。
- 运行时网络出口是**封闭集合**：本地回环 + 用户自己的 Hub（§3 端点清单）。除此之外没有任何一方代码发起网络请求。
- 唯一的"被动"出口是上游 Squirrel 自带的 Sparkle 更新检查（`SUFeedURL` 指向 rime.github.io）——
  本项目 dev 补丁已设 `SUEnableAutomaticChecks=false`（**自动检查关闭**），只有用户手动点「检查更新」才会联网。
- 模型/依赖下载只发生在用户**显式运行** fetch 脚本时（一次性、可复现），不是运行时行为。

## 2. 威胁模型

**资产**：按键/候选选择、语音转写、OCR/ASR 摘要、习惯计数器、热词、JSONL 记忆库、Hub 账号凭据、TLS/签名密钥。

**信任边界**：
1. 设备本地（输入法进程 ↔ 本机文件系统）——完全可信；
2. 设备 ⇄ 用户 Hub（TLS 通道）——Hub 主机由用户/朋友自持；
3. Hub 服务端（主机管理员可见落库数据——见 §6 已知缺口）；
4. 供应链（构建期下载的第三方源码/二进制/模型）。

**不在威胁模型内**（明示）：设备 root/被入侵后的攻击者；Hub 主机管理员主动窥探（静态加密/E2E 未启用前技术上可见，见 §6）；国家级流量分析（自签 CA 场景不抗流量指纹）。

**防护目标**：任何数据**绝不**流向第三方服务器；高敏采集（C1 屏幕/音频、C2 语音摘要）逐项显式同意、默认全关、随时撤回、一键熔断；传输 TLS；多用户（朋友部署）互相不可见。

## 3. 数据分类表

| 数据类 | 本机存储 | 是否离机 | 去向 | 谁能看到 | 门控 |
|---|---|---|---|---|---|
| 按键/候选事件（InteractionEvent） | SQLite（InteractionStore，30 天滚动） | 同意后可选 | 用户 Hub `/v1/ingest` | Hub 管理员（明文落库） | C0 同意 + 熔断 |
| L1 userdb / L2 计数器 / L3 热词 / AI 配置 | SQLite + RIME userdb | 同意后可选 | 用户 Hub `/v1/sync/push` | 同上 | 配对 + 熔断 |
| OCR/ASR **摘要**（C1/C2，只记长度/摘要，不落原文原图） | SQLite | C2 同意才随事件携带 | 用户 Hub | 同上 | C1/C2 逐项显式同意，默认关 |
| 语音音频（PTT） | **不落盘**（16k mono 内存环形缓冲） | 否 | — | — | 用户按住 PTT 键即同意；系统 TCC |
| 屏幕截图（C1） | **不落盘**（Vision OCR 后即弃原图） | 仅摘要可选 | 用户 Hub | 同上 | C1 开关默认关；密码框（secure input）自动停 |
| JSONL 记忆库 | `~/Library/Application Support/mine-input/memory/` | 同步面可选 | 用户 Hub | 同上 | 同意分级 + 熔断 + 可编辑/删除/清空 |
| suggest 请求（before_cursor 等） | 不存（审计只记字段长度） | 按次 | 用户 Hub `/v1/suggest` | 同上 | AI 总开关默认关 |
| TLS 证书/私钥、hub-secret | `hub/tls/certs/`、`hub-data/`（0600，**不入库**） | 否 | — | 主机管理员 | .gitignore 挡 |

**离机数据总集合** = 上表「是否离机=可选/按次」各行 → 全部只去**用户配置的 Hub base_url**。除此之外零数据离开设备。

## 4. 网络出口清单（封闭集合）

### A. 用户主动下载（构建/模型获取，显式脚本触发）
| 端点 | 用途 | 完整性校验 |
|---|---|---|
| github.com/rime/librime、github.com/rime/squirrel | 源码克隆（build/build-*.sh） | depth-1 克隆，**未钉 commit**（缺口） |
| raw.githubusercontent.com（rime schema deps） | schema 依赖 | URL 内 commit SHA 钉死 ✅ |
| raw.githubusercontent.com/llvm/llvm-project | libcxx filesystem 补丁 | tag llvmorg-9.0.0 钉定 |
| github.com/k2-fsa/sherpa-onnx/releases | Android AAR + 语音模型 | SHA256 钉死 ✅（fetch-deps.sh / ModelManager.kt 边下边校验） |
| maven.aliyun.com | commons-compress/commons-io | SHA256 钉死 ✅ |
| mirrors.huaweicloud.com | Android NDK | 仅**记录** SHA256（TOFU，缺口） |
| archives.boost.io | Boost 源码 | 无校验（TOFU，缺口） |
| github.com/osfans/trime/releases | Trime APK（提取 JNI .so） | 仅**记录** SHA256（TOFU，缺口） |
| www.modelscope.cn → cdn-lfs-cn-1.modelscope.cn | Qwen GGUF 模型 | SHA256 逐一复核 ✅ |
| github.com/ggml-org/llama.cpp/releases | llama.cpp 预编译（手动下载提示） | 无强制校验（缺口） |

### B. 本地回环（运行时，永不出机）
`127.0.0.1:8088`（Hub HTTP 回退，默认只绑 loopback）、`localhost:8443`（Hub HTTPS）、compose 内网 `hub:8080`/`llama:8091`、宿主 `host.docker.internal:8092`、模拟器 `10.0.2.2:8088`。

### C. 用户自有 Hub（运行时唯一数据外发面）
base_url 由用户配置（默认 `https://localhost:8443`，TLS 默认开）；朋友部署 = `https://<朋友主机>:8443`。数据内容见 §3。

### D. 上游继承（macOS Squirrel）
`https://rime.github.io/release/squirrel/appcast.xml`（Sparkle 更新源）——自动检查已关，仅手动触发。

## 5. 权限与敏感能力（最小化核查）

**Android**（`android/app/src/main/AndroidManifest.xml`，逐条正当性见 W21-REPORT §4）：
- `INTERNET`：用户 Hub 同步 + 模型下载，正当；运行时出口仅用户 Hub。
- `RECORD_AUDIO`：PTT 语音输入，正当；长按触发、内存缓冲不落盘、runtime 授权（Android 13+）。
- 无存储/定位/通讯录/相机权限；`allowBackup=false` ✅。
- `usesCleartextTraffic=true`：保留 LAN 明文 Hub 模式（W11 明示）——**已知缺口**，远程部署前应换 network security config 限定。
- `DebugReceiver`（调试广播）：`FLAG_DEBUGGABLE` 门（`DebugReceiver.kt:29`），release 包收到即 return，钩子失效。
- Settings/Section/Consent Activity `exported=true`（e2e 经 `am start` 依赖）——低风险残留，建议 release 收敛。

**macOS**：
- 麦克风：PTT 用户按住即同意 + 系统 TCC；C1 音频另需 `c1Audio` 子开关 + C1 总开关（默认关）。
- 屏幕：`W12ScreenCapture` 经 C1 总开关（默认关）+ `c1Screen` + 密码框自动停 + 黑名单 + 熔断即时停。
- 采集只在输入时触发（防抖 2s），只落**摘要**（长度/指纹），不落原文原图。

## 6. Hub 安全面（`hub/`）

**已具备**：
- **TLS 默认开**：smoke/SDK 默认 `https://localhost:8443` + 自签 CA 验证（负例实测拒绝）；HTTP 明文只留 loopback 回退；TLSv1.2/1.3，证书固定 RSA-2048（EC 有 interop bug，W17-REPORT §5）。
- **token 鉴权**：HMAC-SHA256 签名（`hub-secret` 32B 随机、0600 落卷、不入库），TTL 7 天，全部 `/v1/*` 经 `current_user` 依赖强制鉴权；口令 PBKDF2-SHA256（200k 迭代 + 随机盐）。
- **多用户隔离**：全部 SQL 按 `user_id` 分区（W4 双用户互不可见实测）；每用户独立 `key_partition`（E2E 预留）。
- 备份含 hub-secret 提示 0600 保管；审计日志只记字段长度不记内容。

**已知缺口（如实列出）**：
1. **静态加密是预留位**：hub.db 明文落卷，备份同理——主机管理员技术上可读；
2. **E2E 零知识未启用**（key_partition 已签发，加密未实现）；
3. **无速率限制/口令锁定**：register/token 可被爆破（LAN 信任模型假设）；口令最短仅 4 位；
4. token 不可吊销（TTL 内有效）；hub-secret 泄露 = 可伪造任意用户 token；
5. 自签 CA 需带外分发 `ca.crt`，无 ACME/自动轮换（证书 825 天过期需手动重签）；
6. Android 客户端仍允许明文 HTTP（见 §5）。

## 7. 供应链与发布完整性

- 所有下载脚本的 SHA256 钉死状态见 §4A（已钉 ✅ / TOFU 缺口已标注）。
- 第三方代码（Trime GPLv3 JNI、sherpa-onnx、librime/squirrel）复用方式见 `THIRD_PARTY.md`（W22 车道维护）。
- **git 历史残留**：历史提交含开发者个人路径/主机名/author email（14 commits，W21-REPORT §2.4）；发布仓库前须 `git filter-repo` 清洗历史（本仓库 HEAD 已脱敏）。

## 8. 漏洞报告渠道

请开 **GitHub Issues** 报告安全问题（可私设仓库 issue 或联系维护者）；请勿公开披露未修复的高危漏洞利用细节。响应承诺：确认 72 小时内。

## 9. 已知限制（汇总）

见 §6 缺口 + §7 历史残留 + §5 `usesCleartextTraffic`；其余验收性限制（如 launchd 未做真机重启验证）见各车道 REPORT 的「已知限制」小节。本文件与 `macos/W21-REPORT.md` 台账随每次安全相关变更更新。
