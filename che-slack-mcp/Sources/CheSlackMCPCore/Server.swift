import Foundation
import MCP
import SlackWebLib

/// The che-slack-mcp server: one process for every imported workspace
/// (design: 一個 process 管多個 workspace). Nothing is read from the
/// Keychain at startup; each tool call reads what it needs, so a workspace
/// imported or removed while the server runs is seen on the next call.
public final class CheSlackMCPServer {
    public static let name = "che-slack-mcp"
    /// The version reported as `serverInfo.version`. `slack-all` reports its
    /// own copy of the same number (Sources/slack-all/main.swift); bump both.
    public static let version = "0.9.0"

    private let server: Server
    private let transport: StdioTransport
    let handler: SlackToolHandler

    /// The production server: the Keychain through `security`, and Slack
    /// paced by `SLACK_MCP_MIN_INTERVAL_MS` and `SLACK_MCP_MAX_CONCURRENCY`.
    /// An override outside its range is ignored with a warning on standard
    /// error (stdout carries JSON-RPC).
    public convenience init() async throws {
        let client = SlackWebClient(pacing: SlackPacingConfig.fromEnvironment())
        await self.init(handler: SlackToolHandler(store: SlackCredentialStore(), client: client))
    }

    init(handler: SlackToolHandler) async {
        self.handler = handler
        server = Server(
            name: Self.name,
            version: Self.version,
            capabilities: .init(tools: .init())
        )
        transport = StdioTransport()
        await registerHandlers()
    }

    public func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: SlackToolHandler.tools)
        }
        await server.withMethodHandler(CallTool.self) { [handler] params in
            await handler.callTool(name: params.name, arguments: params.arguments)
        }
    }
}
