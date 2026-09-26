// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MoleEngine",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MoleEngine", targets: ["MoleEngine"]),
    ],
    targets: [
        .target(name: "MoleEngine"),
        .testTarget(name: "MoleEngineTests", dependencies: ["MoleEngine"]),
    ]
)
