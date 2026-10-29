import Foundation
import Testing
import SlackAllCore
import SlackWebLib

/// Synthetic credentials. Every output assertion checks none of these, raw
/// or form-encoded, appears.
enum Fake {
    static let alphaToken = "xoxc-fake-alpha-1111"
    static let betaToken = "xoxc-fake-beta-2222"
    static let cookie = "xoxd-fake%2Fcookie%3D"
    static let secrets = [alphaToken, betaToken, cookie, "xoxd-fake%252Fcookie%253D"]

    static let alpha = SlackWorkspace(teamID: "T01", domain: "alpha", name: "Alpha", userID: "U01")
    static let beta = SlackWorkspace(teamID: "T02", domain: "beta", name: "Beta", userID: "U02")

    /// What the console command copies for `alpha` and `beta`.
    static let clipboardList = """
        [{"id":"T01","domain":"alpha","name":"Alpha","token":"\(alphaToken)","user_id":"U01"},\
        {"id":"T02","domain":"beta","name":"Beta","token":"\(betaToken)","user_id":"U02"}]
        """

    static func authTestOK(team: String, user: String) -> String {
        #"{"ok":true,"url":"https://x.slack.com/","team":"X","user":"me","team_id":"\#(team)","user_id":"\#(user)"}"#
    }

    static let invalidAuth = #"{"ok":false,"error":"invalid_auth"}"#
}

/// Records that no secret appears in any line or in the error.
func expectNoSecrets(_ lines: [String], _ error: (any Error)? = nil) {
    let texts = lines + (error.map { ["\($0)"] } ?? [])
    for secret in Fake.secrets {
        #expect(!texts.contains { $0.contains(secret) }, "output contains a fake credential")
    }
}

/// An in-memory clipboard. `copy` stands for the user copying something.
final class FakeClipboard: SlackClipboard, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: String?
    private var clearCount = 0

    init(_ contents: String? = nil) { self.contents = contents }

    func copy(_ text: String?) { lock.withLock { contents = text } }
    var current: String? { lock.withLock { contents } }
    var clears: Int { lock.withLock { clearCount } }

    func text() -> String? { lock.withLock { contents } }

    func clear() {
        lock.withLock {
            contents = nil
            clearCount += 1
        }
    }
}

/// A terminal whose user, at each Enter, has just copied the next entry of
/// `copies` to the clipboard. Once the entries run out, input has ended.
final class ScriptedTerminal: SlackAuthTerminal, @unchecked Sendable {
    private let lock = NSLock()
    private let clipboard: FakeClipboard
    private var copies: [String?]
    private var said: [String] = []
    private var enterCount = 0

    init(clipboard: FakeClipboard, copies: [String?] = []) {
        self.clipboard = clipboard
        self.copies = copies
    }

    var lines: [String] { lock.withLock { said } }
    var enters: Int { lock.withLock { enterCount } }

    func say(_ line: String) { lock.withLock { said.append(line) } }

    func waitForEnter() -> Bool {
        let next: String?? = lock.withLock {
            guard !copies.isEmpty else { return .none }
            enterCount += 1
            return .some(copies.removeFirst())
        }
        guard case .some(let copied) = next else { return false }
        clipboard.copy(copied)
        return true
    }
}

/// An in-memory Keychain for the store: reads, writes and deletes, with
/// failures injectable per service. Writes make no check of their own.
final class MemoryKeychain: KeychainItemReader, KeychainItemWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String]
    private var writeLog: [String] = []
    private var deleteLog: [String] = []
    private var writeFailures: [String: SlackKeychainWriteError] = [:]
    private var deleteFailures: [String: SlackKeychainDeleteError] = [:]

    init(_ items: [String: String] = [:]) { self.items = items }

    var contents: [String: String] { lock.withLock { items } }
    /// Services written, in order.
    var writes: [String] { lock.withLock { writeLog } }
    /// Services deleted, in order.
    var deletes: [String] { lock.withLock { deleteLog } }

    func failWrites(to service: String, with error: SlackKeychainWriteError) {
        lock.withLock { writeFailures[service] = error }
    }

    func failDeletes(of service: String, with error: SlackKeychainDeleteError) {
        lock.withLock { deleteFailures[service] = error }
    }

    func read(service: String) async -> KeychainLookup {
        lock.withLock { items[service].map(KeychainLookup.found) ?? .absent }
    }

    func write(service: String, value: String) async throws {
        try lock.withLock {
            if let error = writeFailures[service] { throw error }
            writeLog.append(service)
            items[service] = value
        }
    }

    func delete(service: String) async throws {
        try lock.withLock {
            if let error = deleteFailures[service] { throw error }
            deleteLog.append(service)
            items[service] = nil
        }
    }
}

/// Answers `auth.test` by the token in the request body and records every
/// request. A token with no answer gets `invalid_auth`.
final class TokenTransport: SlackTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [String: String]
    private var sent: [URLRequest] = []

    init(_ answers: [String: String]) { self.answers = answers }

    var requests: [URLRequest] { lock.withLock { sent } }

    /// The token each request carried, in order.
    var tokens: [String] { requests.map(Self.token) }

    static func token(_ request: URLRequest) -> String {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let field = body.split(separator: "&").first { $0.hasPrefix("token=") } ?? ""
        return String(field.dropFirst("token=".count)).removingPercentEncoding ?? ""
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        let body = answers[Self.token(request)] ?? Fake.invalidAuth
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

/// A client with no pacing delay over `transport`.
func fakeClient(_ transport: TokenTransport) -> SlackWebClient {
    SlackWebClient(transport: transport, pacing: SlackPacingConfig(minIntervalMilliseconds: 0, maxConcurrency: 1)!)
}

/// The base64 index for `workspaces`, written the way the store writes it.
func indexValue(_ workspaces: [SlackWorkspace]) async throws -> String {
    let keychain = MemoryKeychain()
    try await SlackCredentialStore(reader: keychain, writer: keychain).saveWorkspaces(workspaces)
    return keychain.contents["SLACK_WORKSPACES"]!
}
