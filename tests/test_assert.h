/*
 * test_assert.h — 轻量断言（W3 约定：不引重型第三方测试框架）
 * 用法：CHECK(条件)；结束处 return testutil::Finish("用例名");
 */
#ifndef MINE_INPUT_TESTS_TEST_ASSERT_H_
#define MINE_INPUT_TESTS_TEST_ASSERT_H_

#include <cstdio>

namespace testutil {
inline int g_failures = 0;

inline int Finish(const char* name) {
  if (g_failures == 0) {
    std::printf("[PASS] %s\n", name);
    return 0;
  }
  std::printf("[FAIL] %s (%d 个断言失败)\n", name, g_failures);
  return 1;
}
}  // namespace testutil

#define CHECK(cond)                                                     \
  do {                                                                  \
    if (!(cond)) {                                                      \
      std::fprintf(stderr, "[FAIL] %s (%s:%d)\n", #cond, __FILE__,      \
                   __LINE__);                                           \
      testutil::g_failures += 1;                                        \
    }                                                                   \
  } while (0)

#endif  // MINE_INPUT_TESTS_TEST_ASSERT_H_
