#!/usr/bin/env bash
# libjpeg-turbo — JPEG codec. Required by libtiff (TIFF/JPEG compression)
# which is required by GTIFF.
#
# Upstream: https://github.com/libjpeg-turbo/libjpeg-turbo
. "$(dirname "$0")/_common.sh"
dep_common_setup "$@"

VERSION="3.0.3"
TAG="3.0.3"
URL="https://github.com/libjpeg-turbo/libjpeg-turbo.git"
SRC_DIR="${SRC_BASE}/libjpeg-turbo-${VERSION}"

dep_already_built libjpeg.a && exit 0

dep_fetch_git "${URL}" "${TAG}" "${SRC_DIR}"

# libjpeg-turbo's NASM-based SIMD path doesn't apply to arm64; the
# library has its own NEON intrinsics path enabled by default when arch
# is arm64. -DWITH_SIMD=ON is the default; spell it out for clarity.
dep_cmake_build "${SRC_DIR}" "${SRC_DIR}/build-ios-${SDK}" \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON \
    -DWITH_TURBOJPEG=OFF \
    -DWITH_SIMD=ON \
    -DCMAKE_ASM_COMPILER="$(xcrun --sdk "${SYSROOT_NAME}" --find clang)"

dep_validate "${PREFIX}/lib/libjpeg.a"
