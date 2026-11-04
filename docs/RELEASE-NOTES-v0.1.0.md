# 提炼输入法 v0.1.0（Mine Input）

> 五笔 86 + 拼音混合、按住即说的输入法（macOS + Android），背后是**你自己的 AI**。
> **本 Release 的全部安装包由 GitHub Actions 从本仓库源码在 CI 编译产出**（可复现、可审计），
> 不分发任何本地打包产物；构建流程见 [release.yml](.github/workflows/release.yml)。

## 资产清单

| 资产 | 说明 |
|---|---|
| `mine-input-v0.1.0-android.apk` | Android APK（arm64-v8a，发布密钥签名） |
| `mine-input-v0.1.0-macos-arm64.zip` | macOS arm64 包：Squirrel.app + `install.sh` + `uninstall.sh` + 快速开始 README |
| `SHA256SUMS.txt` | 上述资产的 SHA256 校验和 |

校验下载完整性：

```bash
shasum -a 256 -c SHA256SUMS.txt    # Linux 用 sha256sum -c SHA256SUMS.txt
```

## 快速开始

### macOS（arm64，13.0+）

1. 下载 `mine-input-v0.1.0-macos-arm64.zip` 并解压；
2. `cd mine-input-v0.1.0-macos-arm64 && bash install.sh`；
3. 系统设置 → 键盘 → 输入法 → 添加「提炼输入法」（Mine Input）；
4. TextEdit 里试一试：`w`→人、`pinyin`→拼音、`nihao`→你好、`zni` 反查五笔编码。

> 未签名/未公证（M5 决策）：`install.sh` 已自动清 Gatekeeper 隔离属性并 ad-hoc 签名；
> 若系统仍拦截，右键 App → 打开（README/INSTALL 同步明示）。

卸载：`bash uninstall.sh`（`--purge` 连学习数据一起删）。装到用户级
`~/Library/Input Methods/Squirrel-dev.app`，与官方 Squirrel 完全隔离，数据目录
`~/Library/Rime-mine-dev`，不触碰 `~/Library/Rime`。

### Android

1. 下载 `mine-input-v0.1.0-android.apk`；
2. 允许「未知来源」后安装；
3. 系统设置 → 语言与输入法 → 启用「提炼输入法」→ 选择键盘。

## 🔒 安全承诺

见 [SECURITY.md](SECURITY.md)：**无遥测**、数据只进你自己的设备与自托管 Hub、
采集分级 + 显式同意（密码框/支付场景自动暂停）、一键熔断。发布物不含任何用户数据、
密钥或模型权重；第三方依赖归属与分发边界见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 模型获取说明（不随包分发）

AI 语音/建议能力需要本地模型，**任何模型权重都不在 Release 资产内**：

- 语音模型（SenseVoice，约 550MB）：见 [INSTALL.md](INSTALL.md) §3 的 fetch 脚本；
- AI 对话模型（Qwen2.5 GGUF）：`models/fetch_model.sh`，源与 SHA256 实测记录见
  [models/MODEL-SOURCE.md](models/MODEL-SOURCE.md)；
- **不装模型也能用**：混合输入（五笔 86 + 拼音混输、反查、词频造词）是纯本地引擎，零模型依赖。

## 可复现构建

- macOS 包：按 pin 的 commit 浅克隆第三方源码（librime `e930f57b…`、squirrel `d220b92a…`，
  子模块由 gitlink 固定），见 [build/fetch-sources.sh](build/fetch-sources.sh)；
- Android 包：外部依赖（sherpa-onnx AAR、commons jars、librime_jni.so）全部 SHA256 钉死
  后由 `android/fetch-deps.sh` / `android/fetch-rime-jni.sh` 可复现获取；
- 构建流程本身在 [ci.yml](.github/workflows/ci.yml)（测试门）与
  [release.yml](.github/workflows/release.yml) 中可审计。

## 已知限制

- macOS 包未签名/未公证：按上方 Gatekeeper 步骤打开（M5 决策）；
- Android 为侧载分发，未上架应用商店；
- Git 历史首笔提交的作者信息有残留，计划后续 filter-repo 清洗（安全审计 W21 台账已知限制）。
