import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// One request the fake Slack received: the method, its form parameters
/// without the token, and the token on its own.
struct SlackCall: Equatable, Sendable, CustomStringConvertible {
    let method: String
    let parameters: [String: String]
    let token: String

    var description: String { "\(method) \(parameters.sorted { $0.key < $1.key })" }
}

/// Answers by Slack method (and, through the closure, by parameters) and
/// records every request. A method with no scripted answer gets
/// `no_scripted_answer`, so a call the test did not expect cannot pass as a
/// success.
final class MethodTransport: SlackTransport, @unchecked Sendable {
    typealias Responder = @Sendable (SlackCall) -> ScriptedAnswer

    private let lock = NSLock()
    private let respond: Responder
    private var log: [SlackCall] = []

    init(_ respond: @escaping Responder) { self.respond = respond }

    /// One fixed body per method.
    convenience init(_ bodies: [String: String]) {
        self.init { call in .body(bodies[call.method] ?? Fake.slackError("no_scripted_answer")) }
    }

    var calls: [SlackCall] { lock.withLock { log } }
    var methods: [String] { calls.map(\.method) }

    /// The request as the fake sees it, decoding the form body.
    static func call(from request: URLRequest) -> SlackCall {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        var fields: [String: String] = [:]
        for pair in body.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0]).removingPercentEncoding ?? ""
            fields[key] = parts.count > 1 ? (String(parts[1]).removingPercentEncoding ?? "") : ""
        }
        let token = fields.removeValue(forKey: "token") ?? ""
        return SlackCall(method: request.url?.lastPathComponent ?? "", parameters: fields, token: token)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let call = Self.call(from: request)
        lock.withLock { log.append(call) }
        switch respond(call) {
        case let .body(body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        case let .response(status, headers, body):
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
        case let .fail(error):
            throw error
        }
    }
}

/// A one-workspace (`T01 alpha`) handler over `transport`, and its Keychain.
func readHandler(_ transport: MethodTransport) async throws -> (SlackToolHandler, MemoryKeychain) {
    let keychain = try await MemoryKeychain.with([Fake.alpha])
    let handler = SlackToolHandler(
        store: SlackCredentialStore(reader: keychain, writer: keychain),
        client: SlackWebClient(transport: transport,
                               pacing: SlackPacingConfig(minIntervalMilliseconds: 0, maxConcurrency: 1)!,
                               clock: InstantClock()))
    return (handler, keychain)
}

/// Records that `result` is a success whose text is exactly `expected`
/// (sorted keys, no whitespace), and holds no fake credential.
func expectJSON(_ result: CallTool.Result, _ expected: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(result.isError == false, "expected a success: \(text(result))", sourceLocation: sourceLocation)
    #expect(text(result) == expected, sourceLocation: sourceLocation)
    expectNoSecrets(result, sourceLocation: sourceLocation)
}

/// Records that `result` is an error naming `argument`, and that neither
/// Slack nor the Keychain was touched.
func expectRefused(_ result: CallTool.Result, naming argument: String, transport: MethodTransport,
                   keychain: MemoryKeychain, sourceLocation: SourceLocation = #_sourceLocation) {
    expectError(result, containing: [argument], sourceLocation: sourceLocation)
    #expect(transport.calls.isEmpty, "a refused call reached Slack: \(transport.calls)", sourceLocation: sourceLocation)
    #expect(keychain.reads.isEmpty, "a refused call read the Keychain: \(keychain.reads)", sourceLocation: sourceLocation)
}
