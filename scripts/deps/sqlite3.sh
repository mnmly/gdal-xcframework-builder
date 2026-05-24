#!/usr/bin/env bash
# sqlite3 — built from the amalgamation tarball, compiled directly with
# clang (no autoconf, no CMake). PROJ + GPKG need it with COLUMN_METADATA
# and RTREE enabled, so we control CFLAGS directly rather than wrestle
# with the autoconf wrapper.
#
# Upstream: https://www.sqlite.org/2024/sqlite-autoconf-3460000.tar.gz
. "$(dirname "$0")/_common.sh"
dep_common_setup "$@"

VERSION="3.46.0"
TARBALL_NAME="sqlite-autoconf-3460000"
URL="https://www.sqlite.org/2024/${TARBALL_NAME}.tar.gz"
SRC_DIR="${SRC_BASE}/${TARBALL_NAME}"

dep_already_built libsqlite3.a && exit 0

dep_fetch_tarball "${URL}" "${SRC_DIR}"

SDK_PATH="$(xcrun --sdk "${SYSROOT_NAME}" --show-sdk-path)"
case "${SDK}" in
    device)    TARGET_TRIPLE="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}" ;;
    simulator) TARGET_TRIPLE="arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" ;;
esac

BUILD_DIR="${SRC_DIR}/build-ios-${SDK}"
mkdir -p "${BUILD_DIR}" "${PREFIX}/lib" "${PREFIX}/include"

# Compile flags chosen to match what GDAL's CMake probes for via
# GDAL_USE_SQLITE3 + what PROJ needs (column metadata, R*Tree).
CFLAGS=(
    -isysroot "${SDK_PATH}"
    -target "${TARGET_TRIPLE}"
    -arch arm64
    -O2 -fPIC
    -DSQLITE_ENABLE_COLUMN_METADATA=1
    -DSQLITE_ENABLE_RTREE=1
    -DSQLITE_ENABLE_FTS5=1
    -DSQLITE_ENABLE_GEOPOLY=1
    -DSQLITE_OMIT_DEPRECATED
    -DSQLITE_THREADSAFE=1
    -DSQLITE_DEFAULT_MEMSTATUS=0
)

echo "compiling sqlite3.c..."
xcrun --sdk "${SYSROOT_NAME}" clang "${CFLAGS[@]}" \
    -c "${SRC_DIR}/sqlite3.c" -o "${BUILD_DIR}/sqlite3.o"
xcrun --sdk "${SYSROOT_NAME}" libtool -static \
    -o "${PREFIX}/lib/libsqlite3.a" "${BUILD_DIR}/sqlite3.o"
cp "${SRC_DIR}/sqlite3.h" "${PREFIX}/include/"
cp "${SRC_DIR}/sqlite3ext.h" "${PREFIX}/include/"

dep_validate "${PREFIX}/lib/libsqlite3.a"
