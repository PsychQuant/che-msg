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

    /// What a tool returns for any error it throws: the structured result for a TDLib error,
    /// the plain-text one for everything else.
    func testToolErrorResultPicksTheResultForEachError() throws {
        let unknown = TDLibClient.TDError.unknownChat(chatId: 123_456_789, code: 400, message: "Chat not found")
        XCTAssertEqual(try payload(toolErrorResult(unknown))["hint"] as? String, unknown.hint)
        XCTAssertEqual(try payload(toolErrorResult(TDLibClient.TDError.tdlibError(code: 429, message: "Too Many Requests: retry after 30")))["code"] as? Int, 429)
        let plain = toolErrorResult(HandlerArgError(message: "chat_id is required"))
        XCTAssertEqual(plain.isError, true)
        guard case .text(let text, _, _) = try XCTUnwrap(plain.content.first) else { return XCTFail("expected a text block") }
        XCTAssertEqual(text, "Error: chat_id is required")
    }

    /// `handleWithTDLib` needs a TDLib session, so its error path is pinned in the source: one
    /// catch at the function's level, and it returns `toolErrorResult(error)` and nothing else
    /// (#71 verify: dropping the TDLib branch from that catch failed no test).
    func testHandleWithTDLibSendsEveryErrorThroughToolErrorResult() throws {
        let server = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheTelegramAllMCPCore/Server.swift")
        let lines = try String(contentsOf: server, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("    private func handleWithTDLib(") })
        let end = try XCTUnwrap(lines[start...].firstIndex { $0 == "    }" }, "handleWithTDLib's closing brace")
        let body = lines[(start + 1)..<end].filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let catches = body.indices.filter { body[$0].hasPrefix("        } catch") && !body[$0].hasPrefix("         ") }
        XCTAssertEqual(catches.map { body[$0] }, ["        } catch {"], "one catch at the function's level, catching everything")
        guard let only = catches.first, only + 2 < body.endIndex else { return }
        XCTAssertEqual(body[only + 1], "            return toolErrorResult(error)")
        XCTAssertEqual(body[only + 2], "        }")
    }
}
