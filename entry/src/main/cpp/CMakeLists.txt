cmake_minimum_required(VERSION 3.5.0)
project(ruinsss_media CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

add_library(ruinsss_media SHARED
    ${CMAKE_CURRENT_SOURCE_DIR}/ruinsss_media.cpp
)

target_include_directories(ruinsss_media PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

target_compile_options(ruinsss_media PRIVATE
    -O3
    -fvisibility=hidden
    -Wall
    -Wno-unused-parameter
)

# HarmonyOS media NDK import stubs. The implementation lives in the device
# system image; these names are the ones exported by the platform.
target_link_libraries(ruinsss_media PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_core.so
    libnative_media_codecbase.so
    libnative_media_acodec.so
    libnative_media_avsource.so
    libnative_media_avdemuxer.so
    libnative_media_avmuxer.so
)
