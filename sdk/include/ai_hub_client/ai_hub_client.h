// mine-input hub-client SDK（W8）
//
// C++17 + libcurl + SQLite3（系统自带），无其他依赖。
// 对接 hub/app/main.py（W4 FastAPI Hub）：
//   /v1/auth/register|token|whoami
//   /v1/sync/push|pull   —— userdb 时间戳取新、计数器增量累加、push_id 幂等重试
//   /v1/ingest           —— InteractionEvent（技术方案 v0.4 §7/§8 契约）
//   /v1/suggest          —— SSE 流式建议（回调式消费，多帧 + done）
//
// 错误语义（调用方侧）：
//   Status::retryable() == true  → 网络/超时/5xx/429/408/401(可重登后重试)
//                                  适合静默重试或入 OfflineQueue 补传；
//   其余 4xx（含 422/409/400）   → 本地数据问题，重试无意义，直接上报/丢弃。
// 800ms 超时建议（技术方案 v0.4 §7「超时 800ms 弃一轮」）：
//   面向用户的 suggest 调用由调用方设定总预算，SDK 默认 suggest_budget_ms=800，
//   超预算即中断流（已到帧仍经回调交付），返回 Error::Timeout；
//   sync/ingest 走后台通道，不受 800ms 约束，失败由离线队列兜底。
//
// 线程模型：HubClient / OfflineQueue 非线程安全，单线程使用或外部加锁。
#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace aihub {

// ---------------------------------------------------------------- 错误语义

enum class Error {
  Ok = 0,
  InvalidArgument,  // 本地参数非法（空 username、坏 kind 等）
  Network,          // 连接/传输失败（断网、拒连、DNS）→ retryable
  Timeout,          // 超时或 suggest 预算耗尽 → retryable
  Http,             // 非 2xx（见 Status::http_status）→ 视状态码定
  Auth,             // 401/403 → 重登后可重试
  Parse,            // JSON / SSE 解析失败 → 不可重试
  QueueIo,          // 本地队列 SQLite I/O 失败 → 不可重试（本地磁盘问题）
};

const char* to_string(Error e);

struct Status {
  Error code = Error::Ok;
  int http_status = 0;   // HTTP 状态码（无 HTTP 交互时为 0）
  std::string message;

  bool ok() const { return code == Error::Ok; }
  // 可安全静默重试/入队补传（幂等由 push_id 保证）
  bool retryable() const;
};

template <typename T>
struct Result {
  Status status;
  T value{};
  bool ok() const { return status.ok(); }
};

// ---------------------------------------------------------------- 数据模型
// 字段对齐 hub/app/main.py（API 实现为准）

struct RegisterResult {
  int64_t user_id = 0;
  std::string username;
  std::string key_partition_id;   // 每用户独立密钥分区（FR8）
  std::string key_partition_key;  // E2E 预留密钥材料
  int64_t created_at = 0;
};

struct TokenResult {
  std::string access_token;
  std::string token_type;         // "bearer"
  int64_t expires_at = 0;
  int64_t user_id = 0;
  std::string key_partition_id;
};

struct WhoamiResult {
  int64_t user_id = 0;
  std::string username;
  std::string key_partition_id;
  int64_t created_at = 0;
};

struct UserdbEntry {
  std::string key;                // RIME userdb 条目键
  std::string value;
  int64_t updated_at = 0;         // epoch ms，合并取新（>= 视为新写入）
};

struct MetaValue {
  int64_t updated_at = 0;
  std::string value_json;         // 任意 JSON 值（对象/串/…）原样携带
};

struct PushPayload {
  std::string device_id;          // 空则用 ClientConfig::device_id
  std::string push_id;            // 幂等键；空则 SDK 自动生成
  std::vector<UserdbEntry> userdb;
  std::map<std::string, int64_t> counters;  // 增量（服务端累加）
  std::vector<std::string> hotwords;
  std::optional<MetaValue> ai_config;
  std::optional<MetaValue> schema_version;
};

struct PushResult {
  std::string push_id;
  std::string status;             // "merged" | "duplicate"
  bool duplicate = false;
  int userdb_upserted = 0;
  int userdb_kept = 0;            // 时间戳取新：旧值被保留
  int hotwords_added = 0;
  int meta_updated = 0;
  std::map<std::string, int64_t> counters_now;  // 累加后的当前值
};

struct PullState {
  int64_t server_time = 0;
  std::vector<UserdbEntry> userdb;
  std::map<std::string, int64_t> counters;
  std::vector<std::string> hotwords;
  std::optional<MetaValue> ai_config;
  std::optional<MetaValue> schema_version;
};

