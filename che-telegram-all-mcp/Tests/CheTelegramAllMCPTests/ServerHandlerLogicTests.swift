import XCTest
import MCP
@testable import CheTelegramAllMCPCore

/// Tests for `get_chat_history` argument parsing — the pure function
/// `parseGetChatHistoryArgs` extracted from the MCP handler.
///
/// Protects #3 (fromMsgId==0 → maxMessages=limit auto-pagination) and
/// #4 (since_date/until_date/max_messages wiring) against regression.
final class ServerHandlerLogicTests: XCTestCase {

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

    // MARK: - #4: max_messages explicit override

    func testExplicitMaxMessagesOverridesImplicit() throws {
        let args: [String: Value] = [
            "chat_id": .int(100),
            "limit": .int(50),
            "max_messages": .int(5),
        ]
        let parsed = try parseGetChatHistoryArgs(args)
        XCTAssertEqual(parsed.maxMessages, 5,
                       "explicit max_messages should win over fromMsgId==0 default")
    }

    func testMaxMessagesRejectsZeroOrNegative() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .int(0),
        ]))
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .int(-5),
        ]))
    }

    func testMaxMessagesRejectsOverCap() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .int(50_000),
        ]))
    }

    func testMaxMessagesAtCapAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "max_messages": .int(10_000),
        ])
        XCTAssertEqual(parsed.maxMessages, 10_000)
    }

    // MARK: - #4: date parsing

    func testSinceDateValidParsed() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "since_date": .string("2026-04-17"),
        ])
        XCTAssertNotNil(parsed.sinceDate)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour],
            from: parsed.sinceDate!
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 0, "since_date = start of day")
    }

    func testUntilDateUsesEndOfDay() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "until_date": .string("2026-04-17"),
        ])
        XCTAssertNotNil(parsed.untilDate)
        let components = Calendar.current.dateComponents(
            [.hour, .minute, .second],
            from: parsed.untilDate!
        )
        XCTAssertEqual(components.hour, 23)
        XCTAssertEqual(components.minute, 59)
        XCTAssertEqual(components.second, 59)
    }

    func testInvalidDateFormatThrows() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "since_date": .string("2026/04/17"),
        ]))
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "until_date": .string("not-a-date"),
        ]))
    }

    // MARK: - Required field validation

    func testMissingChatIdThrows() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([:]))
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "limit": .int(50),
        ]))
    }

    // MARK: - Defaults

    func testDefaultLimitIs50() throws {
        let parsed = try parseGetChatHistoryArgs(["chat_id": .int(100)])
        XCTAssertEqual(parsed.limit, 50,
                       "default limit should be 50")
    }
}
