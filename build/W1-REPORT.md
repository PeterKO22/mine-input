# W1 macos-core 交付报告（mine-input）

> 车道：W1 macos-core（M0+M1）｜日期：2026-11-04
> 范围：`core/` `macos/` `schema/` `build/`（目录所有权内全部产物）
> 验收目标：librime 编译 + Squirrel 开发版安装 + `ping_wubi_mixed` schema 加载验证

---

## 0. 一句话结论

**librime（arm64）编译通过；`ping_wubi_mixed` 经 rime_deployer + rime_api_console 实测可加载并产出候选（五笔命中/拼音前移/拼音反查三类行为全部实测到）；Squirrel 开发版构建与安装结果见 §4。**

---

## 1. 环境事实（实测）

| 项 | 值 |
|---|---|
| 系统 | macOS 27.0.1（26A434），arm64，18 核 / 128GB |
| Xcode | 27.2（27B52），SDK MacOSX27.2.sdk |
| cmake | 4.3.3 |
| Boost | brew boost 1.92.0_1（**全局安装，已注明**：`brew install boost`，本次车道唯一的全局安装） |

上游文档（curl 实读，raw.githubusercontent.com master）：
- `rime/librime/README-mac.md`：手工构建 = `make deps` → `make`；产物 `build/lib` + `build/bin/rime_*`
- `rime/squirrel/INSTALL.md` + `Makefile`：`make release`（内部：librime 子模块构建安装 → plum 数据 → opencc 数据 → Sparkle → xcodebuild）；`make install` 装到 `/Library/Input Methods`（**本车道未用**，见 §4 dev 安装）

上游拉取（浅克隆，全部 pin 住）：

| 仓库 | 本地路径 | commit |
|---|---|---|
| rime/librime | `core/librime` | `e930f57b5cc2eeac91aed3b6c7fe62e96f1fc8bc` |
| rime/squirrel | `macos/squirrel` | `d220b92ae7d0c916f4cce50df42d9a136668ea52` |
| ↳ librime 子模块 | `macos/squirrel/librime` | `33e78140250125871856cdc5b42ddc6a5fcd3cd4` |
| ↳ plum 子模块 | `macos/squirrel/plum` | `b1be1969f914cc005add4090631b855db00c2591` |

schema 词库/配方文件（`build/fetch-schema-deps.sh`，raw.githubusercontent.com 全 pin）：

| 文件 | 来源 | commit |
|---|---|---|
| `schema/deps/wubi86.dict.yaml` | rime/rime-wubi | `152a0d3f3efe40cae216d1e3b338242446848d07` |
| `schema/deps/pinyin_simp.dict.yaml` / `pinyin_simp.schema.yaml` | rime/rime-pinyin-simp | `0c6861ef7420ee780270ca6d993d18d4101049d0` |
| `schema/deps/key_bindings.yaml` / `punctuation.yaml` / `symbols.yaml` | rime/rime-prelude | `082425ea0684bca36474415d4a0e8db9b016487e` |

---

## 2. librime 编译（core/librime）

**脚本**：`bash build/build-librime.sh`（= `make deps && make`，`MACOSX_DEPLOYMENT_TARGET=13.0`）

**产物（实测 `file` 输出）**：
```
core/librime/build/lib/librime.1.dylib      Mach-O 64-bit dynamically linked shared library arm64
core/librime/build/lib/librime.1.17.0.dylib
core/librime/build/bin/rime_deployer  rime_api_console  rime_console  rime_dict_manager  rime_patch  rime_table_decompiler
```

**踩坑（重要，脚本内已注释）**：librime Makefile 默认 `MACOSX_DEPLOYMENT_TARGET=10.15`，Xcode 27 SDK 的 libc++ 已拒绝该平台：
```
__configuration/availability.h:204:4: error: "The selected platform is no longer supported by libc++." [-Werror,-W#warnings]
make[4]: *** [CMakeFiles/leveldb.dir/db/builder.cc.o] Error 1
```
修复：统一 `MACOSX_DEPLOYMENT_TARGET=13.0` 且先清 `deps/*/build`（CMake 缓存会锁死旧值）。leveldb 开了 `-Werror` 所以它最先炸；其余 dep 只是警告。

**脚本重跑**：`bash build/build-librime.sh` 第二次 EXIT=0（增量，秒级），产物 arch 复核 arm64 ✓。

---

## 3. schema：`ping_wubi_mixed`（schema/ping_wubi_mixed.schema.yaml）

设计（对应 FR1 / 技术方案 §4）：

