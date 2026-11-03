// libcurl HTTP 封装（内部实现）：POST/GET JSON + SSE 流式块回调。
// 超时：connect_timeout_ms 连接预算；timeout_ms 整体预算（含流式）。
// 流式：on_chunk 返回 false 或整体超时 → 中断传输（映射 Error::Timeout）。
#pragma once

#include <functional>
#include <string>

#include "ai_hub_client/ai_hub_client.h"

namespace aihub {
namespace http {

// 返回 false 表示主动中止（预算耗尽）。
using ChunkHandler = std::function<bool(const char* data, size_t len)>;

struct Request {
  std::string method = "POST";   // "POST" | "GET"
  std::string url;
  std::string bearer_token;      // 空则不带 Authorization
  std::string body;              // JSON 请求体（POST 时）
  bool accept_sse = false;       // Accept: text/event-stream
  long connect_timeout_ms = 2000;
  long timeout_ms = 8000;
  ChunkHandler on_chunk;         // 流式响应块；设置时不累积 body
};

struct Reply {
  Status status;                 // 传输层：Ok / Network / Timeout
  long http_status = 0;          // HTTP 状态码（拿到响应头时）
  std::string body;              // 非流式时的响应体
};

Reply perform(const Request& req);

}  // namespace http
}  // namespace aihub
