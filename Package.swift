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
            name: "SwiftUnixSockAPI-Server",
            targets: ["SwiftUnixSockAPI-Server"]),
        .executable(
            name: "SwiftUnixSockAPI-Client", 
            targets: ["SwiftUnixSockAPI-Client"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "SwiftUnixSockAPI",
            dependencies: ["Yams"],
            path: "Sources/SwiftUnixSockAPI"),
        .executableTarget(
            name: "SwiftUnixSockAPI-Server",
            dependencies: ["SwiftUnixSockAPI"],
            path: "Sources/SwiftUnixSockAPI-Server"),
        .executableTarget(
            name: "SwiftUnixSockAPI-Client",
            dependencies: ["SwiftUnixSockAPI"],
            path: "Sources/SwiftUnixSockAPI-Client"),
        .testTarget(
            name: "SwiftUnixSockAPITests",
            dependencies: ["SwiftUnixSockAPI"],
            path: "Tests/SwiftUnixSockAPITests"),
    ]
)