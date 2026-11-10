# W30-REPORT — 本地模型显式开关与配置入口（不开不加载硬保证）

> 2026-11-10 · 需求原话：「加一个显示的开关和配置入口，必须用户打开才会加载本地模型」。
> 哲学：默认不开、显式开启、随时可关、状态可见。

## 1. 交付物一览

| 交付 | 位置 |
|---|---|
| ⌥M 浮层「本地模型（7B）」区块（状态/开关/配置入口） | `macos/w20/src/W20MemoryPanel.swift` |
| 开关抽象 + 生产实现（脚本驱动，唯一加载入口） | `macos/w20/src/W20ModelControl.swift`（`W20ModelControl` / `W20ModelServiceControl`） |
| Squirrel 接线（⌥M 面板注入生产实现） | `macos/w20/src/W20SquirrelGlue.swift` |
| 服务脚本收敛（start/stop/status，幂等） | `models/manage-model-service.sh`（新）；`models/run-llama-native.sh` 降为内部引擎 |
| 脚本化实测入口 | `macos/w20/tools/w20ctl` 新增 `model status\|on\|off`（on 须 `--confirm`） |
| 验收探针 | `macos/w30/scripts/w30-probe.sh` |
| pbxproj 可复现记录 | `macos/w30/squirrel-w30.patch` + `macos/w30/scripts/apply-w30.sh`（幂等实测：reverse-check ✓） |
| 配置文档（唯一配置入口） | `config/ai.example.yaml` 头注释 + `INSTALL.md §5` / `INSTALL.zh-CN.md §5` 四键表 |
| 平价表 | `docs/平价表-macos-android.md` 行 #11 + TODO-H 卡 |
| 本报告 | `macos/W30-REPORT.md` |

## 2. ⌥M 浮层「本地模型（7B）」区块（任务书 (1)）

顶部常显第三行（与 C1 / 记录我的回复同排系）：

- **状态显示**：`本地模型：未加载（默认；探活：未运行）` / `加载中（进程在，探活未过）` /
  `就绪（探活 /v1/models 通过 · :8092）`——三态 + 探活结果实时来自
  `manage-model-service.sh status`（state=not-loaded|loading|ready + probe=/v1/models|/completion|none）。
