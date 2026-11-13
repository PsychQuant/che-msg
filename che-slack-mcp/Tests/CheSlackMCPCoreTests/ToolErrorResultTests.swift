import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// One way beta's Slack call can fail, and what its tool result must say.
struct FailureRow: Sendable, CustomTestStringConvertible {
    let name: String
    let answer: ScriptedAnswer
    let phrases: [String]

    var testDescription: String { name }
}

/// spec: slack-mcp-tools, "Tool error results". Tools that call Slack run
/// inside `withWorkspace`; these tests call Slack from its body the way
/// `get_conversation_history` will.
@Suite("Tool error results")
struct ToolErrorResultTests {
    static let failures: [FailureRow] = [
        FailureRow(name: "sessionInvalid", answer: .body(Fake.slackError("invalid_auth")),
                   phrases: ["T02 beta", "no longer valid", "invalid_auth",
                             "slack-all auth import", "slack-all auth import --from-desktop"]),
        FailureRow(name: "enterpriseRestricted", answer: .body(Fake.slackError("enterprise_is_restricted")),
                   phrases: ["T02 beta", "enterprise_is_restricted",
                             "Enterprise Grid can end automated sessions", "Slack's official MCP server"]),
        FailureRow(name: "rateLimited",
                   answer: .response(status: 429, headers: ["Retry-After": "7"], body: ""),
                   phrases: ["T02 beta", "rate limiting", "7 s"]),
        FailureRow(name: "slackError", answer: .body(Fake.slackError("channel_not_found")),
                   phrases: ["T02 beta", "channel_not_found"]),
        FailureRow(name: "network",
                   answer: .fail(EchoingTransportError(text: "connection reset while sending \(Fake.betaToken)")),
                   phrases: ["T02 beta", "Network error", "connection reset while sending"]),
    ]

    let keychain: MemoryKeychain

    init() async throws {
        keychain = try await MemoryKeychain.with([Fake.alpha, Fake.beta])
    }

    /// Calls `conversations.history` for the selected workspace.
    func readHistory(_ handler: SlackToolHandler, _ arguments: [String: Value]) async -> CallTool.Result {
        await handler.withWorkspace(arguments) { selection in
            _ = try await handler.client.call("conversations.history", parameters: ["channel": "C01"],
                                              credential: selection.credential)
            return ToolResult.json(["ok": true])
        }
    }

    /// spec: "Session expired during a read".
    @Test("get_conversation_history for beta receiving invalid_auth is an error result naming beta and both commands")
    func sessionExpiredDuringRead() async throws {
        let transport = TokenTransport([Fake.betaToken: .body(Fake.slackError("invalid_auth"))])

        let result = await readHistory(makeHandler(keychain, transport), ["workspace": .string("beta")])

        expectError(result, containing: ["beta", "slack-all auth import", "slack-all auth import --from-desktop"])
        #expect(transport.methods == ["conversations.history"])
    }

    @Test("every client error class is an error result naming the workspace", arguments: failures)
    func everyClass(row: FailureRow) async throws {
        let transport = TokenTransport([Fake.betaToken: row.answer])

        let result = await readHistory(makeHandler(keychain, transport), ["workspace": .string("T02")])

        expectError(result, containing: row.phrases)
        #expect(Set(transport.tokens) == [Fake.betaToken])
    }

    @Test("a success from the body is returned unchanged")
    func success() async throws {
        let transport = TokenTransport([Fake.alphaToken: .body(#"{"ok":true}"#)])

        let result = await readHistory(makeHandler(keychain, transport), ["workspace": .string("alpha")])

        #expect(result.isError == false)
        #expect(try json(result) as? [String: Bool] == ["ok": true])
        expectNoSecrets(result)
    }

    @Test("a refused selection runs no body and sends nothing to Slack")
    func refusedSelection() async throws {
        let transport = TokenTransport()

        let result = await readHistory(makeHandler(keychain, transport), [:])

        expectError(result, containing: ["T01 alpha", "T02 beta"])
        #expect(transport.requests.isEmpty)
    }

    struct Unexpected: Error, CustomStringConvertible {
        var description: String { "body said \(Fake.betaToken)" }
    }

    @Test("an error that is not the client's is still an error result, described by its type only")
    func otherError() async throws {
        let handler = makeHandler(keychain)

        let result = await handler.withWorkspace(["workspace": .string("beta")]) { _ in throw Unexpected() }

        expectError(result, containing: ["T02 beta", "Unexpected"])
    }

    @Test("a ToolFailure thrown by the body is returned as its own message")
    func bodyFailure() async throws {
        let handler = makeHandler(keychain)

        let result = await handler.withWorkspace(["workspace": .string("beta")]) { _ in
            throw ToolFailure("limit must be from 1 to 200.")
        }

        #expect(text(result) == "Error: limit must be from 1 to 200.")
        #expect(result.isError == true)
    }
}
