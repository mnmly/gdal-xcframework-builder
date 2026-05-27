# Shared helpers sourced by build.sh and scripts/assemble-ios-framework.sh.
# Do not execute directly.
# shellcheck shell=bash

# Write GDAL's framework module.modulemap to <path>. gdal.h's umbrella does
# not transitively include cpl_conv / cpl_string / ogr_srs_api etc., so we
# spell those out explicitly — otherwise downstream Swift consumers can't
# see CPLSetConfigOption, VSIFree, OSRImportFromEPSG, GDALTranslate, etc.
write_gdal_modulemap() {
    local target="$1"
    mkdir -p "$(dirname "${target}")"
    cat > "${target}" <<'EOF'
framework module gdal {
    umbrella header "gdal.h"
    header "cpl_conv.h"
    header "cpl_string.h"
    header "cpl_vsi.h"
    header "ogr_srs_api.h"
    header "ogr_api.h"
    header "ogr_core.h"
    header "gdal_utils.h"
    header "gdal_alg.h"
    header "gdalwarper.h"
    export *
    module * { export * }
    link "z"
    link "xml2"
    link "iconv"
    link "c++"
}
EOF
}