- **开关（默认关）**：
  - 开 → **显式确认弹窗**（`consentTitle`「开启『本地模型（7B）』？」+ `consentText`
    资源提示：**约 X GB 内存**（mem_hint_gb 按 7B 分片实测字节动态算，本机 5）/**仅本机推理**
    （权重与推理不出本机、不调云端）/ 端口 :8092 / 随时可关）；
  - 确认 → `setEnabled(true, explicitConfirm: true)` → `manage-model-service.sh start`
    （启动 + 健康检查 /v1/models 或 /completion）；启动在后台队列执行不阻塞输入（状态行先置
    「加载中…」），失败开关拨回；
  - **取消 → 开关拨回 off，绝不静默加载**（与 W27 C1 / W29 留存开关同模式）；
  - 关 → `setEnabled(false)` → `manage-model-service.sh stop` **立即停止**（TERM→KILL 兜底，
    返回前已确认进程死）。
- **配置入口**：显示 `config/ai.yaml` 绝对路径 + 「打开配置」按钮（`NSWorkspace.open`
  默认编辑器打开）；文件不存在时先从 `ai.example.yaml` 复制（与文档 `cp` 同一步）再打开。
- 防误触硬门（代码级）：`setEnabled(true, explicitConfirm: false)` 直接 return false
  零副作用——UI 确认弹窗之外无任何开启路径（w20ctl CLI 侧 = `--confirm` 同语义）。

## 3. 防呆审计：全仓「可能自动加载模型」路径逐条（任务书 (3)）

审计口径：launchd plist / compose restart 策略 / 代码 spawn·Process 启动点 / 文档指引；
结论 = **未开启时任何代码路径不得加载模型**（已实证，见 §5 探针 ⑨）。

| # | 路径 | 位置 | 原状 | 处置 |
|---|---|---|---|---|
| 1 | launchd 用户 agent（RunAtLoad=登录自启 + KeepAlive=崩溃拉起） | `models/com.mineinput.llama.plist` + `run-llama-native.sh load/unload/serve` | 登录即自动加载 7B，违反硬保证 | **整条删除**：plist 已 `git rm`；load/unload/serve 子命令与 do_load/do_unload/do_serve 函数删除；`manage-model-service.sh stop/status` 另清扫历史安装的 `com.mineinput.llama`（bootout + 移除 plist，legacy_launchd= 字段如实报） |
| 2 | compose restart 策略 | `hub/docker-compose.yml` llama 服务 `restart: unless-stopped` | 用过 `--profile model up` 的机器会在 Docker daemon 重启/崩溃恢复后自动拉起模型容器 | 改 **`restart: "no"`** + 注释（容器只在用户显式 up 时跑，永不自动回来）。hub/tls 服务的 `unless-stopped` 不涉模型，保留 |
| 3 | 代码 spawn/Process 启动点（Swift） | `macos/w12/src/W12AsrClient.swift:114` | Process() → python ASR（sherpa-onnx） | **保留**：语音转写进程，不加载 LLM（审计：无 llama 引用） |
| 4 | 代码 spawn/Process 启动点（Swift） | `macos/w7/src/W7PttController.swift:232` | Process() → python ASR | **保留**：同上，不涉模型 |
| 5 | 代码 spawn/Process 启动点（Swift） | `macos/w26/w26_probe.swift:219` | Process() → /usr/bin/afplay | **保留**：探针音频回放，不涉模型 |
| 6 | Hub 后端 | `hub/app/model_backend.py` | httpx 客户端连 MODEL_URL（/completion 流式） | **保留**：纯 HTTP 客户端，无 spawn、无自动起模型；模型不可达时按 `allow_stub_fallback` 降级（诚实标注），不拉起任何进程 |
| 7 | 模型灌入脚本 | `models/fetch_model.sh` | `docker run --rm` 把 GGUF 灌进卷 | **保留**：只下载/校验/灌文件，不启动服务 |
| 8 | 构建/安装脚本 | `build/install-dev.sh`、`build/uninstall-dev.sh` 等 | — | **核实无** launchd/llama 引用（全仓 grep launchctl|LaunchAgents|RunAtLoad|launchd 仅命中已删路径与文档） |
| 9 | 文档指引（自动加载口径） | `INSTALL.md §4b/§6/§7`、`INSTALL.zh-CN.md` 同、`hub/README.md`、`hub/smoke.sh` 注释 | 文档教用户 `run-llama-native.sh load`（=自启） | **改写**为显式开关口径（`manage-model-service.sh start/stop/status` + ⌥M 开关；明示「默认关闭、绝不自启」） |
| 10 | 第三方 vendored 代码 | `macos/squirrel/librime/deps/**`（googletest/leveldb benchmark 的 subprocess 工具） | 测试工具的子进程调用 | **保留**：上游测试工具，永不进 app 产物，不涉模型 |
| 11 | 新增代码（本 W30） | `W20ModelServiceControl`（Process → manage-model-service.sh） | — | **唯一加载入口**：只在 `setEnabled(true, explicitConfirm:)` 且 explicitConfirm=true 时执行 start；status/stop 只读/只停 |

红线自查：构建树 Squirrel.app **未 launch**（只 `xcodebuild build`）；单测零 sleep 伪时钟
红线不受影响（探针是真实服务生命周期实测，7B 真加载；w20/w12/context 单测仍零 sleep）；
未碰 `.github/`、`docs/RELEASE-NOTES*`。

## 4. models/ 服务脚本收敛（任务书 (2)）

`models/manage-model-service.sh {start|stop|status}`——服务操作唯一入口（与 ⌥M 开关同源）：

- `start`：已在跑且探活通过 = **幂等 no-op**（原话「幂等 no-op，不重复加载」）；否则
  `run-llama-native.sh start`（内部引擎）→ 健康检查（`GET /v1/models` 优先，404/失败回退
  `POST /completion`（n_predict:1 最小推理）），不过则 exit 1；
- `stop`：立即停止（PID 文件 TERM→KILL 兜底 + pgrep 残留清扫）+ **清扫遗留 launchd 自启**；
  未在跑 = 幂等 ok；
- `status`：机器可读行（`state=not-loaded|loading|ready`、`probe=`、`probe_ok=`、`pid=`、
  `port=`、`model=`、`mem_hint_gb=`、`config=`、`config_exists=`、`legacy_launchd=`）+ 一行人读文案。

`models/run-llama-native.sh` 保留为内部引擎（start/stop/restart/status/health/logrotate），
头注释明示勿直接使用；launchd 面整条删除（§3 #1）。

## 5. 验收（任务书 (5)——全部实测）

### 5.1 探针实证：`bash macos/w30/scripts/w30-probe.sh` → **W30-PROBE ALL GREEN（PASS=39 FAIL=0）**

| 项 | 实证 | 结果 |
|---|---|---|
| 默认状态 = 未加载且无进程 | `state=not-loaded` + `probe=none` + `legacy_launchd=absent` + pgrep llama-server 空 | PASS |
| ⌥M 区块在场 | panel-dump：「本地模型（7B）」+ 状态行 + `config/ai.yaml` 路径 + 「打开配置」+ 确认文案源同源断言（约 \(gb) GB / 仅本机推理） | PASS |
| 无显式确认开 = 拒绝 | `w20ctl model on`（无 --confirm）exit 2，`setEnabled(true, explicitConfirm:false)` 硬门返回 false，拒绝后仍 not-loaded 且无进程（零副作用） | PASS |
| 开关 on → 服务起 + 健康检查过 | `w20ctl model on --confirm` → 「启动成功（…探活 /v1/models 通过 · :8092）」，state=ready、probe_ok=1、进程在、外部 curl /v1/models 200 复核 | PASS |
| 开关 off → 进程停 | `w20ctl model off` → state=not-loaded，pgrep llama-server 空 | PASS |
| 二次 on 幂等 | 引擎原话「幂等 no-op，不重复加载」+ pid 不变（34022 = 34022） | PASS |
| 二次 off 幂等 | 引擎原话「幂等：未在跑也是 ok」+ 仍 not-loaded | PASS |
| 二次 on/off 全环 | on→ready→off→not-loaded 可重复 | PASS |
| 审计快照 | plist 已删 / run-llama-native.sh 无 load·unload·serve / compose llama `restart: "no"` / launchd 无 agent / 终态无进程 | PASS |

### 5.2 回归

| 套件 | 命令 | 结果 |
|---|---|---|
| w20 单测 | `cd macos/w20 && swift test` | **15/15**（0 失败，未新增用例——开关行为由探针实证） |
| w12 单测 | `cd macos/w12 && swift test` | **20/20**（0 失败） |
| context 单测 | `cd context && swift test` | **40/40**（MemoryCore 21 + ContextCore 19，0 失败） |
| 全 app 目标编译 | `xcodebuild -project Squirrel.xcodeproj -configuration Release -scheme Squirrel build` | **BUILD SUCCEEDED**（W20ModelControl/面板/接线均过编译；构建树只编译不 launch） |
| 平价表 TODO 卡 | `docs/平价表-macos-android.md` | 行 #11 + **TODO-H**（本地模型显式开关 Android 版） |

## 6. 配置（任务书 (4)）：config/ai.yaml 为唯一配置入口

- `cp config/ai.example.yaml config/ai.yaml` 是唯一配置入口（`.gitignore` 已补 `config/ai.yaml`，
  用户配置不入库）；⌥M 区块显示该路径 + 一键打开（首次自动从示例复制）。
- 四键含义（INSTALL.md §5 双语表 + ai.example.yaml 头注释）：
  `backend`（local_gguf / openai_compatible / hub——后端形态）、`model`（模型名，如实标注
  source 字段）、`endpoint`（后端地址，本地 llama-server 基址如 `http://127.0.0.1:8092`）、
  `budget_ms`（单轮建议总预算，超时弃本轮、永不阻塞打字）。
- 明示：该文件只是配置，**不会加载模型**——加载只由开关驱动（ai.example.yaml 头注释 ★）。

## 7. 如实标注（诚实边界）

- **真机 IME 人工验收留待装机**：⌥M 浮层弹窗/开关手感、默认编辑器打开配置，需装机
  Squirrel-dev.app 真机点验（红线：构建树 Squirrel.app 绝不 launch）；面板形态已由
  w20ctl panel-dump 脚本化实证。
- **开关不持久化**：模型开关反映**实时服务态**（manage-model-service.sh 是事实源），不做
  meta 持久——登录后不会自动恢复「上次开着」，符合「必须用户打开才会加载」最严口径
  （每次会话显式开，随时关）。
- **探针为真实生命周期实测**：7B 权重真实加载两次（探针注释已说明）；单测层零 sleep
  红线不受影响。
- **端口监听 0.0.0.0**（run-llama-native.sh 原样未动）：llama-server 监听所有接口以保
  Docker 内 Hub 走 `host.docker.internal:8092` 的既有默认链路可用；「仅本机推理」指推理
  全程本地、不调云端。纯本机用户可自行加 `LLAMA_EXTRA`/改脚本收窄监听（本轮不动既有行为）。
- **脚本定位**：`W20ModelServiceControl` 找 `models/manage-model-service.sh` 依
  `MINE_INPUT_ROOT` 环境变量 > 编译期源码路径推仓库根（自构建 dev 树有效）>
  `~/Library/Application Support/mine-input`；找不到时状态行如实报错（exit 127），
  不静默假装。
- 旧行为迁移：历史用 `run-llama-native.sh load` 装过 launchd 自启的机器，
  `manage-model-service.sh stop`（或 status 如实显示 `legacy_launchd=present`）负责清场。
