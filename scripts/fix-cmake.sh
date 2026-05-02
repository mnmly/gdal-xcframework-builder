#!/bin/bash
# Patches GDAL's installed CMake export files so consumers (e.g. PDAL) can
# link against the framework layout rather than the dylib layout.
#
# Args:
#   $1  FRAMEWORK_DIR   absolute path to gdal.framework (still using Versions/X.Y, pre-rename)
#   $2  DYLIB_CMAKE_DIR absolute path to dylib install's lib/cmake/gdal
#   $3  FW_VERSION      framework version dir name, e.g. "3.12"
set -euo pipefail

FRAMEWORK="$1"
SRC="$2"
FW_VERSION="$3"
DEST="${FRAMEWORK}/Versions/${FW_VERSION}/lib/cmake/gdal"

if [ ! -d "${FRAMEWORK}" ]; then
    echo "fix-cmake: framework not found at ${FRAMEWORK}" >&2
    exit 1
fi
if [ ! -d "${SRC}" ]; then
    echo "fix-cmake: dylib cmake dir not found at ${SRC}" >&2
    exit 1
fi

mkdir -p "${DEST}"
cp "${SRC}"/*.cmake "${DEST}/"

sed -i.bak \
    -e 's|IMPORTED_LOCATION_RELEASE "\${_IMPORT_PREFIX}/lib/libgdal\.[^"]*"|IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/gdal"|g' \
    -e "s|IMPORTED_SONAME_RELEASE \"@rpath/libgdal\\.[^\"]*\"|IMPORTED_SONAME_RELEASE \"@rpath/gdal.framework/Versions/${FW_VERSION}/gdal\"|g" \
    -e '/IMPORTED_LINK_DEPENDENT_LIBRARIES_RELEASE/d' \
    -e 's|"\${_IMPORT_PREFIX}/lib/libgdal\.[^"]*"|"${_IMPORT_PREFIX}/gdal"|g' \
    "${DEST}/GDAL-targets-release.cmake"

sed -i.bak \
    -e 's|INTERFACE_INCLUDE_DIRECTORIES "\${_IMPORT_PREFIX}/include"|INTERFACE_INCLUDE_DIRECTORIES "${_IMPORT_PREFIX}/Headers"|g' \
    "${DEST}/GDAL-targets.cmake"

rm -f "${DEST}"/*.cmake.bak

mkdir -p "${FRAMEWORK}/Versions/Current"
ln -sf "../${FW_VERSION}/lib" "${FRAMEWORK}/Versions/Current/lib"

echo "fix-cmake: patched ${DEST}"
