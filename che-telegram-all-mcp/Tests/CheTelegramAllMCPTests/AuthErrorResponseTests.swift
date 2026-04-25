import XCTest
import MCP
@testable import CheTelegramAllMCPCore

/// Covers spec requirement: "MCP response error serialization"
/// Corresponds to design Decision 3.
///
/// Tests target the file-scope helper `tdlibErrorResult(code:message:)` directly,
/// avoiding any need to instantiate the MCP server (which boots TDLib).
final class AuthErrorResponseTests: XCTestCase {

    func testFloodWaitErrorResponseHasIsErrorTrue() {
        let result = tdlibErrorResult(code: 420, message: "FLOOD_WAIT_30")
        XCTAssertEqual(result.isError, true,
                       "Structured TDLib errors MUST set isError: true")
    }

    func testFloodWaitErrorResponseContainsStructuredJSON() throws {
        let result = tdlibErrorResult(code: 420, message: "FLOOD_WAIT_30")

        guard let firstContent = result.content.first,
              case .text(let text, _, _) = firstContent else {
            XCTFail("Expected at least one text content block")
            return
        }

        let payload = try XCTUnwrap(text.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        XCTAssertEqual(parsed?["type"] as? String, "tdlib_error",
                       "Response payload MUST include type=tdlib_error")
        XCTAssertEqual(parsed?["code"] as? Int, 420,
                       "Response payload MUST include numeric code")
        XCTAssertEqual(parsed?["message"] as? String, "FLOOD_WAIT_30",
                       "Response payload MUST include original message")
    }

    func testPhoneCodeInvalidResponseSerializesCorrectly() throws {
        let result = tdlibErrorResult(code: 400, message: "PHONE_CODE_INVALID")

        guard let firstContent = result.content.first,
              case .text(let text, _, _) = firstContent else {
            XCTFail("Expected at least one text content block")
            return
        }

        let payload = try XCTUnwrap(text.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        XCTAssertEqual(parsed?["code"] as? Int, 400)
        XCTAssertEqual(parsed?["message"] as? String, "PHONE_CODE_INVALID")
    }

    func testMessageWithSpecialCharactersIsJSONEscaped() throws {
        let tricky = #"He said "stop" and \n broke"#
        let result = tdlibErrorResult(code: 500, message: tricky)

        guard let firstContent = result.content.first,
              case .text(let text, _, _) = firstContent else {
            XCTFail("Expected at least one text content block")
            return
        }

        // Round-trip must reproduce the message faithfully.
        let payload = try XCTUnwrap(text.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        XCTAssertEqual(parsed?["message"] as? String, tricky,
                       "JSON escaping MUST round-trip quotes/backslashes faithfully")
    }
}
