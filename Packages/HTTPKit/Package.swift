// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "HTTPKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HTTPKit", targets: ["HTTPKit"]),
    ],
    targets: [
        .target(name: "HTTPKit"),
        .testTarget(name: "HTTPKitTests", dependencies: ["HTTPKit"]),
    ]
)
