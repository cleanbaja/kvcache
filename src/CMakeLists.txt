configure_file("config.hpp.in" "${CMAKE_BINARY_DIR}/configured_files/include/internal_use_only/config.hpp" ESCAPE_QUOTES)

add_executable (kvcache main.cpp)

target_link_libraries(kvcache PRIVATE Seastar::seastar)
target_include_directories(kvcache PRIVATE "${CMAKE_BINARY_DIR}/configured_files/include")

if(kvcache_ENABLE_COVERAGE)
    if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" OR CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")
        target_compile_options(kvcache INTERFACE --coverage -O0 -g)
        target_link_libraries(kvcache INTERFACE --coverage)
    endif()
endif()