#!/usr/bin/env bash
# Orchestrate the iOS dep cross-compile for one SDK variant.
#
# Usage: ./scripts/build-deps.sh <sdk>
#   <sdk> = device | simulator
#
# Iterates the per-dep scripts in dependency order, pointing each at
# work/deps-cache/ios-<sdk>/<dep>-<version>/. Each script is idempotent —
# skipping a dep that's already built is the common path.
#
# Cross-dep refs (proj needs sqlite3 + tiff, libgeotiff needs proj +
# tiff + jpeg) are passed via *_PREFIX_FOR_* env vars rather than a
# global CMAKE_PREFIX_PATH, so each consumer is explicit about what it
# pulls in.

set -euo pipefail

SDK="${1:-}"
if [ "${SDK}" != "device" ] && [ "${SDK}" != "simulator" ]; then
    echo "usage: $0 <device|simulator>" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS_DIR="${ROOT}/scripts/deps"
CACHE_BASE="${ROOT}/work/deps-cache/ios-${SDK}"
mkdir -p "${CACHE_BASE}"

# Pinned versions (mirror scripts/deps/README.md — keep in sync).
declare -A VERSIONS=(
    [sqlite3]=3.46.0
    [expat]=2.6.2
    [libpng]=1.6.43
    [libjpeg]=3.0.3
    [libtiff]=4.6.0
    [libgeotiff]=1.7.3
    [proj]=9.4.0
    [geos]=3.13.0
)

prefix_of() { echo "${CACHE_BASE}/$1-${VERSIONS[$1]}"; }

# Build order: leaves first, then deps that pull from earlier ones.
ORDER=(sqlite3 expat libpng libjpeg libtiff geos proj libgeotiff)

for dep in "${ORDER[@]}"; do
    ver="${VERSIONS[$dep]}"
    prefix="$(prefix_of "$dep")"
    printf "\n==> %s %s (sdk=%s)\n" "${dep}" "${ver}" "${SDK}"

    # Cross-dep env vars consumed by individual scripts.
    case "$dep" in
        proj)
            SQLITE_PREFIX_FOR_PROJ="$(prefix_of sqlite3)" \
            TIFF_PREFIX_FOR_PROJ="$(prefix_of libtiff)" \
            "${DEPS_DIR}/${dep}.sh" "${SDK}" "${prefix}"
            ;;
        libgeotiff)
            PROJ_PREFIX_FOR_LIBGEOTIFF="$(prefix_of proj)" \
            TIFF_PREFIX_FOR_LIBGEOTIFF="$(prefix_of libtiff)" \
            JPEG_PREFIX_FOR_LIBGEOTIFF="$(prefix_of libjpeg)" \
            "${DEPS_DIR}/${dep}.sh" "${SDK}" "${prefix}"
            ;;
        *)
            "${DEPS_DIR}/${dep}.sh" "${SDK}" "${prefix}"
            ;;
    esac
done

echo
echo "all deps built (or already cached) at: ${CACHE_BASE}"
