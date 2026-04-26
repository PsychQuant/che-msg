import XCTest
@testable import TelegramAllLib

/// Covers spec requirements:
///   - "Auto-fire chain covers params, phone, and password steps"
///   - "SMS verification code is never auto-fired from environment"
/// Corresponds to design Decision 3: Auto-fire chain — 3 step（params + phone + password），
/// code step 必手動.
///
/// Tests target the pure decision helper `decideAutoFire(state:env...)`,
/// avoiding the heavy ProcessInfo + TDLibClient instance machinery. The
/// production auto-fire methods (`autoSetParametersIfAvailable`,
/// `autoSendPhoneIfAvailable`, `autoSendPasswordIfAvailable`) read env vars,
/// run the same decision, and dispatch through coalesceTask — extracting
/// the decision keeps the env-handling logic testable without subprocess setup.
final class AutoFireChainTests: XCTestCase {

    // MARK: - WaitTdlibParameters

    func testParameters_withBothEnvVars_firesSetParameters() {
        let action = decideAutoFire(
            state: .waitingForParameters,
            envApiId: 12345,
            envApiHash: "abcdef",
            envPhone: nil,
            envPassword: nil,
            envAuthCode: nil
        )
        XCTAssertEqual(action, .fireSetParameters(apiId: 12345, apiHash: "abcdef"))
    }

    func testParameters_withoutEnvVars_doesNotFire() {
        let action = decideAutoFire(
            state: .waitingForParameters,
            envApiId: nil,
            envApiHash: nil,
            envPhone: nil,
            envPassword: nil,
            envAuthCode: nil
        )
        XCTAssertEqual(action, .noOp)
    }

    func testParameters_withOnlyApiId_doesNotFire() {
        // Both required — partial env MUST NOT fire (would corrupt state).
        let action = decideAutoFire(
            state: .waitingForParameters,
            envApiId: 12345,
            envApiHash: nil,
            envPhone: nil,
            envPassword: nil,
            envAuthCode: nil
        )
        XCTAssertEqual(action, .noOp)
    }

    func testParameters_withOnlyApiHash_doesNotFire() {
        let action = decideAutoFire(
            state: .waitingForParameters,
            envApiId: nil,
            envApiHash: "abcdef",
            envPhone: nil,
            envPassword: nil,
            envAuthCode: nil
        )
        XCTAssertEqual(action, .noOp)
    }

    // MARK: - WaitPhoneNumber

    func testPhone_withEnvVar_firesSendPhone() {
        let action = decideAutoFire(
            state: .waitingForPhoneNumber,
            envApiId: nil,
            envApiHash: nil,
            envPhone: "+886912345678",
            envPassword: nil,
            envAuthCode: nil
        )
        XCTAssertEqual(action, .fireSendPhone("+886912345678"))
    }

    func testPhone_withoutEnvVar_doesNotFire() {
        let action = decideAutoFire(
            state: .waitingForPhoneNumber,
            envApiId: nil,
            envApiHash: nil,
            envPhone: nil,
            envPassword: nil,
            envAuthCode: nil
        )
        XCTAssertEqual(action, .noOp)
    }

    // MARK: - WaitCode (CRITICAL: env var MUST NOT trigger auto-fire)

    func testCode_neverFiresFromEnv_evenWhenAuthCodePresent() {
        // Spec: "SMS verification code is never auto-fired from environment"
        // This guards against a future regression where someone "helpfully"
        // adds TELEGRAM_AUTH_CODE auto-fire — the code MUST be supplied via
        // explicit caller invocation only.
        let action = decideAutoFire(
            state: .waitingForCode,
            envApiId: nil,
            envApiHash: nil,
            envPhone: nil,
            envPassword: nil,
            envAuthCode: "12345"
        )
        XCTAssertEqual(action, .noOp,
                       "WaitCode + TELEGRAM_AUTH_CODE in env MUST still result in no-op (one-shot delivery rule)")
    }

    func testCode_withoutAuthCodeEnv_doesNotFire() {
        let action = decideAutoFire(
            state: .waitingForCode,
            envApiId: nil,
            envApiHash: nil,
            envPhone: nil,
            envPassword: nil,
            envAuthCode: nil
        )
        XCTAssertEqual(action, .noOp)
    }

    // MARK: - WaitPassword

    func testPassword_withEnvVar_firesSendPassword() {
        let action = decideAutoFire(
            state: .waitingForPassword,
            envApiId: nil,
            envApiHash: nil,
            envPhone: nil,
            envPassword: "envSecret",
            envAuthCode: nil
        )
        XCTAssertEqual(action, .fireSendPassword("envSecret"))
    }

    func testPassword_withoutEnvVar_doesNotFire() {
        let action = decideAutoFire(
            state: .waitingForPassword,
            envApiId: nil,
            envApiHash: nil,
            envPhone: nil,
            envPassword: nil,
            envAuthCode: nil
        )
        XCTAssertEqual(action, .noOp)
    }

    // MARK: - Ready / Closed

    func testReady_neverFires() {
        let action = decideAutoFire(
            state: .ready,
            envApiId: 12345,
            envApiHash: "abcdef",
            envPhone: "+886912345678",
            envPassword: "envSecret",
            envAuthCode: "12345"
        )
        XCTAssertEqual(action, .noOp,
                       "Ready state must never auto-fire, regardless of env vars present")
    }

    func testClosed_neverFires() {
        let action = decideAutoFire(
            state: .closed,
            envApiId: 12345,
            envApiHash: "abcdef",
            envPhone: "+886912345678",
            envPassword: "envSecret",
            envAuthCode: "12345"
        )
        XCTAssertEqual(action, .noOp)
    }
}
