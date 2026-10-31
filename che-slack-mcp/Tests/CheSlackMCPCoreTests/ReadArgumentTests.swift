import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-mcp-tools, "Conversation read tools" and "Message search":
/// an argument outside its allowed form or range is an error naming the
/// argument, and Slack is not called. Arguments are checked before the
/// Keychain is read, so these also assert no Keychain read.
@Suite("Read tool arguments")
struct ReadArgumentTests {
    /// spec: "Limit out of range is refused".
    @Test("get_conversation_history with limit 500 is refused naming limit, and no request is sent")
    func limitOutOfRange() async throws {
        let transport = MethodTransport([:])
        let (handler, keychain) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_conversation_history",
                                            arguments: ["conversation_id": .string("C01"), "limit": .int(500)])

        expectRefused(result, naming: "limit", transport: transport, keychain: keychain)
    }

    /// spec: "Empty query is refused".
    @Test("search_messages with a query of only spaces is refused naming query, and no request is sent")
    func blankQuery() async throws {
        let transport = MethodTransport([:])
        let (handler, keychain) = try await readHandler(transport)

        let result = await handler.callTool(name: "search_messages", arguments: ["query": .string("   ")])

        expectRefused(result, naming: "query", transport: transport, keychain: keychain)
    }

    /// One argument value that must be refused, and the argument it names.
    struct Refusal: Sendable, CustomTestStringConvertible {
        let tool: String
        let names: String
        let arguments: [String: Value]
        var testDescription: String { "\(tool) \(names): \(arguments[names].map { "\($0)" } ?? "missing")" }
    }

    static func history(_ names: String, _ value: Value?) -> Refusal {
        var arguments: [String: Value] = ["conversation_id": .string("C01")]
        arguments[names] = value
        return Refusal(tool: "get_conversation_history", names: names, arguments: arguments)
    }

    /// Wrong range, wrong JSON type, and wrong form. Numbers are not read
    /// from strings, booleans are not numbers, and timestamps must be strings.
    static let historyRefusals: [Refusal] = [
        history("limit", .int(0)), history("limit", .int(201)), history("limit", .int(-1)),
        history("limit", .double(2.5)), history("limit", .double(.infinity)), history("limit", .string("50")),
        history("limit", .bool(true)), history("limit", .array([.int(50)])),
        history("conversation_id", nil), history("conversation_id", .null), history("conversation_id", .string("")),
        history("conversation_id", .string("#general")), history("conversation_id", .string("C01 ")),
        history("conversation_id", .int(42)), history("conversation_id", .string(String(repeating: "C", count: 65))),
        history("oldest", .double(1730000000.0001)), history("oldest", .int(1730000000)),
        history("oldest", .string("yesterday")), history("oldest", .string("")), history("oldest", .string("1730000000.")),
        history("oldest", .string(".5")), history("oldest", .string("1.2.3")), history("oldest", .string("-1")),
        history("latest", .string("1730000000.000100 ")), history("latest", .string(String(repeating: "1", count: 33))),
    ]

    @Test("get_conversation_history refuses an argument outside its form or range, naming it, before any Keychain read or request",
          arguments: historyRefusals)
    func historyRefusal(row: Refusal) async throws {
        let transport = MethodTransport([:])
        let (handler, keychain) = try await readHandler(transport)

        let result = await handler.callTool(name: row.tool, arguments: row.arguments)

        expectRefused(result, naming: row.names, transport: transport, keychain: keychain)
    }

    @Test("limit accepts its bounds and a whole number written with a fraction; null means the default",
          arguments: [(Value.int(1), "1"), (.int(200), "200"), (.double(50.0), "50"), (.null, "50")])
    func limitAccepted(value: Value, sent: String) async throws {
        let transport = MethodTransport(["conversations.history": #"{"ok":true,"messages":[]}"#])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_conversation_history", arguments: [
            "conversation_id": .string("C01"), "limit": value, "oldest": .null,
        ])

        #expect(result.isError == false)
        #expect(transport.calls.map(\.parameters) == [["channel": "C01", "limit": sent]])
        expectNoSecrets(result)
    }

    /// spec: "Ambiguous call is refused", through the real tool.
    @Test("get_conversation_history without workspace while alpha and beta are imported lists both and sends nothing")
    func ambiguousWorkspace() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha, Fake.beta])
        let transport = TokenTransport()

        let result = await makeHandler(keychain, transport).callTool(name: "get_conversation_history",
                                                                     arguments: ["conversation_id": .string("C01")])

        expectError(result, containing: ["T01 alpha", "T02 beta"])
        #expect(transport.requests.isEmpty)
    }
}
