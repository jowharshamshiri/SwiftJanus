// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SwiftJanus",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "SwiftJanus",
            targets: ["SwiftJanus"]),
        .executable(
            name: "SwiftJanusDgram",
            targets: ["SwiftJanusDgram"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "SwiftJanus",
            dependencies: ["Yams"],
            path: "Sources/SwiftJanus"),
        .executableTarget(
            name: "SwiftJanusDgram",
            dependencies: [
                "SwiftJanus",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/SwiftJanusDgram"),
        .testTarget(
            name: "SwiftJanusTests",
            dependencies: ["SwiftJanus"],
            path: "Tests/SwiftJanusTests"),
    ]
)