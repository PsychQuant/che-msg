import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// `users.info` answers for a person and a bot.
enum UserJSON {
    static let alice = #"{"ok":true,"user":{"id":"U02","team_id":"T01","name":"alice.chen","deleted":false,"real_name":"Alice Chen","#
        + #""is_bot":false,"profile":{"display_name":"Alice","real_name":"Alice Chen","email":"alice@example.com","phone":"0912"}}}"#
    /// A bot whose display name is empty and whose real name is only in the profile.
    static let bot = #"{"ok":true,"user":{"id":"U09","name":"deploybot","is_bot":true,"profile":{"display_name":"","real_name":"Deploy Bot"}}}"#
}

/// spec: slack-mcp-tools, "Conversation read tools": `get_user`.
@Suite("get_user")
struct UserToolTests {
    @Test("returns the display name, real name and whether the account is a bot, and no other profile field",
          arguments: [
              ("U02", UserJSON.alice, #"{"display_name":"Alice","is_bot":false,"real_name":"Alice Chen","user_id":"U02"}"#),
              ("U09", UserJSON.bot, #"{"display_name":"","is_bot":true,"real_name":"Deploy Bot","user_id":"U09"}"#),
          ])
    func fields(userID: String, body: String, expected: String) async throws {
        let transport = MethodTransport(["users.info": body])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_user", arguments: ["user_id": .string(userID)])

        expectJSON(result, expected)
        #expect(!text(result).contains("example.com") && !text(result).contains("0912"))
        #expect(transport.calls == [SlackCall(method: "users.info", parameters: ["user": userID], token: Fake.alphaToken)])
    }

    @Test("a Slack error is an error result naming Slack's code")
    func slackError() async throws {
        let transport = MethodTransport(["users.info": Fake.slackError("user_not_found")])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_user", arguments: ["user_id": .string("U99")])

        expectError(result, containing: ["T01 alpha", "user_not_found"])
    }

    @Test("an ok answer without a user, or a user without an id, is an unexpected_response error",
          arguments: [#"{"ok":true}"#, #"{"ok":true,"user":{"name":"x"}}"#, #"{"ok":true,"user":{"id":"U02","is_bot":"no"}}"#])
    func unexpectedShape(body: String) async throws {
        let transport = MethodTransport(["users.info": body])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_user", arguments: ["user_id": .string("U02")])

        expectError(result, containing: ["unexpected_response"])
    }

    @Test("refuses a missing or malformed user_id, naming it, without a request",
          arguments: [[:], ["user_id": .string("@alice")], ["user_id": .int(2)], ["user_id": .string("")]]
              as [[String: Value]])
    func refusals(arguments: [String: Value]) async throws {
        let transport = MethodTransport([:])
        let (handler, keychain) = try await readHandler(transport)

        let result = await handler.callTool(name: "get_user", arguments: arguments)

        expectRefused(result, naming: "user_id", transport: transport, keychain: keychain)
    }
}
