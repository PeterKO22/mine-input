# W6 REPORT · design 车道 — mine-input 交互线框深色科幻换肤

> 做了什么 / 怎么验证 / 遗留与 blocker。风格源：`design/design-language.md`（唯一风格源）。

## 做了什么

- `design/generate_svg.py` 色彩与效果 token 层整体换成 design-language.md 深色科幻规范；**16 张屏幕的布局坐标零改动**，只换 token、效果与数字字体栈。
- 发光 glow 用 `<filter>` + `feGaussianBlur`（`glowGold` / `glowCyan` / `glowRed` 三个滤镜，svg `<defs>` 注入），严格只用于：选中态、进度条填充、数值强调、当前态（当前候选 / 听写中 / 生成中 / 当前路线）；超出同屏 ≤3 预算处改用「描边提亮近似」（`GOLD_HI` 细描边，见 M6 数值、M9 KPI）。
- 数字文本字体栈加 mono：`'SF Mono','JetBrains Mono','Menlo',monospace`（候选序号、KPI 数值、计数、热键框、模型名、URL、配对码、时钟、编码 `kwwl` 等，共 50 处）。
- 组件形态按 §4 收敛：chip = 深底 + 同色亮描边 + 同色字（chip() 自动描边）；主按钮 = 金实心 + 深色字 + 微光晕；次按钮 = 深底 + 细描边 + 浅字；危险按钮 = 暗红填充 + 红描边 + 红微光；开关 = 金开 / 暗灰关；连线 = 点状虚线 2px + 同色系；M3 上下文条用 HUD 弱网格底（`hudGrid` pattern）；M3/A3 面板 card-glass（`fill-opacity 0.8`）。
- 按 §5 逐屏映射：M1 当前候选金填充微光 + AI 列青描边玻璃卡；M2/A2 听写中青发光脉冲圆 + 青波形（未激活段 `CYAN_DIM`）；M4–M7 分区标题 gold 小字、开关金/灰、热键 mono、Hub 状态绿 chip；M8 C0=青 / C1=红 / 数据去向=金；M9 KPI 数值 gold mono 微光、建议卡金 accent 边；M6/M10 熔断危险形态；A1 深色键帽 + PTT 金实心大键（键位排布未动）。
- 重新生成全部 16 张 SVG（`design/svg/`），生成器末尾内置 `xml.etree.ElementTree` 全量校验（可复现）。

## Token 对照表（design-language.md 值 → 代码常量名 → 最终取值）

### 基底（§1）

| design-language token | 值 | 代码常量 | 最终取值 | 用途落地 |
|---|---|---|---|---|
| `bg` | `#0E2924` | `BG` | `#0E2924` | 画板底、侧栏/听写面板、次按钮深底 |
| `card` | `#18352F` | `CARD` | `#18352F` | 卡片/模块/键帽/输入框填充 |
| `card-glass` | `#18352F` @ ~80% | `CARD_GLASS` | `#18352F` + `fill-opacity="0.8"` | M3/A3 悬浮面板、M1 AI 列 |
| `stroke` | `#2B4B44` | `STROKE` | `#2B4B44` | 全部描边/分隔线，统一 1px |

### 强调色（§1）

| design-language token | 值 | 代码常量 | 最终取值 | 语义 |
|---|---|---|---|---|
| `gold` | `#D4A857` | `GOLD` | `#D4A857` | 数值/进度/主按钮/选中/候选序号/当前候选 |
| `cyan` | `#388A83` | `CYAN` | `#388A83` | 路径/状态/听写中/生成中/AI 列/输入通路 |
| `purple` | `#5D3D8C` | `PURPLE` | `#5D3D8C` | 分类强调（本批 16 屏无推演/计算类功能，未用到） |
| `red` | `#A84B3D` | `RED` | `#A84B3D` | 危险/重要/熔断/C1 高敏 |
| `green` | `#4CB368` | `GREEN` | `#4CB368` | 成功/完成/接受/常开/已连接 |

### 文字层级（§1）

