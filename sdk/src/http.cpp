#include "http.h"

#include <curl/curl.h>

#include <chrono>
#include <mutex>

namespace aihub {
namespace http {

namespace {

std::once_flag g_curl_once;

void ensure_curl() {
  std::call_once(g_curl_once, [] { curl_global_init(CURL_GLOBAL_DEFAULT); });
}

struct Ctx {
  const Request* req = nullptr;
  Reply reply;
  bool aborted_by_chunk = false;
  std::chrono::steady_clock::time_point deadline;
  bool has_deadline = false;
};

size_t write_cb(char* ptr, size_t size, size_t nmemb, void* userdata) {
  auto* ctx = static_cast<Ctx*>(userdata);
  size_t len = size * nmemb;
  if (ctx->req->on_chunk) {
    if (!ctx->req->on_chunk(ptr, len)) {
      ctx->aborted_by_chunk = true;
      return 0;  // 中止传输
    }
  } else {
    ctx->reply.body.append(ptr, len);
  }
  return len;
}

int xferinfo_cb(void* clientp, curl_off_t /*dltotal*/, curl_off_t /*dlnow*/,
                curl_off_t /*ultotal*/, curl_off_t /*ulnow*/) {
  auto* ctx = static_cast<Ctx*>(clientp);
  if (ctx->has_deadline && std::chrono::steady_clock::now() > ctx->deadline) return 1;
  return 0;
}

size_t header_cb(char* buffer, size_t size, size_t nitems, void* userdata) {
  auto* ctx = static_cast<Ctx*>(userdata);
  size_t len = size * nitems;
  std::string line(buffer, len);
  // "HTTP/1.1 200 OK" —— 取首个状态码（重定向会有多个响应块）
  if (line.rfind("HTTP/", 0) == 0) {
    size_t sp = line.find(' ');
    if (sp != std::string::npos) {
      long code = strtol(line.c_str() + sp + 1, nullptr, 10);
      if (code > 0) ctx->reply.http_status = code;
    }
  }
  return len;
}

}  // namespace

Reply perform(const Request& req) {
  ensure_curl();

  Ctx ctx;
  ctx.req = &req;
  if (req.timeout_ms > 0) {
    ctx.has_deadline = true;
    ctx.deadline = std::chrono::steady_clock::now() +
                   std::chrono::milliseconds(req.timeout_ms);
  }

  CURL* curl = curl_easy_init();
  if (!curl) {
    ctx.reply.status.code = Error::Network;
    ctx.reply.status.message = "curl_easy_init failed";
    return ctx.reply;
  }

  struct curl_slist* headers = nullptr;
  headers = curl_slist_append(headers, "Content-Type: application/json");
  headers = curl_slist_append(headers,
                              req.accept_sse ? "Accept: text/event-stream"
                                             : "Accept: application/json");
  if (!req.bearer_token.empty()) {
    std::string auth = "Authorization: Bearer " + req.bearer_token;
    headers = curl_slist_append(headers, auth.c_str());
  }

  curl_easy_setopt(curl, CURLOPT_URL, req.url.c_str());
  curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, req.connect_timeout_ms);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, req.timeout_ms + 500);  // 兜底
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_cb);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, &ctx);
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, header_cb);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, &ctx);
  curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, xferinfo_cb);
  curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &ctx);
  curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);

  if (req.method == "GET") {
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
  } else {
    curl_easy_setopt(curl, CURLOPT_POST, 1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, req.body.c_str());
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, static_cast<long>(req.body.size()));
  }

  CURLcode rc = curl_easy_perform(curl);
  long status = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
  if (ctx.reply.http_status == 0) ctx.reply.http_status = status;

  if (rc == CURLE_OK) {
    ctx.reply.status.code = Error::Ok;
  } else if (rc == CURLE_ABORTED_BY_CALLBACK || rc == CURLE_WRITE_ERROR ||
             rc == CURLE_OPERATION_TIMEDOUT) {
    if (ctx.aborted_by_chunk) {
      // 主动中止（调用方回调拒绝）→ 按预算耗尽处理
      ctx.reply.status.code = Error::Timeout;
      ctx.reply.status.message = "aborted by stream handler (budget)";
    } else {
      ctx.reply.status.code = Error::Timeout;
      ctx.reply.status.message = std::string("timeout: ") + curl_easy_strerror(rc);
    }
  } else {
    ctx.reply.status.code = Error::Network;
    ctx.reply.status.message = std::string("curl error: ") + curl_easy_strerror(rc);
  }
  ctx.reply.status.http_status = static_cast<int>(ctx.reply.http_status);

  curl_slist_free_all(headers);
  curl_easy_cleanup(curl);
  return ctx.reply;
}

}  // namespace http
}  // namespace aihub
