// 极简断言测试框架（W8 sdk）。
#pragma once

#include <cstdio>
#include <string>

namespace testkit {

inline int g_failures = 0;
inline int g_checks = 0;

#define CHECK(cond)                                                          \
  do {                                                                       \
    ++testkit::g_checks;                                                     \
    if (!(cond)) {                                                           \
      ++testkit::g_failures;                                                 \
      std::printf("  [FAIL] %s:%d  %s\n", __FILE__, __LINE__, #cond);        \
    }                                                                        \
  } while (0)

#define CHECK_EQ(a, b)                                                       \
  do {                                                                       \
    ++testkit::g_checks;                                                     \
    if (!((a) == (b))) {                                                     \
      ++testkit::g_failures;                                                 \
      std::printf("  [FAIL] %s:%d  %s == %s\n", __FILE__, __LINE__, #a, #b); \
    }                                                                        \
  } while (0)

#define CHECK_STREQ(a, b)                                                    \
  do {                                                                       \
    ++testkit::g_checks;                                                     \
    std::string _a = (a), _b = (b);                                          \
    if (_a != _b) {                                                          \
      ++testkit::g_failures;                                                 \
      std::printf("  [FAIL] %s:%d  \"%s\" != \"%s\"\n", __FILE__, __LINE__,  \
                  _a.c_str(), _b.c_str());                                   \
    }                                                                        \
  } while (0)

}  // namespace testkit
