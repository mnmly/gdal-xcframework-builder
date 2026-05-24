# CMake toolchain file: iOS arm64 device.
#
# All deps + GDAL itself are configured with this file when targeting
# iphoneos. Companion: ios-sim.cmake (identical except SYSROOT).
#
# Phase 4 of tasks/todo.md will pre-cache try_run answers here for the
# cross-compile cases that fail otherwise (endianness, etc.).

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_SYSROOT iphoneos)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0)
set(CMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE NO)

# Host tools (cmake itself, generators) resolve on the host; libraries/headers/
# packages only inside the SDK + CMAKE_PREFIX_PATH (the deps-cache dirs).
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
