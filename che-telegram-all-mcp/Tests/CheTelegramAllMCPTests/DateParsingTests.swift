import XCTest
@testable import CheTelegramAllMCPCore

/// Tests for ISO date parsing helpers used by `get_chat_history` and
/// `dump_chat_to_markdown`. Covers #5-A1 (until_date inclusive semantics)
/// and #5-A2 (invalid format throws instead of silent nil).
final class DateParsingTests: XCTestCase {

    // MARK: - parseISODate (for since_date)

    func testParseISODateNil() throws {
        XCTAssertNil(try parseISODate(nil))
    }

    func testParseISODateEmpty() throws {
        XCTAssertNil(try parseISODate(""))
    }

    func testParseISODateValid() throws {
        let date = try parseISODate("2026-04-17")
        XCTAssertNotNil(date)
        // Should parse to start-of-day local time
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date!
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    func testParseISODateInvalidFormatThrows() {
        XCTAssertThrowsError(try parseISODate("2026/04/17")) { error in
            XCTAssertTrue(error is DateParseError,
                          "Expected DateParseError, got \(type(of: error))")
        }
        XCTAssertThrowsError(try parseISODate("not-a-date"))
        XCTAssertThrowsError(try parseISODate("17-04-2026"))
    }

    // MARK: - parseUntilDate (for until_date — inclusive whole day)

    func testParseUntilDateNil() throws {
        XCTAssertNil(try parseUntilDate(nil))
    }

    func testParseUntilDateEmpty() throws {
        XCTAssertNil(try parseUntilDate(""))
    }

    func testParseUntilDateIncludesWholeDay() throws {
        let date = try parseUntilDate("2026-04-17")
        XCTAssertNotNil(date)
        // Should parse to end-of-day local time (23:59:59)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date!
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 23)
        XCTAssertEqual(components.minute, 59)
        XCTAssertEqual(components.second, 59)
    }

    func testParseUntilDateInvalidFormatThrows() {
        XCTAssertThrowsError(try parseUntilDate("2026/04/17"))
        XCTAssertThrowsError(try parseUntilDate("not-a-date"))
    }

    // MARK: - Semantic-invalid dates (regex allows shape, DateFormatter rejects value)

    func testParseISODateRejectsMonthOutOfRange() {
        XCTAssertThrowsError(try parseISODate("2026-13-01"),
                             "month 13 should be rejected")
        XCTAssertThrowsError(try parseISODate("2026-00-01"),
                             "month 00 should be rejected")
    }

    func testParseISODateRejectsDayOutOfRange() {
        XCTAssertThrowsError(try parseISODate("2026-02-30"),
                             "Feb 30 should be rejected")
        XCTAssertThrowsError(try parseISODate("2025-02-29"),
                             "Feb 29 in non-leap year should be rejected")
    }

    func testParseISODateAcceptsLeapDay() throws {
        // 2024 is a leap year
        XCTAssertNotNil(try parseISODate("2024-02-29"))
    }

    // MARK: - DST safety (#5 verify finding)

    /// Construct end-of-day across DST fall-back boundary. Previously failed
    /// when parseUntilDate added +23h59m59s to start-of-day on a 25-hour day
    /// (excluding real 23:00-23:59 window). Fix constructs from wall-clock
    /// components directly, so Calendar resolves DST correctly.
    func testParseUntilDateOnDSTFallBackDay() throws {
        // 2026-11-01 is a DST fall-back day in America/New_York (EDT → EST).
        // This test uses current timezone — it serves as a regression guard
        // for any locale that sees this as a DST day; in tz without DST it
        // just confirms 23:59:59 behavior.
        let until = try parseUntilDate("2026-11-01")!
        let components = Calendar.current.dateComponents(
            [.hour, .minute, .second],
            from: until
        )
        XCTAssertEqual(components.hour, 23,
                       "hour must be 23 even on DST boundary day")
        XCTAssertEqual(components.minute, 59)
        XCTAssertEqual(components.second, 59)
    }

    // MARK: - Semantic contract: a message at end of `until_date` day is included

    func testMessageAt23_59_59IsIncluded() throws {
        let until = try parseUntilDate("2026-04-17")!
        // A message sent at 2026-04-17 23:59:58 should be within the bound
        let msgDate = makeLocalDate(year: 2026, month: 4, day: 17, hour: 23, minute: 59, second: 58)
        XCTAssertLessThanOrEqual(msgDate, until,
                                 "message at 23:59:58 should be <= until bound")
    }

    func testMessageAtNextDay00_00_00IsExcluded() throws {
        let until = try parseUntilDate("2026-04-17")!
        // A message sent at 2026-04-18 00:00:00 should be past the bound
        let msgDate = makeLocalDate(year: 2026, month: 4, day: 18, hour: 0, minute: 0, second: 0)
        XCTAssertGreaterThan(msgDate, until,
                             "message at next day 00:00 should be > until bound")
    }

    // MARK: - Helpers

    private func makeLocalDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone.current
        return Calendar.current.date(from: components)!
    }
}
