// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DumpKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DumpKit", targets: ["DumpKit"]),
    ],
    dependencies: [
        .package(path: "../HTTPKit"),
    ],
    targets: [
        .target(name: "DumpKit", dependencies: ["HTTPKit"]),
        .testTarget(name: "DumpKitTests", dependencies: ["DumpKit"]),
    ]
)
