// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WhubPackage",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WhubCore", targets: ["WhubCore"]),
        .library(name: "WhubClient", targets: ["WhubClient"]),
        .library(name: "WhubAgent", targets: ["WhubAgent"]),
        .executable(name: "whub-mac", targets: ["WhubCLI"]),
        .executable(name: "whub-server", targets: ["WhubServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "WhubCore"),
        .target(name: "WhubClient", dependencies: ["WhubAgent"]),
        .target(name: "WhubAgent"),
        .executableTarget(name: "WhubCLI", dependencies: ["WhubCore"]),
        .executableTarget(
            name: "WhubServer",
            dependencies: ["WhubAgent", .product(name: "Hummingbird", package: "hummingbird")]
        ),
        .testTarget(name: "WhubCoreTests", dependencies: ["WhubCore"]),
        .testTarget(name: "WhubServerTests", dependencies: ["WhubServer", "WhubClient", "WhubAgent", .product(name: "HummingbirdTesting", package: "hummingbird")]),
    ]
)
