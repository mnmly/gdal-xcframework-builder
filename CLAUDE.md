# CLAUDE.md — gdal-xcframework-builder

## Purpose

Standalone tool that builds a `gdal.xcframework` for macOS (arm64) from any tagged GDAL release. Lives **outside** the GDAL source tree so future GDAL versions only require `make GDAL_VERSION=X.Y.Z` — no patching of GDAL itself.

The xcframework is consumed downstream by `SwiftPDAL` (a Swift Package). PDAL is built against this xcframework via the sibling project `pdal-xcframework-builder`.

## Pipeline (build.sh, 9 phases)

1. Shallow `git clone --branch v$GDAL_VERSION` into `work/gdal-$VER/src`
2. Configure + build **framework variant** (`-DGDAL_ENABLE_MACOSX_FRAMEWORK=ON`) into `work/.../build-framework`
3. Configure + build + install **dylib variant** into `work/.../build-dylib/install` — purely to capture GDAL's CMake export files (`GDAL-targets*.cmake`), which the framework variant doesn't emit in the right shape
4. `scripts/fix-cmake.sh` patches the dylib's exports to point at the framework layout (`Headers/`, `${prefix}/gdal` instead of `lib/libgdal.dylib`) and copies them into `gdal.framework/Versions/X.Y/lib/cmake/gdal/`
5. Rename `Versions/X.Y` → `Versions/A`; fix `install_name_tool -id` to `@rpath/gdal.framework/Versions/A/gdal`
6. `dylibbundler` pulls all transitive Homebrew deps into `Versions/A/Libraries/` with `@loader_path/Libraries/` rewriting
7. Normalise rpaths in each bundled dylib: collapse duplicate `LC_RPATH` entries, ensure `@loader_path` is present, and rewrite each dep ref from `@loader_path/Libraries/<name>` to `@loader_path/<name>` (siblings)
8. Optional `codesign` (only if `CODESIGN_IDENTITY` set in config.sh — usually unnecessary because Xcode re-signs on Embed & Sign)
9. `xcodebuild -create-xcframework`, `ditto` zip, `swift package compute-checksum`. Optional `gh release create` if `RELEASE=1` and `GH_RELEASE_REPO` is set

## Files

- `build.sh` — orchestrator with 9 numbered, clearly delimited phases
- `scripts/fix-cmake.sh` — CMake export patcher; takes `(framework_dir, dylib_cmake_dir, fw_version)`
- `Makefile` — thin wrapper exposing `xcframework`, `release`, `clean`, `distclean`
- `config.sh.example` — template; user copies to `config.sh` (gitignored)
- `work/`, `output/` — gitignored

## Config knobs (config.sh)

- `CODESIGN_IDENTITY` (optional)
- `OUTPUT_DIR` (default `./output`)
- `SWIFT_PACKAGE_FRAMEWORKS_DIR` (optional mirror dest)
- `GH_RELEASE_REPO` (for `make release`)
- `ARCHS` (`arm64` only tested)
- `DISABLED_OGR_DRIVERS` (default: `XLS XLSX VFK CAD`)
- `EXTRA_CMAKE_FLAGS`

## Conventions and gotchas

- **`FW_VERSION` is derived from `GDAL_VERSION` via `awk -F. '{print $1"."$2}'`** (e.g. `3.12.4` → `3.12`). The Versions/X.Y dir is then renamed to Versions/A. Do not hardcode `3.12` anywhere.
- **`fix-cmake.sh` writes `IMPORTED_SONAME_RELEASE` referencing `Versions/${FW_VERSION}/gdal`**, but the dir is then renamed to `A`. This is a known latent inconsistency preserved from the user's original working notes — don't "fix" it without testing PDAL still links.
- **`gdal_version.h` must be pre-generated per build dir, not into the source tree.** Two related traps:
  1. Configure-time `target_sources` in `gdal.cmake:600` references `${BUILD}/gcore/gdal_version_full/gdal_version.h`, but GDAL's `generate_gdal_version_h` custom target only runs at *build* time → configure fails with "Cannot find source file". Fix: run `cmake -P generate_gdal_version_h.cmake -DBINARY_DIR=${BUILD}` before each `cmake -S -B`. The `gen_version_h` helper does this.
  2. If `BINARY_DIR` is set to the *source* dir, `gcore/gdal_version.h` lands in `src/` and `GdalVersion.cmake:46` errors with "was found, and likely conflicts with ${BUILD}/gcore/gdal_version.h". Always pass the build dir.
  Also `rm -f "${SRC_DIR}/gcore/gdal_version.h"` after clone, defensively, in case a previous run polluted the source tree.
- **Two builds of GDAL are required.** The framework build doesn't emit usable CMake exports; the dylib build is purely for those exports. Don't try to collapse this into one build.
- **`dylibbundler` runs from `${FW_BUILD}` cwd** because it expects the `./gdal.framework/...` relative path. Phase 5 `cd "${FW_BUILD}"` and stays there through phase 8.
- **`dylibbundler` needs `-s` search paths** to resolve `@rpath/libfoo.dylib` references (e.g. `@rpath/libexpat.1.dylib`) without prompting. Configured via `DYLIBBUNDLER_SEARCH_PATHS` (default `/opt/homebrew/lib /opt/homebrew/opt/expat/lib`). If a future build prompts for a missing dep, add its dir there.
- **`expat` must be installed via Homebrew** even though macOS ships it. The system copy lives in dyld_shared_cache (no on-disk file), so `dylibbundler` can't copy it. The script's preflight checks for `/opt/homebrew/opt/expat/lib/libexpat.1.dylib` and aborts with a `brew install expat` hint if missing. Same pattern likely applies to any future dep that's both system-provided and referenced via `@rpath` — add a preflight check.
- **`set -euo pipefail`** is on. The rpath-fixing loop (phase 7) uses `|| true` and `|| break` defensively because `install_name_tool` exits nonzero on legitimate no-ops.
- **Boost env vars** (`BOOST_ROOT`, `CPLUS_INCLUDE_PATH`, `LIBRARY_PATH`) are set from `brew --prefix boost`. Carried over from the user's original recipe — needed for some GDAL drivers.
- **Tag format assumption**: `v$GDAL_VERSION` (GDAL's convention). If a future GDAL release drops the `v` prefix, the clone will fail and the script needs adjustment.

## When the user asks for changes

- Bumping defaults (drivers, deployment target, archs): edit `config.sh.example` and document in README.
- Adding a build phase: insert as a new numbered step; update the `step "N/9 ..."` count consistently.
- Behaviour changes that affect downstream PDAL linkage (cmake export shape, install_name, rpaths): flag explicitly — PDAL builds against this xcframework's `lib/cmake/gdal/`.

## Out of scope

- Cross-compiling for x86_64 (untested; would need `lipo` or separate framework slices).
- iOS / Catalyst (different cmake flags, different deployment target, untested).
- Patching GDAL source — this project is intentionally a pure orchestrator over upstream tags.
