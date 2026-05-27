#!/bin/bash
# Build gdal.xcframework (+ optionally proj.xcframework for iOS) from a tagged
# GDAL release.
#
# Usage: ./build.sh <GDAL_VERSION>             e.g. ./build.sh 3.12.4
#        BUILD_IOS=1 ./build.sh <GDAL_VERSION>  also build iOS device + sim slices
#        RELEASE=1 ./build.sh <GDAL_VERSION>    publish a gh release
#
# Architecture: the 8 build phases (clone, configure, build, framework assembly,
# bundle deps, codesign) are factored into per-slice functions:
#   build_macos_slice    -> dynamic gdal.framework with bundled Homebrew dylibs
#   build_ios_slice      -> static gdal.framework + proj.framework  [not yet wired]
# The orchestrator runs the requested slices and then a single xcframework
# assembly step at the end.
set -euo pipefail

GDAL_VERSION="${1:-}"
if [ -z "${GDAL_VERSION}" ]; then
    echo "Usage: $0 <GDAL_VERSION>" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "${ROOT}/config.sh" ]; then
    echo "Missing ${ROOT}/config.sh — copy config.sh.example and edit it." >&2
    exit 1
fi
# shellcheck disable=SC1091
source "${ROOT}/config.sh"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"

: "${OUTPUT_DIR:=${ROOT}/output}"
: "${ARCHS:=arm64}"
: "${DISABLED_OGR_DRIVERS:=XLS XLSX VFK CAD}"
: "${EXTRA_CMAKE_FLAGS:=}"
: "${DYLIBBUNDLER_SEARCH_PATHS:=/opt/homebrew/lib /opt/homebrew/opt/expat/lib}"
: "${BUILD_IOS:=0}"
: "${IOS_DEPLOYMENT_TARGET:=17.0}"
: "${IOS_ENABLED_RASTER_DRIVERS:=GTIFF VRT}"
: "${IOS_ENABLED_VECTOR_DRIVERS:=SHAPE GEOJSON SQLITE GPKG}"

# Preflight: tools and Homebrew deps that aren't auto-discovered by cmake but
# are needed at bundle time (because macOS hides their system copies inside
# the dyld shared cache).
missing=()
for cmd in cmake dylibbundler xcodebuild git; do
    command -v "$cmd" >/dev/null || missing+=("$cmd (command)")
done
[ -f /opt/homebrew/opt/expat/lib/libexpat.1.dylib ] || missing+=("expat (brew install expat)")
if [ "${#missing[@]}" -gt 0 ]; then
    echo "Missing prerequisites:" >&2
    printf '  - %s\n' "${missing[@]}" >&2
    echo "Install with:  brew install cmake boost dylibbundler expat" >&2
    exit 1
fi

# Framework Versions/<X.Y> dir derived from GDAL version (e.g. 3.12.4 -> 3.12).
FW_VERSION="$(echo "${GDAL_VERSION}" | awk -F. '{print $1"."$2}')"

WORK="${ROOT}/work/gdal-${GDAL_VERSION}"
SRC_DIR="${WORK}/src"
FW_BUILD="${WORK}/build-framework"
DYLIB_BUILD="${WORK}/build-dylib"
DYLIB_INSTALL="${DYLIB_BUILD}/install"

mkdir -p "${OUTPUT_DIR}"

cmake_arch_flag=""
for a in ${ARCHS}; do
    cmake_arch_flag="${cmake_arch_flag};${a}"
done
cmake_arch_flag="${cmake_arch_flag#;}"

driver_flags=()
for d in ${DISABLED_OGR_DRIVERS}; do
    driver_flags+=("-DOGR_ENABLE_DRIVER_${d}=OFF")
done

# Boost discovery (matches original notes). macOS-only — iOS path doesn't use it.
BOOST_PREFIX="$(brew --prefix boost)"
export BOOST_ROOT="${BOOST_PREFIX}"
export CPLUS_INCLUDE_PATH="${BOOST_PREFIX}/include:${CPLUS_INCLUDE_PATH:-}"
export LIBRARY_PATH="${BOOST_PREFIX}/lib:${LIBRARY_PATH:-}"

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