- **形码主 translator**：`table_translator`（默认 `translator` 命名空间）→ `dictionary: wubi86`（rime-wubi 86），`initial_quality: 2`
- **拼音并联 translator**：`script_translator@pinyin_simp` → `dictionary: pinyin_simp`（rime-pinyin-simp），`initial_quality: 1`
  - **形码优先**：wubi 候选 quality = exp(weight)+2（wubi86 码表 weight 为字频级大数，exp 主导）恒高于拼音候选；命中即排最前
  - **拼音前移**：无五笔命中时拼音候选是唯一来源，自动占据候选栏最前（实测：`pinyin`→拼音、`nihao`→你好均为首选）
- **拼音反查**：`reverse_lookup_translator`，前缀 `z`，`dictionary: pinyin_simp`；注释=候选在 `translator/dictionary`(wubi86) 中的编码（librime `reverse_lookup_translator.cc` 默认 `target=translator`）→ 打拼音看五笔码
- **自定义短语**：`table_translator@custom_phrase` + `schema/custom_phrase.txt`（独立文件维护，热调不重编译，NFR7）
- **上屏默认值**：四码自动上屏=关（不设 `speller/max_code_length`）；空码顶字=关；候选数 8（`schema/default.yaml` `menu/page_size: 8`）
- filters 仅 `uniquifier`（不挂 simplifier，避免部署目录强依赖 opencc 数据）

**部署器坑（实测发现，已写进 schema 注释）**：librime 部署只编译 `schema/translator/dictionary` 与 `schema/dependencies` 各 schema 的 `translator/dictionary`（`deployment_tasks.cc` / `compile_unit.cc` 只认固定 `translator` 命名空间）——命名 translator（`@pinyin_simp`）的码表**不会**被自动编译。首测时 `pinyin_simp.table.bin` 缺失、拼音候选为垃圾串。修复：按上游 wubi86 的做法声明 `dependencies: [pinyin_simp]` 并落 `pinyin_simp.schema.yaml`（依赖 schema 的编译单元产出 `pinyin_simp.table/prism/reverse.bin`，prism 带拼音 algebra）。

### 3.1 验收实测（rime_deployer + rime_api_console，`bash build/verify-schema.sh`）

部署目录：**`~/Library/Rime-mine-dev`（dev 专用，未触碰 `~/Library/Rime`）**

`rime_deployer --build ~/Library/Rime-mine-dev` 产出：
```
build/:
default.yaml  ping_wubi_mixed.schema.yaml
pinyin_simp.prism.bin  pinyin_simp.reverse.bin  pinyin_simp.schema.yaml  pinyin_simp.table.bin
wubi86.prism.bin  wubi86.reverse.bin  wubi86.table.bin
```

console 实测（`rime_api_console`，cd 至 dev 目录运行；完整输出见 `build/logs/verify-*.log`）：

```
schema list:
1. 拼音五笔混合·dev [ping_wubi_mixed]
current schema: [ping_wubi_mixed]
```

① 五笔一级简码（形码命中，形码优先）——键入 `w`：
```
[w]|
page: 1  (of size 8)
1. [人]
2.  他 ~b
3.  个 ~h
...
```

② 五笔全码——键入 `gggg`：
```
[gggg]|
1. [王]
2.  五一
3.  琵琶
4.  龶
```

③ 无五笔命中 → 拼音前移——键入 `pinyin`：
```
[pin yin]|
1. [拼音]
2.  宵憱  ☯
3.  品
4.  拼
...
```

④ 拼音词组并联——键入 `nihao`：
```
[ni hao]|
1. [你好]
2.  悄虚  ☯
3.  你
...
```

⑤ 拼音反查（注释=五笔编码）——键入 `zni`：
```
[z ni]|〔反查〕
1. [找你]
2.  祝你
3.  阻尼
4.  珍妮
5.  你 wq wqi wqiy
6.  拟 rny rnyw
7.  尼 nx nxv
8.  呢 knx knxn
```
（`你 wq wqi wqiy` 即反查出的五笔编码提示 ✓）

**脚本重跑**：`build/verify-schema.sh` 重跑 EXIT=0，五组输出逐项一致 ✓。

---

## 4. Squirrel 开发版（macos/squirrel → ~/Library/Input Methods）

（构建与安装结果见下文“构建实测/安装实测”两节）

### 4.1 dev 隔离补丁（`build/squirrel-dev.patch`，build-squirrel.sh 自动套用）

