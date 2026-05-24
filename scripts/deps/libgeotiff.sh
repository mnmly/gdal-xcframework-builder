#!/usr/bin/env bash
# libgeotiff — GeoTIFF citation / projection metadata on top of libtiff.
# Depends on libtiff, libjpeg, proj (built earlier).
#
# Upstream: https://github.com/OSGeo/libgeotiff — CMake project lives in
# `libgeotiff/` subdir.
#
# IMPORTANT: must be built AFTER proj/geos since it needs PROJ::proj for
# the CMake `find_package(PROJ)` call.
. "$(dirname "$0")/_common.sh"
dep_common_setup "$@"

VERSION="1.7.3"
TAG="1.7.3"
URL="https://github.com/OSGeo/libgeotiff.git"
SRC_DIR="${SRC_BASE}/libgeotiff-${VERSION}"

dep_already_built libgeotiff.a && exit 0

dep_fetch_git "${URL}" "${TAG}" "${SRC_DIR}"

# CMAKE_PREFIX_PATH points at the same PREFIX we install into — the
# deps-cache layout is one prefix per (sdk, dep), and we deliberately
# install everything for one sdk under the same root so find_package
# resolves siblings cleanly.
# (Actually each dep lives under deps-cache/<sdk>/<dep>-<ver>/ in the
# orchestrator. The build-deps.sh wrapper sets CMAKE_PREFIX_PATH to a
# semicolon-list of all sibling dep prefixes when invoking GDAL — see
# phase 5. Here, just give libgeotiff a hint via its own PROJ_DIR / etc.
# variables which we expect the caller to pass through env if needed.)
PROJ_PREFIX="${PROJ_PREFIX_FOR_LIBGEOTIFF:-}"
TIFF_PREFIX="${TIFF_PREFIX_FOR_LIBGEOTIFF:-}"
JPEG_PREFIX="${JPEG_PREFIX_FOR_LIBGEOTIFF:-}"
SIBLINGS="${PROJ_PREFIX};${TIFF_PREFIX};${JPEG_PREFIX}"

dep_cmake_build "${SRC_DIR}/libgeotiff" "${SRC_DIR}/build-ios-${SDK}" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_PREFIX_PATH="${SIBLINGS}" \
    -DWITH_UTILITIES=OFF \
    -DWITH_TIFF=ON \
    -DWITH_PROJ=ON \
    -DWITH_JPEG=ON \
    -DWITH_ZLIB=ON \
    -DPROJ_INCLUDE_DIR="${PROJ_PREFIX}/include" \
    -DPROJ_LIBRARY="${PROJ_PREFIX}/lib/libproj.a" \
    -DTIFF_INCLUDE_DIR="${TIFF_PREFIX}/include" \
    -DTIFF_LIBRARY="${TIFF_PREFIX}/lib/libtiff.a" \
    -DJPEG_INCLUDE_DIR="${JPEG_PREFIX}/include" \
    -DJPEG_LIBRARY="${JPEG_PREFIX}/lib/libjpeg.a" \
    -DHAVE_TIFFOPEN=1 \
    -DHAVE_TIFFMERGEFIELDINFO=1

dep_validate "${PREFIX}/lib/libgeotiff.a"
