// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheSlackMCP",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SlackWebLib", targets: ["SlackWebLib"]),
        .library(name: "CheSlackMCPCore", targets: ["CheSlackMCPCore"]),
        .library(name: "SlackAllCore", targets: ["SlackAllCore"]),
        .executable(name: "CheSlackMCP", targets: ["CheSlackMCP"]),
        .executable(name: "slack-all", targets: ["slack-all"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SlackWebLib",
            path: "Sources/SlackWebLib"
        ),
        .target(
            name: "CheSlackMCPCore",
            dependencies: [
                "SlackWebLib",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/CheSlackMCPCore"
        ),
        .executableTarget(
            name: "CheSlackMCP",
            dependencies: ["CheSlackMCPCore"],
            path: "Sources/CheSlackMCP"
        ),
        .target(
            name: "SlackAllCore",
            dependencies: ["SlackWebLib"],
            path: "Sources/SlackAllCore"
        ),
        .executableTarget(
            name: "slack-all",
            dependencies: [
                "SlackAllCore",
                "SlackWebLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/slack-all"
        ),
        .testTarget(
            name: "SlackWebLibTests",
            dependencies: ["SlackWebLib"],
            path: "Tests/SlackWebLibTests"
        ),
        .testTarget(
            name: "SlackAllCoreTests",
            dependencies: ["SlackAllCore", "SlackWebLib"],
            path: "Tests/SlackAllCoreTests"
        ),
    ]
)
