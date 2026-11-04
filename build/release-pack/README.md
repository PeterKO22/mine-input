# 提炼输入法（Mine Input）— macOS 快速开始

五笔 86 + 拼音混合、按住即说的输入法。本包由 GitHub Actions 从源码编译产出
（pin 的第三方 commit，见仓库 `build/fetch-sources.sh`），**不含任何模型权重、
密钥或用户数据**。

## 安装（macOS 13.0+，arm64）

```bash
bash install.sh
```

然后：系统设置 → 键盘 → 输入法 → 添加「提炼输入法」（Mine Input）。
（macOS 对输入法列表有缓存，看不到就注销重登一次。）

> **Gatekeeper 提示**：本包未签名/未公证（M5 决策）。`install.sh` 已自动清除
> 隔离属性并 ad-hoc 签名；若系统仍拦截，右键 App → 打开，或执行：
> `xattr -rd com.apple.quarantine ~/Library/Input\ Methods/Squirrel-dev.app`

## 试一试（TextEdit）

| 敲 | 得到 |
|---|---|
| `w` | 首选「人」（五笔一级简码，形码优先） |
| `pinyin` | 「拼音」排最前（无五笔命中 → 拼音兜底） |
| `nihao` | 「你好」（拼音词组） |
| `zni` | 反查候选，注释里显示五笔编码 |

- 四码自动上屏=关、空码顶字=关、候选 8 个；词频学习 + 自动造词常开。
- PTT 语音：按住右⌘说话，松开上屏（首次会请求麦克风权限；音频不落盘）。

## 隔离说明（不碰你现有的输入法）

- 装到 `~/Library/Input Methods/Squirrel-dev.app`（用户级），与官方 Squirrel 共存；
- 数据目录固定 `~/Library/Rime-mine-dev`，**不读写** `~/Library/Rime`；
- bundle id / 连接名均带 `.dev`，卸载一键干净。

## 卸载

```bash
bash uninstall.sh          # 保留学习数据
bash uninstall.sh --purge  # 连 ~/Library/Rime-mine-dev 一起删
```

## 更多

- 完整文档：<https://github.com/PeterKO22/mine-input>（README / INSTALL.md）
- 安全承诺（无遥测、数据不出你的地盘）：<https://github.com/PeterKO22/mine-input/blob/main/SECURITY.md>
- AI 模型（可选，不随包分发）：`models/fetch_model.sh` + `models/MODEL-SOURCE.md`
