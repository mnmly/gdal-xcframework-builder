// swift-tools-version: 6.0
//
// Minimal harness that proves the iOS slices of gdal.xcframework +
// proj.xcframework are well-formed: imports the modules, calls
// GDALAllRegister(), reads GDALVersionInfo("RELEASE_NAME"), and asserts
// it matches the GDAL version this builder produced.
//
// Build:
//   xcodebuild -scheme IOSSample-Package \
//     -destination 'generic/platform=iOS' build           # device, compile-only
//   xcodebuild -scheme IOSSample-Package \
//     -destination 'platform=iOS Simulator,name=iPhone 16' test
//
// `make verify-ios` from the repo root drives both.

import PackageDescription

let package = Package(
    name: "IOSSample",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "IOSSample", targets: ["IOSSample"]),
    ],
    targets: [
        .binaryTarget(name: "gdal", path: "../../output/gdal.xcframework"),
        .binaryTarget(name: "proj", path: "../../output/proj.xcframework"),
        .target(
            name: "IOSSample",
            dependencies: ["gdal", "proj"]
        ),
        .testTarget(
            name: "IOSSampleTests",
            dependencies: ["IOSSample"],
            resources: [
                .copy("Resources/test.tif"),
            ]
        ),
    ]
)
