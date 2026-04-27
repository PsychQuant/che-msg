import XCTest
import MCP
@testable import CheTelegramAllMCPCore
import TelegramAllLib

/// Handler-glue integration tests (#14, subsumes #18).
///
/// `ServerHandlerLogicTests` covers the pure-function parser layer
/// (`parseGetChatHistoryArgs` / `parseDumpChatToMarkdownArgs`). What was
/// previously uncovered: the **catch chain** that converts parse-stage
/// errors into `CallTool.Result` with `isError: true`. If someone changed
/// the thrown error type or rewired the catch order, the parser tests
/// would still pass but downstream MCP callers would see different
/// payloads.
///
/// The catch chain is now centralized in `errorResultFromParse(_:)`
/// (HandlerArgs.swift). These tests pin its contract:
/// - `HandlerArgError` → `isError: true`, text starts with `"Error: "`
/// - `DateParseError` → same shape, distinct message
/// - Unknown `Error` → fallback via `localizedDescription`
///
/// Out of scope (separate follow-up): TDLib parameter spy verification —
/// that requires a `TDLibProtocol` abstraction (breaking change touching
/// 21+ call sites). Tracked separately.
final class HandlerGlueTests: XCTestCase {

    // MARK: - errorResultFromParse contract

    func testHandlerArgErrorBecomesIsErrorTrue() {
        let error = HandlerArgError(message: "chat_id is required")
        let result = errorResultFromParse(error)
        XCTAssertTrue(result.isError ?? false,
                      "HandlerArgError must produce isError: true")
        XCTAssertEqual(result.content.count, 1,
                       "errorResult should have exactly one text content")
        guard case let .text(text, _, _) = result.content[0] else {
            XCTFail("expected .text content; got \(result.content[0])")
            return
        }
        XCTAssertEqual(text, "Error: chat_id is required")
    }

    func testDateParseErrorBecomesIsErrorTrue() {
        let error = DateParseError(input: "2026/04/17", expected: "YYYY-MM-DD")
        let result = errorResultFromParse(error)
        XCTAssertTrue(result.isError ?? false)
        guard case let .text(text, _, _) = result.content[0] else {
            XCTFail("expected .text content")
            return
        }
        XCTAssertEqual(
            text,
            "Error: Date format invalid: expected YYYY-MM-DD, got \"2026/04/17\""
        )
    }

    /// Defensive — neither parser throws non-Handler/Date errors today, but
    /// if a future refactor introduces one, the catch chain falls back to
    /// `localizedDescription` rather than crashing.
    func testUnknownErrorFallsBackToLocalizedDescription() {
        struct WeirdError: Error, LocalizedError {
            var errorDescription: String? { "unexpected condition" }
        }
        let result = errorResultFromParse(WeirdError())
        XCTAssertTrue(result.isError ?? false)
        guard case let .text(text, _, _) = result.content[0] else {
            XCTFail("expected .text content")
            return
        }
        XCTAssertTrue(text.hasPrefix("Error: "),
                      "unknown error should still get Error: prefix")
        XCTAssertTrue(text.contains("unexpected condition"),
                      "should reflect localizedDescription")
    }

    // MARK: - End-to-end glue: parser-throws → errorResultFromParse path

    /// Models the actual handler glue: `do { try parse... } catch { return errorResultFromParse(error) }`.
    /// Verifies that a missing chat_id surfaces as a properly-shaped error result.
    func testGetChatHistoryGlueChatIdMissing() {
        let result: CallTool.Result
        do {
            _ = try parseGetChatHistoryArgs([:])
            XCTFail("parser should have thrown for missing chat_id")
            return
        } catch {
            result = errorResultFromParse(error)
        }
        XCTAssertTrue(result.isError ?? false)
        guard case let .text(text, _, _) = result.content[0] else {
            XCTFail("expected .text content")
            return
        }
        XCTAssertEqual(text, "Error: chat_id is required")
    }

    /// Same for dump_chat_to_markdown — output_path required surfaces correctly.
    func testDumpToMarkdownGlueOutputPathMissing() {
        let result: CallTool.Result
        do {
            _ = try parseDumpChatToMarkdownArgs(["chat_id": .int(100)])
            XCTFail("parser should have thrown for missing output_path")
            return
        } catch {
            result = errorResultFromParse(error)
        }
        XCTAssertTrue(result.isError ?? false)
        guard case let .text(text, _, _) = result.content[0] else {
            XCTFail("expected .text content")
            return
        }
        XCTAssertEqual(text, "Error: output_path is required")
    }

    /// DateParseError flows through the same pipe — verify date errors don't
    /// accidentally fall into the unknown-error branch.
    func testGetChatHistoryGlueInvalidDate() {
        let result: CallTool.Result
        do {
            _ = try parseGetChatHistoryArgs([
                "chat_id": .int(100),
                "since_date": .string("2026/04/17"),
            ])
            XCTFail("parser should have thrown for invalid date")
            return
        } catch {
            result = errorResultFromParse(error)
        }
        XCTAssertTrue(result.isError ?? false)
        guard case let .text(text, _, _) = result.content[0] else {
            XCTFail("expected .text content")
            return
        }
        XCTAssertTrue(text.hasPrefix("Error: Date format invalid:"),
                      "DateParseError must reach the date-error catch arm; got \(text)")
    }
}
