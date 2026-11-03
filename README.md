# mine-input

个人专用输入法：五笔 86 + 拼音混合、语音输入（按住即说）、自托管 AI（本地/远程 Hub）、
上下文感知动态提词器，越用越贴手。**当前范围：macOS + Android 先行**（Windows/iOS 后续再排）。
个人自用，亦可分发给朋友（数据全端同步，隐私不出自家地盘）。

## 当前状态

**开发中（2026-11-04 起）** —— Wave 1 六车道多 Agent 并行开发已启动，任务图与约定见 [docs/开发任务计划.md](docs/开发任务计划.md)。

## 文档索引

| 文档 | 说明 |
|---|---|
| [docs/需求文档-v1.0.md](docs/需求文档-v1.0.md) | **需求定稿**：决策台账 D1–D14、场景、FR/NFR、验收标准 |
| [docs/技术方案-v0.4.md](docs/技术方案-v0.4.md) | **技术定稿**：架构、模块、里程碑（Mac+Android）、遗留实测项 |
| [design/design-language.md](design/design-language.md) | **统一设计语言**：伴生系统深色科幻 token（唯一风格源） |
| design/svg/ + generate_svg.py | 16 张交互线框（生成器可复现；待按 design-language 换肤） |
| docs/技术方案-v0.3.md | 全端愿景版（Windows/iOS 硬墙结论留档于此） |
| docs/技术方案-v0.2.md / v0.1 | 历史留档 |

## 已拍板决策（2026-11-03）

- 五笔 **86**
- 语音：**按住指定键**即开始听写（Push-to-Talk），无唤醒词
- AI：默认**本地**后端（离线优先），云端仅作可选
- 词库：无存量导入，核心在**使用中自适应学习**（词频、造词、热词、习惯调参）
- 分发：可能给朋友用 → GPLv3 合规 + 签名分发提前纳入计划
- 命名：目录/仓库用横线 `mine-input`（kebab-case）

**v0.3 追加（同日）**：

- 平台扩为 **macOS / Windows / Android / iOS** 四端，能力分级（iOS 为伴侣版）
- AI 后端 = **自托管 AI Hub**（本地常驻设备或自有远程服务器，可切换）
- 输入习惯（语音+文本）**全端同步**，学习成果全端共享
- **上下文引擎**：按下键盘时自动采集屏幕/音频（分级可控），记录交互过程
- **动态提词器**：快捷键唤起流式建议，语音输入中建议实时刷新

## 技术底座（已核实）

| 能力 | 选型 | 许可证 |
|---|---|---|
| 输入引擎 | librime | BSD-3-Clause |
| macOS 外壳 | fork Squirrel（InputMethodKit） | GPLv3 |
| Windows 外壳 | fork Weasel（TSF） | GPLv3 |
| 五笔+拼音混合 | rime-wubi (86) + rime-pinyin-simp | 见各配方 LICENSE |
| 语音（离线） | sherpa-onnx（SenseVoice/Paraformer + VAD + 标点） | Apache-2.0 |
| AI 辅助 | 自研 SPI，本地 GGUF（llama.cpp）默认 | 自有 |

## 里程碑速览

M0 骨架 → M1 混合输入+自学习 → M2 语音 MVP（macOS）→ M3 AI 本地 → M4 Windows 对齐 → M5 分发准备（按需触发）

详见设计文档 §7。
