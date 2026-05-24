import Testing
import Foundation
@testable import IOSSample

@Test func gdalRelease_isNonEmpty() {
    let release = IOSSample.gdalRelease()
    print("GDAL release: \(release)")
    #expect(!release.isEmpty)
    // Sanity: looks like a SemVer-ish string starting with a digit.
    #expect(release.first.map { $0.isNumber } == true)
}

/// Opens a real 16x16 GeoTIFF bundled as a test resource. Proves the
/// GTIFF driver was actually compiled into the iOS slice — not just
/// that the registry registers something.
@Test func opensBundledGeoTIFF() throws {
    let url = try #require(
        Bundle.module.url(forResource: "test", withExtension: "tif")
    )
    let info = try #require(IOSSample.openRaster(at: url.path))
    print("GDAL opened: \(info.width)x\(info.height) bands=\(info.bandCount) driver=\(info.driverShortName)")
    #expect(info.width == 16)
    #expect(info.height == 16)
    #expect(info.bandCount == 1)
    #expect(info.driverShortName == "GTiff")
}
