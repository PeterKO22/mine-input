// PushPayload / InteractionEvent ↔ JSON（内部实现；队列持久化 + HTTP 载荷共用）。
#pragma once

#include <string>

#include "ai_hub_client/ai_hub_client.h"
#include "json.h"

namespace aihub {
namespace ser {

json::Value push_payload_to_json(const PushPayload& p);
bool push_payload_from_json(const json::Value& v, PushPayload* out, std::string* err);

json::Value event_to_json(const InteractionEvent& e);
bool event_from_json(const json::Value& v, InteractionEvent* out, std::string* err);

// MetaValue：value_json 里装任意 JSON；解析失败按字符串原样包一层。
json::Value meta_to_json(const MetaValue& m);
bool meta_from_json(const json::Value& v, MetaValue* out);

}  // namespace ser
}  // namespace aihub
