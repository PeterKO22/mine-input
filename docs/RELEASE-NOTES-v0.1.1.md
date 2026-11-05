# v0.1.1 — 英文模式与密码框隐私

> **English summary** — Incremental release over v0.1.0: the macOS design is ported to Android,
> fixing "Chinese-only input". Highlights: persistent 中/EN keyboard toggle (survives restarts)
> with direct English/number/symbol commit (Sogou-style `commit_code`, bypassing the engine), a
> `?123` symbol panel, number-key 1-9 candidate picking in Chinese mode, and English insertion
> inside Chinese strings; password-field privacy (auto-switch to English and forced non-switchable
> while focused, all context capture and AI/cloud calls disabled, restored on leaving — e2e-verified
> zero capture logs); AI smart-candidate badges (cyan glass card + "AI" tag); and a public macOS ↔
> Android feature-parity table. Assets: Android APK (release-signed, upgrades from v0.1.0), macOS
> one-command package, `SHA256SUMS.txt`. The full notes below are in Chinese.

对 v0.1.0 的增量：把 macOS 版的设计同步进 Android，解决「只能输入中文」问题。

## 亮点

- **Android 英文模式**：键盘工具栏「中/EN」持久切换（跨重启保留）；英文态字母/数字/符号直接上屏（搜狗式 commit_code 语义，不过引擎）；`?123` 符号面板；中文态数字键 1-9 选候选；中文串中插英文的混合场景支持。
- **密码框隐私（Mac C1 设计同步）**：焦点进入密码框（textPassword / textVisiblePassword / webPassword / numberPassword）自动切英文且强制不可切回，同时**关闭一切上下文采集、不调 AI/云端**；离开密码框自动恢复。e2e 实证零采集日志。
- **AI 智能候选标记**：AI 组候选以 cyan 玻璃卡 + 「AI」角标渲染（来源接线列 TODO-C）。
- **功能平价表**：macOS ↔ Android 8 项对照公开在 `docs/平价表-macos-android.md`（提案卡 / 记忆管理的 Android 版列 TODO-A/B）。

## 下载

| 资产 | 说明 |
|---|---|
| `mine-input-v0.1.1-android.apk` | Android 侧载安装（正式签名，可从 v0.1.0 直接升级） |
| `mine-input-v0.1.1-macos-arm64.zip` | macOS 一键安装（内含 install.sh / uninstall.sh / 快速开始） |
| `SHA256SUMS.txt` | 校验和（CI 构建后自动生成，建议核对） |

macOS 端 Gatekeeper 提示：右键 App → 打开，或 `xattr -dr com.apple.quarantine /Applications/提炼输入法.app`（详见包内 README）。

## 安全

- 构建产物由 GitHub Actions 从本仓库源码按 pin 的 commit 编译，可复现；
- 「无遥测」承诺与威胁模型见 [SECURITY.zh-CN.md](../SECURITY.zh-CN.md)；
- 语音模型不随包分发，按 [INSTALL.zh-CN.md](../INSTALL.zh-CN.md) 本地获取（不出网上报）。

## 变更明细

- 提交 `3f584d6`（11 文件），审计台账见 `android/W24-REPORT.md`；
- e2e：新增 `android/w24-e2e.py` 45 断言全绿 + w16 20/20 / w14 32/32 / w11 13/13 回归全绿。
