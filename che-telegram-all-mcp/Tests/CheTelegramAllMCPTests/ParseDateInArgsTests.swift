import XCTest
import MCP
@testable import CheTelegramAllMCPCore
import TelegramAllLib

/// `since_date` / `until_date`: #10 range sanity, #4 date parsing, and the dump's date arguments.
/// Moved out of ServerHandlerLogicTests.swift (#26) without changes.
final class ParseDateInArgsTests: XCTestCase {

    // MARK: - #10 C2: since_date / until_date range sanity check

    /// `since > until` previously silently filtered to empty result with no
    /// error. New: throws "since_date must be earlier than until_date".
    func testSinceAfterUntilThrows() {
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "since_date": .string("2026-12-31"),
            "until_date": .string("2026-01-01"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "since_date must be earlier than until_date")
        }
    }

    /// Boundary: same date → since at 00:00 < until at 23:59:59, should pass.
    func testSinceEqualsUntilSameDayAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "since_date": .string("2026-04-17"),
            "until_date": .string("2026-04-17"),
        ])
        XCTAssertNotNil(parsed.sinceDate)
        XCTAssertNotNil(parsed.untilDate)
    }

    /// Only since: range check skipped (no upper bound to compare).
    func testOnlySinceAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "since_date": .string("2026-04-17"),
        ])
        XCTAssertNotNil(parsed.sinceDate)
        XCTAssertNil(parsed.untilDate)
    }

    /// Only until: range check skipped.
    func testOnlyUntilAccepted() throws {
        let parsed = try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "until_date": .string("2026-04-17"),
        ])
        XCTAssertNil(parsed.sinceDate)
        XCTAssertNotNil(parsed.untilDate)
    }

    /// Dump parser parity for #10 C2.
    func testDumpSinceAfterUntilThrows() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "since_date": .string("2026-12-31"),
            "until_date": .string("2026-01-01"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "since_date must be earlier than until_date")
        }
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
        // #15-C3: assert year/month/day too — without these a TZ drift bug
        // could shift `until_date` to a different calendar day while keeping
        // hour/min/sec at 23:59:59 (same wall clock, wrong date).
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: parsed.untilDate!
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 23)
        XCTAssertEqual(components.minute, 59)
        XCTAssertEqual(components.second, 59)
    }

    func testInvalidDateFormatThrows() {
        // #11: error message text is part of the MCP contract
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "since_date": .string("2026/04/17"),
        ])) { error in
            XCTAssertEqual(
                (error as? DateParseError)?.description,
                "Date format invalid: expected YYYY-MM-DD, got \"2026/04/17\""
            )
        }
        XCTAssertThrowsError(try parseGetChatHistoryArgs([
            "chat_id": .int(100),
            "until_date": .string("not-a-date"),
        ])) { error in
            XCTAssertEqual(
                (error as? DateParseError)?.description,
                "Date format invalid: expected YYYY-MM-DD, got \"not-a-date\""
            )
        }
    }

    func testDumpInvalidDateThrows() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "since_date": .string("2026/04/17"),
        ]))
    }

    /// Parity with #15-C3 — until_date must hit end-of-day with full
    /// year/month/day assertions to catch TZ drift bugs.
    func testDumpUntilDateUsesEndOfDay() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "until_date": .string("2026-04-17"),
        ])
        XCTAssertNotNil(parsed.untilDate)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: parsed.untilDate!
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 23)
        XCTAssertEqual(components.minute, 59)
        XCTAssertEqual(components.second, 59)
    }
}
