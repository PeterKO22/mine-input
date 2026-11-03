// SSE（text/event-stream）增量帧解析器（内部实现）。
// 逐块喂入（libcurl write callback 粒度任意），按空行切帧：
//   event: suggestion\ndata: {...}\n\n
// 支持 \n / \r\n 行分隔、多行 data 拼接（按规范以 \n 连接）、注释行（':' 开头）。
#pragma once

#include <cstddef>
#include <string>
#include <vector>

namespace aihub {
namespace sse {

struct Frame {
  std::string event;  // 缺省 "message"
  std::string data;
};

class Parser {
 public:
  // 喂入任意字节块，产出其中完整的帧（0..n 个）。
  void feed(const char* data, size_t len, std::vector<Frame>* out);
  // 流结束：若缓冲残留一个带 data 的未终结帧，补发。
  void finish(std::vector<Frame>* out);

 private:
  std::string buf_;
  void drain(std::vector<Frame>* out, bool end_of_stream);
  static bool parse_block(const std::string& block, Frame* out, bool* has_data);
};

}  // namespace sse
}  // namespace aihub
