import Foundation
import MCP
import SlackWebLib

public final class CheSlackMCPServer {
    public static let name = "che-slack-mcp"
    public static let version = "0.9.0"

    private let server: Server
    private let transport: StdioTransport

    public init() async throws {
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
            .init(tools: [])
        }
    }
}
