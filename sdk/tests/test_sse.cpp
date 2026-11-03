#include <string>

#include "sse.h"
#include "testkit.h"

using aihub::sse::Frame;
using aihub::sse::Parser;

void run_sse_tests() {
  std::printf("[sse]\n");

  // 完整流：3 帧 suggestion + 1 帧 done（与 hub/app/main.py 桩一致）
  std::string stream =
      "event: suggestion\ndata: {\"text\":\"a\",\"score\":0.86,\"source\":\"hub-stub\",\"seq\":1}\n\n"
      "event: suggestion\ndata: {\"text\":\"b\",\"seq\":2}\n\n"
      "event: done\ndata: {\"status\":\"ok\",\"suggestions\":3}\n\n";

  // 1 字节粒度喂入（碎片化边界）
  Parser p;
  std::vector<Frame> frames;
  for (char c : stream) p.feed(&c, 1, &frames);
  p.finish(&frames);
  CHECK_EQ(frames.size(), 3u);
  if (frames.size() == 3) {
    CHECK_STREQ(frames[0].event, "suggestion");
    CHECK_STREQ(frames[0].data, "{\"text\":\"a\",\"score\":0.86,\"source\":\"hub-stub\",\"seq\":1}");
    CHECK_STREQ(frames[1].event, "suggestion");
    CHECK_STREQ(frames[2].event, "done");
    CHECK_STREQ(frames[2].data, "{\"status\":\"ok\",\"suggestions\":3}");
  }

  // \r\n 行分隔 + 注释行 + 多行 data
  Parser p2;
  std::vector<Frame> f2;
  std::string s2 =
      ": keep-alive\r\nevent: suggestion\r\ndata: {\"a\":\r\ndata: 1}\r\n\r\n";
  p2.feed(s2.data(), s2.size(), &f2);
  CHECK_EQ(f2.size(), 1u);
  if (!f2.empty()) {
    CHECK_STREQ(f2[0].event, "suggestion");
    CHECK_STREQ(f2[0].data, "{\"a\":\n1}");
  }

  // 流尾未终结帧兜底
  Parser p3;
  std::vector<Frame> f3;
  std::string s3 = "event: done\ndata: {\"x\":1}\n";
  p3.feed(s3.data(), s3.size(), &f3);
  CHECK_EQ(f3.size(), 0u);
  p3.finish(&f3);
  CHECK_EQ(f3.size(), 1u);
}
