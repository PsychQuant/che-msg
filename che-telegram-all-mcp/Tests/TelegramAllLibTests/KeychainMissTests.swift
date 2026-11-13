import XCTest
@testable import TelegramAllLib

/// Why a Keychain lookup produced no value, as `auth_status` reports it
/// (PsychQuant/che-msg#95): a reason class only, never the value or what
/// `security` printed.
final class KeychainMissTests: XCTestCase {
    func testEachLookupWithoutAValueHasAReason() {
        XCTAssertEqual(KeychainMiss(.absent), .notStored)
        XCTAssertEqual(KeychainMiss(.timedOut), .timedOut)
        XCTAssertEqual(KeychainMiss(.unavailable(exitStatus: 51)), .unavailable)
    }

    func testAFoundValueIsNotAMiss() {
        XCTAssertNil(KeychainMiss(.found("secret-value")))
    }

    func testTheReportedNamesAreFixed() {
        XCTAssertEqual(KeychainMiss.notStored.rawValue, "not_stored")
        XCTAssertEqual(KeychainMiss.timedOut.rawValue, "timed_out")
        XCTAssertEqual(KeychainMiss.unavailable.rawValue, "unavailable")
    }

    /// auth_run's lookup records its outcome only while TDLib still waits for
    /// that credential (Codex review of #95).
    func testEachCredentialBelongsToTheStateThatAsksForIt() {
        XCTAssertEqual(waitingState(for: .phone), .waitingForPhoneNumber)
        XCTAssertEqual(waitingState(for: .password), .waitingForPassword)
    }
}
