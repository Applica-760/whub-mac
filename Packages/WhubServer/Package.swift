// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "WhubServer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "whub-server", targets: ["WhubServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "WhubServer",
            dependencies: [.product(name: "Hummingbird", package: "hummingbird")]
        ),
    ]
)
