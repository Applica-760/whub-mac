// swift-tools-version: 6.2

import PackageDescription

#if os(Linux)
let localProducts: [Product] = []
let localTargets: [Target] = []
#else
let localProducts: [Product] = [
    .library(name: "WhubCore", targets: ["WhubCore"]),
    .executable(name: "whub-mac", targets: ["WhubCLI"]),
]
let localTargets: [Target] = [
    .target(name: "WhubCore"),
    .executableTarget(name: "WhubCLI", dependencies: ["WhubCore"]),
    .testTarget(name: "WhubCoreTests", dependencies: ["WhubCore"]),
]
#endif

let package = Package(
    name: "WhubPackage",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WhubGit", targets: ["WhubGit"]),
        .library(name: "WhubClient", targets: ["WhubClient"]),
        .library(name: "WhubAgent", targets: ["WhubAgent"]),
        .executable(name: "whub-server", targets: ["WhubServer"]),
    ] + localProducts,
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "WhubGit"),
        .target(name: "WhubClient", dependencies: ["WhubAgent"]),
        .target(name: "WhubAgent"),
        .executableTarget(
            name: "WhubServer",
            dependencies: ["WhubAgent", "WhubGit", .product(name: "Hummingbird", package: "hummingbird")]
        ),
        .testTarget(name: "WhubGitTests", dependencies: ["WhubGit"]),
        .testTarget(name: "WhubServerTests", dependencies: ["WhubServer", "WhubClient", "WhubAgent", .product(name: "HummingbirdTesting", package: "hummingbird")]),
    ] + localTargets
)
