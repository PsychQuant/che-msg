import XCTest
import MCP
@testable import CheTelegramAllMCPCore
import TelegramAllLib

/// What any tool answers for a TDLib error (PsychQuant/che-msg#71): `tdlib_error` with
/// TDLib's code and message, and a `hint` when TDLib could not load the chat the tool was
/// given. `handleWithTDLib` needs a TDLib session, so its catch goes through
/// `tdlibErrorResult(for:)`, tested here.
final class TDLibErrorResultTests: XCTestCase {
    private func payload(_ result: CallTool.Result?) throws -> [String: Any] {
        let result = try XCTUnwrap(result)
        XCTAssertEqual(result.isError, true)
        guard case .text(let text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("expected a text block")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testATDLibErrorKeepsItsCodeAndMessage() throws {
        let json = try payload(tdlibErrorResult(for: TDLibClient.TDError.tdlibError(code: 400, message: "User not found")))
        XCTAssertEqual(json["type"] as? String, "tdlib_error")
        XCTAssertEqual(json["code"] as? Int, 400)
        XCTAssertEqual(json["message"] as? String, "User not found")
        XCTAssertNil(json["hint"], "only an unknown chat has a hint")
    }

    func testA406IsReportedWithoutItsMessage() throws {
        let json = try payload(tdlibErrorResult(for: TDLibClient.TDError.tdlibError(code: 406, message: "")))
        XCTAssertEqual(json["code"] as? Int, 406)
        XCTAssertEqual(json["message"] as? String, "")
    }

    /// Same type, code and message as any TDLib error, so callers that branch on them are
    /// unaffected; the hint is an extra field.
    func testAnUnknownChatAddsTheHint() throws {
        let error = TDLibClient.TDError.unknownChat(chatId: -1_001_234_567_890, code: 400, message: "Chat not found")
        let json = try payload(tdlibErrorResult(for: error))
        XCTAssertEqual(json["type"] as? String, "tdlib_error")
        XCTAssertEqual(json["code"] as? Int, 400)
        XCTAssertEqual(json["message"] as? String, "Chat not found")
        XCTAssertEqual(json["hint"] as? String, error.hint)
        XCTAssertEqual(Set(json.keys), ["type", "code", "message", "hint"])
    }

    /// The client's own errors and argument errors keep their plain-text result.
    func testOtherErrorsAreNotTDLibErrors() {
        XCTAssertNil(tdlibErrorResult(for: TDLibClient.TDError.sessionClosed))
        XCTAssertNil(tdlibErrorResult(for: TDLibClient.TDError.notAuthenticated))
        XCTAssertNil(tdlibErrorResult(for: HandlerArgError(message: "chat_id is required")))
    }
}
