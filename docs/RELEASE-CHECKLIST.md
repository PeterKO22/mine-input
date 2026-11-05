# docs/RELEASE-CHECKLIST.md — 发布前检查清单

> 用途：每次对外发布（GitHub 公开仓 / 分发给朋友）前逐项打勾。带 ☐ 的都要有实证
> （命令输出/截图/日志），不许凭印象。发现不合格项 → 停止发布，先修。
> 维护：发布负责人；涉及安全项与 SECURITY.md 对齐（W21 负责该文件）。

## 1. 许可证与合规（GPLv3，决策 D5）

- [ ] 根目录 `LICENSE` 为 GPL-3.0 全文（674 行，与 https://www.gnu.org/licenses/gpl-3.0.txt 一致）
- [ ] `THIRD_PARTY.md` 存在且**逐条 curl 实证**未过期（URL 可达、SHA256 与表内一致）
      复核命令：`curl -s <URL> | shasum -a 256`（对照表内缩写值）
- [ ] RIME 词库配方（rime-wubi / rime-pinyin-simp / rime-prelude）LICENSE 署名随数据文件保留
- [ ] Trime 派生 Kotlin（`android/.../com/osfans/trime/core/`）SPDX GPL-3.0-or-later 头在位
- [ ] `android/LICENSE.md` 与 `THIRD_PARTY.md` B 表 Android 行一致（librime_jni.so 归属）
- [ ] 二进制分发物的**对应源**可用：本仓 + `build/squirrel-*.patch` + 上游 URL（GPLv3 §6）
- [ ] Qwen2.5 等模型权重**不在**任何分发包内（仅 fetch 脚本可取）

## 2. 仓库卫生（不泄私、不塞垃圾）

- [ ] `git ls-files | wc -l` 与预期一致；无新增大文件（>1MB 仅允许 `schema/deps/*.dict.yaml` 两个词库）
- [ ] 无密钥/证书/私货入库：`hub/tls/certs/`、`hub-secret`、`config/ai.yaml`、`*.gguf`、模型/venv 全部 .gitignore
- [ ] 无个人路径/主机名/邮箱泄漏：`grep -rn "/Users/" --include='*.md' --include='*.yaml'` 结果审阅（另按本机用户名/主机名各扫一遍）
- [ ] 日志类文件（`build/logs/`、`voice/poc/last_run.json`）内容不含隐私输入样例
- [ ] `.gitignore` 覆盖：`models/`、`voice/models/`、`voice/.venv/`、`android/**/jniLibs/`、`config/ai.yaml`

## 3. 文档完整性

- [ ] `README.md` 结构完整：产品定位 / 功能矩阵 / 🔒 安全承诺 / 🤖 AI 可配置专区 / 安装 / 构建依赖 / 架构图 / 路线图
- [ ] README 链接全部可达（相对链接逐个点过或脚本核）：INSTALL.md、THIRD_PARTY.md、SECURITY.md、docs/、hub/DEPLOY-FRIENDS.md、android/LICENSE.md
- [ ] `SECURITY.md` 已就位（W21 交付）且与 README 安全承诺无矛盾
- [ ] `INSTALL.md` 步骤在**干净环境**逐条走通（或标注未实测项）
- [ ] 产品名统一：中文「提炼输入法」/ 英文 "Mine Input"（D15），macOS 输入源、Android 应用名、README 标题三处一致
- [ ] 发布文档双语：README / INSTALL / SECURITY 中英双版齐备（英文版用标准文件名，中文版 `*.zh-CN.md` 逐字保留），顶部互挂语言切换行；README/RELEASE-NOTES/报告里引用它们的相对链接指向对应语言版本且逐一可解析
- [ ] `config/ai.example.yaml` 四键（backend/model/endpoint/budget_ms）与 README AI 专区、INSTALL §5 表述一致

## 4. 构建与测试（实测打勾，不走过场）

- [ ] macOS：`bash build/build-librime.sh && bash build/build-squirrel.sh && bash build/install-dev.sh` 全绿
- [ ] `bash build/verify-schema.sh` 通过；手工输入冒烟（w/gggg/nihao/zni 反查）
- [ ] 回归：W7 回放 17/17 + 挂点 22/22；W9 11/11；W20 swift 15/15 + ctest 4/4（或当期等价套件）
- [ ] Android：`./gradlew assembleDebug` 出 APK；`bash android/w16-e2e.py`（或当期 e2e）全绿
- [ ] Hub：`cd hub && ./smoke.sh` ALL GREEN（42/42）；TLS 通（curl --cacert /healthz）
- [ ] 语音：`voice/poc` 样音转写冒烟通过（若本版改动语音链路）
- [ ] `config/ai-env.sh` 五场景（示例/定制/优先级/缺文件/eval）复测通过

## 5. 分发物

- [ ] macOS：签名/公证决策已做（M5）——未公证则 README/INSTALL 明示 Gatekeeper 处理步骤
- [ ] Android：APK 已用发布密钥签名（非 debug）；`aapt badging` 核应用名=「提炼输入法」
- [ ] 版本号/标签：`vX.Y.Z` 语义化；commit 已收口（工作树 `git status` 干净或仅白名单改动）
- [ ] Release 附件清单：APK、（可选）Squirrel 压缩包、checksums.txt（SHA256）
- [ ] 分发包内**不含**：模型权重、hub-secret、CA 私钥、任何用户数据

## 6. 发布后

- [ ] 公开仓链接、安装文档在 README 首屏可达
- [ ] 打 tag、写 Release notes（含第三方归属链接 THIRD_PARTY.md、安全承诺链接 SECURITY.md）
- [ ] 朋友分发：走 [hub/DEPLOY-FRIENDS.md](../hub/DEPLOY-FRIENDS.md)（地址 + CA + 注册），知情同意页在位
- [ ] 观察一周内 issue：许可证/安全类 issue 按 SECURITY.md 流程响应

---
*创建：W22（2026-11-04）。每次发布后把发现的漏项回填进本清单。*
