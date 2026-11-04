# W3 ai-spi：AiAssist SPI 契约 + 端侧后端骨架
find_package(Threads REQUIRED)

add_library(ai_spi STATIC
  spi/timeout_assist.cc
  backends/null/null_ai_assist.cc
  # W20：提案契约 v2 的 Null 提案桩（提案→确认→执行，契约见 spi/ai_assist_v2.h）
  backends/null/null_proposal_agent.cc
)

# include 根 = 仓库根：统一 #include "ai/spi/ai_assist.h" 形态（W4 文档引用同形）
target_include_directories(ai_spi PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/..)
target_compile_features(ai_spi PUBLIC cxx_std_17)
target_link_libraries(ai_spi PUBLIC Threads::Threads)

# W20 单测（在 ai/ 内注册，不动 tests/ 车道文件）：提案契约 v2 + Null 提案桩，
# 含红线断言「未 confirm 不得执行」；断言头复用 tests/test_assert.h（W3 约定）。
enable_testing()
add_executable(test_proposal_v2 tests/test_proposal_v2.cpp)
target_link_libraries(test_proposal_v2 PRIVATE ai_spi)
target_include_directories(test_proposal_v2 PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../tests)
add_test(NAME test_proposal_v2 COMMAND test_proposal_v2)
set_tests_properties(test_proposal_v2 PROPERTIES TIMEOUT 60)
