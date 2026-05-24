#!/usr/bin/env bash
# expat — XML parser, required by GDAL's KML / GMT / and a few format
# helpers, plus by libgeotiff for GeoTIFF citation parsing on some
# builds. Plain CMake-aware, builds clean for iOS.
#
# Upstream: https://github.com/libexpat/libexpat — repo layout has an
# `expat/` subdirectory holding the actual CMake project.
. "$(dirname "$0")/_common.sh"
dep_common_setup "$@"

VERSION="2.6.2"
TAG="R_2_6_2"
URL="https://github.com/libexpat/libexpat.git"
SRC_DIR="${SRC_BASE}/libexpat-${VERSION}"

dep_already_built libexpat.a && exit 0

dep_fetch_git "${URL}" "${TAG}" "${SRC_DIR}"

# CMake project lives in expat/ subdir, not at repo root.
dep_cmake_build "${SRC_DIR}/expat" "${SRC_DIR}/build-ios-${SDK}" \
    -DEXPAT_BUILD_TOOLS=OFF \
    -DEXPAT_BUILD_EXAMPLES=OFF \
    -DEXPAT_BUILD_TESTS=OFF \
    -DEXPAT_BUILD_DOCS=OFF \
    -DEXPAT_SHARED_LIBS=OFF \
    -DEXPAT_BUILD_PKGCONFIG=OFF

dep_validate "${PREFIX}/lib/libexpat.a"
