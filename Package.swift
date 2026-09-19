// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "brother-mac-driver",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BrotherPDL", targets: ["BrotherPDL"]),
        .executable(name: "rastertobrother", targets: ["rastertobrother"]),
        .executable(name: "pxltool", targets: ["pxltool"]),
    ],
    targets: [
        // libcups from the macOS SDK. Only the filter executable may depend on this.
        .systemLibrary(name: "CCUPS", path: "Sources/CCUPS"),

        // Page-description-language encoders. Pure Swift and deliberately free of CUPS,
        // so it stays unit-testable and can be rehosted outside a CUPS filter.
        .target(name: "BrotherPDL"),

        .executableTarget(name: "rastertobrother", dependencies: ["BrotherPDL", "CCUPS"]),
        .executableTarget(name: "pxltool", dependencies: ["BrotherPDL"]),

        .testTarget(name: "BrotherPDLTests", dependencies: ["BrotherPDL"]),
    ]
)
