import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// Synthetic credentials and workspaces. Every assertion on a tool result
/// also checks that none of the secrets, raw or form-encoded, appears in it.
enum Fake {
    static let alphaToken = "xoxc-fake-alpha-1111"
    static let betaToken = "xoxc-fake-beta-2222"
    static let alphaCookie = "xoxd-fake%2Falpha%3D"
    static let betaCookie = "xoxd-fake%2Fbeta%3D"
    static let secrets = [alphaToken, betaToken, alphaCookie, betaCookie,
                          "xoxd-fake%252Falpha%253D", "xoxd-fake%252Fbeta%253D"]

    // The spec's example table: `T01 alpha`, `T02 beta`.
    static let alpha = SlackWorkspace(teamID: "T01", domain: "alpha", name: "Alpha", userID: "U01")
    static let beta = SlackWorkspace(teamID: "T02", domain: "beta", name: "Beta", userID: "U02")

    static func authTestOK(team: String, user: String) -> String {
        #"{"ok":true,"url":"https://x.slack.com/","team":"X","user":"me","team_id":"\#(team)","user_id":"\#(user)"}"#
    }

    static func slackError(_ code: String) -> String { #"{"ok":false,"error":"\#(code)"}"# }
}

/// An in-memory Keychain. Reads are recorded; a lookup result can be forced
/// per service. Writes and deletes are recorded and applied, so a test can
/// assert that a tool changed nothing.
final class MemoryKeychain: KeychainItemReader, KeychainItemWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]
    private var forced: [String: KeychainLookup] = [:]
    private var readLog: [String] = []
    private var changeLog: [String] = []

    init(_ items: [String: String] = [:]) { self.items = items }

    /// Services read, in order.
    var reads: [String] { lock.withLock { readLog } }
    /// Services written or deleted, in order.
    var changes: [String] { lock.withLock { changeLog } }

    func force(_ service: String, _ lookup: KeychainLookup) { lock.withLock { forced[service] = lookup } }

    func read(service: String) async -> KeychainLookup {
        lock.withLock {
            readLog.append(service)
            if let lookup = forced[service] { return lookup }
            return items[service].map(KeychainLookup.found) ?? .absent
        }
    }

    func write(service: String, value: String) async throws {
        lock.withLock {
            changeLog.append("write \(service)")
            items[service] = value
        }
    }

    func delete(service: String) async throws {
        lock.withLock {
            changeLog.append("delete \(service)")
            items[service] = nil
        }
    }

    /// A Keychain holding `workspaces` in the index and, for each, the token
    /// and cookie in `credentials` (by team id).
    static func with(_ workspaces: [SlackWorkspace],
                     credentials: [String: (token: String, cookie: String)] = Fake.defaultCredentials) async throws -> MemoryKeychain {
        let staging = MemoryKeychain()
        try await SlackCredentialStore(reader: staging, writer: staging).saveWorkspaces(workspaces)
        var items = ["SLACK_WORKSPACES": staging.items["SLACK_WORKSPACES"]!]
        for workspace in workspaces {
            guard let credential = credentials[workspace.teamID] else { continue }
            items["SLACK_TOKEN_\(workspace.teamID)"] = credential.token
            items["SLACK_COOKIE_\(workspace.teamID)"] = credential.cookie
        }
        return MemoryKeychain(items)
    }
}

extension Fake {
    static let defaultCredentials: [String: (token: String, cookie: String)] = [
        "T01": (alphaToken, alphaCookie),
        "T02": (betaToken, betaCookie),
    ]
}

/// What the fake transport answers for one token.
enum ScriptedAnswer: Sendable {
    case body(String)
    case response(status: Int, headers: [String: String], body: String)
    case fail(any Error & Sendable)
}

/// Answers by the token in the request body and records every request. A
/// token with no scripted answer gets `no_scripted_answer`, so a call the
/// test did not expect cannot pass as a success.
final class TokenTransport: SlackTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [String: ScriptedAnswer]
    private var sent: [URLRequest] = []

    init(_ answers: [String: ScriptedAnswer] = [:]) { self.answers = answers }

    var requests: [URLRequest] { lock.withLock { sent } }
    /// The token each request carried, in order.
    var tokens: [String] { requests.map(Self.token) }
    /// The Slack method each request called, in order.
    var methods: [String] { requests.map { $0.url?.lastPathComponent ?? "" } }

    static func token(_ request: URLRequest) -> String {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let field = body.split(separator: "&").first { $0.hasPrefix("token=") } ?? ""
        return String(field.dropFirst("token=".count)).removingPercentEncoding ?? ""
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        let answer = answers[Self.token(request)] ?? .body(Fake.slackError("no_scripted_answer"))
        switch answer {
        case let .body(body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case let .response(status, headers, body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        case let .fail(error):
            throw error
        }
    }
}

/// A clock whose sleeps return at once, so rate-limit retries take no time.
struct InstantClock: SlackClock {
    func now() -> Duration { .zero }
    func sleep(for duration: Duration) async throws { try Task.checkCancellation() }
}

/// A transport error whose description echoes whatever it was given.
struct EchoingTransportError: LocalizedError, Sendable {
    let text: String
    var errorDescription: String? { text }
}

/// A handler over `keychain` and `transport`, with no pacing delay.
func makeHandler(_ keychain: MemoryKeychain, _ transport: TokenTransport = TokenTransport()) -> SlackToolHandler {
    SlackToolHandler(
        store: SlackCredentialStore(reader: keychain, writer: keychain),
        client: SlackWebClient(transport: transport,
                               pacing: SlackPacingConfig(minIntervalMilliseconds: 0, maxConcurrency: 1)!,
                               clock: InstantClock()))
}

/// The text of every text item in `result`, joined by newlines.
func text(_ result: CallTool.Result) -> String {
    result.content.compactMap { content -> String? in
        if case let .text(text, _, _) = content { return text }
        return nil
    }.joined(separator: "\n")
}

/// The result's single text item decoded as JSON.
func json(_ result: CallTool.Result) throws -> Any {
    try JSONSerialization.jsonObject(with: Data(text(result).utf8))
}

/// Records that no fake credential appears anywhere in `result`, including
/// its structured content.
func expectNoSecrets(_ result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) {
    let encoded = (try? JSONEncoder().encode(result)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    for secret in Fake.secrets {
        #expect(!text(result).contains(secret), "result text contains a fake credential", sourceLocation: sourceLocation)
        #expect(!encoded.contains(secret), "encoded result contains a fake credential", sourceLocation: sourceLocation)
    }
}

/// Records that `result` is an error result whose text holds every phrase.
func expectError(_ result: CallTool.Result, containing phrases: [String],
                 sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(result.isError == true, "expected isError: true", sourceLocation: sourceLocation)
    for phrase in phrases {
        #expect(text(result).contains(phrase), "error text lacks \(String(reflecting: phrase)): \(text(result))",
                sourceLocation: sourceLocation)
    }
    expectNoSecrets(result, sourceLocation: sourceLocation)
}
