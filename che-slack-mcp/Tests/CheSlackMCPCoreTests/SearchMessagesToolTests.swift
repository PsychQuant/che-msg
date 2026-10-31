import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-mcp-tools, "Message search".
@Suite("search_messages")
struct SearchMessagesToolTests {
    /// A `search.messages` answer: a channel match and a direct-message
    /// match (whose channel name is the other user's id, as Slack sends it).
    static let answer = #"""
        {"ok":true,"query":"ignored","messages":{"total":2,
          "paging":{"count":20,"total":2,"page":1,"pages":1},
          "matches":[
            {"iid":"a1","team":"T01","channel":{"id":"C01","is_channel":true,"name":"general","is_private":false},"type":"message",
             "user":"U02","username":"alice.chen","ts":"1730000300.000300","text":"deploy done",
             "permalink":"https://alpha.slack.com/archives/C01/p1730000300000300"},
            {"iid":"a2","team":"T01","channel":{"id":"D01","is_im":true,"name":"U02"},"type":"message",
             "user":"U01","username":"che","ts":"1730000200.000200","text":"deploy now?",
             "permalink":"https://alpha.slack.com/archives/D01/p1730000200000200"}
          ]}}
        """#

    static let expected = #"{"matches":["#
        + #"{"conversation_id":"C01","conversation_name":"general","permalink":"https://alpha.slack.com/archives/C01/p1730000300000300","#
        + #""sender_name":"alice.chen","text":"deploy done","ts":"1730000300.000300","user_id":"U02"},"#
        + #"{"conversation_id":"D01","conversation_name":"U02","permalink":"https://alpha.slack.com/archives/D01/p1730000200000200","#
        + #""sender_name":"che","text":"deploy now?","ts":"1730000200.000200","user_id":"U01"}],"total":2}"#

    @Test("passes the query unchanged with count 20 by default, and returns each match's conversation id and name, ts, sender, text and permalink")
    func fields() async throws {
        let query = "in:#general from:@alice  deploy \"done\" "
        let transport = MethodTransport(["search.messages": Self.answer])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "search_messages", arguments: ["query": .string(query)])

        expectJSON(result, Self.expected)
        #expect(transport.calls == [SlackCall(method: "search.messages", parameters: ["query": query, "count": "20"],
                                              token: Fake.alphaToken)])
    }

    @Test("count is sent as given within 1 to 100", arguments: [1, 100])
    func count(count: Int) async throws {
        let transport = MethodTransport(["search.messages": #"{"ok":true,"messages":{"total":0,"matches":[]}}"#])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "search_messages",
                                            arguments: ["query": .string("deploy"), "count": .int(count)])

        expectJSON(result, #"{"matches":[],"total":0}"#)
        #expect(transport.calls.map(\.parameters) == [["query": "deploy", "count": String(count)]])
    }

    @Test("refuses a missing, blank or non-string query and a count outside 1 to 100, naming the argument, without a request",
          arguments: [
              ("query", [:]), ("query", ["query": .string("")]), ("query", ["query": .string(" \n\t ")]),
              ("query", ["query": .int(5)]), ("query", ["query": .null]),
              ("count", ["query": .string("deploy"), "count": .int(0)]),
              ("count", ["query": .string("deploy"), "count": .int(101)]),
              ("count", ["query": .string("deploy"), "count": .string("20")]),
              ("count", ["query": .string("deploy"), "count": .double(1.5)]),
          ] as [(String, [String: Value])])
    func refusals(names: String, arguments: [String: Value]) async throws {
        let transport = MethodTransport([:])
        let (handler, keychain) = try await readHandler(transport)

        let result = await handler.callTool(name: "search_messages", arguments: arguments)

        expectRefused(result, naming: names, transport: transport, keychain: keychain)
    }

    @Test("a Slack error is an error result naming Slack's code")
    func slackError() async throws {
        let transport = MethodTransport(["search.messages": Fake.slackError("not_allowed_token_type")])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "search_messages", arguments: ["query": .string("deploy")])

        expectError(result, containing: ["T01 alpha", "not_allowed_token_type"])
    }

    @Test("an ok answer without messages.matches, or a match without ts, is an unexpected_response error",
          arguments: [#"{"ok":true}"#, #"{"ok":true,"messages":{"total":3}}"#,
                      #"{"ok":true,"messages":{"matches":[{"text":"no ts","channel":{"id":"C01"}}]}}"#])
    func unexpectedShape(body: String) async throws {
        let transport = MethodTransport(["search.messages": body])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "search_messages", arguments: ["query": .string("deploy")])

        expectError(result, containing: ["unexpected_response"])
    }
}