| 层级 | 色值 | 代码常量 | 最终取值 | 字重用法 |
|---|---|---|---|---|
| 模块标题 | `#E0E6E4` | `TXT_HI` | `#E0E6E4` | Bold 600–700 标题 |
| 正文/核心 | `#C8D0CC` | `TXT_BODY` | `#C8D0CC` | Medium 400–500 正文/行标签 |
| 弱化/辅助 | `#8A9E99` | `TXT_DIM` | `#8A9E99` | Regular 辅助/提示 |
| 数值强调 | `gold` 或白 | `GOLD`（+ `GOLD_HI` 提亮描边） | `#D4A857` / `#E8C98C` | Bold + mono + 微发光 |
| 数字 mono 栈 | SF Mono/JetBrains Mono 档 | `MONO` | `'SF Mono','JetBrains Mono','Menlo',monospace` | 数字/编码/热键/模型名一律 mono |

### 派生值（非 spec 直给，均由上列 token 混合/取用，附推导）

| 代码常量 | 最终取值 | 推导 |
|---|---|---|
| `GOLD_TINT` | `#273E32` | gold 8% 混 card：金 chip / 选中深底 |
| `CYAN_TINT` | `#1B3E37` | cyan 10% 混 card：状态 / 听写深底 |
| `RED_TINT` | `#263730` | red 10% 混 card：危险 chip 深底 |
| `GREEN_TINT` | `#1D4235` | green 10% 混 card：成功 chip 深底 |
| `CYAN_DIM` | `#23534C` | cyan 35% 混 card：波形未激活段 |
| `GOLD_HI` | `#E8C98C` | 金提亮，作微发光的「描边提亮近似」 |
| `OFF` | `#2B4B44` | 开关关闭态（暗灰=关，取 stroke 色） |
| `KNOB` | `#E0E6E4` | 开关旋钮 |
| `DARK_INK` | `#0E2924` | 金实心按钮深色字（主按钮=深色字） |

### 效果（§3）

| 规则 | 落地 |
|---|---|
| glow 仅选中/进度/数值/当前态 | `glowGold`/`glowCyan`/`glowRed`（feGaussianBlur stdDeviation 2.5 + 双层 feMerge）；逐屏 ≤3 处，超出用 `GOLD_HI` 描边提亮近似 |
| 渐变仅局部功能件 | 进度条以「暗轨 OFF + 金填充」表达（同屏 ≤3 预算下未叠渐变）；波形以 CYAN→CYAN_DIM 分段近似青渐变 |
| 连线点状虚线 2–3px | F1 连线 `stroke-dasharray="2,4"` sw=2；glow 仅当前路线（建议下行 2 条） |
| HUD 弱网格 | `hudGrid` 8px pattern（M3 上下文摘要条） |

## 怎么验证

1. `python3 design/generate_svg.py` → 16/16 生成，末尾内置校验输出 `validate: 16/16 XML OK (xml.etree.ElementTree)`。
2. 独立复验（不走生成器）：对 `design/svg/` 16 个文件逐一 `xml.etree.ElementTree.parse` → 16/16 well-formed，根节点均 `svg`。
3. 浅色主题残留审计（`#FFFFFF/#111827/#2563EB/#F3F4F6/#D1D5DB/#BFDBFE` 等 14 个旧 token）→ **0 残留**。
4. 发光预算审计：逐文件统计 `filter="url(#glow…)"` 引用 → 全部 ≤3（最高 M4=3）。
5. mono 栈存在性检查 → 通过，16 张共 50 处 mono 文本。

## 遗留与偏差（诚实记录）

- **F1 连线保留三角箭头**：§4 写「仅当前路线带三角箭头」，但流程图箭头承载流向语义，全部保留；虚线 + 语义配色 + 当前路线发光已按 spec 落地。如需严格收窄箭头可再改一版。
- **装饰层未启用**：星点光斑、全局噪点 grain 属「克制使用」的可选项，本批未加，保持线框干净；需要时在 `artboard()` 的 DEFS 加 pattern 即可。
- **进度条渐变未铺**：为守同屏发光 ≤3，进度条用纯金填充 + 发光，未叠「暗金→亮奶油」渐变；如放开预算可在 `GOLD` 渐变上再进一步。
- 无 blocker；`purple` token 已定义但 16 屏暂无对应语义位。
