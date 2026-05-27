#!/usr/bin/env bash
# Assemble static gdal.framework + proj.framework for one iOS slice.
#
# Usage: ./scripts/assemble-ios-framework.sh <GDAL_VERSION> <sdk>
#   <sdk> = device | simulator
#
# Inputs:
#   work/gdal-<ver>/install-ios-<sdk>/{lib,include}   (Phase 5 output)
#   work/deps-cache/ios-<sdk>/<dep>-<ver>/lib/lib*.a  (Phase 3 output)
#
# Outputs:
#   work/gdal-<ver>/framework-ios-<sdk>/
#     gdal.framework/  -> merged static archive of GDAL + sibling deps (NOT proj)
#     proj.framework/  -> standalone PROJ static archive
#
# Phase 7 (fix-cmake-static.sh) patches the CMake exports; this script
# leaves them as-shipped from the install dirs.

set -euo pipefail

GDAL_VERSION="${1:?usage: $0 <GDAL_VERSION> <device|simulator>}"
SDK="${2:?usage: $0 <GDAL_VERSION> <device|simulator>}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "${ROOT}/scripts/lib.sh"
WORK="${ROOT}/work/gdal-${GDAL_VERSION}"
INSTALL="${WORK}/install-ios-${SDK}"
DEPS_CACHE="${ROOT}/work/deps-cache/ios-${SDK}"
OUT_DIR="${WORK}/framework-ios-${SDK}"

case "${SDK}" in
    device)    PLATFORM="iPhoneOS";        SYSROOT_NAME="iphoneos" ;;
    simulator) PLATFORM="iPhoneSimulator"; SYSROOT_NAME="iphonesimulator" ;;
    *) echo "usage: $0 <ver> <device|simulator>" >&2; exit 1 ;;
esac

: "${IOS_DEPLOYMENT_TARGET:=17.0}"

# Pinned versions (mirror scripts/deps/README.md).
declare -A VERSIONS=(
    [sqlite3]=3.46.0 [expat]=2.6.2 [libpng]=1.6.43 [libjpeg]=3.0.3
    [libtiff]=4.6.0 [libgeotiff]=1.7.3 [proj]=9.4.0 [geos]=3.13.0
)
prefix_of() { echo "${DEPS_CACHE}/$1-${VERSIONS[$1]}"; }

step() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }

rm -rf "${OUT_DIR}"
mkdir -p "${OUT_DIR}"

############################################
step "gdal.framework: merge libgdal.a + sibling deps (excluding libproj.a)"
############################################
GDAL_FW="${OUT_DIR}/gdal.framework"
mkdir -p "${GDAL_FW}/Headers" "${GDAL_FW}/Modules" "${GDAL_FW}/lib/cmake/gdal"

merge_inputs=(
    "${INSTALL}/lib/libgdal.a"
    "$(prefix_of geos)/lib/libgeos.a"
    "$(prefix_of geos)/lib/libgeos_c.a"
    "$(prefix_of libtiff)/lib/libtiff.a"
    "$(prefix_of libgeotiff)/lib/libgeotiff.a"
    "$(prefix_of sqlite3)/lib/libsqlite3.a"
    "$(prefix_of expat)/lib/libexpat.a"
    "$(prefix_of libpng)/lib/libpng.a"
    "$(prefix_of libjpeg)/lib/libjpeg.a"
)
# Validate every input exists before invoking libtool.
for f in "${merge_inputs[@]}"; do
    [ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

xcrun --sdk "${SYSROOT_NAME}" libtool -static \
    -o "${GDAL_FW}/gdal" "${merge_inputs[@]}"

# Headers — iOS install lays them out flat in include/.
cp -R "${INSTALL}/include/"* "${GDAL_FW}/Headers/"

# CMake exports (Phase 7 patches these in place).
if [ -d "${INSTALL}/lib/cmake/gdal" ]; then
    cp -R "${INSTALL}/lib/cmake/gdal/"* "${GDAL_FW}/lib/cmake/gdal/"
fi

# Info.plist — flat layout, MinimumOSVersion + platform tag for the slice.
cat > "${GDAL_FW}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>gdal</string>
  <key>CFBundleIdentifier</key><string>org.osgeo.gdal</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>gdal</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${GDAL_VERSION}</string>
  <key>CFBundleVersion</key><string>${GDAL_VERSION}</string>
  <key>CFBundleSupportedPlatforms</key>
  <array><string>${PLATFORM}</string></array>
  <key>MinimumOSVersion</key><string>${IOS_DEPLOYMENT_TARGET}</string>
</dict>
</plist>
EOF
plutil -convert binary1 "${GDAL_FW}/Info.plist"

# module.modulemap — declare the framework module + explicit headers for
# the CPL/OGR APIs that gdal.h's umbrella doesn't transitively include,
# plus system-lib link directives. Shared with the macOS slice via
# scripts/lib.sh so both modulemaps stay in lockstep.
write_gdal_modulemap "${GDAL_FW}/Modules/module.modulemap"

echo "  -> ${GDAL_FW}"
ls -lh "${GDAL_FW}/gdal" | awk '{print "     gdal:", $5}'

############################################
step "proj.framework: standalone libproj.a wrap"
############################################
PROJ_FW="${OUT_DIR}/proj.framework"
PROJ_PREFIX="$(prefix_of proj)"
mkdir -p "${PROJ_FW}/Headers" "${PROJ_FW}/Modules" "${PROJ_FW}/lib/cmake/proj"

# Single-input libtool reformat — produces a framework-compatible Mach-O
# layout even though there's only one input archive.
xcrun --sdk "${SYSROOT_NAME}" libtool -static \
    -o "${PROJ_FW}/proj" "${PROJ_PREFIX}/lib/libproj.a"

# Headers — preserve any subdir structure (proj has a proj/ subdir).
cp -R "${PROJ_PREFIX}/include/"* "${PROJ_FW}/Headers/"

# CMake exports.
if [ -d "${PROJ_PREFIX}/lib/cmake/proj" ]; then
    cp -R "${PROJ_PREFIX}/lib/cmake/proj/"* "${PROJ_FW}/lib/cmake/proj/"
fi

cat > "${PROJ_FW}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>proj</string>
  <key>CFBundleIdentifier</key><string>org.osgeo.proj</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>proj</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>${VERSIONS[proj]}</string>
  <key>CFBundleVersion</key><string>${VERSIONS[proj]}</string>
  <key>CFBundleSupportedPlatforms</key>
  <array><string>${PLATFORM}</string></array>
  <key>MinimumOSVersion</key><string>${IOS_DEPLOYMENT_TARGET}</string>
</dict>
</plist>
EOF
plutil -convert binary1 "${PROJ_FW}/Info.plist"

cat > "${PROJ_FW}/Modules/module.modulemap" <<'EOF'
framework module proj {
    umbrella header "proj.h"
    export *
    module * { export * }
    link "c++"
}
EOF

echo "  -> ${PROJ_FW}"
ls -lh "${PROJ_FW}/proj" | awk '{print "     proj:", $5}'

echo
echo "✔ frameworks for iOS ${SDK} assembled at ${OUT_DIR}"
