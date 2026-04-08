// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheTelegramBotMCP",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CheTelegramBotMCPCore", targets: ["CheTelegramBotMCPCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.2")
    ],
    targets: [
        .target(
            name: "CheTelegramBotMCPCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            path: "Sources/CheTelegramBotMCPCore"
        ),
        .executableTarget(
            name: "CheTelegramBotMCP",
            dependencies: ["CheTelegramBotMCPCore"],
            path: "Sources/CheTelegramBotMCP"
        ),
        .testTarget(
            name: "CheTelegramBotMCPTests",
            dependencies: ["CheTelegramBotMCPCore"],
            path: "Tests/CheTelegramBotMCPTests"
        )
    ]
)
