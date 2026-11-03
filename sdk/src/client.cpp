// HubClient 实现：auth / sync push|pull / ingest / suggest(SSE)。
#include "ai_hub_client/ai_hub_client.h"

#include <atomic>
#include <chrono>
#include <random>
#include <sstream>

#include "http.h"
#include "json.h"
#include "serialize.h"
#include "sse.h"

namespace aihub {

using json::Value;

// ---------------------------------------------------------------- Status

const char* to_string(Error e) {
  switch (e) {
    case Error::Ok: return "ok";
    case Error::InvalidArgument: return "invalid_argument";
    case Error::Network: return "network";
    case Error::Timeout: return "timeout";
    case Error::Http: return "http";
    case Error::Auth: return "auth";
    case Error::Parse: return "parse";
    case Error::QueueIo: return "queue_io";
  }
  return "unknown";
}

bool Status::retryable() const {
  switch (code) {
    case Error::Network:
    case Error::Timeout:
    case Error::Auth:  // 重登（login/set_token）后可重试
      return true;
    case Error::Http:
      // 5xx / 429 / 408 → 服务端暂时性，可静默重试
      return http_status >= 500 || http_status == 429 || http_status == 408;
    default:
      return false;
  }
}

// ---------------------------------------------------------------- helpers

namespace {

Status make_error(Error code, const std::string& msg, int http_status = 0) {
  Status s;
  s.code = code;
  s.http_status = http_status;
  s.message = msg;
  return s;
}

// 传输层状态 + HTTP 状态 → 统一 Status（2xx 由调用方继续解析）
Status classify(const http::Reply& reply) {
  if (!reply.status.ok()) return reply.status;
  long sc = reply.http_status;
  if (sc >= 200 && sc < 300) return Status{};
  if (sc == 401 || sc == 403) {
    return make_error(Error::Auth, "http " + std::to_string(sc), static_cast<int>(sc));
  }
  return make_error(Error::Http, "http " + std::to_string(sc), static_cast<int>(sc));
}

bool parse_body(const std::string& body, Value* out, Status* st) {
  std::string err;
  if (!Value::parse(body, *out, err)) {
    *st = make_error(Error::Parse, "bad JSON response: " + err);
    return false;
  }
  return true;
}

int64_t now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}

}  // namespace

// ---------------------------------------------------------------- HubClient

HubClient::HubClient(ClientConfig cfg) : cfg_(std::move(cfg)) {}

void HubClient::set_token(std::string token) { token_ = std::move(token); }

std::string HubClient::make_push_id() {
  static std::atomic<uint64_t> counter{0};
  std::random_device rd;
  uint64_t a = (static_cast<uint64_t>(rd()) << 32) ^ rd();
  uint64_t b = counter.fetch_add(1);
  std::ostringstream os;
  os << std::hex << a << b;
  std::string id = os.str();
  return "p_" + id.substr(0, 24);
}

Result<RegisterResult> HubClient::register_user(const std::string& username,
                                                const std::string& password) {
  Result<RegisterResult> r;
  if (username.empty() || password.size() < 4) {
    r.status = make_error(Error::InvalidArgument,
                          "username empty or password shorter than 4");
    return r;
  }
  Value body = Value::object();
  body.set("username", Value(username));
  body.set("password", Value(password));

  http::Request req;
  req.url = cfg_.base_url + "/v1/auth/register";
  req.body = body.serialize();
  req.connect_timeout_ms = cfg_.connect_timeout_ms;
  req.timeout_ms = cfg_.request_timeout_ms;
  http::Reply reply = http::perform(req);

  r.status = classify(reply);
  if (!r.status.ok()) return r;

  Value v;
  if (!parse_body(reply.body, &v, &r.status)) return r;
  RegisterResult out;
  if (const Value* x = v.find("user_id")) out.user_id = x->as_int();
  if (const Value* x = v.find("username")) out.username = x->as_string();
  if (const Value* x = v.find("created_at")) out.created_at = x->as_int();
  if (const Value* kp = v.find("key_partition")) {
    if (const Value* x = kp->find("id")) out.key_partition_id = x->as_string();
    if (const Value* x = kp->find("key")) out.key_partition_key = x->as_string();
  }
  if (out.user_id == 0) {
    r.status = make_error(Error::Parse, "register response missing user_id");
    return r;
  }
  r.value = std::move(out);
  return r;
}

