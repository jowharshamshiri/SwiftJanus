// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftUnixSockAPI",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "SwiftUnixSockAPI",
            targets: ["SwiftUnixSockAPI"]),
        .executable(
            name: "SwiftUnixSockDgram",
            targets: ["SwiftUnixSockDgram"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "SwiftUnixSockAPI",
            dependencies: ["Yams"],
            path: "Sources/SwiftUnixSockAPI"),
        .executableTarget(
            name: "SwiftUnixSockDgram",
            dependencies: [
                "SwiftUnixSockAPI",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/SwiftUnixSockDgram"),
        .testTarget(
            name: "SwiftUnixSockAPITests",
            dependencies: ["SwiftUnixSockAPI"],
            path: "Tests/SwiftUnixSockAPITests"),
    ]
)