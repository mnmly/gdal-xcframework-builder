# gdal-xcframework-builder

Standalone builder that produces a signed `gdal.xcframework` for macOS (arm64) — and optionally `gdal.xcframework` + `proj.xcframework` with iOS device + simulator slices — from any tagged GDAL release. Keeps the build recipe outside the GDAL source tree so future GDAL versions only require a version bump.

## One-time setup

```sh
cp config.sh.example config.sh
$EDITOR config.sh   # set OUTPUT_DIR (and optionally CODESIGN_IDENTITY)
brew install cmake boost dylibbundler expat
```

`expat` is required at bundling time: macOS keeps system libexpat inside the
dyld shared cache (not on disk), so some Homebrew lib in GDAL's dep chain
references `@rpath/libexpat.1.dylib` and `dylibbundler` needs a real file to
copy. Installing the Homebrew expat satisfies it.

GDAL's other build deps (proj, geos, libtiff, sqlite, etc.) come from Homebrew
automatically via cmake's discovery. If `dylibbundler` ever prompts for another
missing `@rpath/libfoo.dylib`, `brew install foo` and rerun.

## Build

```sh
make GDAL_VERSION=3.12.4
```

Or directly:

```sh
./build.sh 3.12.4
```

This will:

1. Shallow-clone `https://github.com/OSGeo/gdal` at tag `v$GDAL_VERSION` into `work/gdal-$GDAL_VERSION/`
2. Build the framework variant (`GDAL_ENABLE_MACOSX_FRAMEWORK=ON`)
3. Build a parallel dylib variant to capture the CMake export files
4. Patch the framework's CMake exports (`scripts/fix-cmake.sh`)
5. Rename `Versions/<X.Y>` → `Versions/A`, fix install names
6. `dylibbundler` all transitive deps into `Versions/A/Libraries/`
7. Rewrite rpaths so each bundled dylib references siblings via `@loader_path`
8. **Codesign inside-out** — every nested `*.dylib` and the `gdal` Mach-O binary are signed individually first, then the bundle is sealed with `--deep`. Defaults to ad-hoc (`-`) when `CODESIGN_IDENTITY` is unset. macOS 26 rejects pages whose nested-library signatures don't match the outer bundle's resource hashes, so the order matters — do not replace this with a single `--deep` pass.
9. Wrap into `gdal.xcframework` at `OUTPUT_DIR/gdal.xcframework`
10. Zip + print Swift Package checksum

## Other targets

```sh
make GDAL_VERSION=3.12.4 release           # also gh release create
make GDAL_VERSION=3.12.4 xcframework-ios   # macOS + iOS device + iOS simulator
make GDAL_VERSION=3.12.4 release-ios       # iOS build + gh release create
make verify-ios                            # build + run verify/ios-sample
make verify-macos-baseline                 # regression-diff against baseline
make clean                                 # wipe work/
make distclean                             # wipe work/ and output/ and verify/.../build/
```

## iOS slices (`BUILD_IOS=1`)

`make xcframework-ios` (or `BUILD_IOS=1 ./build.sh <ver>`) produces:

- `output/gdal.xcframework` with **three** slices: `macos-arm64` (dynamic
  framework with bundled Homebrew dylibs, identical to the no-iOS build),
  `ios-arm64` (static, device), `ios-arm64-simulator` (static, Apple Silicon sim).
- `output/proj.xcframework` with **two** iOS slices (device + simulator).
  No macOS slice — the macOS PDAL build keeps consuming Homebrew PROJ.

### Prerequisites for iOS

Same as macOS, plus a working Xcode install (`xcode-select -p`). The iOS
pipeline cross-compiles all of GDAL's deps from source into
`work/deps-cache/ios-{device,simulator}/`, so no extra Homebrew deps are
required for the iOS path. First run cold-builds all 8 deps × 2 SDK
variants (≈2–3 minutes total wall) plus iOS GDAL itself (≈3–5 minutes
per slice). Subsequent runs reuse the deps cache.

