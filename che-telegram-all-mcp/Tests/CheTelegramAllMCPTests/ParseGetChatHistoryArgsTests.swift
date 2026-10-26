import XCTest
import MCP
@testable import CheTelegramAllMCPCore
import TelegramAllLib

/// `parseGetChatHistoryArgs`: #3 auto-pagination when `from_message_id` is 0, required fields, defaults, and #12 numeric-string ids.
/// Moved out of ServerHandlerLogicTests.swift (#26) without changes.
final class ParseGetChatHistoryArgsTests: XCTestCase {

    // MARK: - #3 regression: fromMsgId==0 auto-pagination

    func testFromMsgIdZeroDefaultsMaxMessagesToLimit() throws {
        let args: [String: Value] = [
            "chat_id": .int(100),
            "limit": .int(50),
        ]
        let parsed = try parseGetChatHistoryArgs(args)
        XCTAssertEqual(parsed.chatId, 100)
        XCTAssertEqual(parsed.limit, 50)
        XCTAssertEqual(parsed.fromMessageId, 0)
        XCTAssertEqual(parsed.maxMessages, 50,
                       "fromMsgId==0 should default maxMessages to limit (#3)")
    }

    func testFromMsgIdNonZeroLeavesMaxMessagesNil() throws {
        let args: [String: Value] = [
            "chat_id": .int(100),
            "limit": .int(50),
            "from_message_id": .int(12345),
        ]
        let parsed = try parseGetChatHistoryArgs(args)
        XCTAssertEqual(parsed.fromMessageId, 12345)
        XCTAssertNil(parsed.maxMessages,
                     "fromMsgId>0 should keep maxMessages nil (backward-compat)")
    }

    // MARK: - Required field validation

    func testMissingChatIdThrows() {
        // #11: assert exact contract message
        XCTAssertThrowsError(try parseGetChatHistoryArgs([:])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id is required")
        }
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "limit": .int(50),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id is required")
        }
    }

    // MARK: - Defaults

    func testDefaultLimitIs50() throws {
        let parsed = try parseGetChatHistoryArgs(["chat_id": .int(100)])
        XCTAssertEqual(parsed.limit, 50,
                       "default limit should be 50")
    }

    // MARK: - #12 backward-compat: numeric-string chat_id / from_message_id

    /// `int64ArgValue` accepts `.string("123")` for callers that quote integers
    /// in JSON (legacy MCP clients). Lock this dual-path so a refactor that
    /// drops string fallback would be caught.
    func testChatIdAsStringAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .string("100"),
        ])
        XCTAssertEqual(parsed.chatId, 100)
    }

    func testFromMessageIdAsStringAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "from_message_id": .string("12345"),
        ])
        XCTAssertEqual(parsed.fromMessageId, 12345)
    }

    /// #22: non-numeric string for `chat_id` now throws a type-mismatch
    /// error instead of the misleading "chat_id is required". Pre-#22,
    /// `int64ArgValue` silently returned nil on parse-fail, so the caller
    /// threw "is required" — leading the user to check args structure
    /// instead of value type. Post-#22, `int64ArgValueStrict` distinguishes
    /// absent (nil → caller decides) vs. wrong type (throws with quoted
    /// value for debug clarity).
    func testChatIdAsStringInvalidThrows() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .string("not-a-number"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id must be an integer; got \"not-a-number\"")
        }
    }

    /// #22 parity for `from_message_id` — same type-mismatch handling via
    /// `int64ArgValueStrict`. Without this test, a regression that re-narrows
    /// strictness only to `chat_id` could go unnoticed.
    func testFromMessageIdAsStringInvalidThrows() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "from_message_id": .string("garbage"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "from_message_id must be an integer; got \"garbage\"")
        }
    }

    /// #22 parity for `parseDumpChatToMarkdownArgs.chat_id` — confirms the
    /// strict-helper upgrade applied to both parsers, not just
    /// `parseGetChatHistoryArgs`.
    func testDumpChatIdAsStringInvalidThrows() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .string("not-a-number"),
            "output_path": .string("/tmp/x.md"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id must be an integer; got \"not-a-number\"")
        }
    }

    func testDumpChatIdAsStringAccepted() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .string("100"),
            "output_path": .string("/tmp/x.md"),
        ])
        XCTAssertEqual(parsed.chatId, 100)
    }
}
