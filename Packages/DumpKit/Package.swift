// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DumpKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DumpKit", targets: ["DumpKit"]),
    ],
    targets: [
        .target(name: "DumpKit"),
        .testTarget(name: "DumpKitTests", dependencies: ["DumpKit"]),
    ]
)
