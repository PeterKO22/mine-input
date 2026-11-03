/*
 * ai_assist.h — AiAssist SPI 唯一契约源（mine-input · W3 ai-spi / 里程碑 M3）
 *
 * 本地调用与远程协议同契约，W4 以 HTTP 映射。
 *
 * 契约即协议（docs/技术方案-v0.4.md §7 / 需求文档-v1.0.md FR6）：
 *   rescore / complete / correct / suggest(流式回调) / ingest —— 端侧后端与
 *   Hub 后端同方法签名，换后端零改动；本地调用与远程协议同契约，W4 以 HTTP 映射。
 *
 * 字段对齐 docs/技术方案-v0.4.md §7.2 / §8.2 的契约文本：
 *   - §7.2（SPI 方法面）：五方法；场景顺序 语音同音字纠错 → 候选重排 → 续写联想；
 *   - §8.2（上下文与提词）：采集分级 C0/C1（默认 C0，仅输入时触发）、安全输入
 *     （密码框/支付）自动暂停、交互日志（本地 SQLite、时间索引事件流、默认 30 天
 *     滚动）、提词三唤起（随打异步 / ⌥Esc 流式面板 / 语音 300–500ms 增量刷新）、
 *     只建议不上屏（Tab/数字/点按才采纳）。
 *
 * 工程约束（§7 / 需求 NFR3 / FR5 / FR6）：
 *   1. 全异步、永不阻塞：按键→上屏路径不等待 AI；调用侧经 spi/timeout_assist.h
 *      异步派发，任何方法不得阻塞调用方；
 *   2. 超时 800ms 弃本轮（NFR3）：由 TimeoutAssist 包装层强制，超时后本轮结果
 *      一律丢弃，绝不拖住输入；
 *   3. 默认全关（FR6）：AI 总开关 + 场景独立开关默认关（用户开才跑），开关由
 *      上层持有；被开关/安全输入拒绝的轮次返回 Status::kDisabled；
 *   4. 审计日志只记字段不记全文（FR6）：经 AuditSink 记录 AuditRecord，结构上
 *      只含方法名/条目计数/耗时/状态等字段，绝不含输入输出全文；
 *   5. 上下文最小化：默认 C0；text_after 等 C1 字段仅显式开启后填充（本地后端
 *      不受限）；secure_input（密码框/支付）自动暂停，后端见之必须直接返回
 *      kDisabled 且不做任何处理。
 *
 * suggest 流式语义（FR5 三唤起 / §8.2）：
 *   调用立即返回；on_update 先收若干 kDelta 增量，后收恰好一次终止事件
 *   （kDone / kError；超时由包装层补 kTimeout）；终止之后的一切更新必须丢弃。
 *   若 suggest 同步返回值非 kOk，表示未受理，回调不再触发（包装层补终止）。
 *   回调内不得重入同一轮调用。
 *
 * 生命周期约定（TimeoutAssist）：析构 join 全部已派发线程；应先销毁
 *   TimeoutAssist，再销毁其 AiAssist 后端与 AuditSink。
 *
 * 依据文档：docs/技术方案-v0.4.md §7/§8、docs/需求文档-v1.0.md FR5/FR6/NFR3。
 */
