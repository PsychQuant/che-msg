import XCTest
@testable import TelegramAllLib

final class TDLibClientTests: XCTestCase {

    // MARK: - AuthState Enum

    func testAuthStateValues() {
        let states: [TDLibClient.AuthState] = [
            .waitingForParameters, .waitingForPhoneNumber,
            .waitingForCode, .waitingForPassword,
            .ready, .closed,
        ]
        XCTAssertEqual(states.count, 6)
        XCTAssertEqual(TDLibClient.AuthState.waitingForParameters.rawValue, "waitingForParameters")
        XCTAssertEqual(TDLibClient.AuthState.waitingForPhoneNumber.rawValue, "waitingForPhoneNumber")
        XCTAssertEqual(TDLibClient.AuthState.waitingForCode.rawValue, "waitingForCode")
        XCTAssertEqual(TDLibClient.AuthState.waitingForPassword.rawValue, "waitingForPassword")
        XCTAssertEqual(TDLibClient.AuthState.ready.rawValue, "ready")
        XCTAssertEqual(TDLibClient.AuthState.closed.rawValue, "closed")
    }

    // MARK: - Error Types

    func testTDErrorNotAuthenticated() {
        let error = TDLibClient.TDError.notAuthenticated
        XCTAssertTrue(error.localizedDescription.contains("Not authenticated"))
    }

    func testTDErrorMissingCredentials() {
        let error = TDLibClient.TDError.missingCredentials("TELEGRAM_API_ID")
        XCTAssertTrue(error.localizedDescription.contains("TELEGRAM_API_ID"))
    }

    func testTDErrorTDLibError() {
        let error = TDLibClient.TDError.tdlibError(code: 500, message: "connection timeout")
        XCTAssertTrue(error.localizedDescription.contains("500"),
                      "errorDescription must include the numeric code")
        XCTAssertTrue(error.localizedDescription.contains("connection timeout"),
                      "errorDescription must include the original message")
    }

    // MARK: - Sendable Conformance

    func testAuthStateIsSendable() {
        let state: TDLibClient.AuthState = .ready
        Task {
            // Compiles only if AuthState is Sendable
            let _ = state
        }
    }
}