############################################
# Phase 1 (shared): fetch GDAL source once. All slices clone the same tag.
############################################
fetch_gdal_src() {
    step "1/9  Fetch GDAL ${GDAL_VERSION}"
    if [ ! -d "${SRC_DIR}/.git" ]; then
        rm -rf "${SRC_DIR}"
        git clone --depth 1 --branch "v${GDAL_VERSION}" \
            https://github.com/OSGeo/gdal.git "${SRC_DIR}"
    else
        echo "source already present at ${SRC_DIR}"
    fi
    # Defensive: a previous run may have leaked a generated gdal_version.h
    # into the source tree, which then conflicts with the per-build copy.
    rm -f "${SRC_DIR}/gcore/gdal_version.h"
}

# GDAL's CMakeLists references gcore/gdal_version.h via target_sources at
# configure time, but the generate_gdal_version_h custom target only runs at
# build time. Pre-generate it into each build dir before configuring.
gen_version_h() {
    local build_dir="$1"
    mkdir -p "${build_dir}"
    cmake -DSOURCE_DIR="${SRC_DIR}" -DBINARY_DIR="${build_dir}" \
          -P "${SRC_DIR}/cmake/helpers/generate_gdal_version_h.cmake"
}

############################################
# Slice builder: macOS arm64 dynamic framework with bundled Homebrew dylibs.
# Runs phases 2–8 of the original script. Leaves the assembled framework at
# ${FW_BUILD}/gdal.framework; orchestrator picks it up in phase 9.
############################################
build_macos_slice() {
    local common_cmake_flags=(
        -DBUILD_SHARED_LIBS=ON
        -DBUILD_APPS=OFF
        -DBUILD_TESTING=OFF
        -DBUILD_PYTHON_BINDINGS=OFF
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_OSX_ARCHITECTURES="${cmake_arch_flag}"
        -DCMAKE_CXX_FLAGS="-I/opt/homebrew/include"
        "${driver_flags[@]}"
    )

    ############################################
    step "2/9  [macOS] Configure + build framework variant"
    ############################################
    rm -rf "${FW_BUILD}"
    gen_version_h "${FW_BUILD}"
    cmake -S "${SRC_DIR}" -B "${FW_BUILD}" \
        "${common_cmake_flags[@]}" \
        -DGDAL_ENABLE_MACOSX_FRAMEWORK=ON \
        ${EXTRA_CMAKE_FLAGS}
    cmake --build "${FW_BUILD}" -j "$(sysctl -n hw.ncpu)"

    ############################################
    step "3/9  [macOS] Configure + build dylib variant (for cmake exports)"
    ############################################
    rm -rf "${DYLIB_BUILD}"
    gen_version_h "${DYLIB_BUILD}"
    cmake -S "${SRC_DIR}" -B "${DYLIB_BUILD}" \
        "${common_cmake_flags[@]}" \
        -DGDAL_ENABLE_MACOSX_FRAMEWORK=OFF \
        -DCMAKE_INSTALL_PREFIX="${DYLIB_INSTALL}" \
        ${EXTRA_CMAKE_FLAGS}
    cmake --build "${DYLIB_BUILD}" -j "$(sysctl -n hw.ncpu)"
    cmake --install "${DYLIB_BUILD}"

    ############################################
    step "4/9  [macOS] Patch CMake export files into framework"
    ############################################
    "${ROOT}/scripts/fix-cmake.sh" \
        "${FW_BUILD}/gdal.framework" \
        "${DYLIB_INSTALL}/lib/cmake/gdal" \
        "${FW_VERSION}"

    ############################################
    step "5/9  [macOS] Rename Versions/${FW_VERSION} -> Versions/A and fix install name"
    ############################################
    cd "${FW_BUILD}"
    local FW="gdal.framework"
    if [ -d "${FW}/Versions/${FW_VERSION}" ]; then
        mv "${FW}/Versions/${FW_VERSION}" "${FW}/Versions/A"
    fi
    install_name_tool -id "@rpath/gdal.framework/Versions/A/gdal" "${FW}/Versions/A/gdal"

    rm -rf "${FW}/Versions/A/Libraries"
    rm -rf "${FW}/Versions/Current"
    mkdir -p "${FW}/Versions/A/Libraries"
    ( cd "${FW}/Versions" && ln -sf A Current )

    # Upstream license — GDAL is MIT/X11; binary redistribution must carry
    # the notice. Ship it inside the framework's Resources/.
    mkdir -p "${FW}/Versions/A/Resources"
    local LICENSE_SRC
    LICENSE_SRC="$(find "${SRC_DIR}" -maxdepth 1 -type f -iname 'license*' | head -1)"
    if [ -n "${LICENSE_SRC}" ]; then
        cp "${LICENSE_SRC}" "${FW}/Versions/A/Resources/LICENSE.txt"
    else
        echo "warning: no LICENSE file found in ${SRC_DIR}" >&2
    fi

    ############################################
    step "5b/9 [macOS] Emit module.modulemap"
    ############################################
    # CMake's GDAL_ENABLE_MACOSX_FRAMEWORK doesn't write a modulemap, so
    # Swift consumers can't `import gdal` against the framework as-shipped.
    # Emit one with explicit headers for the CPL/OGR APIs that gdal.h's
    # umbrella omits. Phase 8 codesign re-seals the bundle and covers it.
    write_gdal_modulemap "${FW}/Versions/A/Modules/module.modulemap"
    ( cd "${FW}" && ln -sfn Versions/Current/Modules Modules )

    ############################################
    step "6/9  [macOS] Bundle dylib dependencies"
    ############################################
    # dylibbundler is macOS-only by design (rewrites Mach-O install_names).
    # The iOS path uses static archives instead and must NOT reach here.
    local search_flags=()
    for p in ${DYLIBBUNDLER_SEARCH_PATHS}; do
        [ -d "$p" ] && search_flags+=("-s" "$p")
    done
    dylibbundler -od -b -x "./${FW}/Versions/A/gdal" \
        -d "./${FW}/Versions/A/Libraries/" \
        -p "@loader_path/Libraries/" \
        "${search_flags[@]}"

    # Dual-sqlite avoidance. gdal links to /usr/lib/libsqlite3.dylib (system),
    # but libspatialite (and potentially other bundled deps) pull in
    # Homebrew's libsqlite3 via dylibbundler. Two sqlite copies = two distinct
    # global hash tables; an sqlite3* opened in one and passed to the other
    # crashes on the next sqlite3_create_function_v2() call inside
    # InitSpatialite during GPKG dataset create. Retarget any bundled
    # libsqlite3 references back to the system one, then remove the duplicate.
    local fw_libs_dir="./${FW}/Versions/A/Libraries"
    local bundled_sqlite
    bundled_sqlite=$(ls "${fw_libs_dir}"/libsqlite3*.dylib 2>/dev/null || true)
    if [ -n "${bundled_sqlite}" ]; then
        for lib in "${fw_libs_dir}"/*.dylib; do
            otool -L "$lib" | awk '/libsqlite3[.0-9]*\.dylib/{print $1}' | while read -r dep; do
                case "$dep" in
                    /usr/lib/*) ;;
                    *)
                        install_name_tool -change "$dep" \
                            "/usr/lib/libsqlite3.dylib" "$lib" 2>/dev/null || true
                        ;;
                esac
            done
        done
        rm -f "${fw_libs_dir}"/libsqlite3*.dylib
    fi

    ############################################
    step "7/9  [macOS] Normalise rpaths inside bundled dylibs"
    ############################################
    for lib in "./${FW}/Versions/A/Libraries/"*.dylib; do
        local count
        count=$(otool -l "$lib" | grep -c "cmd LC_RPATH" || true)
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        while [ "$count" -gt 1 ]; do
            install_name_tool -delete_rpath @loader_path/Libraries/ "$lib" 2>/dev/null || break
            count=$(otool -l "$lib" | grep -c "cmd LC_RPATH" || true)
            [[ "$count" =~ ^[0-9]+$ ]] || count=0
        done
        if [ "$count" -eq 0 ]; then
            install_name_tool -add_rpath @loader_path "$lib" 2>/dev/null || true
        fi
        otool -L "$lib" | awk '/@loader_path\/Libraries\//{print $1}' | while read -r dep; do
            local libname
            libname="$(basename "$dep")"
            install_name_tool -change "$dep" "@loader_path/$libname" "$lib" 2>/dev/null || true
        done
    done

    ( cd "${FW}" && ln -sfn Versions/Current/Libraries Libraries )

    ############################################
    step "8/9  [macOS] Codesign framework (optional)"
    ############################################
    local SIGN_ID="${CODESIGN_IDENTITY:--}"
    echo "signing inside-out with identity: ${SIGN_ID}"
    # Sign every nested Mach-O first, then seal the bundle. macOS 26
    # rejects pages whose nested-library signatures don't match the
    # outer bundle's resource hashes.
    find "${FW}/Versions/A" -type f \( -name "*.dylib" -o -name "gdal" \) \
        -exec codesign --force --sign "${SIGN_ID}" --timestamp=none {} \;
    codesign --force --sign "${SIGN_ID}" --timestamp=none --deep "${FW}"

    cd "${ROOT}"
}

############################################
# iOS pipeline.
#
# build_ios_deps <sdk>      -> cross-compile sqlite3..libgeotiff into deps-cache
# build_ios_gdal <sdk>      -> configure + build GDAL static, install into work/install-ios-<sdk>
# assemble_ios_framework... -> phase 6, separate function below
############################################

# Pinned versions — mirror scripts/deps/README.md and scripts/build-deps.sh.
IOS_DEP_VERSIONS=(
    "sqlite3:3.46.0"
    "expat:2.6.2"
    "libpng:1.6.43"
    "libjpeg:3.0.3"
    "libtiff:4.6.0"
    "libgeotiff:1.7.3"
    "proj:9.4.0"
    "geos:3.13.0"
)

ios_dep_prefix() {
    # Usage: ios_dep_prefix <sdk> <dep>
    local sdk="$1" dep="$2" entry ver
    for entry in "${IOS_DEP_VERSIONS[@]}"; do
        if [ "${entry%%:*}" = "${dep}" ]; then
            ver="${entry##*:}"
            echo "${ROOT}/work/deps-cache/ios-${sdk}/${dep}-${ver}"
            return 0
        fi
    done
    echo "internal error: unknown dep '${dep}'" >&2
    return 1
}

build_ios_deps() {
    local sdk="$1"
    step "iOS deps (${sdk})"
    "${ROOT}/scripts/build-deps.sh" "${sdk}"
}

build_ios_gdal() {
    local sdk="$1"
    local toolchain="${ROOT}/scripts/toolchain/ios-${sdk}.cmake"
    local build="${WORK}/build-ios-${sdk}"
    local install="${WORK}/install-ios-${sdk}"

    local sqlite3 expat libpng libjpeg libtiff libgeotiff proj geos
    sqlite3="$(ios_dep_prefix "${sdk}" sqlite3)"
    expat="$(ios_dep_prefix "${sdk}" expat)"
    libpng="$(ios_dep_prefix "${sdk}" libpng)"
    libjpeg="$(ios_dep_prefix "${sdk}" libjpeg)"
    libtiff="$(ios_dep_prefix "${sdk}" libtiff)"
    libgeotiff="$(ios_dep_prefix "${sdk}" libgeotiff)"
    proj="$(ios_dep_prefix "${sdk}" proj)"
    geos="$(ios_dep_prefix "${sdk}" geos)"

    # Driver enables → cmake flags.
    local driver_enable_flags=()
    for d in ${IOS_ENABLED_RASTER_DRIVERS}; do
        driver_enable_flags+=("-DGDAL_ENABLE_DRIVER_${d}=ON")
    done
    for d in ${IOS_ENABLED_VECTOR_DRIVERS}; do
        driver_enable_flags+=("-DOGR_ENABLE_DRIVER_${d}=ON")
    done

    step "iOS GDAL configure (${sdk})"
    rm -rf "${build}" "${install}"
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
}

assemble_ios_framework() {
    local sdk="$1"
    step "iOS framework assembly (${sdk})"
    "${ROOT}/scripts/assemble-ios-framework.sh" "${GDAL_VERSION}" "${sdk}"
    "${ROOT}/scripts/fix-cmake-static.sh" \
        "${WORK}/framework-ios-${sdk}/gdal.framework" gdal
    "${ROOT}/scripts/fix-cmake-static.sh" \
        "${WORK}/framework-ios-${sdk}/proj.framework" proj
}

build_ios_slices() {
    # Build deps + GDAL for both iOS variants, then assemble + patch
    # each slice's gdal.framework + proj.framework. Phase 9 (xcframework
    # wrap, in the orchestrator below) consumes what we produce here.
    for sdk in device simulator; do
        build_ios_deps "${sdk}"
        build_ios_gdal "${sdk}"
        assemble_ios_framework "${sdk}"
    done
}

############################################
# Phase 9: orchestrator — fetch source, build requested slices, wrap into
# xcframework(s), zip, optional gh release.
############################################
fetch_gdal_src
build_macos_slice

if [ "${BUILD_IOS}" = "1" ]; then
    build_ios_slices
fi

############################################
step "9/9  Wrap in xcframework + zip"
############################################

# gdal.xcframework: macOS + (optionally) iOS device + iOS simulator.
GDAL_XC_OUT="${OUTPUT_DIR}/gdal.xcframework"
rm -rf "${GDAL_XC_OUT}"
gdal_xc_inputs=(-framework "${FW_BUILD}/gdal.framework")
if [ "${BUILD_IOS}" = "1" ]; then
    gdal_xc_inputs+=(-framework "${WORK}/framework-ios-device/gdal.framework")
    gdal_xc_inputs+=(-framework "${WORK}/framework-ios-simulator/gdal.framework")
fi
xcodebuild -create-xcframework "${gdal_xc_inputs[@]}" -output "${GDAL_XC_OUT}"

# proj.xcframework: iOS-only (device + simulator). macOS PDAL build keeps
# using Homebrew PROJ, per tasks/todo.md §3 decision.
PROJ_XC_OUT="${OUTPUT_DIR}/proj.xcframework"
if [ "${BUILD_IOS}" = "1" ]; then
    rm -rf "${PROJ_XC_OUT}"
    xcodebuild -create-xcframework \
        -framework "${WORK}/framework-ios-device/proj.framework" \
        -framework "${WORK}/framework-ios-simulator/proj.framework" \
        -output "${PROJ_XC_OUT}"
fi

if [ -n "${SWIFT_PACKAGE_FRAMEWORKS_DIR:-}" ]; then
    mkdir -p "${SWIFT_PACKAGE_FRAMEWORKS_DIR}"
    rm -rf "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/gdal.xcframework"
    cp -R "${GDAL_XC_OUT}" "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/"
    echo "copied to ${SWIFT_PACKAGE_FRAMEWORKS_DIR}/gdal.xcframework"
    if [ "${BUILD_IOS}" = "1" ] && [ -d "${PROJ_XC_OUT}" ]; then
        rm -rf "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/proj.xcframework"
        cp -R "${PROJ_XC_OUT}" "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/"
        echo "copied to ${SWIFT_PACKAGE_FRAMEWORKS_DIR}/proj.xcframework"
    fi
fi

zip_and_checksum() {
    local name="$1"
    local zip="${name}.xcframework.zip"
    ( cd "${OUTPUT_DIR}" && rm -f "${zip}" \
        && ditto -c -k --sequesterRsrc --keepParent "${name}.xcframework" "${zip}" )
    local sum=""
    if command -v swift >/dev/null 2>&1; then
        sum="$(cd "${OUTPUT_DIR}" && swift package compute-checksum "${zip}")"
    fi
    printf "      %-22s %s\n" "${zip}:" "${OUTPUT_DIR}/${zip}"
    [ -n "${sum}" ] && printf "      %-22s %s\n" "${name} checksum:" "${sum}"
}

printf "\n\033[1;32mDONE\033[0m\n"
printf "      gdal:                  %s\n" "${GDAL_XC_OUT}"
zip_and_checksum gdal
if [ "${BUILD_IOS}" = "1" ]; then
    printf "      proj:                  %s\n" "${PROJ_XC_OUT}"
    zip_and_checksum proj
fi

if [ "${RELEASE:-0}" = "1" ]; then
    if [ -z "${GH_RELEASE_REPO:-}" ]; then
        echo "RELEASE=1 set but GH_RELEASE_REPO is empty in config.sh — skipping gh release" >&2
        exit 0
    fi
    TAG="gdal-v${GDAL_VERSION}"
    step "Publishing gh release ${TAG} to ${GH_RELEASE_REPO}"
    release_assets=("${OUTPUT_DIR}/gdal.xcframework.zip")
    [ "${BUILD_IOS}" = "1" ] && [ -f "${OUTPUT_DIR}/proj.xcframework.zip" ] \
        && release_assets+=("${OUTPUT_DIR}/proj.xcframework.zip")
    gh release create "${TAG}" "${release_assets[@]}" \
        --repo "${GH_RELEASE_REPO}" \
        --title "GDAL v${GDAL_VERSION} Framework" \
        --notes "Binary framework for GDAL v${GDAL_VERSION}"
fi
