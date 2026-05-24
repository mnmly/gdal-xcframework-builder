#!/usr/bin/env bash
# PROJ — cartographic projection / datum transform engine. Depends on
# sqlite3 and libtiff. EMBED_PROJ_DATA=ON bakes proj.db into the static
# archive so iOS consumers don't need a runtime resource search path.
#
# Upstream: https://github.com/OSGeo/PROJ
#
# This is the dep that ships separately in proj.xcframework — see
# tasks/todo.md §5.3 for the rationale.
. "$(dirname "$0")/_common.sh"
dep_common_setup "$@"

VERSION="9.4.0"
TAG="9.4.0"
URL="https://github.com/OSGeo/PROJ.git"
SRC_DIR="${SRC_BASE}/proj-${VERSION}"

dep_already_built libproj.a && exit 0

dep_fetch_git "${URL}" "${TAG}" "${SRC_DIR}"

SQLITE_PREFIX="${SQLITE_PREFIX_FOR_PROJ:-}"
TIFF_PREFIX="${TIFF_PREFIX_FOR_PROJ:-}"
SIBLINGS="${SQLITE_PREFIX};${TIFF_PREFIX}"

# EMBED_PROJ_DATA=ON: critical for iOS — bakes the resource bundle
# (proj.db etc.) into the static archive, so consumers don't need
# PROJ_LIB / proj_context_set_search_paths() at runtime. Matches the
# "iOS PROJ data" pitfall in tasks/todo.md §8.
dep_cmake_build "${SRC_DIR}" "${SRC_DIR}/build-ios-${SDK}" \
    -DCMAKE_PREFIX_PATH="${SIBLINGS}" \
    -DBUILD_APPS=OFF \
    -DBUILD_TESTING=OFF \
    -DENABLE_CURL=OFF \
    -DENABLE_TIFF=ON \
    -DEMBED_PROJ_DATA=ON \
    -DSQLITE3_INCLUDE_DIR="${SQLITE_PREFIX}/include" \
    -DSQLITE3_LIBRARY="${SQLITE_PREFIX}/lib/libsqlite3.a" \
    -DEXE_SQLITE3=/usr/bin/sqlite3 \
    -DTIFF_INCLUDE_DIR="${TIFF_PREFIX}/include" \
    -DTIFF_LIBRARY_RELEASE="${TIFF_PREFIX}/lib/libtiff.a"

dep_validate "${PREFIX}/lib/libproj.a"
