// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheTelegramAllMCP",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CheTelegramAllMCPCore", targets: ["CheTelegramAllMCPCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.2"),
        .package(url: "https://github.com/Swiftgram/TDLibKit.git", exact: "1.5.2-tdlib-1.8.60-cb863c16"),
    ],
    targets: [
        .target(
            name: "CheTelegramAllMCPCore",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "TDLibKit", package: "TDLibKit"),
            ],
            path: "Sources/CheTelegramAllMCPCore"
        ),
        .executableTarget(
            name: "CheTelegramAllMCP",
            dependencies: ["CheTelegramAllMCPCore"],
            path: "Sources/CheTelegramAllMCP"
        ),
        .testTarget(
            name: "CheTelegramAllMCPTests",
            dependencies: ["CheTelegramAllMCPCore"],
            path: "Tests/CheTelegramAllMCPTests"
        )
    ]
)
