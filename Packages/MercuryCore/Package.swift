// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MercuryCore",
    platforms: [.iOS(.v17), .macOS(.v14), .visionOS(.v2)],
    products: [
        .library(name: "MercuryKit", targets: ["MercuryKit"]),
        .library(name: "ChatCore", targets: ["ChatCore"]),
    ],
    targets: [
        .target(name: "MercuryKit"),
        .target(name: "ChatCore", dependencies: ["MercuryKit"]),
        .testTarget(name: "MercuryKitTests", dependencies: ["MercuryKit"]),
        .testTarget(name: "ChatCoreTests", dependencies: ["ChatCore"]),
    ]
)
