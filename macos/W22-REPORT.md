# W22-REPORT — 发布物料（release-packaging）

> 车道：W22 release-packaging｜日期：2026-11-04｜范围（写权限）：根 README.md、LICENSE、
> THIRD_PARTY.md、INSTALL.md、config/、docs/RELEASE-CHECKLIST.md + 本报告。

## 1. 交付物

| 文件 | 内容 | 验证 |
|---|---|---|
| `LICENSE` | GPL-3.0 全文（674 行） | SHA256 `3972dc97…36986`，与 gnu.org/gpl-3.0.txt 直拉一致 |
| `THIRD_PARTY.md` | 逐依赖许可证归属 + 分发边界 + GPL 合规要点（A 入库/B 构建分发/C 不随包/ D 工具链四表） | **28 项逐条 curl 实证**：27/28 直拉成功（URL+SHA256 入表）；Sparkle 上游 raw 404（文件布局差异），改以 vendored 副本 `macos/squirrel/Sparkle/LICENSE`（sha256 `78babcec…25f6`）如实标注 |
| `README.md` | 公开版重写：产品定位（提炼输入法/Mine Input）/ 功能矩阵 8 行 / 🔒 安全承诺专区（无遥测、数据只进自有 Hub、链 SECURITY.md）/ 🤖 AI 可配置专区（config/ai.example.yaml 四键 + 账号登录路线）/ 安装速览 / 构建依赖清单 / ASCII 架构图 / 路线图 / 文档索引 | 相对链接全核：仅 SECURITY.md 缺（W21 负责，按约定先链接） |
| `INSTALL.md` | 四块总览 + macOS/Android/语音模型/Hub 逐步命令 + §5 AI 配置 + 卸载 + 故障速查 | 命令均出自仓内实测脚本（build-*.sh、fetch-*.sh、smoke.sh、run-llama-native.sh） |
| `config/ai.example.yaml` | 用户可改 AI 配置（逐键注释）：backend=local_gguf\|openai_compatible\|hub、model、endpoint、budget_ms、allow_stub_fallback + env 映射表 | `yaml.safe_load` 解析通过 |
| `config/ai-env.sh` | **Hub 读取该文件的最小支持**：ai.yaml → MODEL_NAME/MODEL_URL/SUGGEST_BUDGET_MS/SUGGEST_ALLOW_STUB_FALLBACK | 5 场景实测通过（见 §2） |
| `config/ai-compose.override.yml` | 把 budget_ms 透传进 Hub 容器（补 docker-compose.yml 未列之键，不改 hub/ 原文件） | `docker compose config` 合并实测：SUGGEST_BUDGET_MS=1200 正确出现在 hub 服务环境 |
| `config/.gitignore` | `config/ai.yaml` 不入库 | — |
| `docs/RELEASE-CHECKLIST.md` | 发布前 6 区检查清单（合规/卫生/文档/构建测试/分发物/发布后），每项带复核命令 | — |

## 2. config/ai-env.sh 实测（全部通过）

1. 示例文件 → 正确导出 7B/8092/800/1 ；2. 定制值（引号+行内注释+false）→ 0.5B/1200/0 正确剥离；
3. 环境变量优先（MODEL_NAME 已设不被文件覆盖）；4. 缺文件 → 退出码 1 + 引导提示；
5. `eval "$(...)"` 后四变量在 shell 中生效。compose 合并（第 6 项）见上表。

## 3. 许可证核验结论（要点）

- **GPL-3.0-only 为合规交集**：Squirrel（GPL-3.0）+ Trime JNI（GPL-3.0-or-later）→ GPLv3；librime BSD-3 自由组合；
- **RIME 词库实测归属**（与坊间记忆不同，以 curl 原文为准）：rime-wubi / rime-prelude / rime-essay /
  rime-stroke 均 **LGPL-3.0**；rime-pinyin-simp **Apache-2.0**——数据原样随附+署名即合规；
- **Qwen2.5 Apache-2.0（不随包分发）**：GitHub QwenLM/Qwen2.5 无 LICENSE 文件（404），实证取
  HuggingFace 权重仓 raw LICENSE（sha256 `832dd9e0…e92e`）；模型仅经 fetch 脚本自取；
- 两个 >1MB 词库 YAML（wubi86.dict.yaml 2.2MB / pinyin_simp.dict.yaml 1.2MB）是预侦察所述入库大文件，
  归属已入 A 表。

## 4. 遗留 / Blocker / 越权说明

1. **SECURITY.md 尚不存在**（W21 并行负责）：README 已按约定链接，发布前须落地（已写入
   docs/RELEASE-CHECKLIST.md §3）；
2. **写权限约束下的 Hub 侧最小支持**：任务允许「hub 读取该文件的最小支持」，但本车道写权限
   不含 `hub/`——故实现为 `config/ai-env.sh` + `config/ai-compose.override.yml`（compose 多文件合并，
   语义等价于往 hub 容器传 env，已实测）。若后续允许改 hub/，可升级为 hub 直接读 YAML；
3. **backend=openai_compatible 为预留值**：Hub 上游仅实现 llama.cpp /completion，选此项需自架
   兼容代理（README/ai.example.yaml 已诚实标注，勿写成已支持）；
4. **Sparkle 许可证 curl 404**：raw.githubusercontent.com 各路径/分支/标签均 404，以构建树
   vendored 副本为证（THIRD_PARTY 表内如实标注），发布后可再核上游布局；
5. macOS 发布签名/公证（M5）、发布密钥签名 APK 未做（属发布动作而非物料），已列入
   RELEASE-CHECKLIST §5；
6. 未动任何既有文件（README.md 为根 README 公开版重写，按任务指定范围执行）；工作树中
   既有未收口改动（docs/ 等他车道文件）未触碰、未提交。

## 5. 提交

单提交 `W22: release-packaging——…`，仅含上述白名单文件。
