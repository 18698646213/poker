// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Poker",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "PokerCore", targets: ["PokerCore"]),
        .executable(name: "PokerDesktop", targets: ["PokerDesktop"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.3"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.2"),
    ],
    targets: [
        .target(
            name: "PokerCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        ),
        .executableTarget(
            name: "PokerDesktop",
            dependencies: ["PokerCore"]
        ),
        .testTarget(
            name: "PokerCoreTests",
            dependencies: ["PokerCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
