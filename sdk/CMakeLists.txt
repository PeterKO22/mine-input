# mine-input hub-client SDK（W8）—— C++17 + libcurl + SQLite3，无其他依赖
cmake_minimum_required(VERSION 3.16)
project(ai_hub_client LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

find_package(CURL REQUIRED)
find_package(SQLite3 REQUIRED)
find_package(Threads REQUIRED)

add_library(ai_hub_client
  src/json.cpp
  src/sse.cpp
  src/http.cpp
  src/serialize.cpp
  src/client.cpp
  src/offline_queue.cpp
)
target_include_directories(ai_hub_client
  PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include
  PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src
)
target_link_libraries(ai_hub_client
  PUBLIC CURL::libcurl SQLite::SQLite3 Threads::Threads
)

# ---- 单元测试（本地 mock HTTP + 可选真实 Hub 集成，AI_HUB_URL 不可达自跳过）
enable_testing()
add_executable(sdk_tests
  tests/test_main.cpp
  tests/test_json.cpp
  tests/test_sse.cpp
  tests/test_queue.cpp
  tests/test_client.cpp
)
target_link_libraries(sdk_tests PRIVATE ai_hub_client)
target_include_directories(sdk_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
add_test(NAME sdk_tests COMMAND sdk_tests)

# ---- 验收 demo：对真实 Hub 跑全链路
add_executable(sync-demo sync-demo/main.cpp)
target_link_libraries(sync-demo PRIVATE ai_hub_client)
