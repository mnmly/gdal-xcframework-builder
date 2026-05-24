#!/usr/bin/env bash
# Compare two gdal.framework directories on the surface that downstream
# consumers depend on: install_name, rpaths, exported symbols, dependency
# list of the main binary, and the set + per-dylib dep list of bundled
# Libraries/. Cosmetic differences (timestamps, code-signature blobs,
# install-prefix paths) are normalized out.
#
# Usage:   scripts/diff-frameworks.sh <baseline.framework> <candidate.framework>
# Exit:    0 = no substantive diff; 1 = differences detected; 2 = bad args.

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <baseline.framework> <candidate.framework>" >&2
    exit 2
fi

A="$1"
B="$2"

for d in "$A" "$B"; do
    if [ ! -d "$d" ]; then
        echo "error: not a directory: $d" >&2
        exit 2
    fi
done

TMP="$(mktemp -d -t diff-frameworks.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Normalize otool / nm output: strip leading address columns, library paths
# prefixes that legitimately vary (uuid, current/compat versions), and
# trailing whitespace. Keeps the structural shape.
norm() {
    sed -E \
        -e 's/\(offset [0-9]+\)//g' \
        -e 's/0x[0-9a-fA-F]+/0xADDR/g' \
        -e 's/[0-9]+\.[0-9]+\.[0-9]+/X.Y.Z/g' \
        -e 's/[[:space:]]+$//' \
        -e '/uuid /d' \
        -e '/cryptid/d' \
        -e '/dataoff/d' \
        -e '/datasize/d' \
        -e '/^Load command/d' \
        -e '/code signature/Id'
}

capture() {
    local fw="$1"
    local out="$2"
    mkdir -p "$out/per-dylib"

    local bin="$fw/Versions/A/gdal"
    if [ ! -f "$bin" ]; then
        echo "error: missing main binary $bin" >&2
        exit 2
    fi
    # `otool` prefixes a "path:" header line that legitimately differs
    # between baseline and candidate — drop it with `tail -n +2`.
    otool -L "$bin" | tail -n +2 | norm > "$out/gdal.deps"
    otool -l "$bin" | tail -n +2 | norm > "$out/gdal.loadcmds"
    nm -gU "$bin" 2>/dev/null | awk '{print $NF}' | LC_ALL=C sort -u > "$out/gdal.symbols"

    local libdir="$fw/Versions/A/Libraries"
    if [ -d "$libdir" ]; then
        ( cd "$libdir" && ls -1 *.dylib 2>/dev/null | LC_ALL=C sort ) > "$out/libraries.set"
        local dylib
        for dylib in "$libdir"/*.dylib; do
            [ -f "$dylib" ] || continue
            local base
            base="$(basename "$dylib" .dylib)"
            otool -L "$dylib" | tail -n +2 | norm > "$out/per-dylib/${base}.deps"
        done
    else
        : > "$out/libraries.set"
    fi
}

capture "$A" "$TMP/a"
capture "$B" "$TMP/b"

rc=0
if ! diff -ruN "$TMP/a" "$TMP/b" > "$TMP/diff.out"; then
    rc=1
    echo "==> SUBSTANTIVE DIFFERENCES between"
    echo "    A: $A"
    echo "    B: $B"
    echo
    cat "$TMP/diff.out"
else
    echo "==> no substantive differences"
fi

exit "$rc"
