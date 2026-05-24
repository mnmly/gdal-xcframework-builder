#!/usr/bin/env bash
# Dev iteration helper: run only the iOS GDAL configure+build for one
# slice, skipping the macOS pipeline (which takes ~30 min and is
# unrelated). Equivalent to the configure+build step inside build.sh's
# `build_ios_gdal()` function.
#
# Usage: ./scripts/test-ios-gdal.sh <GDAL_VERSION> <sdk>
#   <sdk> = device | simulator
#
# Requires the GDAL source already cloned at work/gdal-<ver>/src and the
# iOS deps already built at work/deps-cache/ios-<sdk>/. Both are produced
# by a prior `BUILD_IOS=1 ./build.sh <ver>` run.
#
# Production users: run `./build.sh <ver>` with BUILD_IOS=1 — that does
# the whole pipeline. This script is for iterating on GDAL configure
# flags without rebuilding the macOS slice every time.

set -euo pipefail

GDAL_VERSION="${1:?usage: $0 <GDAL_VERSION> <device|simulator>}"
SDK="${2:?usage: $0 <GDAL_VERSION> <device|simulator>}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/config.sh" 2>/dev/null || true

: "${IOS_DEPLOYMENT_TARGET:=17.0}"
: "${IOS_ENABLED_RASTER_DRIVERS:=GTIFF VRT}"
: "${IOS_ENABLED_VECTOR_DRIVERS:=SHAPE GEOJSON SQLITE GPKG}"
: "${EXTRA_CMAKE_FLAGS:=}"

FW_VERSION="$(echo "${GDAL_VERSION}" | awk -F. '{print $1"."$2}')"
WORK="${ROOT}/work/gdal-${GDAL_VERSION}"
SRC_DIR="${WORK}/src"

if [ ! -d "${SRC_DIR}/.git" ]; then
    echo "error: GDAL source not at ${SRC_DIR} — run ./build.sh ${GDAL_VERSION} first" >&2
    exit 1
fi

# Reuse the same helpers as build.sh by sourcing a fragment of it.
# (Cleaner than duplicating; keeps single source of truth.)
step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
gen_version_h() {
    local build_dir="$1"
    mkdir -p "${build_dir}"
    cmake -DSOURCE_DIR="${SRC_DIR}" -DBINARY_DIR="${build_dir}" \
          -P "${SRC_DIR}/cmake/helpers/generate_gdal_version_h.cmake"
}

# Pull build_ios_gdal + helpers in via eval. Use 'declare -f' indirectly
# by sourcing build.sh up to the orchestrator entry point. Since the
# orchestrator runs unconditionally at the bottom of build.sh, we set a
# guard env var the orchestrator doesn't know about, and instead inline
# the function body here.
#
# Simpler: redefine the needed function bodies inline here. That way we
# don't have to refactor build.sh to be source-safe.

IOS_DEP_VERSIONS=(
    "sqlite3:3.46.0" "expat:2.6.2" "libpng:1.6.43" "libjpeg:3.0.3"
    "libtiff:4.6.0" "libgeotiff:1.7.3" "proj:9.4.0" "geos:3.13.0"
)
ios_dep_prefix() {
    local sdk="$1" dep="$2" entry ver
    for entry in "${IOS_DEP_VERSIONS[@]}"; do
        if [ "${entry%%:*}" = "${dep}" ]; then
            ver="${entry##*:}"
            echo "${ROOT}/work/deps-cache/ios-${sdk}/${dep}-${ver}"
            return 0
        fi
    done
    return 1
}

sdk="${SDK}"
toolchain="${ROOT}/scripts/toolchain/ios-${sdk}.cmake"
build="${WORK}/build-ios-${sdk}"
install="${WORK}/install-ios-${sdk}"

sqlite3="$(ios_dep_prefix "${sdk}" sqlite3)"
expat="$(ios_dep_prefix "${sdk}" expat)"
libpng="$(ios_dep_prefix "${sdk}" libpng)"
libjpeg="$(ios_dep_prefix "${sdk}" libjpeg)"
libtiff="$(ios_dep_prefix "${sdk}" libtiff)"
libgeotiff="$(ios_dep_prefix "${sdk}" libgeotiff)"
proj="$(ios_dep_prefix "${sdk}" proj)"
geos="$(ios_dep_prefix "${sdk}" geos)"