| 补丁点 | 内容 | 目的 |
|---|---|---|
| `sources/Main.swift` | userDir 支持 Info.plist `RimeUserDir` 覆盖；appDir=Bundle 实际位置 | RIME 用户目录固定 `~/Library/Rime-mine-dev`；任意位置可注册 |
| `sources/InputSource.swift` | 输入源 ID → `im.rime.inputmethod.Squirrel.dev.Hans/.Hant` | 与用户现有 Squirrel 输入源 ID 互斥 |
| `resources/Info.plist` | bundle/TIS/连接名全 `.dev` 化（`Squirrel_Dev_Connection`）、`CFBundleName=Squirrel Dev`、`RimeUserDir=~/Library/Rime-mine-dev`、**SUEnableAutomaticChecks=false** | 不与现有输入法冲突；**绝不自动升级覆盖官方版** |
| `project.pbxproj` | `PRODUCT_BUNDLE_IDENTIFIER=im.rime.inputmethod.Squirrel.dev` | 独立 bundle id |
| 分布式通知名 | `Squirrel*Notification` / `SquirrelASCIIModeResponse` 加 `.dev` 后缀 | dev/官方实例互不触发 reload/sync |
| `Makefile` | `copy-rime-binaries` 对缺失 `rime-plugins` 容错 | 无插件时上游 make 直接报错的坑 |

安全边界：只写 `~/Library/Input Methods/Squirrel-dev.app` 与 `~/Library/Rime-mine-dev`；不运行上游 `make install`（会写 `/Library/Input Methods/Squirrel.app`）与 `scripts/postinstall`（会写 `~/Library/Rime`）。

### 4.2 构建实测（bash build/build-squirrel.sh）

```
** BUILD SUCCEEDED **          （xcodebuild，scheme Squirrel，Release，ARCHS=arm64，MACOSX_DEPLOYMENT_TARGET=13.0）
== artifact ==
macos/squirrel/build/Build/Products/Release/Squirrel.app   （21MB，Mach-O 64-bit executable arm64）
  "CFBundleIdentifier"          => "im.rime.inputmethod.Squirrel.dev"
  "CFBundleName"                => "Squirrel Dev"
  "TISInputSourceID"            => "im.rime.inputmethod.Squirrel.dev"（modes: .dev.Hans / .dev.Hant）
  "InputMethodConnectionName"   => "Squirrel_Dev_Connection"
  "RimeUserDir"                 => "~/Library/Rime-mine-dev"
  "SUEnableAutomaticChecks"     => false
```
**脚本重跑**：`bash build/build-squirrel.sh` 重跑 EXIT=0（增量构建，`squirrel-dev.patch already applied` → BUILD SUCCEEDED）✓。补丁可复现性：在 pristine worktree（干净 HEAD）上 `git apply --check build/squirrel-dev.patch` 通过 ✓。

构建过程踩坑（全部已在补丁/脚本中修复，重跑不会再遇）：
1. **plum 网络抖动**：`git clone github.com` 偶发 `LibreSSL SSL_connect: SSL_ERROR_SYSCALL`（rime-bopomofo 等 :preset 包）。重试即可；build-squirrel.sh 语义上可重跑（plum/output 缓存）。
2. **上游 copy-rime-binaries 不容错**：无 librime 插件时 `cp -pR librime/dist/lib/rime-plugins` 直接报错中断 → Makefile 补丁改为容错拷贝。
3. **`package/add_data_files` 污染 pbxproj**：该脚本把 `lib/rime-plugins/*` 的目录清单逐条烤进 `project.pbxproj` 的 Copy Rime plugins 相位；构建机上曾出现非插件杂项（含上游提交里不存在的条目），xcodebuild Copy 阶段因缺文件失败 18 项。修复：① pbxproj 中清除全部 `lib/rime-plugins/*` 引用（含上游自带的 librime-lua/octagram/predict 三个 dylib 引用——本 dev 版不带插件）；② `add_data_files` 只收录 `lib/rime-plugins/*.dylib` 且必须真实存在。pbxproj 修复在 `squirrel-dev.patch` 里，fresh clone 亦生效（pristine 树 `git apply --check` 验证过）。
4. **bin/rime_deployer、rime_dict_manager 缺失**：由坑 2 的中断级联导致（copy 中断先于拷 bin 工具），全量构建不受影响；增量修复用 `make copy-rime-binaries`。

### 4.3 安装实测（bash build/install-dev.sh）

```
== [1/4] 安装 ~/Library/Input Methods/Squirrel-dev.app ==     （ad-hoc codesign --force --deep --sign -）
== [2/4] 部署并验证 RIME 用户目录 ~/Library/Rime-mine-dev ==   （rime_deployer --build + console 五组实测，同 §3.1）
== [3/4] 注册输入源 ==
Registered input source from file:///Users/you/Library/Input%20Methods/Squirrel-dev.app/
```
- `~/Library/Input Methods/` 终态：仅 `Squirrel-dev.app`；用户系统级输入法 `/Library/Input Methods/SogouWBInput.app`（搜狗五笔）全程未被读写。
- 用户机器本无 `~/Library/Rime`；dev 专用 `~/Library/Rime-mine-dev` 内含 `ping_wubi_mixed` 部署产物（wubi86 / pinyin_simp table+prism+reverse 全部编译成功）。
- **一键卸载实测**：`bash build/uninstall-dev.sh` 删除 `Squirrel-dev.app` 与 `~/Library/Rime-mine-dev` 成功、无残留；随后 `install-dev.sh` 重新安装 EXIT=0 复原终态（卸载→重装全链路验证过）。
- 上游 `make install`（写 `/Library/Input Methods`）与 `scripts/postinstall`（写 `~/Library/Rime`）**均未使用**。

