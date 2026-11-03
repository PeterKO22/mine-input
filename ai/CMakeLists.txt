# W3 ai-spi：AiAssist SPI 契约 + 端侧后端骨架
find_package(Threads REQUIRED)

add_library(ai_spi STATIC
  spi/timeout_assist.cc
  backends/null/null_ai_assist.cc
)

# include 根 = 仓库根：统一 #include "ai/spi/ai_assist.h" 形态（W4 文档引用同形）
target_include_directories(ai_spi PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/..)
target_compile_features(ai_spi PUBLIC cxx_std_17)
target_link_libraries(ai_spi PUBLIC Threads::Threads)
