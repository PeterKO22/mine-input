#include "serialize.h"

namespace aihub {
namespace ser {

using json::Value;

Value meta_to_json(const MetaValue& m) {
  Value o = Value::object();
  o.set("updated_at", Value(m.updated_at));
  Value inner;
  std::string err;
  if (!m.value_json.empty() && Value::parse(m.value_json, inner, err)) {
    o.set("value", std::move(inner));
  } else {
    o.set("value", Value(m.value_json));
  }
  return o;
}

bool meta_from_json(const Value& v, MetaValue* out) {
  if (!v.is_object()) return false;
  const Value* ua = v.find("updated_at");
  const Value* val = v.find("value");
  if (!ua || !val) return false;
  out->updated_at = ua->as_int();
  out->value_json = val->serialize();
  return true;
}

Value push_payload_to_json(const PushPayload& p) {
  Value o = Value::object();
  o.set("device_id", Value(p.device_id));
  o.set("push_id", Value(p.push_id));
  Value userdb = Value::array();
  for (const auto& e : p.userdb) {
    Value item = Value::object();
    item.set("key", Value(e.key));
    item.set("value", Value(e.value));
    item.set("updated_at", Value(e.updated_at));
    userdb.push_back(std::move(item));
  }
  o.set("userdb", std::move(userdb));
  Value counters = Value::object();
  for (const auto& kv : p.counters) counters.set(kv.first, Value(kv.second));
  o.set("counters", std::move(counters));
  Value hotwords = Value::array();
  for (const auto& w : p.hotwords) hotwords.push_back(Value(w));
  o.set("hotwords", std::move(hotwords));
  if (p.ai_config) o.set("ai_config", meta_to_json(*p.ai_config));
  if (p.schema_version) o.set("schema_version", meta_to_json(*p.schema_version));
  return o;
}

bool push_payload_from_json(const Value& v, PushPayload* out, std::string* err) {
  if (!v.is_object()) {
    if (err) *err = "push payload: not an object";
    return false;
  }
  PushPayload p;
  if (const Value* d = v.find("device_id")) p.device_id = d->as_string();
  if (const Value* d = v.find("push_id")) p.push_id = d->as_string();
  if (const Value* arr = v.find("userdb")) {
    for (const auto& item : arr->items()) {
      UserdbEntry e;
      if (const Value* k = item.find("key")) e.key = k->as_string();
      if (const Value* val = item.find("value")) e.value = val->as_string();
      if (const Value* ua = item.find("updated_at")) e.updated_at = ua->as_int();
      p.userdb.push_back(std::move(e));
    }
  }
  if (const Value* c = v.find("counters")) {
    for (const auto& kv : c->members()) p.counters[kv.first] = kv.second.as_int();
  }
  if (const Value* h = v.find("hotwords")) {
    for (const auto& w : h->items()) p.hotwords.push_back(w.as_string());
  }
  if (const Value* m = v.find("ai_config")) {
    MetaValue mv;
    if (meta_from_json(*m, &mv)) p.ai_config = mv;
  }
  if (const Value* m = v.find("schema_version")) {
    MetaValue mv;
    if (meta_from_json(*m, &mv)) p.schema_version = mv;
  }
  *out = std::move(p);
  return true;
}

Value event_to_json(const InteractionEvent& e) {
  Value o = Value::object();
  o.set("ts", Value(e.ts));
  o.set("device_id", Value(e.device_id));
  o.set("app_id", Value(e.app_id));
  o.set("kind", Value(e.kind));
  o.set("text_in", Value(e.text_in));
  o.set("text_out", Value(e.text_out));
  if (e.ocr_digest) o.set("ocr_digest", Value(*e.ocr_digest));
  if (e.asr_digest) o.set("asr_digest", Value(*e.asr_digest));
  if (e.keystroke_cadence) o.set("keystroke_cadence", Value(*e.keystroke_cadence));
  if (e.suggestion_shown) o.set("suggestion_shown", Value(*e.suggestion_shown));
  if (e.suggestion_taken) o.set("suggestion_taken", Value(*e.suggestion_taken));
  return o;
}

bool event_from_json(const Value& v, InteractionEvent* out, std::string* err) {
  if (!v.is_object()) {
    if (err) *err = "event: not an object";
    return false;
  }
  InteractionEvent e;
  if (const Value* x = v.find("ts")) e.ts = x->as_int();
  if (const Value* x = v.find("device_id")) e.device_id = x->as_string();
  if (const Value* x = v.find("app_id")) e.app_id = x->as_string();
  if (const Value* x = v.find("kind")) e.kind = x->as_string();
  if (const Value* x = v.find("text_in")) e.text_in = x->as_string();
  if (const Value* x = v.find("text_out")) e.text_out = x->as_string();
  if (const Value* x = v.find("ocr_digest")) e.ocr_digest = x->as_string();
  if (const Value* x = v.find("asr_digest")) e.asr_digest = x->as_string();
  if (const Value* x = v.find("keystroke_cadence")) e.keystroke_cadence = x->as_double();
  if (const Value* x = v.find("suggestion_shown")) e.suggestion_shown = x->as_int();
  if (const Value* x = v.find("suggestion_taken")) e.suggestion_taken = x->as_int();
  *out = std::move(e);
  return true;
}

}  // namespace ser
}  // namespace aihub
