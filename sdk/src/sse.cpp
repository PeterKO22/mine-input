#include "sse.h"

namespace aihub {
namespace sse {

namespace {
// 找最早出现的帧分隔："\n\n" 或 "\r\n\r\n"；返回分隔符长度（2 或 4）。
bool find_boundary(const std::string& s, size_t from, size_t* pos, size_t* sep_len) {
  size_t a = s.find("\n\n", from);
  size_t b = s.find("\r\n\r\n", from);
  if (a == std::string::npos && b == std::string::npos) return false;
  if (b != std::string::npos && (a == std::string::npos || b < a)) {
    *pos = b;
    *sep_len = 4;
  } else {
    *pos = a;
    *sep_len = 2;
  }
  return true;
}
}  // namespace

void Parser::feed(const char* data, size_t len, std::vector<Frame>* out) {
  buf_.append(data, len);
  drain(out, false);
}

void Parser::finish(std::vector<Frame>* out) {
  drain(out, true);
}

void Parser::drain(std::vector<Frame>* out, bool end_of_stream) {
  size_t pos, sep_len;
  while (find_boundary(buf_, 0, &pos, &sep_len)) {
    std::string block = buf_.substr(0, pos);
    buf_.erase(0, pos + sep_len);
    Frame f;
    bool has_data = false;
    if (parse_block(block, &f, &has_data) && has_data) out->push_back(std::move(f));
  }
  if (end_of_stream && !buf_.empty()) {
    std::string block = buf_;
    buf_.clear();
    Frame f;
    bool has_data = false;
    if (parse_block(block, &f, &has_data) && has_data) out->push_back(std::move(f));
  }
}

bool Parser::parse_block(const std::string& block, Frame* out, bool* has_data) {
  *has_data = false;
  out->event = "message";
  out->data.clear();
  bool first_data = true;

  size_t i = 0;
  while (i <= block.size()) {
    size_t eol = block.find('\n', i);
    std::string line = block.substr(i, eol == std::string::npos ? std::string::npos : eol - i);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    i = (eol == std::string::npos) ? block.size() + 1 : eol + 1;

    if (line.empty() || line[0] == ':') continue;  // 空行/注释
    size_t colon = line.find(':');
    std::string field = (colon == std::string::npos) ? line : line.substr(0, colon);
    std::string value;
    if (colon != std::string::npos) {
      value = line.substr(colon + 1);
      if (!value.empty() && value[0] == ' ') value.erase(0, 1);  // 规范：单个前导空格
    }
    if (field == "event") {
      out->event = value;
    } else if (field == "data") {
      if (!first_data) out->data.push_back('\n');
      out->data += value;
      first_data = false;
      *has_data = true;
    }  // id / retry 等字段忽略
  }
  return true;
}

}  // namespace sse
}  // namespace aihub
