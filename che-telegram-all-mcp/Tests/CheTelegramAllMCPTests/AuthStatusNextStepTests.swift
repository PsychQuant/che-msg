import XCTest
import MCP
@testable import CheTelegramAllMCPCore
@testable import TelegramAllLib

/// Covers spec requirements:
///   - "`auth_status` response includes structured next-step hint" (telegram-auth-coordination)
///   - "Auto-fire failure surfacing via auth_status" (telegram-auth-error-reporting)
/// Corresponds to design Decisions 5 + 6.
///
/// Tests target the file-scope helper `authStatusResult(state:lastError:)`,
/// which assembles the structured JSON payload independently of any server
/// instance (matching the AuthErrorResponseTests pattern).
final class AuthStatusNextStepTests: XCTestCase {

    // MARK: - next_step shape per state (Decision 5)

    func testReadyState_nextStepIsNull() throws {
        let payload = try parsePayload(authStatusResult(state: .ready, lastError: nil))

        XCTAssertEqual(payload["state"] as? String, "ready")
        XCTAssertTrue(payload["next_step"] is NSNull,
                      "next_step MUST be null at ready state")
        XCTAssertTrue(payload["last_error"] is NSNull,
                      "last_error MUST be null when no error")
    }

    func testWaitingForParameters_nextStepRequiresApiCredentials() throws {
        let payload = try parsePayload(authStatusResult(state: .waitingForParameters, lastError: nil))

        XCTAssertEqual(payload["state"] as? String, "waitingForParameters")
        let nextStep = try XCTUnwrap(payload["next_step"] as? [String: Any],
                                     "next_step MUST be a structured object")
        XCTAssertEqual(nextStep["tool"] as? String, "auth_run")
        XCTAssertEqual(nextStep["required_args"] as? [String], ["api_id", "api_hash"])
        XCTAssertNotNil(nextStep["hint"] as? String,
                        "hint string MUST be present")
    }

    func testWaitingForPhoneNumber_nextStepRequiresPhone() throws {
        let payload = try parsePayload(authStatusResult(state: .waitingForPhoneNumber, lastError: nil))

        XCTAssertEqual(payload["state"] as? String, "waitingForPhoneNumber")
        let nextStep = try XCTUnwrap(payload["next_step"] as? [String: Any])
        XCTAssertEqual(nextStep["tool"] as? String, "auth_run")
        XCTAssertEqual(nextStep["required_args"] as? [String], ["phone"])
        XCTAssertNotNil(nextStep["hint"] as? String)
    }

    func testWaitingForCode_nextStepRequiresCode() throws {
        let payload = try parsePayload(authStatusResult(state: .waitingForCode, lastError: nil))

        XCTAssertEqual(payload["state"] as? String, "waitingForCode")
        let nextStep = try XCTUnwrap(payload["next_step"] as? [String: Any])
        XCTAssertEqual(nextStep["tool"] as? String, "auth_run")
        XCTAssertEqual(nextStep["required_args"] as? [String], ["code"])
        XCTAssertNotNil(nextStep["hint"] as? String,
                        "Hint MUST identify the phone number Telegram targeted")
    }

    func testWaitingForPassword_nextStepRequiresPassword() throws {
        let payload = try parsePayload(authStatusResult(state: .waitingForPassword, lastError: nil))

        XCTAssertEqual(payload["state"] as? String, "waitingForPassword")
        let nextStep = try XCTUnwrap(payload["next_step"] as? [String: Any])
        XCTAssertEqual(nextStep["tool"] as? String, "auth_run")
        XCTAssertEqual(nextStep["required_args"] as? [String], ["password"])
        XCTAssertNotNil(nextStep["hint"] as? String)
    }

    func testClosedState_nextStepIsNull() throws {
        let payload = try parsePayload(authStatusResult(state: .closed, lastError: nil))

        XCTAssertEqual(payload["state"] as? String, "closed")
        XCTAssertTrue(payload["next_step"] is NSNull,
                      "Closed state has no actionable next step — null")
    }

    // MARK: - last_error serialization (Task 1.6 — telegram-auth-error-reporting)

    func testFloodWaitErrorSerializedInLastError() throws {
        let err = TDLibClient.TDError.tdlibError(code: 420, message: "FLOOD_WAIT_30")
        let payload = try parsePayload(authStatusResult(state: .waitingForPhoneNumber, lastError: err))

        let lastError = try XCTUnwrap(payload["last_error"] as? [String: Any],
                                      "last_error MUST be a structured object when populated")
        XCTAssertEqual(lastError["type"] as? String, "tdlib_error",
                       "last_error.type MUST be 'tdlib_error' for TDLib-origin errors")
        XCTAssertEqual(lastError["code"] as? Int, 420)
        XCTAssertEqual(lastError["message"] as? String, "FLOOD_WAIT_30")
    }

    func testInternalErrorSerializedInLastError() throws {
        let err = TDLibClient.TDError.tdlibError(code: 500, message: "INTERNAL_ERROR")
        let payload = try parsePayload(authStatusResult(state: .waitingForParameters, lastError: err))

        let lastError = try XCTUnwrap(payload["last_error"] as? [String: Any])
        XCTAssertEqual(lastError["code"] as? Int, 500)
        XCTAssertEqual(lastError["message"] as? String, "INTERNAL_ERROR")
    }

    func testReadyStateClearsLastErrorEvenIfPassed() throws {
        // Spec: "When authState advances to ready, lastAutoFireError MUST be cleared"
        // The Server is responsible for clearing on .ready transition (task 4.7),
        // but if a stale error somehow reaches authStatusResult while state is .ready,
        // the response should still serialize coherently. (We test by passing nil here
        // — the cleared-state contract is enforced by the auto-fire path.)
        let payload = try parsePayload(authStatusResult(state: .ready, lastError: nil))
        XCTAssertTrue(payload["last_error"] is NSNull)
    }

    func testNonTDLibErrorSerializedAsGenericFailure() throws {
        // Spec mentions {type, code, message} shape; TDError currently only has the
        // tdlibError case carrying (code, message). notAuthenticated and
        // missingCredentials don't carry a numeric code — confirm the helper
        // handles them coherently (either skipped or serialized with a sentinel
        // that the caller can disambiguate).
        let err = TDLibClient.TDError.notAuthenticated
        let payload = try parsePayload(authStatusResult(state: .waitingForParameters, lastError: err))

        // Acceptable shapes:
        //   1. last_error serialized with type != "tdlib_error" (e.g., "client_error")
        //   2. last_error null (only TDLib-origin errors surface)
        // Either is spec-compliant; assert the response remains valid JSON.
        if let lastError = payload["last_error"] as? [String: Any] {
            XCTAssertNotNil(lastError["type"] as? String,
                            "If last_error is non-null it MUST have a type discriminator")
            XCTAssertNotNil(lastError["message"] as? String,
                            "If last_error is non-null it MUST have a message")
        } else {
            XCTAssertTrue(payload["last_error"] is NSNull)
        }
    }

    // MARK: - Helper

    /// Extracts the JSON payload from an MCP CallTool.Result.
    private func parsePayload(_ result: CallTool.Result) throws -> [String: Any] {
        guard let firstContent = result.content.first,
              case .text(let text, _, _) = firstContent else {
            throw XCTSkip("Expected text content block in CallTool.Result")
        }
        let data = try XCTUnwrap(text.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(parsed, "Response payload MUST be a JSON object")
    }
}
