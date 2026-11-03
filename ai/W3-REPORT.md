# W3 ai-spi 报告 — AiAssist SPI 契约与端侧后端骨架（C++17）

> 车道：W3 ai-spi ｜ 里程碑：M3 ｜ 日期：2026-11-04
> 依据：docs/技术方案-v0.4.md §7/§8（字段对齐 §7.2/§8.2 契约文本）、docs/需求文档-v1.0.md FR5/FR6/NFR3、docs/开发任务计划.md §2 W3 + §3 工作约定

---

## 1. 做了什么

**契约（唯一契约源）**
- `ai/spi/ai_assist.h`：
  - 接口 `AiAssist`：`rescore`（候选重排，就地重打分）/ `complete`（续写联想）/ `correct`（语音同音字纠错）/ `suggest`（流式回调）/ `ingest`（交互事件归集）——端侧后端与 Hub 后端同方法签名，换后端零改动；头文件注释已注明「本地调用与远程协议同契约，W4 以 HTTP 映射」；
  - 结构体 `Candidate`（text/score/source）、`AiContext`（C0/C1 分级 + preedit/text_before/text_after/app_id/locale/secure_input）、`InteractionEvent`（timestamp_ms 时间索引 / type 事件流 / text 留存默认关 / fields 只记字段）——字段对齐技术方案 §7.2/§8.2 契约文本（采集分级、安全输入自动暂停、交互日志 30 天滚动、提词三唤起只建议不上屏）；
  - `Status`（kOk/kTimeout/kDisabled/kError）+ `StreamStatus`（kDelta/kDone/kError/kTimeout）+ `SuggestCallback` 流式回调语义：先若干 kDelta、后恰好一次终止、终止后更新丢弃；
  - 工程约束逐条入注释：全异步不阻塞、超时 800ms 弃本轮、默认全关（开关上层持有）、审计只记字段、上下文最小化（本地后端不受限）。

**超时包装（800ms 语义）**
- `ai/spi/timeout_assist.{h,cc}` `TimeoutAssist`：`rescoreAsync/completeAsync/correctAsync/suggestAsync/ingestAsync` 全部立即返回（只做线程派发，绝不阻塞调用方）；每轮「后端结果 vs 800ms 看门狗」竞争，先到者拿走本轮——超时弃本轮，后端迟到结果一律丢弃；每轮回调/终止恰好一次；`secure_input` 直接 kDisabled 且后端不被调用；析构 join 全部已派发线程。

**Null 空后端**
- `ai/backends/null/null_ai_assist.{h,cc}` `NullAiAssist`：rescore 原样返回 / complete 空 / correct 原文恒等回传 / suggest 立即恰好一次 kDone / ingest 丢弃；secure_input 一律 kDisabled。

**审计日志接口桩（只记字段不记全文）**
- `AuditSink` 接口 + `AuditRecord`（method/level/input_count/output_count/elapsed_ms/status，结构上无全文成员）在 `ai_assist.h`；桩实现 `ai/audit/audit_stub.h` `MemoryAuditSink`（内存环形，供测试与上层查询；真实 SQLite 落盘实现后续替换，接口不变）。`TimeoutAssist` 每轮恰好记一条（含超时轮）。

**构建与测试**
- 顶层 `CMakeLists.txt`（C++17，`enable_testing()` + ctest 集成）、`ai/CMakeLists.txt`（静态库 `ai_spi`，include 根 = 仓库根，统一 `#include "ai/spi/ai_assist.h"` 形态）、`tests/CMakeLists.txt`（3 个测试目标 + `add_test`，TIMEOUT 60）。
- `tests/` 单元测试（轻量断言 `tests/test_assert.h`，无第三方框架）：
  - `test_null_backend`：Null 后端五方法行为 + secure_input 拒绝 + 审计桩字段/环形容量；
  - `test_timeout`：快路径恰好一次回调 + 800ms 超时弃本轮（迟到结果丢弃）+ 调用方 <100ms 脱身 + 自定义短超时窗口 + secure_input 后端零调用 + ingest/correct 路径；
  - `test_stream`：3 增量→恰好一次 kDone 且终止在最后 + 永不终止后端 150ms 补 kTimeout + 迟到增量/迟到终止全部丢弃 + 同步失败补 kError + Null 经包装层恰好一次 kDone + secure_input 同步终止。

## 2. 怎么验证（实测输出，2026-11-04，macOS arm64 / AppleClang 21 / cmake 4.3.3）

干净重跑验收命令 `cmake -B build && cmake --build build && ctest --test-dir build`，exit=0：

