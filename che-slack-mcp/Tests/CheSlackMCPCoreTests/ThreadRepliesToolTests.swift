import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-mcp-tools, "Conversation read tools": `get_thread_replies`.
@Suite("get_thread_replies")
struct ThreadRepliesToolTests {
    static let parent = #"{"type":"message","user":"U02","text":"question","ts":"1730000300.000300","thread_ts":"1730000300.000300","reply_count":2}"#
    static let firstReply = #"{"type":"message","user":"U03","text":"answer 1","ts":"1730000310.000310","thread_ts":"1730000300.000300"}"#
    static let secondReply = #"{"type":"message","user":"U02","text":"answer 2","ts":"1730000320.000320","thread_ts":"1730000300.000300"}"#

    /// Two pages; the second repeats the parent, as Slack may.
    static let pages: MethodTransport.Responder = { call in
        guard call.method == "conversations.replies" else { return .body(Fake.slackError("no_scripted_answer")) }
        switch call.parameters["cursor"] {
        case nil:
            return .body(#"{"ok":true,"messages":[\#(parent),\#(firstReply)],"has_more":true,"response_metadata":{"next_cursor":"c2"}}"#)
        case "c2":
            return .body(#"{"ok":true,"messages":[\#(parent),\#(secondReply)],"has_more":false,"response_metadata":{"next_cursor":""}}"#)
        default:
            return .body(Fake.slackError("invalid_cursor"))
        }
    }

    @Test("returns the parent then its replies oldest first, following next_cursor and listing the parent once")
    func parentThenReplies() async throws {
        let transport = MethodTransport(Self.pages)
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_thread_replies", arguments: [
            "conversation_id": .string("C01"), "thread_ts": .string("1730000300.000300"),
        ])

        expectJSON(result, #"{"conversation_id":"C01","has_more":false,"messages":["#
            + #"{"reply_count":2,"text":"question","thread_ts":"1730000300.000300","ts":"1730000300.000300","user_id":"U02"},"#
            + #"{"text":"answer 1","thread_ts":"1730000300.000300","ts":"1730000310.000310","user_id":"U03"},"#
            + #"{"text":"answer 2","thread_ts":"1730000300.000300","ts":"1730000320.000320","user_id":"U02"}],"#
            + #""thread_ts":"1730000300.000300"}"#)
        #expect(transport.calls == [
            SlackCall(method: "conversations.replies",
                      parameters: ["channel": "C01", "ts": "1730000300.000300", "limit": "200"], token: Fake.alphaToken),
            SlackCall(method: "conversations.replies",
                      parameters: ["channel": "C01", "ts": "1730000300.000300", "limit": "200", "cursor": "c2"],
                      token: Fake.alphaToken),
        ])
    }

    @Test("stops after 5 pages of 200 and reports has_more when Slack still offers a cursor")
    func pageCap() async throws {
        let transport = MethodTransport { call in
            let page = call.parameters["cursor"].flatMap { Int($0.dropFirst()) } ?? 0
            return .body(#"{"ok":true,"messages":[{"ts":"1730000300.00030\#(page)","text":"m\#(page)"}],"#
                         + #""has_more":true,"response_metadata":{"next_cursor":"p\#(page + 1)"}}"#)
        }
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_thread_replies", arguments: [
            "conversation_id": .string("C01"), "thread_ts": .string("1730000300.000300"),
        ])

        #expect(result.isError == false)
        #expect(transport.calls.count == 5)
        #expect(transport.calls.map { $0.parameters["cursor"] } == [nil, "p1", "p2", "p3", "p4"])
        let answer = try #require(try json(result) as? [String: Any])
        #expect(answer["has_more"] as? Bool == true)
        #expect((answer["messages"] as? [Any])?.count == 5)
        expectNoSecrets(result)
    }

    @Test("a Slack error on a later page is an error result, not a partial thread")
    func laterPageError() async throws {
        let transport = MethodTransport { call in
            call.parameters["cursor"] == nil
                ? .body(#"{"ok":true,"messages":[\#(Self.parent)],"response_metadata":{"next_cursor":"c2"}}"#)
                : .body(Fake.slackError("thread_not_found"))
        }
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_thread_replies", arguments: [
            "conversation_id": .string("C01"), "thread_ts": .string("1730000300.000300"),
        ])

        expectError(result, containing: ["T01 alpha", "thread_not_found"])
        #expect(transport.calls.count == 2)
    }

    @Test("refuses a missing or malformed thread_ts or conversation_id, naming it, without a request",
          arguments: [
              ("thread_ts", ["conversation_id": .string("C01")]),
              ("thread_ts", ["conversation_id": .string("C01"), "thread_ts": .double(1730000300.0003)]),
              ("thread_ts", ["conversation_id": .string("C01"), "thread_ts": .string("latest")]),
              ("conversation_id", ["thread_ts": .string("1730000300.000300")]),
              ("conversation_id", ["conversation_id": .string("#general"), "thread_ts": .string("1730000300.000300")]),
          ] as [(String, [String: Value])])
    func refusals(names: String, arguments: [String: Value]) async throws {
        let transport = MethodTransport([:])
        let (handler, keychain) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_thread_replies", arguments: arguments)

        expectRefused(result, naming: names, transport: transport, keychain: keychain)
    }
}
