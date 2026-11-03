cmake_minimum_required(VERSION 3.16)
project(mine_input LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# W3 ai-spi：SPI 契约 + 端侧后端骨架（其他车道目标后续在各自子目录追加）
add_subdirectory(ai)

enable_testing()
add_subdirectory(tests)
