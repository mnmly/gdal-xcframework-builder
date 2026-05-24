#!/usr/bin/env bash
# libpng — PNG codec. Not in the iOS GDAL driver allow-list, but PROJ
# can pull it indirectly via libtiff (which can be built with PNG
# predictor support). Cheap to build; keep in the dep set.
#
# Upstream: https://github.com/glennrp/libpng
. "$(dirname "$0")/_common.sh"
dep_common_setup "$@"

VERSION="1.6.43"
TAG="v1.6.43"
URL="https://github.com/glennrp/libpng.git"
SRC_DIR="${SRC_BASE}/libpng-${VERSION}"

dep_already_built libpng.a && exit 0

dep_fetch_git "${URL}" "${TAG}" "${SRC_DIR}"

# libpng's "ARM NEON optimisations" toggle: ON is default on arm64, but
# we set it explicitly so cross-compile try_run probes don't fall back
# to the timid default.
dep_cmake_build "${SRC_DIR}" "${SRC_DIR}/build-ios-${SDK}" \
    -DPNG_SHARED=OFF \
    -DPNG_STATIC=ON \
    -DPNG_FRAMEWORK=OFF \
    -DPNG_EXECUTABLES=OFF \
    -DPNG_TESTS=OFF \
    -DPNG_TOOLS=OFF \
    -DPNG_ARM_NEON=on

# libpng installs the static archive as libpng16.a + a libpng.a symlink.
# Prefer the canonical name for the rest of the pipeline.
if [ ! -f "${PREFIX}/lib/libpng.a" ] && [ -f "${PREFIX}/lib/libpng16.a" ]; then
    ( cd "${PREFIX}/lib" && ln -sf libpng16.a libpng.a )
fi

dep_validate "${PREFIX}/lib/libpng.a"
