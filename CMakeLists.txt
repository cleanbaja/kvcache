cmake_minimum_required(VERSION 3.21)

# We use C++20 without GNU extensions.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_EXTENSIONS OFF)

project(
  kvcache
  VERSION 0.0.1
  DESCRIPTION "High-performance & low-latency key-value store."
  HOMEPAGE_URL "https://github.com/cleanbaja/kvcache"
  LANGUAGES CXX C)

include(cmake/PreventInSourceBuilds.cmake)

# Only required package is Seastar
find_package (Seastar REQUIRED)

# Restrict symbols to the local library
set(CMAKE_CXX_VISIBILITY_PRESET hidden)

# Set a default build type if none was specified
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  message(STATUS "Setting build type to 'RelWithDebInfo' as none was specified.")
  set(CMAKE_BUILD_TYPE
      RelWithDebInfo
      CACHE STRING "Choose the type of build." FORCE)
  # Set the possible values of build type for cmake-gui, ccmake
  set_property(
    CACHE CMAKE_BUILD_TYPE
    PROPERTY STRINGS
             "Debug"
             "Release"
             "MinSizeRel"
             "RelWithDebInfo")
endif()

# Generate compile_commands.json to make it easier to work with clang based tools
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Enhance error reporting and compiler messages
if(CMAKE_CXX_COMPILER_ID MATCHES ".*Clang")
  if(WIN32)
    # On Windows cuda nvcc uses cl and not clang
    add_compile_options($<$<COMPILE_LANGUAGE:C>:-fcolor-diagnostics> $<$<COMPILE_LANGUAGE:CXX>:-fcolor-diagnostics>)
  else()
    add_compile_options(-fcolor-diagnostics)
  endif()
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  if(WIN32)
    # On Windows cuda nvcc uses cl and not gcc
    add_compile_options($<$<COMPILE_LANGUAGE:C>:-fdiagnostics-color=always>
                        $<$<COMPILE_LANGUAGE:CXX>:-fdiagnostics-color=always>)
  else()
    add_compile_options(-fdiagnostics-color=always)
  endif()
elseif(CMAKE_CXX_COMPILER_ID STREQUAL "MSVC" AND MSVC_VERSION GREATER 1900)
  add_compile_options(/diagnostics:column)
else()
  message(STATUS "No colored compiler diagnostic set for '${CMAKE_CXX_COMPILER_ID}' compiler.")
endif()

set(GIT_SHA
    "Unknown"
    CACHE STRING "SHA this build was generated from")
string(SUBSTRING
    "${GIT_SHA}"
    0
    8
    GIT_SHORT_SHA)

# Define options
option(kvcache_ENABLE_COVERAGE "Enable coverage reporting" OFF)
if(NOT PROJECT_IS_TOP_LEVEL OR kvcache_PACKAGING_MAINTAINER_MODE)
    option(kvcache_WARNINGS_AS_ERRORS "Treat Warnings As Errors" OFF)
    option(kvcache_ENABLE_CLANG_TIDY "Enable clang-tidy" OFF)
    option(kvcache_ENABLE_CPPCHECK "Enable cpp-check analysis" OFF)
    option(kvcache_ENABLE_CACHE "Enable ccache" OFF)
else()
    option(kvcache_WARNINGS_AS_ERRORS "Treat Warnings As Errors" ON)
    option(kvcache_ENABLE_CLANG_TIDY "Enable clang-tidy" ON)
    option(kvcache_ENABLE_CPPCHECK "Enable cpp-check analysis" ON)
    option(kvcache_ENABLE_CACHE "Enable ccache" ON)
endif()

# Parse options based on if they were set.
include(cmake/StaticAnalyzers.cmake)
if(kvcache_ENABLE_CACHE)
    include(cmake/Cache.cmake)
    kvcache_enable_cache()
endif()
if(kvcache_ENABLE_CLANG_TIDY)
    kvcache_enable_clang_tidy(${kvcache_WARNINGS_AS_ERRORS})
endif()
if(kvcache_ENABLE_CPPCHECK)
    kvcache_enable_cppcheck(${kvcache_WARNINGS_AS_ERRORS} "")
endif()
if(kvcache_WARNINGS_AS_ERRORS)
    check_cxx_compiler_flag("-Wl,--fatal-warnings" LINKER_FATAL_WARNINGS)
    if(LINKER_FATAL_WARNINGS)
        target_link_options(kvcache_options INTERFACE -Wl,--fatal-warnings)
    endif()
endif()

# Adding the src:
add_subdirectory(src)