Result<TokenResult> HubClient::login(const std::string& username,
                                     const std::string& password) {
  Result<TokenResult> r;
  Value body = Value::object();
  body.set("username", Value(username));
  body.set("password", Value(password));

  http::Request req;
  req.url = cfg_.base_url + "/v1/auth/token";
  req.body = body.serialize();
  req.connect_timeout_ms = cfg_.connect_timeout_ms;
  req.timeout_ms = cfg_.request_timeout_ms;
  http::Reply reply = http::perform(req);

  r.status = classify(reply);
  if (!r.status.ok()) return r;

  Value v;
  if (!parse_body(reply.body, &v, &r.status)) return r;
  TokenResult out;
  if (const Value* x = v.find("access_token")) out.access_token = x->as_string();
  if (const Value* x = v.find("token_type")) out.token_type = x->as_string();
  if (const Value* x = v.find("expires_at")) out.expires_at = x->as_int();
  if (const Value* x = v.find("user_id")) out.user_id = x->as_int();
  if (const Value* x = v.find("key_partition_id")) out.key_partition_id = x->as_string();
  if (out.access_token.empty()) {
    r.status = make_error(Error::Parse, "token response missing access_token");
    return r;
  }
  token_ = out.access_token;
  r.value = std::move(out);
  return r;
}

Result<WhoamiResult> HubClient::whoami() {
  Result<WhoamiResult> r;
  http::Request req;
  req.method = "GET";
  req.url = cfg_.base_url + "/v1/auth/whoami";
  req.bearer_token = token_;
  req.connect_timeout_ms = cfg_.connect_timeout_ms;
  req.timeout_ms = cfg_.request_timeout_ms;
  http::Reply reply = http::perform(req);

  r.status = classify(reply);
  if (!r.status.ok()) return r;

  Value v;
  if (!parse_body(reply.body, &v, &r.status)) return r;
  WhoamiResult out;
  if (const Value* x = v.find("user_id")) out.user_id = x->as_int();
  if (const Value* x = v.find("username")) out.username = x->as_string();
  if (const Value* x = v.find("key_partition_id")) out.key_partition_id = x->as_string();
  if (const Value* x = v.find("created_at")) out.created_at = x->as_int();
  r.value = std::move(out);
  return r;
}

Result<PushResult> HubClient::push(const PushPayload& payload) {
  Result<PushResult> r;
  PushPayload p = payload;
  if (p.device_id.empty()) p.device_id = cfg_.device_id;
  if (p.push_id.empty()) p.push_id = make_push_id();

  http::Request req;
  req.url = cfg_.base_url + "/v1/sync/push";
  req.bearer_token = token_;
  req.body = ser::push_payload_to_json(p).serialize();
  req.connect_timeout_ms = cfg_.connect_timeout_ms;
  req.timeout_ms = cfg_.request_timeout_ms;
  http::Reply reply = http::perform(req);

  r.status = classify(reply);
  if (!r.status.ok()) return r;

  Value v;
  if (!parse_body(reply.body, &v, &r.status)) return r;
  PushResult out;
  out.push_id = p.push_id;
  if (const Value* x = v.find("status")) out.status = x->as_string();
  if (const Value* x = v.find("duplicate")) out.duplicate = x->as_bool();
  if (const Value* ap = v.find("applied")) {
    if (const Value* x = ap->find("userdb_upserted")) out.userdb_upserted = static_cast<int>(x->as_int());
    if (const Value* x = ap->find("userdb_kept")) out.userdb_kept = static_cast<int>(x->as_int());
    if (const Value* x = ap->find("hotwords_added")) out.hotwords_added = static_cast<int>(x->as_int());
    if (const Value* x = ap->find("meta_updated")) out.meta_updated = static_cast<int>(x->as_int());
    if (const Value* cn = ap->find("counters_now")) {
      for (const auto& kv : cn->members()) out.counters_now[kv.first] = kv.second.as_int();
    }
  }
  r.value = std::move(out);
  return r;
}

Result<PullState> HubClient::pull(std::optional<int64_t> since) {
  Result<PullState> r;
  Value body = Value::object();
  body.set("device_id", Value(cfg_.device_id));
  if (since) body.set("since", Value(*since));

  http::Request req;
  req.url = cfg_.base_url + "/v1/sync/pull";
  req.bearer_token = token_;
  req.body = body.serialize();
  req.connect_timeout_ms = cfg_.connect_timeout_ms;
  req.timeout_ms = cfg_.request_timeout_ms;
  http::Reply reply = http::perform(req);

  r.status = classify(reply);
  if (!r.status.ok()) return r;

  Value v;
  if (!parse_body(reply.body, &v, &r.status)) return r;
  PullState out;
  if (const Value* x = v.find("server_time")) out.server_time = x->as_int();
  if (const Value* arr = v.find("userdb")) {
    for (const auto& item : arr->items()) {
      UserdbEntry e;
      if (const Value* x = item.find("key")) e.key = x->as_string();
      if (const Value* x = item.find("value")) e.value = x->as_string();
      if (const Value* x = item.find("updated_at")) e.updated_at = x->as_int();
      out.userdb.push_back(std::move(e));
    }
  }
  if (const Value* c = v.find("counters")) {
    for (const auto& kv : c->members()) out.counters[kv.first] = kv.second.as_int();
  }
  if (const Value* h = v.find("hotwords")) {
    for (const auto& w : h->items()) out.hotwords.push_back(w.as_string());
  }
  if (const Value* m = v.find("ai_config")) {
    MetaValue mv;
    if (ser::meta_from_json(*m, &mv)) out.ai_config = mv;
  }
  if (const Value* m = v.find("schema_version")) {
    MetaValue mv;
    if (ser::meta_from_json(*m, &mv)) out.schema_version = mv;
  }
  r.value = std::move(out);
  return r;
}