#ifndef MINE_INPUT_AI_SPI_AI_ASSIST_H_
#define MINE_INPUT_AI_SPI_AI_ASSIST_H_

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace mine {
namespace ai {

// NFR3 / 技术方案 §7：超时 800ms 弃本轮。
inline constexpr std::chrono::milliseconds kAiTimeout{800};

// 轮次状态（同步方法与流式终止共用）。
enum class Status {
  kOk,       // 成功
  kTimeout,  // 超时弃本轮（NFR3）
  kDisabled, // 默认全关 / 安全输入暂停，本轮未执行（FR6/FR5）
  kError,    // 后端错误
};

// 上下文采集分级（技术方案 §8.2，D9/D10）：默认 C0，C1 显式开启。
enum class ContextLevel {
  kC0 = 0,  // 最小上下文：preedit / text_before（仅输入时触发）
  kC1 = 1,  // 显式开启：追加 text_after / app_id 等（本地后端不受限）
};

// 候选 / 建议项（候选重排、续写联想、语音纠错三场景共用）。
struct Candidate {
  std::string text;   // 候选文本
  double score = 0.0; // 模型得分 / 置信度（后端归一到 0..1，非硬性）
  std::string source; // 来源标识（如 "wubi" / "pinyin" / "voice" / "ai"）
};

// 调用上下文（上下文最小化：默认 C0，C1 字段仅显式开启后填充）。
struct AiContext {
  ContextLevel level = ContextLevel::kC0; // 采集分级，默认 C0
  std::string preedit;      // 当前输入串（C0）
  std::string text_before;  // 光标前最小窗口（C0）
  std::string text_after;   // 光标后文本（仅 C1）
  std::string app_id;       // 前台应用标识（仅 C1；黑名单/审计用）
  std::string locale;       // 语言区域，如 "zh-Hans"
  bool secure_input = false; // 密码框/支付：自动暂停不可关，后端必须直接拒绝
};

// 交互事件类型（提词三唤起「只建议不上屏」与纠错采纳均可观测）。
enum class InteractionEventType {
  kCommit,             // 上屏（L3 留存默认关）
  kSuggestionShown,    // 建议展示（未采纳）
  kSuggestionAdopted,  // Tab/数字/点按采纳
  kSuggestionDismissed,// 忽略/取消
  kCorrectionApplied,  // 语音纠错采纳
};

// 交互日志事件（§8.2：本地 SQLite、时间索引事件流、默认 30 天滚动，可查可导可清）。
struct InteractionEvent {
  std::int64_t timestamp_ms = 0; // Unix 毫秒（时间索引）
  InteractionEventType type = InteractionEventType::kCommit;
  std::string text;   // 关联文本（上屏文本留存默认关；未开启时为空）
  std::string fields; // 结构化字段串（键=值；审计/同步只取字段）
};

// suggest 流式更新（kDelta 为增量；其余为终止事件，恰好一次）。
enum class StreamStatus {
  kDelta,   // 增量建议（300–500ms 级刷新，FR5）
  kDone,    // 终止：正常完成
  kError,   // 终止：错误（error 字段给简要原因，不含全文）
  kTimeout, // 终止：超时弃本轮（由包装层补发）
};

struct SuggestUpdate {
  StreamStatus status = StreamStatus::kDelta;
  std::vector<Candidate> candidates; // kDelta：增量建议；终止：通常为空
  std::string error;                 // kError/kTimeout 简要原因（字段级）
};

// 流式回调：先若干 kDelta，后恰好一次终止（kDone/kError/kTimeout）。
using SuggestCallback = std::function<void(const SuggestUpdate&)>;

// 审计记录 —— 只记字段不记全文（FR6）：结构上不含任何输入/输出全文成员。
struct AuditRecord {
  std::string method;             // rescore / complete / correct / suggest / ingest
  ContextLevel level = ContextLevel::kC0;
  std::size_t input_count = 0;    // 输入条目数（候选/事件数；无列表为 1）
  std::size_t output_count = 0;   // 输出条目数（流式为增量批次数）
  std::int64_t elapsed_ms = 0;    // 本轮耗时
  Status status = Status::kOk;
};

// 审计日志接口桩（FR6）：实现只允许落字段；全文落盘属违约。
class AuditSink {
 public:
  virtual ~AuditSink() = default;
  virtual void record(const AuditRecord& rec) = 0;
};

// AiAssist SPI —— 端侧后端与 Hub 后端同方法签名，换后端零改动。
// 同步语义：方法应立即返回（微秒级），重活由后端自身异步执行体承担；
// 需要 800ms 超时与异步派发时，一律经 TimeoutAssist（spi/timeout_assist.h）调用。
class AiAssist {
 public:
  virtual ~AiAssist() = default;

  // 候选重排：就地对 candidates 重打分/重排序（输出参数，后端就地修改）。
  virtual Status rescore(const AiContext& ctx,
                         std::vector<Candidate>& candidates) = 0;

  // 续写联想：按 prefix 给出续写建议；out 先清空再填充。
  virtual Status complete(const AiContext& ctx, const std::string& prefix,
                          std::vector<Candidate>& out) = 0;

  // 语音同音字纠错：对 spoken 给出纠错候选；out 先清空再填充。
  virtual Status correct(const AiContext& ctx, const std::string& spoken,
                         std::vector<Candidate>& out) = 0;

  // 流式建议（提词三唤起）：返回 kOk 表示已受理，结果经 on_update 增量推送，
  // 恰好一次终止事件；返回非 kOk 表示未受理，不得再触发 on_update。
  virtual Status suggest(const AiContext& ctx,
                         const SuggestCallback& on_update) = 0;

  // 交互日志归集（L1-L3 学习入料）：单事件 ingest。
  virtual Status ingest(const InteractionEvent& event) = 0;
};

}  // namespace ai
}  // namespace mine

#endif  // MINE_INPUT_AI_SPI_AI_ASSIST_H_
