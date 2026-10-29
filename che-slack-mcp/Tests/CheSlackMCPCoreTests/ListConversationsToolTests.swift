import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-mcp-tools, "Conversation read tools": `list_conversations`.
@Suite("list_conversations")
struct ListConversationsToolTests {
    static let firstPageParameters = ["types": "public_channel,private_channel,mpim,im", "exclude_archived": "true",
                                      "limit": "200"]

    /// One of each kind the user is a member of, plus a legacy private
    /// channel that has `is_group` and no `is_private`.
    static let channels = #"""
        {"ok":true,"channels":[
          {"id":"C01","name":"general","is_channel":true,"is_group":false,"is_im":false,"is_mpim":false,"is_private":false},
          {"id":"G01","name":"secret-lab","is_channel":true,"is_group":false,"is_im":false,"is_mpim":false,"is_private":true},
          {"id":"D01","created":1700000000,"is_im":true,"is_org_shared":false,"user":"U02","is_user_deleted":false},
          {"id":"G02","name":"mpdm-che--alice--bob-1","is_channel":false,"is_group":false,"is_im":false,"is_mpim":true,"is_private":true},
          {"id":"G03","name":"old-private","is_group":true}
        ],"response_metadata":{"next_cursor":""}}
        """#

    @Test("returns each conversation's id, type and name, naming a direct message by the other user's display name")
    func fields() async throws {
        let transport = MethodTransport(["users.conversations": Self.channels, "users.info": UserJSON.alice])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "list_conversations", arguments: [:])

        expectJSON(result, #"{"conversations":[{"id":"C01","name":"general","type":"public_channel"},"#
            + #"{"id":"G01","name":"secret-lab","type":"private_channel"},"#
            + #"{"id":"D01","name":"Alice","type":"im","user_id":"U02"},"#
            + #"{"id":"G02","name":"mpdm-che--alice--bob-1","type":"mpim"},"#
            + #"{"id":"G03","name":"old-private","type":"private_channel"}],"has_more":false}"#)
        #expect(transport.calls == [
            SlackCall(method: "users.conversations", parameters: Self.firstPageParameters, token: Fake.alphaToken),
            SlackCall(method: "users.info", parameters: ["user": "U02"], token: Fake.alphaToken),
        ])
    }

    static func dm(_ id: String, _ user: String) -> String { #"{"id":"\#(id)","is_im":true,"user":"\#(user)"}"# }

    static func page(_ entries: [String], next: String) -> String {
        #"{"ok":true,"channels":[\#(entries.joined(separator: ","))],"response_metadata":{"next_cursor":"\#(next)"}}"#
    }

    static func person(_ id: String, display: String, real: String) -> String {
        #"{"ok":true,"user":{"id":"\#(id)","name":"h-\#(id)","real_name":"\#(real)","is_bot":false,"profile":{"display_name":"\#(display)","real_name":"\#(real)"}}}"#
    }

    @Test("follows next_cursor across pages, and a user without a display name is named by real name")
    func pages() async throws {
        let transport = MethodTransport { call in
            switch (call.method, call.parameters["cursor"]) {
            case ("users.conversations", nil): return .body(Self.page([#"{"id":"C01","name":"general"}"#], next: "c2"))
            case ("users.conversations", "c2"): return .body(Self.page([Self.dm("D03", "U03")], next: ""))
            case ("users.info", _): return .body(Self.person("U03", display: "", real: "Bob Lin"))
            default: return .body(Fake.slackError("no_scripted_answer"))
            }
        }
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "list_conversations", arguments: [:])

        expectJSON(result, #"{"conversations":[{"id":"C01","name":"general","type":"public_channel"},"#
            + #"{"id":"D03","name":"Bob Lin","type":"im","user_id":"U03"}],"has_more":false}"#)
        var second = Self.firstPageParameters
        second["cursor"] = "c2"
        #expect(transport.calls.map(\.parameters) == [Self.firstPageParameters, second, ["user": "U03"]])
    }

    @Test("stops after 10 pages of 200 and reports has_more when Slack still offers a cursor")
    func pageCap() async throws {
        let transport = MethodTransport { call in
            let page = call.parameters["cursor"].flatMap { Int($0.dropFirst()) } ?? 0
            return .body(Self.page([#"{"id":"C\#(page)","name":"c\#(page)"}"#], next: "p\(page + 1)"))
        }
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "list_conversations", arguments: [:])

        #expect(result.isError == false)
        #expect(transport.methods == Array(repeating: "users.conversations", count: 10))
        let answer = try #require(try json(result) as? [String: Any])
        #expect(answer["has_more"] as? Bool == true)
        #expect((answer["conversations"] as? [Any])?.count == 10)
        expectNoSecrets(result)
    }

    @Test("a direct message whose user Slack cannot look up is listed with name_error instead of a name")
    func lookupSlackError() async throws {
        let transport = MethodTransport { call in
            switch call.method {
            case "users.conversations": return .body(Self.page([Self.dm("D01", "U02"), Self.dm("D09", "U09")], next: ""))
            case "users.info" where call.parameters["user"] == "U02": return .body(UserJSON.alice)
            default: return .body(Fake.slackError("user_not_found"))
            }
        }
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "list_conversations", arguments: [:])

        expectJSON(result, #"{"conversations":[{"id":"D01","name":"Alice","type":"im","user_id":"U02"},"#
            + #"{"id":"D09","name_error":"user_not_found","type":"im","user_id":"U09"}],"has_more":false}"#)
    }

    @Test("a direct message without a user field is listed with name_error no_user, and nothing is looked up")
    func directMessageWithoutUser() async throws {
        let transport = MethodTransport(["users.conversations": Self.page([#"{"id":"D05","is_im":true}"#], next: "")])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "list_conversations", arguments: [:])

        expectJSON(result, #"{"conversations":[{"id":"D05","name_error":"no_user","type":"im"}],"has_more":false}"#)
        #expect(transport.methods == ["users.conversations"])
    }

    @Test("a session that fails during a name lookup fails the whole call with the session message")
    func lookupSessionInvalid() async throws {
        let transport = MethodTransport { call in
            call.method == "users.conversations"
                ? .body(Self.page([Self.dm("D01", "U02"), Self.dm("D09", "U09")], next: ""))
                : .body(Fake.slackError("invalid_auth"))
        }
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "list_conversations", arguments: [:])

        expectError(result, containing: ["T01 alpha", "invalid_auth", "slack-all auth import --from-desktop"])
        #expect(transport.methods == ["users.conversations", "users.info"])
    }

    @Test("looks up at most 50 users per call; later direct messages get name_error lookup_limit")
    func lookupCap() async throws {
        let users = (100...150).map { "U\($0)" }
        let transport = MethodTransport { call in
            if call.method == "users.conversations" {
                return .body(Self.page(users.map { Self.dm("D\($0.dropFirst())", $0) }, next: ""))
            }
            let user = call.parameters["user"] ?? ""
            return .body(Self.person(user, display: "n\(user)", real: "R"))
        }
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "list_conversations", arguments: [:])

        #expect(result.isError == false)
        #expect(transport.calls.filter { $0.method == "users.info" }.map { $0.parameters["user"] } == users.prefix(50).map { $0 })
        let listed = try #require((try json(result) as? [String: Any])?["conversations"] as? [[String: Any]])
        #expect(listed.count == 51)
        #expect(listed[49]["name"] as? String == "nU149")
        #expect(listed[50]["name"] == nil)
        #expect(listed[50]["name_error"] as? String == "lookup_limit")
        expectNoSecrets(result)
    }

    @Test("looks up each user once per call")
    func cache() async throws {
        let transport = MethodTransport { call in
            call.method == "users.conversations"
                ? .body(Self.page([Self.dm("D01", "U02"), Self.dm("D02", "U02")], next: ""))
                : .body(UserJSON.alice)
        }
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "list_conversations", arguments: [:])

        expectJSON(result, #"{"conversations":[{"id":"D01","name":"Alice","type":"im","user_id":"U02"},"#
            + #"{"id":"D02","name":"Alice","type":"im","user_id":"U02"}],"has_more":false}"#)
        #expect(transport.methods == ["users.conversations", "users.info"])
    }

    @Test("an ok answer without channels, or a channel without an id, is an unexpected_response error",
          arguments: [#"{"ok":true}"#, #"{"ok":true,"channels":[{"name":"general"}]}"#,
                      #"{"ok":true,"channels":[{"id":"C01","is_im":"yes"}]}"#])
    func unexpectedShape(body: String) async throws {
        let transport = MethodTransport(["users.conversations": body])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "list_conversations", arguments: [:])

        expectError(result, containing: ["unexpected_response"])
    }
}