### 4.4 手工测试步骤（TextEdit）

1. 若输入法列表没有「Squirrel Dev」：`~/Library/Input\ Methods/Squirrel-dev.app/Contents/MacOS/Squirrel --register-input-source`，然后**注销并重新登录**（macOS 对新输入法的刷新时机）。
2. 系统设置 → 键盘 → 输入法 → 添加「Squirrel Dev」（源 ID `im.rime.inputmethod.Squirrel.dev.Hans`）。
3. 打开 TextEdit 新建纯文本，切到「Squirrel Dev」：
   - 敲 `w` → 首选「人」（五笔一级简码）
   - 敲 `gggg` → 首选「王」（五笔全码）
   - 敲 `pinyin` → 首选「拼音」（无五笔命中，拼音前移）
   - 敲 `nihao` → 首选「你好」（拼音并联）
   - 敲 `zni` → 〔反查〕候选注释显示五笔编码（如 `你 wq wqi wqiy`）
   - `Ctrl+`` ` 或 `F4` → 方案选单仅「拼音五笔混合·dev」
4. 一键卸载：`bash build/uninstall-dev.sh`（只删 `Squirrel-dev.app` 与 `~/Library/Rime-mine-dev`）。

---

## 5. 可复现脚本一览（build/）

| 脚本 | 作用 | 重跑 |
|---|---|---|
| `fetch-schema-deps.sh` | 拉取 pin 死的词库/配方文件 → `schema/deps/` | ✓（幂等覆盖） |
| `build-librime.sh` | librime deps + Release（arm64） | ✓（增量，实测 EXIT=0） |
| `build-squirrel.sh` | 套 dev 补丁 + `make release ARCHS=arm64` | ✓（实测见 §4.2） |
| `verify-schema.sh` | 部署 + rime_deployer + rime_api_console 五组实测 | ✓（实测 EXIT=0） |
| `install-dev.sh` | 装 `Squirrel-dev.app` + 部署 dev 用户目录 + 注册输入源 + 打印手工步骤 | ✓ |
| `uninstall-dev.sh` | 一键卸载（只删 dev 产物） | ✓ |
| `squirrel-dev.patch` | Squirrel fork dev 隔离补丁（唯一事实源） | — |

---

## 6. 遗留与 blocker

1. **wubi 句子构造噪音**：`enable_sentence: true`（上游 wubi86 默认）会让纯拼音输入的第 2 位出现 wubi 编码拼出的生造句（如 `pinyin` → `宵憱 ☯`）。不影响首选正确性；如要收紧可关 `translator/enable_sentence` 或加 `sentence_cutoff_threshold`（schema 级热调）。
2. **z 反查与拼音缩写的重叠**：依赖 schema（pinyin_simp）的 prism 自带缩写 algebra（`z`=zhao…），故 `zni` 会同时出拼音缩写短语（找你/祝你…）与反查候选。反查功能本身正确（注释=五笔码）。收紧方案：给 `pinyin_simp` 命名 translator 换独立 prism（无缩写）或调 recognizer 优先级，留待 W2 集成时定。
3. **自定义短语排序**：wubi86 码表 weight 为字频大数（quality=exp(weight)→inf），custom_phrase 的有限 quality 排不进 wubi 命中之前。需要“短语绝对优先”时改用 userdb 或调整权重方案（NFR7 参数化）。
4. **手工上屏测试未执行**：本环境禁用 computer_use，TextEdit 真机打字依赖人工执行 §4.4；console 级候选链已逐项实测。
5. **librime 构建目标 13.0**：产物最小系统 macOS 13+（与 Squirrel 上游要求一致）；如需 10.15 便携构建需换旧 SDK 或 `install-boost.sh` 源码 Boost。
6. **dev 版不带 librime 插件**：librime-lua / librime-octagram / librime-predict 未装（pbxproj 的 Copy Rime plugins 相位已清空）。W2 需要 lua 脚本/语法模型时按 squirrel INSTALL.md `bash librime/install-plugins.sh …` 补装，`add_data_files` 补丁会自动收录 `.dylib`。
7. **上游克隆未入 git**：`core/librime`、`macos/squirrel` 为第三方浅克隆（体积大、可按 §1 pin 的 commit 复现），本车道 git 提交只含 `schema/`、`build/` 下的自有文件；克隆与构建产物留给 `.gitignore` 级决策（根目录文件不归本车道，未动）。
