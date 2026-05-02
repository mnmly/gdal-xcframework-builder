# gdal-xcframework-builder

Standalone builder that produces a signed `gdal.xcframework` for macOS (arm64) from any tagged GDAL release. Keeps the build recipe outside the GDAL source tree so future GDAL versions only require a version bump.

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
make GDAL_VERSION=3.12.4 release   # also gh release create
make clean                         # wipe work/
make distclean                     # wipe work/ and output/
```

## Layout

```
build.sh              # orchestrator — phases are clearly delimited
config.sh             # your personal paths/identity (gitignored)
config.sh.example     # template
Makefile              # thin wrapper
scripts/
  fix-cmake.sh        # patches GDAL's cmake exports for framework layout
work/                 # cloned source + build dirs (gitignored)
output/               # default OUTPUT_DIR if config doesn't override
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
