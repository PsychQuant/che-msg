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
/// `onEnter` runs at each Enter with its number (1 for the first), for a
/// test that changes something while the import waits.
final class ScriptedTerminal: SlackAuthTerminal, @unchecked Sendable {
    private let lock = NSLock()
    private let clipboard: FakeClipboard
    private let onEnter: (@Sendable (Int) -> Void)?
    private var copies: [String?]
    private var said: [String] = []
    private var enterCount = 0

    init(clipboard: FakeClipboard, copies: [String?] = [], onEnter: (@Sendable (Int) -> Void)? = nil) {
        self.clipboard = clipboard
        self.copies = copies
        self.onEnter = onEnter
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
        onEnter?(enters)
        return true
    }
}

/// An in-memory Keychain for the store: reads, writes and deletes, with
/// failures injectable per service. Its `check` is the production writer's,
/// line length included, so the store refuses here what it would refuse for
/// real. Writes make no check of their own.
final class MemoryKeychain: KeychainItemReader, KeychainItemWriter, @unchecked Sendable {
    /// Only its `check` is used, and that starts nothing; the executable
    /// cannot exist, so no call could start `security` either.
    static let productionChecks = SecurityCLIKeychainWriter(executable: URL(fileURLWithPath: "/dev/null/security"))

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

    /// Another process (a second `slack-all`) changing an item: not logged
    /// in `writes`, which records this process's writes only.
    func writeFromAnotherProcess(service: String, value: String?) {
        lock.withLock { items[service] = value }
    }

    func failWrites(to service: String, with error: SlackKeychainWriteError) {
        lock.withLock { writeFailures[service] = error }
    }

    func failDeletes(of service: String, with error: SlackKeychainDeleteError) {
        lock.withLock { deleteFailures[service] = error }
    }

    func check(service: String, value: String) throws {
        try Self.productionChecks.check(service: service, value: value)
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

/// Synthetic workspaces of a typical size, numbered from 1: an 11-character
/// team id and user id, a 15-character domain and a 20-character name.
enum ManyWorkspaces {
    static func workspace(_ number: Int) -> SlackWorkspace {
        let digits = String(format: "%010d", number)
        return SlackWorkspace(teamID: "T\(digits)", domain: "workspace-\(digits.suffix(5))",
                              name: "Example Team \(digits.suffix(7))", userID: "U\(digits)")
    }

    static func token(_ number: Int) -> String { "xoxc-fake-many-\(number)" }

    /// One entry as the console command copies it.
    static func entry(_ number: Int) -> String {
        let workspace = workspace(number)
        return #"{"id":"\#(workspace.teamID)","domain":"\#(workspace.domain)","name":"\#(workspace.name)","#
            + #""token":"\#(token(number))","user_id":"\#(workspace.userID)"}"#
    }

    /// What the console command copies for `numbers`.
    static func clipboardList(_ numbers: some Sequence<Int>) -> String {
        "[" + numbers.map(entry).joined(separator: ",") + "]"
    }

    /// A transport whose `auth.test` verifies every one of `numbers`.
    static func transport(_ numbers: some Sequence<Int>) -> TokenTransport {
        TokenTransport(Dictionary(uniqueKeysWithValues: numbers.map { number in
            let workspace = workspace(number)
            return (token(number), Fake.authTestOK(team: workspace.teamID, user: workspace.userID))
        }))
    }

    /// Records that none of these tokens appears in any line or in the error.
    static func expectNoTokens(_ lines: [String], _ error: (any Error)? = nil) {
        let texts = lines + (error.map { ["\($0)"] } ?? [])
        #expect(!texts.contains { $0.contains("xoxc-fake-many-") }, "output contains a fake token")
    }
}
