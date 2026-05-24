#!/usr/bin/env bash
# GEOS — geometry engine. Used by GDAL for vector geometry operations
# (intersections, buffers, etc.). No deps within this set.
#
# Upstream: https://github.com/libgeos/geos
. "$(dirname "$0")/_common.sh"
dep_common_setup "$@"

VERSION="3.13.0"
TAG="3.13.0"
URL="https://github.com/libgeos/geos.git"
SRC_DIR="${SRC_BASE}/geos-${VERSION}"

dep_already_built libgeos.a && exit 0

dep_fetch_git "${URL}" "${TAG}" "${SRC_DIR}"

dep_cmake_build "${SRC_DIR}" "${SRC_DIR}/build-ios-${SDK}" \
    -DBUILD_TESTING=OFF \
    -DBUILD_BENCHMARKS=OFF \
    -DBUILD_DOCUMENTATION=OFF \
    -DBUILD_GEOSOP=OFF \
    -DBUILD_ASTYLE=OFF

dep_validate "${PREFIX}/lib/libgeos.a"
