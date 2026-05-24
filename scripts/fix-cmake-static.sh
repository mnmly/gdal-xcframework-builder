#!/usr/bin/env bash
# Patch CMake export files for a static iOS framework (gdal.framework or
# proj.framework) so that downstream consumers see the framework layout
# instead of the original install-tree layout.
#
# Usage: ./scripts/fix-cmake-static.sh <framework_dir> <package>
#   <framework_dir> = e.g. work/.../gdal.framework
#   <package>       = gdal | proj
#
# Three changes per export:
#   1. INTERFACE_INCLUDE_DIRECTORIES: `${_IMPORT_PREFIX}/include` →
#      `${_IMPORT_PREFIX}/Headers`.
#   2. INTERFACE_LINK_LIBRARIES: see per-package overrides below.
#   3. IMPORTED_LOCATION_RELEASE: `${_IMPORT_PREFIX}/lib/lib<pkg>.a` →
#      `${_IMPORT_PREFIX}/<exec>`. Same for the check-files list.
#
# The `_IMPORT_PREFIX` walk in `<pkg>-targets.cmake` (4 PATH ups) is left
# untouched: the framework layout `<fw>/lib/cmake/<pkg>/file.cmake`
# happens to be the same shape as the install layout the export was
# generated for, so 4 ups still lands on the framework root (= prefix).
#
# Per-package overrides for INTERFACE_LINK_LIBRARIES:
#   - gdal: drop everything bundled into the merged archive (GEOS,
#     SQLite, EXPAT, JPEG, TIFF, GEOTIFF, ZLIB-internal, etc.) and
#     declare only what the consumer must resolve at link time:
#     `PROJ::proj` (sibling framework) + the SDK system libs already
#     linked by the modulemap (`z`, `xml2`, `iconv`, `c++`).
#   - proj: empty link interface. `libproj.a` depends on sqlite3 +
#     tiff, both of which live inside gdal.framework's merged archive.
#     This works as long as the consumer links gdal alongside proj —
#     documented in README.md as a constraint.

set -euo pipefail

FW="${1:?usage: $0 <framework_dir> <gdal|proj>}"
PKG="${2:?usage: $0 <framework_dir> <gdal|proj>}"

case "${PKG}" in
    gdal)
        EXEC="gdal"
        ARCHIVE="libgdal.a"
        LINK_INTERFACE='PROJ::proj;z;xml2;iconv;c++'
        TARGETS_FILE="GDAL-targets.cmake"
        RELEASE_FILE="GDAL-targets-release.cmake"
        ;;
    proj)
        EXEC="proj"
        ARCHIVE="libproj.a"
        LINK_INTERFACE=''
        TARGETS_FILE="proj-targets.cmake"
        RELEASE_FILE="proj-targets-release.cmake"
        ;;
    *)
        echo "unknown package: ${PKG} (want gdal|proj)" >&2
        exit 1
        ;;
esac

CMAKE_DIR="${FW}/lib/cmake/${PKG}"
[ -d "${CMAKE_DIR}" ] || { echo "missing: ${CMAKE_DIR}" >&2; exit 1; }

T="${CMAKE_DIR}/${TARGETS_FILE}"
R="${CMAKE_DIR}/${RELEASE_FILE}"

# GDALConfig.cmake calls find_dependency(TIFF), find_dependency(EXPAT),
# etc. for every dep GDAL was originally linked against. All of those
# (except PROJ) are MERGED into gdal.framework's executable, so the
# consumer doesn't need to find_package them — and trying to would
# either fail or resolve to the wrong dylib (e.g. a Homebrew libtiff
# that's older than what GDAL was compiled against). Drop them, keep
# only PROJ.
CONFIG_FILE="${CMAKE_DIR}/GDALConfig.cmake"
if [ "${PKG}" = "gdal" ] && [ -f "${CONFIG_FILE}" ]; then
    sed -i.bak -E '/find_dependency\((Threads|Iconv|LibXml2|EXPAT|ZLIB|TIFF|GeoTIFF|PNG|JPEG|SQLite3|HDF5|GEOS|CURL)/d' \
        "${CONFIG_FILE}"
    rm -f "${CONFIG_FILE}.bak"
fi

# ----- patch <pkg>-targets.cmake -----
if [ -f "${T}" ]; then
    # INTERFACE_INCLUDE_DIRECTORIES → Headers/.
    sed -i.bak -E 's|INTERFACE_INCLUDE_DIRECTORIES "\$\{_IMPORT_PREFIX\}/include"|INTERFACE_INCLUDE_DIRECTORIES "${_IMPORT_PREFIX}/Headers"|' "${T}"

    # INTERFACE_LINK_LIBRARIES — replace whole line. Use python rather
    # than sed because the value is a long ;-list with $<LINK_ONLY:...>
    # wrappers and special chars that sed handles poorly.
    python3 - "${T}" "${LINK_INTERFACE}" <<'PYEOF'
import re, sys
path, link_iface = sys.argv[1], sys.argv[2]
with open(path) as f:
    src = f.read()
src = re.sub(
    r'INTERFACE_LINK_LIBRARIES\s+"[^"]*"',
    f'INTERFACE_LINK_LIBRARIES "{link_iface}"',
    src,
)
with open(path, 'w') as f:
    f.write(src)
PYEOF

    rm -f "${T}.bak"
fi

# ----- patch <pkg>-targets-release.cmake -----
if [ -f "${R}" ]; then
    sed -i.bak -E "s|\\\$\\{_IMPORT_PREFIX\\}/lib/${ARCHIVE}|\${_IMPORT_PREFIX}/${EXEC}|g" "${R}"
    # Drop dylib-only properties that don't apply to static archives.
    # (IMPORTED_SONAME_RELEASE, IMPORTED_LINK_DEPENDENT_LIBRARIES_RELEASE.)
    sed -i.bak2 -E '/IMPORTED_SONAME_RELEASE/d; /IMPORTED_LINK_DEPENDENT_LIBRARIES_RELEASE/d' "${R}"
    rm -f "${R}.bak" "${R}.bak2"
fi

# proj ships a `proj4-*` legacy compat target alongside the modern
# `proj-*` exports. Modern consumers use `PROJ::proj`; nothing in our
# stack references `PROJ4::proj`. Drop the legacy files so they don't
# try to resolve a (now non-existent) `lib/libproj.a` path.
if [ "${PKG}" = "proj" ]; then
    rm -f "${CMAKE_DIR}/proj4-targets.cmake" \
          "${CMAKE_DIR}/proj4-targets-release.cmake"
    # proj-config.cmake unconditionally includes any proj4-*.cmake it
    # finds; strip the include block too.
    if [ -f "${CMAKE_DIR}/proj-config.cmake" ]; then
        sed -i.bak -E '/proj4-targets/d' "${CMAKE_DIR}/proj-config.cmake"
        rm -f "${CMAKE_DIR}/proj-config.cmake.bak"
    fi
fi

echo "✔ patched ${FW}/lib/cmake/${PKG}/{${TARGETS_FILE},${RELEASE_FILE}}"
