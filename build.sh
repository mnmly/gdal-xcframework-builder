#!/bin/bash
# Build a signed gdal.xcframework for macOS from a tagged GDAL release.
#
# Usage: ./build.sh <GDAL_VERSION>            e.g. ./build.sh 3.12.4
#        RELEASE=1 ./build.sh <GDAL_VERSION>  also publish a gh release
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

: "${OUTPUT_DIR:=${ROOT}/output}"
: "${ARCHS:=arm64}"
: "${DISABLED_OGR_DRIVERS:=XLS XLSX VFK CAD}"
: "${EXTRA_CMAKE_FLAGS:=}"
: "${DYLIBBUNDLER_SEARCH_PATHS:=/opt/homebrew/lib /opt/homebrew/opt/expat/lib}"

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

# Boost discovery (matches original notes)
BOOST_PREFIX="$(brew --prefix boost)"
export BOOST_ROOT="${BOOST_PREFIX}"
export CPLUS_INCLUDE_PATH="${BOOST_PREFIX}/include:${CPLUS_INCLUDE_PATH:-}"
export LIBRARY_PATH="${BOOST_PREFIX}/lib:${LIBRARY_PATH:-}"

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

############################################
step "1/9  Fetch GDAL ${GDAL_VERSION}"
############################################
if [ ! -d "${SRC_DIR}/.git" ]; then
    rm -rf "${SRC_DIR}"
    git clone --depth 1 --branch "v${GDAL_VERSION}" \
        https://github.com/OSGeo/gdal.git "${SRC_DIR}"
else
    echo "source already present at ${SRC_DIR}"
fi

# A previous version of this script accidentally generated gdal_version.h into
# the source tree, which then conflicts with the per-build copy. Clean it up.
rm -f "${SRC_DIR}/gcore/gdal_version.h"

common_cmake_flags=(
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
# GDAL's CMakeLists references gcore/gdal_version.h via target_sources at
# configure time, but the generate_gdal_version_h custom target only runs at
# build time. Pre-generate it into each build dir before configuring.
gen_version_h() {
    local build_dir="$1"
    mkdir -p "${build_dir}"
    cmake -DSOURCE_DIR="${SRC_DIR}" -DBINARY_DIR="${build_dir}" \
          -P "${SRC_DIR}/cmake/helpers/generate_gdal_version_h.cmake"
}

step "2/9  Configure + build framework variant"
############################################
rm -rf "${FW_BUILD}"
gen_version_h "${FW_BUILD}"
cmake -S "${SRC_DIR}" -B "${FW_BUILD}" \
    "${common_cmake_flags[@]}" \
    -DGDAL_ENABLE_MACOSX_FRAMEWORK=ON \
    ${EXTRA_CMAKE_FLAGS}
cmake --build "${FW_BUILD}" -j "$(sysctl -n hw.ncpu)"

############################################
step "3/9  Configure + build dylib variant (for cmake exports)"
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
step "4/9  Patch CMake export files into framework"
############################################
"${ROOT}/scripts/fix-cmake.sh" \
    "${FW_BUILD}/gdal.framework" \
    "${DYLIB_INSTALL}/lib/cmake/gdal" \
    "${FW_VERSION}"

############################################
step "5/9  Rename Versions/${FW_VERSION} -> Versions/A and fix install name"
############################################
cd "${FW_BUILD}"
FW="gdal.framework"
if [ -d "${FW}/Versions/${FW_VERSION}" ]; then
    mv "${FW}/Versions/${FW_VERSION}" "${FW}/Versions/A"
fi
install_name_tool -id "@rpath/gdal.framework/Versions/A/gdal" "${FW}/Versions/A/gdal"

rm -rf "${FW}/Versions/A/Libraries"
rm -rf "${FW}/Versions/Current"
mkdir -p "${FW}/Versions/A/Libraries"
( cd "${FW}/Versions" && ln -sf A Current )

############################################
step "6/9  Bundle dylib dependencies"
############################################
search_flags=()
for p in ${DYLIBBUNDLER_SEARCH_PATHS}; do
    [ -d "$p" ] && search_flags+=("-s" "$p")
done
dylibbundler -od -b -x "./${FW}/Versions/A/gdal" \
    -d "./${FW}/Versions/A/Libraries/" \
    -p "@loader_path/Libraries/" \
    "${search_flags[@]}"

############################################
step "7/9  Normalise rpaths inside bundled dylibs"
############################################
for lib in "./${FW}/Versions/A/Libraries/"*.dylib; do
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
        libname="$(basename "$dep")"
        install_name_tool -change "$dep" "@loader_path/$libname" "$lib" 2>/dev/null || true
    done
done

( cd "${FW}" && ln -sfn Versions/Current/Libraries Libraries )

############################################
step "8/9  Codesign framework (optional)"
############################################
SIGN_ID="${CODESIGN_IDENTITY:--}"
echo "signing inside-out with identity: ${SIGN_ID}"
# Sign every nested Mach-O first, then seal the bundle. macOS 26
# rejects pages whose nested-library signatures don't match the
# outer bundle's resource hashes.
find "${FW}/Versions/A" -type f \( -name "*.dylib" -o -name "gdal" \) \
    -exec codesign --force --sign "${SIGN_ID}" --timestamp=none {} \;
codesign --force --sign "${SIGN_ID}" --timestamp=none --deep "${FW}"

############################################
step "9/9  Wrap in xcframework + zip"
############################################
XC_OUT="${OUTPUT_DIR}/gdal.xcframework"
rm -rf "${XC_OUT}"
xcodebuild -create-xcframework -framework "${FW_BUILD}/${FW}" -output "${XC_OUT}"

if [ -n "${SWIFT_PACKAGE_FRAMEWORKS_DIR:-}" ]; then
    mkdir -p "${SWIFT_PACKAGE_FRAMEWORKS_DIR}"
    rm -rf "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/gdal.xcframework"
    cp -R "${XC_OUT}" "${SWIFT_PACKAGE_FRAMEWORKS_DIR}/"
    echo "copied to ${SWIFT_PACKAGE_FRAMEWORKS_DIR}/gdal.xcframework"
fi

cd "${OUTPUT_DIR}"
ZIP="gdal.xcframework.zip"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent gdal.xcframework "${ZIP}"

CHECKSUM=""
if command -v swift >/dev/null 2>&1; then
    CHECKSUM="$(swift package compute-checksum "${ZIP}")"
fi

printf "\n\033[1;32mDONE\033[0m  %s\n" "${XC_OUT}"
printf "      zip: %s\n" "${OUTPUT_DIR}/${ZIP}"
[ -n "${CHECKSUM}" ] && printf "      swift checksum: %s\n" "${CHECKSUM}"

if [ "${RELEASE:-0}" = "1" ]; then
    if [ -z "${GH_RELEASE_REPO:-}" ]; then
        echo "RELEASE=1 set but GH_RELEASE_REPO is empty in config.sh — skipping gh release" >&2
        exit 0
    fi
    TAG="gdal-v${GDAL_VERSION}"
    step "Publishing gh release ${TAG} to ${GH_RELEASE_REPO}"
    gh release create "${TAG}" "${OUTPUT_DIR}/${ZIP}" \
        --repo "${GH_RELEASE_REPO}" \
        --title "GDAL v${GDAL_VERSION} Framework" \
        --notes "Binary framework for GDAL v${GDAL_VERSION}"
fi
