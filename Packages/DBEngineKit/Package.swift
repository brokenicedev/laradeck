// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DBEngineKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DBEngineKit", targets: ["DBEngineKit"]),
    ],
    targets: [
        .target(name: "DBEngineKit"),
        .testTarget(name: "DBEngineKitTests", dependencies: ["DBEngineKit"]),
    ]
)
