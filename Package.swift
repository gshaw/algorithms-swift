// swift-tools-version: 6.0
import PackageDescription

// Each algorithm is one library target with one self-contained file, to copy into an
// app or depend on. `evaluate` is the harness the checker runs.
let package = Package(
    name: "Algorithms",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "WMM", targets: ["WMM"]),
        .library(name: "UTMMGRS", targets: ["UTMMGRS"]),
    ],
    targets: [
        .target(name: "WMM"),
        .target(name: "UTMMGRS"),
        .executableTarget(name: "evaluate", dependencies: ["WMM", "UTMMGRS"]),
    ]
)
