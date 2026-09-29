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
        .library(name: "Bearings", targets: ["Bearings"]),
        .library(name: "AstronomicalTime", targets: ["AstronomicalTime"]),
    ],
    targets: [
        .target(name: "WMM"),
        .target(name: "UTMMGRS"),
        .target(name: "Bearings"),
        .target(name: "AstronomicalTime"),
        .executableTarget(name: "evaluate", dependencies: ["WMM", "UTMMGRS", "Bearings", "AstronomicalTime"]),
    ]
)
