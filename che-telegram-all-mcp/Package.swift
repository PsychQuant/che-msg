// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheTelegramAllMCP",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TelegramAllLib", targets: ["TelegramAllLib"]),
        .library(name: "CheTelegramAllMCPCore", targets: ["CheTelegramAllMCPCore"]),
        .executable(name: "telegram-all", targets: ["telegram-all"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/Swiftgram/TDLibKit.git", exact: "1.5.2-tdlib-1.8.60-cb863c16"),
        .package(url: "https://github.com/Swiftgram/TDLibFramework.git", exact: "1.8.60-cb863c16"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "TelegramAllLib",
            dependencies: [
                .product(name: "TDLibKit", package: "TDLibKit"),
                .product(name: "TDLibFramework", package: "TDLibFramework"),
            ],
            path: "Sources/TelegramAllLib"
        ),
        .target(
            name: "CheTelegramAllMCPCore",
            dependencies: [
                "TelegramAllLib",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/CheTelegramAllMCPCore"
        ),
        .executableTarget(
            name: "CheTelegramAllMCP",
            dependencies: ["CheTelegramAllMCPCore"],
            path: "Sources/CheTelegramAllMCP"
        ),
        .executableTarget(
            name: "telegram-all",
            dependencies: [
                "TelegramAllLib",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/telegram-all"
        ),
        .testTarget(
            name: "TelegramAllLibTests",
            dependencies: ["TelegramAllLib"],
            path: "Tests/TelegramAllLibTests"
        ),
        .testTarget(
            name: "E2ETests",
            dependencies: ["TelegramAllLib", "CheTelegramAllMCPCore"],
            path: "Tests/E2ETests"
        ),
        .testTarget(
            name: "CheTelegramAllMCPTests",
            dependencies: ["CheTelegramAllMCPCore"],
            path: "Tests/CheTelegramAllMCPTests"
        ),
    ]
)
