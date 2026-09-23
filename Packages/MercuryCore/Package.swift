// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MercuryCore",
    platforms: [.iOS(.v17), .macOS(.v14), .visionOS(.v2)],
    products: [
        .library(name: "ChatCore", targets: ["ChatCore"]),
    ],
    dependencies: [
        // The shared Chat/Voice protocol kit. Pinned exactly: bump it
        // deliberately, together with the app's own package reference in
        // project.yml, so both resolve to the same version.
        .package(url: "https://github.com/angel12/mercurykit", exact: "0.3.0"),
    ],
    targets: [
        .target(
            name: "ChatCore",
            dependencies: [.product(name: "MercuryKit", package: "mercurykit")]),
        .testTarget(
            name: "ChatCoreTests",
            dependencies: ["ChatCore", .product(name: "MercuryKit", package: "mercurykit")]),
    ]
)