```
$ cmake -B build
-- The CXX compiler identification is AppleClang 21.0.0.21000401
-- Detecting CXX compiler ABI info
-- Detecting CXX compiler ABI info - done
-- Check for working CXX compiler: /usr/bin/c++ - skipped
-- Detecting CXX compile features
-- Detecting CXX compile features - done
-- Performing Test CMAKE_HAVE_LIBC_PTHREAD
-- Performing Test CMAKE_HAVE_LIBC_PTHREAD - Success
-- Found Threads: TRUE
-- Configuring done (0.4s)
-- Generating done (0.0s)
-- Build files have been written to: /Users/you/AITECreate/mine-input/build

$ cmake --build build
[ 11%] Building CXX object ai/CMakeFiles/ai_spi.dir/spi/timeout_assist.cc.o
[ 22%] Building CXX object ai/CMakeFiles/ai_spi.dir/backends/null/null_ai_assist.cc.o
[ 33%] Linking CXX static library libai_spi.a
[ 33%] Built target ai_spi
[ 44%] Building CXX object tests/CMakeFiles/test_null_backend.dir/test_null_backend.cpp.o
[ 55%] Linking CXX executable test_null_backend
[ 55%] Built target test_null_backend
[ 66%] Building CXX object tests/CMakeFiles/test_timeout.dir/test_timeout.cpp.o
[ 77%] Linking CXX executable test_timeout
[ 77%] Built target test_timeout
[ 88%] Building CXX object tests/CMakeFiles/test_stream.dir/test_stream.cpp.o
[100%] Linking CXX executable test_stream
[100%] Built target test_stream

$ ctest --test-dir build
Test project /Users/you/AITECreate/mine-input/build
    Start 1: test_null_backend
1/3 Test #1: test_null_backend ................   Passed    0.14 sec
    Start 2: test_timeout
2/3 Test #2: test_timeout .....................   Passed    4.90 sec
    Start 3: test_stream
3/3 Test #3: test_stream ......................   Passed    2.36 sec

100% tests passed, 0 tests failed out of 3

Total Test time (real) =   7.40 sec
```

关键断言实测（全部命中）：
- 超时弃本轮：默认 800ms 超时下慢后端（1500ms）回调 kTimeout，实测判负耗时在 750–1500ms 窗口（约 800ms 到点），后端迟到结果落地后回调计数仍为 1（无回灌）；
- 绝不阻塞调用方：慢后端下 `rescoreAsync` 返回耗时 <100ms；
- 流式完成语义：3 增量后恰好一次 kDone 且位于最后；永不终止后端由包装层在 150ms 补恰好一次 kTimeout；迟到增量/迟到终止（400/500ms）全部丢弃，更新总数停在 1；
- 审计只记字段：每轮恰好 1 条 AuditRecord（method/level/计数/耗时/状态），超时轮记 kTimeout，断言字段与调用一致（无全文可记——结构上不存在全文成员）。

## 3. 交付物清单

| 路径 | 说明 |
|---|---|
| `ai/spi/ai_assist.h` | SPI 唯一契约源（5 方法 + Candidate/AiContext/InteractionEvent + Status/流式/审计接口） |
| `ai/spi/timeout_assist.h` / `.cc` | 800ms 超时包装（弃本轮、不阻塞、恰好一次回调、审计） |
| `ai/backends/null/null_ai_assist.h` / `.cc` | Null 空后端 |
| `ai/audit/audit_stub.h` | 审计日志接口桩（MemoryAuditSink，只记字段） |
| `tests/test_assert.h` / `test_null_backend.cpp` / `test_timeout.cpp` / `test_stream.cpp` | 单元测试（3 个 ctest 用例） |
| `CMakeLists.txt`（顶层）/ `ai/CMakeLists.txt` / `tests/CMakeLists.txt` | C++17 构建 + ctest 集成 |
| `ai/W3-REPORT.md` | 本报告 |

## 4. 遗留与 blocker

- **无 blocker**。遗留项：
  1. 顶层 `CMakeLists.txt`、`tests/` 位于 `ai/` 之外——按本任务交付清单明确要求（「顶层 CMakeLists」「tests/」）创建；若与其他车道根文件冲突，以文档方式报告后合并，未擅改他人文件；
  2. `build/` 构建产物未入库（未 git add）；W1 车道目录规划中也有 `build/`（放构建脚本），若 W1 落地同名目录，建议改用 `build-ai/` 或调整目录规划，已在本报告留档；
  3. `TimeoutAssist` 每轮派发 2 条线程（调用 + 看门狗），骨架可接受；M3 接真实 GGUF 后端时换线程池；析构 join 语义下应先销毁 `TimeoutAssist` 再销毁后端与 AuditSink（头文件已注明）；
  4. 审计桩为内存环形；SQLite 落盘（§8.2 交互日志 30 天滚动）属 M5，接口不变；
  5. W4 以文档方式引用 `ai/spi/ai_assist.h` 映射 HTTP（契约即协议）：五方法一一对应 `/v1/...`，`suggest` 映射为流式响应；字段名以本头文件为唯一契约源。
