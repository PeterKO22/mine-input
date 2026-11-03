#include "json.h"
#include "testkit.h"

using aihub::json::Value;

void run_json_tests() {
  std::printf("[json]\n");

  // 基础解析
  Value v;
  std::string err;
  CHECK(Value::parse(R"({"a":1,"b":"x","c":true,"d":null,"e":[1,2],"f":{"g":1.5}})", v, err));
  CHECK(v.is_object());
  CHECK_EQ(v.find("a")->as_int(), 1);
  CHECK_STREQ(v.find("b")->as_string(), "x");
  CHECK(v.find("c")->as_bool());
  CHECK(v.find("d")->is_null());
  CHECK_EQ(v.find("e")->size(), 2u);
  CHECK_EQ(v.find("e")->at(1).as_int(), 2);
  CHECK_EQ(v.find("f")->find("g")->as_double(), 1.5);

  // 转义与 \u / 代理对
  Value vs;
  CHECK(Value::parse(R"("\u4e2d\u6587 \ud83d\ude00 \" \\ \/ \n")", vs, err));
  // U+4E2D U+6587 空格 U+1F600 空格 " \ / 换行
  CHECK_STREQ(vs.as_string(), "\xe4\xb8\xad\xe6\x96\x87 \xf0\x9f\x98\x80 \" \\ / \n");

  // 中文原样 UTF-8 往返
  Value vo = Value::object();
  vo.set("key", Value("五笔——好的"));
  std::string s = vo.serialize();
  Value back;
  CHECK(Value::parse(s, back, err));
  CHECK_STREQ(back.find("key")->as_string(), "五笔——好的");

  // 大整数（epoch ms）精确往返
  Value vi;
  CHECK(Value::parse("1793730162150", vi, err));
  CHECK_EQ(vi.as_int(), 1793730162150LL);
  CHECK_STREQ(vi.serialize(), "1793730162150");

  // 坏输入
  Value bad;
  CHECK(!Value::parse("{", bad, err));
  CHECK(!Value::parse("[1,]", bad, err));
  CHECK(!Value::parse("tru", bad, err));
  CHECK(!Value::parse("{\"a\":1} extra", bad, err));
}
