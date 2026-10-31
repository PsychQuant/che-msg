import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-mcp-tools, "Send message".
@Suite("send_message")
struct SendMessageToolTests {
    /// A `chat.postMessage` answer for a new message `ts` in `channel`.
    static func posted(channel: String = "C01", ts: String = "1730000000.000200") -> String {
        #"{"ok":true,"channel":"\#(channel)","ts":"\#(ts)","#
            + #""message":{"type":"message","user":"U01","text":"收到","ts":"\#(ts)"}}"#
    }

    /// spec: "Reply in a thread".
    @Test("C01, 收到 and thread_ts 1730000000.000100 post with channel, text and thread_ts, and return the new ts")
    func replyInThread() async throws {
        let transport = MethodTransport(["chat.postMessage": Self.posted()])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "send_message", arguments: [
            "conversation_id": .string("C01"), "text": .string("收到"), "thread_ts": .string("1730000000.000100"),
        ])

        expectJSON(result, #"{"conversation_id":"C01","ts":"1730000000.000200"}"#)
        #expect(transport.calls == [
            SlackCall(method: "chat.postMessage",
                      parameters: ["channel": "C01", "text": "收到", "thread_ts": "1730000000.000100"],
                      token: Fake.alphaToken),
        ])
    }
}

/// What `send_message` sends and returns besides the spec scenario.
@Suite("send_message requests")
struct SendMessageRequestTests {
    @Test("without thread_ts (omitted or null) only channel and text are sent, so the message goes to the conversation",
          arguments: [nil, Value.null])
    func topLevel(threadTS: Value?) async throws {
        let transport = MethodTransport(["chat.postMessage": SendMessageToolTests.posted()])
        let (handler, _) = try await readHandler(transport)
        var arguments: [String: Value] = ["conversation_id": .string("C01"), "text": .string("收到")]
        arguments["thread_ts"] = threadTS

        let result = await handler.callTool(name: "send_message", arguments: arguments)

        expectJSON(result, #"{"conversation_id":"C01","ts":"1730000000.000200"}"#)
        #expect(transport.calls.map(\.parameters) == [["channel": "C01", "text": "收到"]])
    }

    @Test("text is sent exactly as given: surrounding whitespace, newlines, Slack markup and form-encoding characters")
    func textUnchanged() async throws {
        let message = "  <@U02> *done* & 100% = ok?\n第二行\t "
        let transport = MethodTransport(["chat.postMessage": SendMessageToolTests.posted()])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "send_message", arguments: [
            "conversation_id": .string("C01"), "text": .string(message),
        ])

        #expect(result.isError == false)
        #expect(transport.calls.map { $0.parameters["text"] } == [message])
        expectNoSecrets(result)
    }

    @Test("the conversation id returned is the one Slack answers with (a user id posts to the direct message)")
    func slackChannel() async throws {
        let transport = MethodTransport(["chat.postMessage": SendMessageToolTests.posted(channel: "D01")])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "send_message", arguments: [
            "conversation_id": .string("U02"), "text": .string("hi"),
        ])

        expectJSON(result, #"{"conversation_id":"D01","ts":"1730000000.000200"}"#)
        #expect(transport.calls.map(\.parameters) == [["channel": "U02", "text": "hi"]])
    }

    @Test("with two workspaces imported and workspace given, the named workspace's token posts")
    func namedWorkspace() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha, Fake.beta])
        let transport = TokenTransport([Fake.betaToken: .body(SendMessageToolTests.posted())])

        let result = await makeHandler(keychain, transport).callTool(name: "send_message", arguments: [
            "workspace": .string("beta"), "conversation_id": .string("C01"), "text": .string("hi"),
        ])

        expectJSON(result, #"{"conversation_id":"C01","ts":"1730000000.000200"}"#)
        #expect(transport.tokens == [Fake.betaToken])
        #expect(transport.methods == ["chat.postMessage"])
    }

    @Test("with two workspaces imported and no workspace, nothing is posted and both are listed")
    func ambiguousWorkspace() async throws {
        let keychain = try await MemoryKeychain.with([Fake.alpha, Fake.beta])
        let transport = TokenTransport()

        let result = await makeHandler(keychain, transport).callTool(name: "send_message", arguments: [
            "conversation_id": .string("C01"), "text": .string("hi"),
        ])

        expectError(result, containing: ["T01 alpha", "T02 beta"])
        #expect(transport.requests.isEmpty)
    }
}

