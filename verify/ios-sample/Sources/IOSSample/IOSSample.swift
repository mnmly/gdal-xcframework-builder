import gdal
import Foundation

public enum IOSSample {
    /// Registers all GDAL drivers and returns the runtime release-name
    /// string (e.g. "3.12.4"). Proves the iOS slices link + run.
    public static func gdalRelease() -> String {
        GDALAllRegister()
        guard let cstr = GDALVersionInfo("RELEASE_NAME") else { return "" }
        return String(cString: cstr)
    }

    /// Read-back from a real GeoTIFF — proves the GTIFF driver is wired
    /// up end-to-end (registered, dataset opens, raster size + driver
    /// short-name are readable). Returns nil on any failure so callers
    /// can assert with a clean message.
    public struct RasterInfo {
        public let width: Int
        public let height: Int
        public let bandCount: Int
        public let driverShortName: String
    }

    public static func openRaster(at path: String) -> RasterInfo? {
        GDALAllRegister()
        guard let ds = GDALOpen(path, GA_ReadOnly) else { return nil }
        defer { GDALClose(ds) }
        let w = Int(GDALGetRasterXSize(ds))
        let h = Int(GDALGetRasterYSize(ds))
        let n = Int(GDALGetRasterCount(ds))
        guard let drv = GDALGetDatasetDriver(ds),
              let nameC = GDALGetDriverShortName(drv) else { return nil }
        return RasterInfo(
            width: w, height: h, bandCount: n,
            driverShortName: String(cString: nameC)
        )
    }
}
