// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PhpSwitcherCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhpSwitcherCore", targets: ["PhpSwitcherCore"]),
    ],
    targets: [
        // Everything that talks to Homebrew / Valet / the shell. No AppKit, so it is testable.
        .target(name: "PhpSwitcherCore"),
        .testTarget(name: "PhpSwitcherCoreTests", dependencies: ["PhpSwitcherCore"]),
    ]
)
