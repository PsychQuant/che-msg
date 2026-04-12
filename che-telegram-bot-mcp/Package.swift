// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheTelegramBotMCP",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TelegramBotAPI", targets: ["TelegramBotAPI"]),
        .library(name: "CheTelegramBotMCPCore", targets: ["CheTelegramBotMCPCore"]),
        .executable(name: "telegram-bot", targets: ["telegram-bot"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "TelegramBotAPI",
            path: "Sources/TelegramBotAPI"
        ),
        .target(
            name: "CheTelegramBotMCPCore",
            dependencies: [
                "TelegramBotAPI",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/CheTelegramBotMCPCore"
        ),
        .executableTarget(
            name: "CheTelegramBotMCP",
            dependencies: ["CheTelegramBotMCPCore"],
            path: "Sources/CheTelegramBotMCP"
        ),
        .executableTarget(
            name: "telegram-bot",
            dependencies: [
                "TelegramBotAPI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/telegram-bot"
        ),
        .testTarget(
            name: "CheTelegramBotMCPTests",
            dependencies: ["CheTelegramBotMCPCore"],
            path: "Tests/CheTelegramBotMCPTests"
        ),
    ]
)