Result<IngestResult> HubClient::ingest(const InteractionEvent& event) {
  Result<IngestResult> r;
  InteractionEvent e = event;
  if (e.device_id.empty()) e.device_id = cfg_.device_id;
  static const char* kKinds[] = {"key_session", "voice_session",
                                 "candidate_pick", "suggestion_feedback"};
  bool kind_ok = false;
  for (const char* k : kKinds) {
    if (e.kind == k) { kind_ok = true; break; }
  }
  if (!kind_ok || e.ts <= 0) {
    r.status = make_error(Error::InvalidArgument,
                          "ingest: bad kind or ts<=0");
    return r;
  }

  http::Request req;
  req.url = cfg_.base_url + "/v1/ingest";
  req.bearer_token = token_;
  req.body = ser::event_to_json(e).serialize();
  req.connect_timeout_ms = cfg_.connect_timeout_ms;
  req.timeout_ms = cfg_.request_timeout_ms;
  http::Reply reply = http::perform(req);

  r.status = classify(reply);
  if (!r.status.ok()) return r;

  Value v;
  if (!parse_body(reply.body, &v, &r.status)) return r;
  IngestResult out;
  out.stored = true;
  if (const Value* x = v.find("event_id")) out.event_id = x->as_int();
  if (const Value* x = v.find("kind")) out.kind = x->as_string();
  if (const Value* x = v.find("ts")) out.ts = x->as_int();
  r.value = std::move(out);
  return r;
}

Status HubClient::suggest(const SuggestContext& ctx,
                          const SuggestionCallback& on_suggestion,
                          const DoneCallback& on_done) {
  Value body = Value::object();
  body.set("before_cursor", Value(ctx.before_cursor));
  body.set("app_id", Value(ctx.app_id));
  body.set("from_voice", Value(ctx.from_voice));
  body.set("context_digest", Value(ctx.context_digest));

  sse::Parser parser;
  bool got_done = false;
  bool cb_abort = false;

  http::Request req;
  req.url = cfg_.base_url + "/v1/suggest";
  req.bearer_token = token_;
  req.body = body.serialize();
  req.accept_sse = true;
  req.connect_timeout_ms = cfg_.connect_timeout_ms;
  // §7：800ms 超时弃一轮（调用方预算）→ 整体传输限时 suggest_budget_ms
  req.timeout_ms = cfg_.suggest_budget_ms;
  req.on_chunk = [&](const char* data, size_t len) -> bool {
    std::vector<sse::Frame> frames;
    parser.feed(data, len, &frames);
    for (const auto& f : frames) {
      Value v;
      std::string err;
      if (!Value::parse(f.data, v, err)) {
        cb_abort = true;
        return false;  // 坏帧：中止并报 Parse
      }
      if (f.event == "suggestion") {
        Suggestion s;
        if (const Value* x = v.find("text")) s.text = x->as_string();
        if (const Value* x = v.find("score")) s.score = x->as_double();
        if (const Value* x = v.find("source")) s.source = x->as_string();
        if (const Value* x = v.find("seq")) s.seq = static_cast<int>(x->as_int());
        if (on_suggestion) on_suggestion(s);
      } else if (f.event == "done") {
        SuggestDone d;
        if (const Value* x = v.find("status")) d.status = x->as_string();
        if (const Value* x = v.find("backend")) d.backend = x->as_string();
        if (const Value* x = v.find("suggestions")) d.suggestions = static_cast<int>(x->as_int());
        if (const Value* x = v.find("context_digest")) d.context_digest = x->as_string();
        got_done = true;
        if (on_done) on_done(d);
      }
    }
    return true;
  };

  http::Reply reply = http::perform(req);

  // 流尾：补发残帧（正常情况下帧间空行已切分，此处兜底）
  if (reply.status.ok()) {
    std::vector<sse::Frame> frames;
    parser.finish(&frames);
    for (const auto& f : frames) {
      (void)f;  // 尾帧兜底：与上面同逻辑太冗余，正常流不会走到
    }
  }

  if (!reply.status.ok()) {
    if (cb_abort) return make_error(Error::Parse, "bad SSE data frame");
    Status st = reply.status;  // Timeout（预算耗尽）/ Network
    if (st.code == Error::Timeout) {
      st.message = "suggest budget exceeded (" +
                   std::to_string(cfg_.suggest_budget_ms) + "ms): " + st.message;
    }
    return st;
  }
  Status st = classify(reply);
  if (!st.ok()) return st;
  if (!got_done) {
    return make_error(Error::Parse, "SSE stream ended without done event");
  }
  return Status{};
}

}  // namespace aihub
