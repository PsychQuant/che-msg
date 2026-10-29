import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-mcp-tools, "Conversation read tools": `get_conversation_history`.
@Suite("get_conversation_history")
struct ConversationHistoryToolTests {
    /// A `conversations.history` answer, newest first as Slack sends it: a
    /// thread parent, a bot message, a user whose profile has an empty
    /// display name, and a message with neither profile nor `text`.
    static let history = #"""
        {"ok":true,"messages":[
          {"type":"message","user":"U02","text":"see thread","ts":"1730000300.000300","thread_ts":"1730000300.000300",
           "reply_count":2,"reply_users_count":1,"user_profile":{"display_name":"Alice","real_name":"Alice Chen","name":"alice.chen"}},
          {"type":"message","subtype":"bot_message","bot_id":"B01","username":"deploybot","text":"deployed","ts":"1730000200.000200"},
          {"type":"message","user":"U03","text":"hi","ts":"1730000100.000100","user_profile":{"display_name":"","real_name":"Bob Lin"}},
          {"type":"message","user":"U04","ts":"1730000050.000050"}
        ],"has_more":true,"pin_count":0,"response_metadata":{"next_cursor":"bmV4dA=="}}
        """#

    static let expected = #"{"conversation_id":"C01","has_more":true,"messages":["#
        + #"{"reply_count":2,"sender_name":"Alice","text":"see thread","thread_ts":"1730000300.000300","ts":"1730000300.000300","user_id":"U02"},"#
        + #"{"bot_id":"B01","sender_name":"deploybot","subtype":"bot_message","text":"deployed","ts":"1730000200.000200"},"#
        + #"{"sender_name":"Bob Lin","text":"hi","ts":"1730000100.000100","user_id":"U03"},"#
        + #"{"text":"","ts":"1730000050.000050","user_id":"U04"}]}"#

    @Test("returns Slack's newest-first messages with ts, sender, text and, for a thread parent, reply_count; limit defaults to 50")
    func fields() async throws {
        let transport = MethodTransport(["conversations.history": Self.history])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_conversation_history",
                                            arguments: ["conversation_id": .string("C01")])

        expectJSON(result, Self.expected)
        #expect(transport.calls == [SlackCall(method: "conversations.history",
                                              parameters: ["channel": "C01", "limit": "50"], token: Fake.alphaToken)])
    }

    @Test("passes limit, oldest and latest to conversations.history unchanged")
    func parameters() async throws {
        let transport = MethodTransport(["conversations.history": #"{"ok":true,"messages":[],"has_more":false}"#])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_conversation_history", arguments: [
            "conversation_id": .string("C01"), "limit": .int(200),
            "oldest": .string("1730000000.000100"), "latest": .string("1730000400"),
        ])

        expectJSON(result, #"{"conversation_id":"C01","has_more":false,"messages":[]}"#)
        #expect(transport.calls.map(\.parameters) == [
            ["channel": "C01", "limit": "200", "oldest": "1730000000.000100", "latest": "1730000400"],
        ])
    }

    @Test("a Slack error is an error result naming the workspace and Slack's code")
    func slackError() async throws {
        let transport = MethodTransport(["conversations.history": Fake.slackError("channel_not_found")])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_conversation_history",
                                            arguments: ["conversation_id": .string("C09")])

        expectError(result, containing: ["T01 alpha", "channel_not_found"])
    }

    @Test("an ok answer without a messages array, or with a message lacking ts, is an unexpected_response error",
          arguments: [#"{"ok":true}"#, #"{"ok":true,"messages":{}}"#,
                      #"{"ok":true,"messages":[{"type":"message","text":"no ts"}]}"#,
                      #"{"ok":true,"messages":[{"ts":1730000100.0001}]}"#])
    func unexpectedShape(body: String) async throws {
        let transport = MethodTransport(["conversations.history": body])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_conversation_history",
                                            arguments: ["conversation_id": .string("C01")])

        expectError(result, containing: ["T01 alpha", "unexpected_response"])
    }
}