### Why two artifacts on iOS

GDAL is shipped as a single merged static framework (gdal + geos + tiff
+ geotiff + sqlite + expat + png + jpeg), but **PROJ is split out** so
PDAL's iOS build can resolve `find_package(PROJ)` against a real install
tree. PROJ's CMake exports `PROJ::proj`; gdal's CMake exports declare
it as the one externalised dep. Subtle consequence: **`proj.xcframework`
on iOS is not usable on its own** — it needs sqlite3 + tiff symbols
which only exist inside `gdal.xcframework`'s merged archive. iOS
consumers must link both. Documented in `tasks/todo.md` §5.3.

### Driver strip

The iOS GDAL build uses an aggressive allow-list:

- Master switches OFF (`GDAL_BUILD_OPTIONAL_DRIVERS`,
  `OGR_BUILD_OPTIONAL_DRIVERS`, `GDAL_ENABLE_PLUGINS`).
- Raster: `GTIFF` (auto-includes COG), `VRT`. `MEM` is always-on.
- Vector: `SHAPE`, `GEOJSON`, `SQLITE`, `GPKG`.

Rationale + audit method in `scripts/deps/README.md`. Override via
`IOS_ENABLED_RASTER_DRIVERS` / `IOS_ENABLED_VECTOR_DRIVERS` in `config.sh`.

### iOS pipeline file map

```
scripts/
  toolchain/
    ios-device.cmake        # CMake toolchain (iphoneos, arm64, iOS 17.0)
    ios-simulator.cmake     # same, iphonesimulator sysroot
  deps/
    _common.sh              # shared fetch/build/validate helpers
    <dep>.sh × 8            # cross-compile scripts per dep
    README.md               # pinned versions + driver-strip rationale
  build-deps.sh             # orchestrator: builds all 8 deps for one sdk
  assemble-ios-framework.sh # libtool -static merge + Info.plist + modulemap
  fix-cmake-static.sh       # patches CMake exports for framework layout
verify/
  baseline/                 # captured macOS baseline (gitignored)
  ios-sample/               # SwiftPM package proving the iOS slices link + run
```

## Layout

```
build.sh              # orchestrator — phases are clearly delimited
config.sh             # your personal paths/identity (gitignored)
config.sh.example     # template
Makefile              # thin wrapper
scripts/
  fix-cmake.sh        # patches GDAL's cmake exports for macOS framework
  fix-cmake-static.sh # ... same for iOS static framework
  diff-frameworks.sh  # regression check against captured baseline
  build-deps.sh       # iOS deps orchestrator (BUILD_IOS=1)
  assemble-ios-framework.sh
  toolchain/          # iOS CMake toolchain files
  deps/               # per-dep cross-compile scripts
work/                 # cloned source + build dirs (gitignored)
output/               # default OUTPUT_DIR if config doesn't override
verify/               # baseline + ios-sample (gitignored)
```

## Disabled drivers

The same set as the original notes: `XLS`, `XLSX`, `VFK`, `CAD`. Edit `DISABLED_OGR_DRIVERS` in `config.sh` to change.

## Codesigning

`CODESIGN_IDENTITY` defaults to `-` (ad-hoc) when unset.

**Ad-hoc is fine when:**
- Consumers integrate via SwiftPM and re-sign with their own identity at app-build time.
- Distributing to TestFlight / App Store — Xcode re-signs everything during archive.
- Local development.

**Ad-hoc is NOT enough when:**
- Shipping a notarized `.app`/`.pkg` directly to end users (notarization requires Developer ID + hardened runtime + a real timestamp).
- The consuming app uses hardened runtime with library validation enabled (no `com.apple.security.cs.disable-library-validation` entitlement). Library validation requires nested code signed with the same Team ID as the host.

For Developer ID releases, set:

```sh
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
```

and update step 8 of `build.sh` to pass `--timestamp` (instead of `--timestamp=none`) and `--options=runtime` to enable hardened runtime, then notarize the resulting `.zip` with `xcrun notarytool submit`.
