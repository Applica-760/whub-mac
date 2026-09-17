// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WhubCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WhubCore", targets: ["WhubCore"]),
        .executable(name: "whub", targets: ["WhubCLI"]),
    ],
    targets: [
        .target(name: "WhubCore"),
        .executableTarget(name: "WhubCLI", dependencies: ["WhubCore"]),
    ]
)