driver_enable_flags=()
for d in ${IOS_ENABLED_RASTER_DRIVERS}; do
    driver_enable_flags+=("-DGDAL_ENABLE_DRIVER_${d}=ON")
done
for d in ${IOS_ENABLED_VECTOR_DRIVERS}; do
    driver_enable_flags+=("-DOGR_ENABLE_DRIVER_${d}=ON")
done

step "iOS GDAL configure (${sdk})"
rm -rf "${build}" "${install}"
rm -f "${SRC_DIR}/gcore/gdal_version.h"
gen_version_h "${build}"
cmake -S "${SRC_DIR}" -B "${build}" \
    -DCMAKE_TOOLCHAIN_FILE="${toolchain}" \
    -DCMAKE_INSTALL_PREFIX="${install}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_APPS=OFF \
    -DBUILD_TESTING=OFF \
    -DBUILD_PYTHON_BINDINGS=OFF \
    -DBUILD_JAVA_BINDINGS=OFF \
    -DBUILD_CSHARP_BINDINGS=OFF \
    -DGDAL_ENABLE_MACOSX_FRAMEWORK=OFF \
    -DGDAL_BUILD_OPTIONAL_DRIVERS=OFF \
    -DOGR_BUILD_OPTIONAL_DRIVERS=OFF \
    -DGDAL_ENABLE_PLUGINS=OFF \
    -DGDAL_ENABLE_PLUGINS_NO_DEPS=OFF \
    "${driver_enable_flags[@]}" \
    -DCMAKE_PREFIX_PATH="${proj};${geos};${libtiff};${libgeotiff};${libpng};${libjpeg};${sqlite3};${expat}" \
    -DPROJ_INCLUDE_DIR="${proj}/include" \
    -DPROJ_LIBRARY="${proj}/lib/libproj.a" \
    -DGEOS_INCLUDE_DIR="${geos}/include" \
    -DGEOS_LIBRARY="${geos}/lib/libgeos_c.a" \
    -DTIFF_INCLUDE_DIR="${libtiff}/include" \
    -DTIFF_LIBRARY="${libtiff}/lib/libtiff.a" \
    -DGEOTIFF_INCLUDE_DIR="${libgeotiff}/include" \
    -DGEOTIFF_LIBRARY="${libgeotiff}/lib/libgeotiff.a" \
    -DPNG_PNG_INCLUDE_DIR="${libpng}/include" \
    -DPNG_LIBRARY="${libpng}/lib/libpng.a" \
    -DJPEG_INCLUDE_DIR="${libjpeg}/include" \
    -DJPEG_LIBRARY="${libjpeg}/lib/libjpeg.a" \
    -DSQLite3_INCLUDE_DIR="${sqlite3}/include" \
    -DSQLite3_LIBRARY="${sqlite3}/lib/libsqlite3.a" \
    -DEXPAT_INCLUDE_DIR="${expat}/include" \
    -DEXPAT_LIBRARY="${expat}/lib/libexpat.a" \
    -DGDAL_USE_CURL=OFF \
    -DGDAL_USE_ICONV=ON \
    -DGDAL_USE_LIBXML2=ON \
    -DGDAL_USE_ZLIB=ON \
    -DGDAL_USE_TIFF_INTERNAL=OFF \
    -DGDAL_USE_GEOTIFF_INTERNAL=OFF \
    -DGDAL_USE_PNG_INTERNAL=OFF \
    -DGDAL_USE_JPEG_INTERNAL=OFF \
    -DGDAL_USE_JPEG12_INTERNAL=OFF \
    ${EXTRA_CMAKE_FLAGS}

step "iOS GDAL build + install (${sdk})"
cmake --build "${build}" -j "$(sysctl -n hw.ncpu)"
cmake --install "${build}"

echo "✔ iOS GDAL (${sdk}) installed at ${install}"
