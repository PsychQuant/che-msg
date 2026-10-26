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
        XCTAssertEqual(message, "TDLib is closing or has closed this session; no further request was sent. "
                       + "A new session opens on the first call after a successful logout, after the idle close "
                       + "(CHE_TELEGRAM_ALL_IDLE_TIMEOUT s with no call), or after you reconnect telegram-all with /mcp.")
        XCTAssertFalse(message.contains("Not authenticated"), message)
        XCTAssertTrue(message.contains(IdleTimeout.environmentVariable), message)
    }

    /// The raw TDLibKit client is private to TDLibClient.swift, so the compiler
    /// keeps every other file on `openClient`, which calls `requireOpen`. In
    /// that file the raw client is used only to close (`close` works on a
    /// closing client and returns at once on a closed one) and for its id.
    /// The one exception is #98's request seam: the class hands the raw client
    /// once to `TDLibKitCredentialRequests`, whose phone-number and 2FA-password
    /// requests `AuthCoordinator` sends only after `requestRefusal`, under the
    /// lock the request is handed to TDLib under
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

        let classStart = try XCTUnwrap(client.range(of: "public final class TDLibClient {"))
        let seam = String(client[..<classStart.lowerBound])
        let body = String(client[classStart.lowerBound...])
        XCTAssertTrue(body.contains("requests: TDLibKitCredentialRequests(client: client)"),
                      "the request seam gets the raw client in init")

        let rawUse = try NSRegularExpression(pattern: #"\bclient\.([A-Za-z]+)"#)
        func members(_ source: String) -> [String] {
            var found: [String] = []
            for line in source.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                let text = String(line)
                for match in rawUse.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    found.append(String(text[Range(match.range(at: 1), in: text)!]))
                }
            }
            return found
        }
        XCTAssertEqual(Set(members(body)), ["id", "close"], "raw client members used: \(members(body))")
        XCTAssertEqual(Set(members(seam)), ["setAuthenticationPhoneNumber", "checkAuthenticationPassword"],
                       "the request seam sends only the two credential requests: \(members(seam))")

        for file in ["TDLibClient.swift", "TDLibClient+Archive.swift"] {
            let source = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(source.contains("openClient."), file)
        }
    }
}
