// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MockAPIKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MockAPIKit", targets: ["MockAPIKit"]),
    ],
    dependencies: [
        .package(path: "../HTTPKit"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(name: "MockAPIKit", dependencies: ["HTTPKit", "Yams"]),
        .testTarget(
            name: "MockAPIKitTests",
            dependencies: ["MockAPIKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
