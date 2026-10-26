import XCTest
@testable import TelegramAllLib

/// A request to a client TDLib has closed is never answered: TDLibKit drops a
/// client from its table on `authorizationStateClosed` and routes no answer to
/// it, so the call waited forever and never ended (PsychQuant/che-msg#64).
/// Every request now checks the state first, under the client's lock.
///
/// A `TDLibClient` needs a TDLib session, so these tests cover the decision
/// (`requestRefusal`) and, in the source, that no request reaches TDLib without
/// it. No test calls a `TDLibClient` method itself.
final class TDLibClosedClientTests: XCTestCase {
    private let loginStates: [TDLibClient.AuthState] = [
        .waitingForParameters, .waitingForPhoneNumber, .waitingForCode, .waitingForPassword,
    ]

    private func refusal(_ state: TDLibClient.AuthState, authorized: Bool) -> String? {
        guard let error = TDLibClient.requestRefusal(state: state, authorized: authorized) else { return nil }
        switch error {
        case .sessionClosed: return "sessionClosed"
        case .notAuthenticated: return "notAuthenticated"
        case .missingCredentials: return "missingCredentials"
        case .tdlibError: return "tdlibError"
        case .unknownChat: return "unknownChat"
        }
    }

    /// Closing is refused too: TDLib is on its way to `closed`, and nothing
    /// can usefully be sent to it (#64).
    func testAClosingOrClosedClientRefusesEveryRequest() {
        for state in [TDLibClient.AuthState.closing, .closed] {
            XCTAssertEqual(refusal(state, authorized: false), "sessionClosed", "\(state)")
            XCTAssertEqual(refusal(state, authorized: true), "sessionClosed", "never Not authenticated: \(state)")
        }
    }

    /// The authentication requests are sent in every login state and at ready.
    func testAuthenticationRequestsGoThroughWhileTheClientIsOpen() {
        for state in loginStates + [.ready] {
            XCTAssertNil(refusal(state, authorized: false), "\(state)")
        }
    }

    /// Every other request still needs authorization, as before.
    func testOtherRequestsStillNeedAuthorization() {
        for state in loginStates {
            XCTAssertEqual(refusal(state, authorized: true), "notAuthenticated", "\(state)")
        }
        XCTAssertNil(refusal(.ready, authorized: true))
    }

    /// The message says what happened and what the server does next: it keeps
    /// the closed client until a logout succeeds or the idle close runs, or
    /// until the server restarts (#64).
    func testTheClosedMessageGivesTheNextStep() throws {
        let message = try XCTUnwrap(TDLibClient.TDError.sessionClosed.errorDescription)
        XCTAssertEqual(message, "TDLib is closing or has closed this session; no request was sent. "
                       + "A new session opens on the first call after a successful logout, after the idle close "
                       + "(when CHE_TELEGRAM_ALL_IDLE_TIMEOUT is not 0, once no call is running), or after a reconnect with /mcp.")
        XCTAssertLessThanOrEqual(message.count, 256, "error results are cut at 256 characters")
        XCTAssertFalse(message.contains("Not authenticated"), message)
        XCTAssertTrue(message.contains(IdleTimeout.environmentVariable), message)
    }

    /// The raw TDLibKit client is private to TDLibClient.swift, so the compiler
    /// keeps every other file on `openClient`, which calls `requireOpen`. In
    /// that file the raw client appears only in its declaration, its creation,
    /// `close` and `id`, and `openClient`'s `return client`, whatever way a
    /// use is written. How `close` behaves on a closing client is TDLib's and
    /// is not verified here. `openClient` is always used directly (`openClient.`),
    /// never bound once and reused across pages (#64 verify).
    /// The one exception is #98's request seam: the class hands the raw client
    /// once to `TDLibKitCredentialRequests` (above the class), whose
    /// phone-number and 2FA-password requests `AuthCoordinator` sends only after
    /// `requestRefusal`, under the lock the request is handed to TDLib under
    /// (`AuthCoordinatorTests.testAClosingOrClosedClientRefusesAnExplicitCredential`).
    func testNoRequestBypassesTheClosedCheck() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TelegramAllLib")
        let client = try String(contentsOf: sources.appendingPathComponent("TDLibClient.swift"), encoding: .utf8)
        XCTAssertTrue(client.contains("    private let client: TDLibKit.TDLibClient\n"))
        XCTAssertTrue(client.contains("""
                var openClient: TDLibKit.TDLibClient {
                    get throws {
                        try requireOpen()
                        return client
                    }
                }
            """), "openClient checks the state before handing out the client")

        func codeLines(_ source: String) -> [String] {
            source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        }
        let classStart = try XCTUnwrap(client.range(of: "public final class TDLibClient {"))
        let seam = String(client[..<classStart.lowerBound])
        let body = String(client[classStart.lowerBound...])

        // Every word `client` in the code, once the allowed forms are removed.
        let allowed = ["private let client: TDLibKit.TDLibClient", "client = Self.manager.createClient",
                       "client.id", "client.close(", "TDLibKitCredentialRequests(client: client)"]
        let word = try NSRegularExpression(pattern: #"\bclient\b"#)
        var returns = 0
        for line in codeLines(body) {
            var text = line
            for form in allowed { text = text.replacingOccurrences(of: form, with: "") }
            if text.trimmingCharacters(in: .whitespaces) == "return client" { returns += 1; continue }
            let left = word.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertEqual(left, 0, "raw client used outside close / id: \(line)")
        }
        XCTAssertEqual(returns, 1, "only openClient hands out the raw client")
        XCTAssertTrue(body.contains("requests: TDLibKitCredentialRequests(client: client)"),
                      "the request seam gets the raw client in init")

        // The seam sends only the two credential requests.
        let seamForms = ["let client: TDLibKit.TDLibClient", "try client.setAuthenticationPhoneNumber(",
                         "try client.checkAuthenticationPassword("]
        for line in codeLines(seam) {
            var text = line
            for form in seamForms { text = text.replacingOccurrences(of: form, with: "") }
            let left = word.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            XCTAssertEqual(left, 0, "raw client used in the request seam for something else: \(line)")
        }

        // `openClient` is used directly, never bound and reused.
        let declaration = "var openClient: TDLibKit.TDLibClient {"
        let bare = try NSRegularExpression(pattern: #"\bopenClient\b(?!\.)"#)
        for file in ["TDLibClient.swift", "TDLibClient+Archive.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("openClient."), file)
            for line in codeLines(source) where !line.contains(declaration) {
                let hits = bare.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line))
                XCTAssertEqual(hits, 0, "\(file): openClient not used directly: \(line)")
            }
        }
    }
}