/// `text` is at most 40000 characters, counted as UTF-16 code units (an
/// emoji outside the Basic Multilingual Plane counts as 2). The strings are
/// built by hand so the count is known without the code under test.
@Suite("send_message text length")
struct SendMessageLengthTests {
    @Test("text of exactly 40000 UTF-16 units is posted unchanged",
          arguments: [String(repeating: "a", count: 40000), String(repeating: "收", count: 40000),
                      String(repeating: "😀", count: 20000)])
    func atLimit(message: String) async throws {
        #expect(message.utf16.count == 40000)
        let transport = MethodTransport(["chat.postMessage": SendMessageToolTests.posted()])
        let (handler, _) = try await readHandler(transport)

        let result = await handler.callTool(name: "send_message", arguments: [
            "conversation_id": .string("C01"), "text": .string(message),
        ])

        #expect(result.isError == false)
        #expect(transport.calls.map { $0.parameters["text"] } == [message])
        expectNoSecrets(result)
    }

    /// The emoji row has 20001 Characters and 20001 Unicode scalars but
    /// 40002 UTF-16 units: counting Characters would let it through.
    @Test("text over 40000 UTF-16 units is refused naming text, without a Keychain read or request",
          arguments: [String(repeating: "a", count: 40001), String(repeating: "收", count: 40001),
                      String(repeating: "😀", count: 20000) + "a", String(repeating: "😀", count: 20001)])
    func overLimit(message: String) async throws {
        #expect(message.utf16.count > 40000 && message.count <= 40001)
        let transport = MethodTransport([:])
        let (handler, keychain) = try await readHandler(transport)

        let result = await handler.callTool(name: "send_message", arguments: [
            "conversation_id": .string("C01"), "text": .string(message),
        ])

        expectRefused(result, naming: "text", transport: transport, keychain: keychain)
        expectError(result, containing: ["40000", "UTF-16"])
    }
}

/// spec: an argument outside its allowed form is an error naming it, and
/// Slack is not called; checked before the Keychain is read.
@Suite("send_message arguments")
struct SendMessageArgumentTests {
    static func call(_ names: String, _ value: Value?) -> (String, [String: Value]) {
        var arguments: [String: Value] = ["conversation_id": .string("C01"), "text": .string("收到"),
                                          "thread_ts": .string("1730000000.000100")]
        arguments[names] = value
        return (names, arguments)
    }

    /// Blank text (whitespace-only includes newlines, tabs and the
    /// ideographic space), and wrong JSON types: a number is not read as a
    /// string or a timestamp.
    static let refusals: [(String, [String: Value])] = [
        call("text", nil), call("text", .null), call("text", .string("")), call("text", .string("   ")),
        call("text", .string(" \n\t\r ")), call("text", .string("\u{3000}")), call("text", .int(5)),
        call("text", .double(1.5)), call("text", .bool(true)), call("text", .array([.string("收到")])),
        call("thread_ts", .double(1730000000.0001)), call("thread_ts", .int(1730000000)),
        call("thread_ts", .string("latest")), call("thread_ts", .string("")), call("thread_ts", .string("1730000000.")),
        call("conversation_id", nil), call("conversation_id", .string("#general")),
        call("conversation_id", .string("@alice")), call("conversation_id", .string("")),
        call("conversation_id", .int(42)),
    ]

    @Test("refuses a missing, blank or wrongly typed argument, naming it, before any Keychain read or request",
          arguments: refusals)
    func refusal(names: String, arguments: [String: Value]) async throws {
        let transport = MethodTransport([:])
        let (handler, keychain) = try await readHandler(transport)

        let result = await handler.callTool(name: "send_message", arguments: arguments)

        expectRefused(result, naming: names, transport: transport, keychain: keychain)
    }
}

