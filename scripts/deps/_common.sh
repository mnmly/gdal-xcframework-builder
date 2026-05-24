# Shared helpers for scripts/deps/<dep>.sh — sourced, not executed.
#
# Each per-dep script does:
#   . "$(dirname "$0")/_common.sh"
#   dep_common_setup "$@"        # validates args, sets SDK/PREFIX/TOOLCHAIN/etc.
#   dep_already_built libfoo.a && exit 0
#   dep_fetch_git URL TAG SRC_DIR        # or dep_fetch_tarball URL SRC_DIR
#   dep_cmake_build SRC_DIR BUILD_DIR -DEXTRA_FLAG=...
#   dep_validate "${PREFIX}/lib/libfoo.a"
#
# All variables this helper sets are uppercase and prefixed with intent:
# SDK, PREFIX, ROOT, SRC_BASE, TOOLCHAIN, SYSROOT_NAME.

# shellcheck shell=bash
set -euo pipefail

dep_common_setup() {
    SDK="${1:-}"
    PREFIX="${2:-}"
    if [ "${SDK}" != "device" ] && [ "${SDK}" != "simulator" ]; then
        echo "usage: $(basename "$0") <device|simulator> <install_prefix>" >&2
        exit 1
    fi
    if [ -z "${PREFIX}" ]; then
        echo "usage: $(basename "$0") <device|simulator> <install_prefix>" >&2
        exit 1
    fi

    ROOT="$(cd "$(dirname "${BASH_SOURCE[1]}")/../.." && pwd)"
    SRC_BASE="${ROOT}/work/src-deps"
    mkdir -p "${SRC_BASE}"
    mkdir -p "$(dirname "${PREFIX}")"

    case "${SDK}" in
        device)    SYSROOT_NAME="iphoneos"
                   TOOLCHAIN="${ROOT}/scripts/toolchain/ios-device.cmake" ;;
        simulator) SYSROOT_NAME="iphonesimulator"
                   TOOLCHAIN="${ROOT}/scripts/toolchain/ios-simulator.cmake" ;;
    esac

    : "${IOS_DEPLOYMENT_TARGET:=17.0}"
}

dep_already_built() {
    local libname="$1"
    if [ -f "${PREFIX}/lib/${libname}" ]; then
        echo "✔ ${libname} already at ${PREFIX} — skipping"
        return 0
    fi
    return 1
}

dep_fetch_git() {
    local url="$1" tag="$2" dir="$3"
    if [ ! -d "${dir}/.git" ]; then
        rm -rf "${dir}"
        git clone --depth 1 --branch "${tag}" "${url}" "${dir}"
    fi
}

dep_fetch_tarball() {
    # Usage: dep_fetch_tarball <url> <dir> [strip_components=1]
    local url="$1" dir="$2" strip="${3:-1}"
    if [ ! -d "${dir}" ] || [ -z "$(ls -A "${dir}" 2>/dev/null)" ]; then
        rm -rf "${dir}"
        mkdir -p "${dir}"
        curl -L --fail -o "${dir}.tar.gz" "${url}"
        tar -xzf "${dir}.tar.gz" -C "${dir}" --strip-components="${strip}"
        rm -f "${dir}.tar.gz"
    fi
}

dep_cmake_build() {
    # Usage: dep_cmake_build <src_dir> <build_dir> [extra cmake flags...]
    local src="$1" build="$2"
    shift 2
    rm -rf "${build}"
    cmake -S "${src}" -B "${build}" \
        -DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET}" \
        "$@"
    cmake --build "${build}" -j "$(sysctl -n hw.ncpu)"
    cmake --install "${build}"
}

dep_validate() {
    # Confirm the produced static archive is arm64 and tagged with the
    # right iOS platform. Fails the build loudly if either is off — we
    # would rather catch a stray host-arch build now than at link time.
    local lib="$1"
    if [ ! -f "${lib}" ]; then
        echo "✗ missing: ${lib}" >&2
        exit 1
    fi

    local arch_info
    arch_info=$(lipo -info "${lib}" 2>&1 || true)
    case "${arch_info}" in
        *arm64*) ;;
        *) echo "✗ ${lib}: lipo reports non-arm64: ${arch_info}" >&2; exit 1 ;;
    esac

    # Extract one .o member and check its LC_BUILD_VERSION platform.
    local tmp
    tmp="$(mktemp -d)"
    ( cd "${tmp}" && ar -x "${lib}" 2>/dev/null ) || true
    local member
    member="$(find "${tmp}" -name '*.o' | head -1)"
    if [ -n "${member}" ]; then
        local build_info
        build_info=$(vtool -show-build "${member}" 2>&1 || true)
        local expect
        case "${SDK}" in
            device)    expect="IOS" ;;
            simulator) expect="IOSSIMULATOR" ;;
        esac
        if ! echo "${build_info}" | grep -qE "platform[[:space:]]+${expect}\b"; then
            echo "✗ ${lib}: vtool platform mismatch (want ${expect})" >&2
            echo "${build_info}" >&2
            rm -rf "${tmp}"
            exit 1
        fi
    fi
    rm -rf "${tmp}"

    echo "✔ $(basename "${lib}"): arm64 / ${SDK} OK"
}
