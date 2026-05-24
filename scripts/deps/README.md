# iOS deps cross-compile scripts

Each `<dep>.sh` cross-compiles one dependency for an iOS slice and
installs it into the deps cache:

```
./scripts/deps/<dep>.sh <sdk> <install_prefix>
  <sdk>            = device | simulator
  <install_prefix> = work/deps-cache/<sdk>/<dep>-<version>/
```

Scripts are idempotent: if `<install_prefix>/lib/lib<dep>.a` exists, the
script exits 0 without rebuilding. Bumping a pinned version = new
`<dep>-<NEW>` directory; old one is stale and can be deleted manually.

## Pinned versions (defaults, override only with evidence)

| Dep            | Version    |
| -------------- | ---------- |
| sqlite3        | 3.46.0     |
| expat          | 2.6.2      |
| libpng         | 1.6.43     |
| libjpeg-turbo  | 3.0.3      |
| libtiff        | 4.6.0      |
| libgeotiff     | 1.7.3      |
| proj           | 9.4.0      |
| geos           | 3.13.0     |

## Build order (orchestrated by `scripts/build-deps.sh`)

```
sqlite3, expat, libpng, libjpeg     (leaves)
  ↓
libtiff           (needs libjpeg + SDK zlib)
  ↓
proj              (needs sqlite3, libtiff)
geos              (no deps in this set)
  ↓
libgeotiff        (needs libtiff, libjpeg, proj)
```

## iOS driver strip rationale (Phase 2 audit)

The iOS GDAL build is configured with:

- `GDAL_BUILD_OPTIONAL_DRIVERS=OFF`
- `OGR_BUILD_OPTIONAL_DRIVERS=OFF`
- `GDAL_ENABLE_PLUGINS=OFF`        ← non-negotiable, iOS forbids dlopen
- `GDAL_ENABLE_PLUGINS_NO_DEPS=OFF` ← defensive

Then a small explicit allow-list re-enables what PDAL actually uses.

### Allow-list

**Raster (`-DGDAL_ENABLE_DRIVER_<X>=ON`):**

| Driver | Why |
| ------ | --- |
| GTIFF  | Required by `readers.gdal` (SwiftPDAL `.tif`/`.tiff` route) and 10 PDAL non-test files (SMRFilter, FaceRaster, etc.). Auto-enabled by GDAL's CMake when TIFF + GeoTIFF deps are present, but we set it explicitly. **Also includes COG**: cogdriver.cpp is bundled into the GTIFF target, no separate flag. |
| VRT    | Composable raster — common in GTiff pipelines, used implicitly when chaining warps/translations. Cheap; keep. |

**Vector (`-DOGR_ENABLE_DRIVER_<X>=ON`):**

| Driver | Why |
| ------ | --- |
| SHAPE     | `"ESRI Shapefile"` — used by DensityKernel, TIndexKernel, OGR.cpp (4 files in PDAL). |
| GEOJSON   | Used by HexBinFilter + density kernels (3 files in PDAL). |
| SQLITE    | Required by GPKG (`ogr_dependent_driver(gpkg ... "GDAL_USE_SQLITE3;OGR_ENABLE_DRIVER_SQLITE")`). Also a common consumer format. |
| GPKG      | Modern OGC vector storage; SwiftPDAL consumers likely expect it. Trivial extra cost given sqlite3 already shipped for PROJ. |

**Always-on (no flag needed):** MEM — declared as `gdal_format()` not
`gdal_optional_format()`, so the master switch doesn't touch it. PDAL
needs it for in-memory raster scratch.

### What got dropped (and why it's OK)

- All raster JPEG / PNG / HDF / NetCDF / JP2 / PDF / MRF / NITF / ECW /
  HFA / GRIB / DTED / etc. — PDAL doesn't open or write any of these
  via GDAL. (PDAL's own `writers.png` is separate.)
- All OGR drivers except the four above. PDAL only references
  `"GTiff"`, `"MEM"`, `"GeoJSON"`, `"ESRI Shapefile"` in production
  code. `"SQLite"` and `"CSV"` are doc-only / TextWriter-only (not GDAL
  drivers in that context). `"XYZ"` is doc-only.
- All `*_PLUGIN` variants (NITF, HDF4, HDF5, GRIB, JPEG2000, PDF, etc.)
  — iOS forbids `dlopen` for App Store distribution. `GDAL_ENABLE_PLUGINS=OFF`
  enforces this; nothing in this allow-list is plugin-style anyway.

### Audit method (so future-you can re-run it)

```
grep -rEho '"(GTiff|COG|VRT|MEM|GeoJSON|GPKG|ESRI Shapefile|JPEG|netCDF|HDF|JP2|...)"' \
    pdal-xcframework-builder/work/pdal-X.Y.Z/src/ | grep -v test | sort -u
grep -nE 'case ".*":[[:space:]]*return "(readers|writers)\.' \
    SwiftPDAL/Sources/SwiftPDAL/Convert.swift
```

The first finds GDAL driver-name string literals in PDAL non-test code.
The second enumerates SwiftPDAL's user-facing reader/writer surface
(`.tif`/`.tiff` → `readers.gdal`, the only GDAL-driver-backed path).
