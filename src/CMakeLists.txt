configure_file("config.hpp.in" "${CMAKE_BINARY_DIR}/configured_files/include/internal_use_only/config.hpp" ESCAPE_QUOTES)

add_executable (kvcache main.cpp)

target_link_libraries(kvcache PRIVATE Seastar::seastar)
target_include_directories(kvcache PRIVATE "${CMAKE_BINARY_DIR}/configured_files/include")