/// Slack refusing the message is an error result naming Slack's error and
/// the workspace; the post is sent once and not retried. Slack said no, so
/// the result does not suggest the message may have been posted, except
/// after `internal_error` and `fatal_error`.
@Suite("send_message Slack errors")
struct SendMessageSlackErrorTests {
    static let mayHavePosted = "may have been posted"

    static func send(_ transport: MethodTransport) async throws -> CallTool.Result {
        let (handler, _) = try await readHandler(transport)
        return await handler.callTool(name: "send_message", arguments: [
            "conversation_id": .string("C01"), "text": .string("收到"),
        ])
    }

    @Test("a Slack error is an error result naming the workspace and Slack's error, after exactly one request",
          arguments: [("channel_not_found", [String]()), ("not_in_channel", []), ("is_archived", []),
                      ("msg_too_long", []), ("no_text", []), ("restricted_action", []),
                      ("invalid_auth", ["slack-all auth import", "slack-all auth import --from-desktop"]),
                      ("enterprise_is_restricted", ["Slack's official MCP server"])])
    func slackError(code: String, phrases: [String]) async throws {
        let transport = MethodTransport(["chat.postMessage": Fake.slackError(code)])

        let result = try await Self.send(transport)

        expectError(result, containing: ["T01 alpha", code] + phrases)
        #expect(!text(result).contains(Self.mayHavePosted))
        #expect(transport.methods == ["chat.postMessage"])
    }

    @Test("rate limiting is retried 3 times, then an error result; Slack posts nothing it rate limits")
    func rateLimited() async throws {
        let transport = MethodTransport { _ in .response(status: 429, headers: ["Retry-After": "7"], body: "") }

        let result = try await Self.send(transport)

        expectError(result, containing: ["T01 alpha", "rate limiting", "7 s"])
        #expect(!text(result).contains(Self.mayHavePosted))
        #expect(transport.methods == Array(repeating: "chat.postMessage", count: 4))
    }

    /// The request may have reached Slack, but no answer saying what
    /// happened came back: the error says so, so the caller checks the
    /// conversation instead of posting the same message twice. Not retried.
    @Test("a failure after which Slack may have posted the message says so, after exactly one request",
          arguments: [
              (ScriptedAnswer.fail(EchoingTransportError(text: "connection reset sending \(Fake.alphaToken)")),
               "Network error"),
              (.body("<html>Service Unavailable</html>"), "invalid_json"),
              (.response(status: 502, headers: [:], body: "<html>Bad Gateway</html>"), "http_502"),
              (.body(#"{"ok":true,"channel":"C01"}"#), "unexpected_response"),
              (.body(#"{"ok":true,"ts":"1730000000.000200"}"#), "unexpected_response"),
              (.body(#"{"ok":true,"channel":"C01","ts":1730000000.0002}"#), "unexpected_response"),
          ])
    func outcomeUnknown(answer: ScriptedAnswer, phrase: String) async throws {
        let transport = MethodTransport { _ in answer }

        let result = try await Self.send(transport)

        expectError(result, containing: ["T01 alpha", phrase, Self.mayHavePosted])
        #expect(transport.methods == ["chat.postMessage"])
    }

    /// spec: "internal_error may have posted". Slack's chat.postMessage
    /// reference says that after `internal_error` or `fatal_error` part of
    /// the operation may have succeeded, so these two `ok: false` codes do
    /// not mean "nothing was sent"; `channel_not_found` still does.
    @Test("internal_error and fatal_error say the message may have been posted; channel_not_found does not",
          arguments: [("internal_error", true), ("fatal_error", true), ("channel_not_found", false)])
    func okFalseMayHavePosted(code: String, mayHavePosted: Bool) async throws {
        let transport = MethodTransport(["chat.postMessage": Fake.slackError(code)])

        let result = try await Self.send(transport)

        expectError(result, containing: ["T01 alpha", code])
        #expect(text(result).contains(Self.mayHavePosted) == mayHavePosted)
        #expect(text(result).contains("get_conversation_history before sending it again") == mayHavePosted)
        #expect(transport.methods == ["chat.postMessage"])
    }
}