struct InteractionEvent {
  int64_t ts = 0;                 // epoch ms
  std::string device_id;          // 空则用 ClientConfig::device_id
  std::string app_id;
  std::string kind;               // key_session|voice_session|candidate_pick|suggestion_feedback
  std::string text_in;
  std::string text_out;
  std::optional<std::string> ocr_digest;
  std::optional<std::string> asr_digest;
  std::optional<double> keystroke_cadence;
  std::optional<int64_t> suggestion_shown;
  std::optional<int64_t> suggestion_taken;
};

struct IngestResult {
  bool stored = false;
  int64_t event_id = 0;
  std::string kind;
  int64_t ts = 0;
};

struct Suggestion {                 // Candidate := { text, score, source }
  std::string text;
  double score = 0.0;
  std::string source;
  int seq = 0;
};

struct SuggestDone {
  std::string status;
  std::string backend;
  int suggestions = 0;
  std::string context_digest;
};

struct SuggestContext {             // AiContext
  std::string before_cursor;
  std::string app_id;
  bool from_voice = false;
  std::string context_digest;
};

// ---------------------------------------------------------------- 配置

struct ClientConfig {
  std::string base_url = "http://localhost:8088";
  std::string device_id = "dev-unknown";
  long connect_timeout_ms = 2000;
  long request_timeout_ms = 8000;   // sync/ingest/auth 后台通道
  long suggest_budget_ms = 800;     // §7：800ms 弃一轮（调用方预算，可调）
};

// ---------------------------------------------------------------- HubClient

class HubClient {
 public:
  explicit HubClient(ClientConfig cfg);

  // token：login() 成功自动保存；也可 set_token() 注入既有 token
  void set_token(std::string token);
  const std::string& token() const { return token_; }

  // /v1/auth
  Result<RegisterResult> register_user(const std::string& username,
                                       const std::string& password);
  Result<TokenResult> login(const std::string& username,
                            const std::string& password);
  Result<WhoamiResult> whoami();

  // /v1/sync —— push_id 幂等：同一 push_id 重发返回 duplicate=true 且不重复累加
  Result<PushResult> push(const PushPayload& payload);
  Result<PullState> pull(std::optional<int64_t> since = std::nullopt);

  // /v1/ingest
  Result<IngestResult> ingest(const InteractionEvent& event);

  // /v1/suggest —— SSE 流式，回调式消费；预算超时中断（已到帧已交付回调）
  using SuggestionCallback = std::function<void(const Suggestion&)>;
  using DoneCallback = std::function<void(const SuggestDone&)>;
  Status suggest(const SuggestContext& ctx,
                 const SuggestionCallback& on_suggestion,
                 const DoneCallback& on_done = nullptr);

  // 生成 push_id（随机 32 hex，进程内单调后缀防碰撞）
  static std::string make_push_id();

  const ClientConfig& config() const { return cfg_; }

 private:
  ClientConfig cfg_;
  std::string token_;
};

// ---------------------------------------------------------------- 离线队列
// SQLite 文件队列：断网入队、联网补传、失败静默重试（attempts 递增留痕）。
// 补传顺序 FIFO；push 条目沿用原 push_id（幂等），重复补传不重复累加。

struct QueueItem {
  int64_t id = 0;
  std::string kind;               // "push" | "ingest"
  std::string payload_json;
  std::string push_id;
  int attempts = 0;
  int64_t created_at = 0;
};

class OfflineQueue {
 public:
  explicit OfflineQueue(const std::string& db_path);
  ~OfflineQueue();
  OfflineQueue(const OfflineQueue&) = delete;
  OfflineQueue& operator=(const OfflineQueue&) = delete;

  Status enqueue_push(const PushPayload& payload);
  Status enqueue_ingest(const InteractionEvent& event);
  size_t pending() const;
  std::vector<QueueItem> items() const;   // 测试/诊断用

  struct FlushReport {
    size_t sent = 0;      // 成功送出并已删除
    size_t kept = 0;      // 失败保留（含其后未尝试的），下次再试
    size_t dropped = 0;   // 永久性 4xx，丢弃（避免死循环）
    Status last_error;
  };
  // 逐条补传；遇到可重试错误即停（保序），静默留队；
  // 永久 4xx（422/400 等）丢弃该条后继续。
  FlushReport flush(HubClient& client);

 private:
  struct Impl;
  Impl* impl_;
};

}  // namespace aihub
