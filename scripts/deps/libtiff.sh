#!/usr/bin/env bash
# libtiff — TIFF I/O. Required by GDAL GTIFF driver and by libgeotiff.
# Depends on libjpeg (built earlier) and zlib (from the iOS SDK).
#
# Upstream: https://gitlab.com/libtiff/libtiff
. "$(dirname "$0")/_common.sh"
dep_common_setup "$@"

VERSION="4.6.0"
TAG="v4.6.0"
URL="https://gitlab.com/libtiff/libtiff.git"
SRC_DIR="${SRC_BASE}/libtiff-${VERSION}"

dep_already_built libtiff.a && exit 0

dep_fetch_git "${URL}" "${TAG}" "${SRC_DIR}"

# libjpeg must already be installed under the same PREFIX; libtiff's
# CMake picks it up via CMAKE_PREFIX_PATH (which we set to PREFIX itself).
# Disable everything we don't need to keep the surface tiny.
dep_cmake_build "${SRC_DIR}" "${SRC_DIR}/build-ios-${SDK}" \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -Dtiff-tools=OFF \
    -Dtiff-tests=OFF \
    -Dtiff-contrib=OFF \
    -Dtiff-docs=OFF \
    -Djbig=OFF \
    -Dlerc=OFF \
    -Dlzma=OFF \
    -Dzstd=OFF \
    -Dwebp=OFF \
    -Dlibdeflate=OFF

dep_validate "${PREFIX}/lib/libtiff.a"
