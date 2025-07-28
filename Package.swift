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
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "SwiftUnixSockAPI",
            dependencies: ["Yams"],
            path: "Sources/SwiftUnixSockAPI"),
        .testTarget(
            name: "SwiftUnixSockAPITests",
            dependencies: ["SwiftUnixSockAPI"],
            path: "Tests/SwiftUnixSockAPITests"),
    ]
)