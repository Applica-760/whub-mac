// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WhubCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "WhubCore", targets: ["WhubCore"]),
        .executable(name: "whub-mac", targets: ["WhubCLI"]),
    ],
    targets: [
        .target(name: "WhubCore", resources: [.copy("Resources/remote_agent.py"), .copy("Resources/remote_files.py")]),
        .executableTarget(name: "WhubCLI", dependencies: ["WhubCore"]),
        .testTarget(name: "WhubCoreTests", dependencies: ["WhubCore"]),
    ]
)
