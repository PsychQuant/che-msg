import Foundation

/// Thrown when an ISO date string fails to parse. Distinct from the silent-nil
/// path used for empty/nil input (which represents "no filter").
public struct DateParseError: Error, CustomStringConvertible {
    public let input: String
    public let expected: String

    /// Cap reflected input at 128 chars to prevent response-size amplification
    /// (#10 C1). Caller sending a 1MB string would otherwise produce a 1MB
    /// errorResult body — minor concern, but worth bounding for log capture
    /// and streaming clients.
    private static let inputDisplayCap = 128

    public init(input: String, expected: String) {
        self.input = input
        self.expected = expected
    }

    public var description: String {
        let displayed: String
        if input.count > Self.inputDisplayCap {
            displayed = String(input.prefix(Self.inputDisplayCap)) + "...(truncated)"
        } else {
            displayed = input
        }
        return "Date format invalid: expected \(expected), got \"\(displayed)\""
    }
}

/// Parse an ISO date string (`YYYY-MM-DD`) as the **start of the day** in
/// the server's zone (the tool schemas call it "local"), or in `timeZone`.
/// Used for `since_date` bounds. Tests pass a fixed zone so their oracle does
/// not share the host's zone with the code under test (#16).
///
/// - Returns `nil` for nil or empty input (meaning "no lower bound").
/// - Throws `DateParseError` for any non-empty string that doesn't match the format.
///
/// The throwing behavior is deliberate: silent-nil on invalid input (previous
/// behavior) was a UX footgun — a typo like `"2026/04/17"` silently disabled
/// the filter (#5-A2).
public func parseISODate(_ s: String?) throws -> Date? {
    try parseISODate(s, timeZone: .current)
}

/// `parseISODate(_:)` in a given zone (#16).
///
/// The day is read with a Gregorian calendar pinned to `timeZone`, never the
/// Region's calendar (#84), and its start is the day's first instant: on a day
/// whose 00:00 is skipped (America/Santiago 2026-09-06) that is 01:00, where a
/// strict formatter rejected the day as a bad format (#85). Impossible dates
/// (2026-02-30, 2026-13-01) are rejected because their components do not
/// survive the round trip through the calendar.
public func parseISODate(_ s: String?, timeZone: TimeZone) throws -> Date? {
    guard let s = s, !s.isEmpty else { return nil }
    guard let day = calendarDay(s, timeZone: timeZone) else {
        throw DateParseError(input: s, expected: "YYYY-MM-DD")
    }
    return day.calendar.startOfDay(for: day.noon)
}

/// Noon of the day `s` names, and the calendar that read it. Noon exists on
/// every day the zone has, so a missing midnight cannot make a real day fail.
/// Digits must be ASCII: `\d` in the pattern also matches full-width and
/// Arabic-Indic digits, which `Int` then refuses.
private func calendarDay(_ s: String, timeZone: TimeZone) -> (calendar: Calendar, noon: Date)? {
    // A strict pattern first: the calendar would otherwise normalise the
    // pieces of "2026/04/17" or "26-4-17" as well (#5-A2).
    guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
    let parts = s.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let wanted = DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12)
    guard let noon = calendar.date(from: wanted) else { return nil }
    let got = calendar.dateComponents([.year, .month, .day], from: noon)
    guard got.year == parts[0], got.month == parts[1], got.day == parts[2] else { return nil }
    return (calendar, noon)
}

/// Parse an ISO date string (`YYYY-MM-DD`) as the **end of the day** (23:59:59)
/// in the server's zone, or in `timeZone`. Used for `until_date` bounds so that
/// "include the whole day" semantics work correctly.
///
/// - Returns `nil` for nil or empty input.
/// - Throws `DateParseError` for invalid format.
///
/// Without this helper, `until_date: "2026-04-17"` would parse to
/// 2026-04-17 00:00:00 and exclude all messages later that day (#5-A1).
///
/// The end is the day's last instant, from the same calendar and zone as
/// `parseISODate`. Not wall-clock 23:59:59: on a day whose clocks fall back at
/// midnight (America/Santiago 2026-04-04) 23:00–23:59 happens twice and
/// 23:59:59 names the first of them, which would leave an hour out (#85). Nor
/// start of day plus 23:59:59, which is wrong on every 23- or 25-hour day
/// (America/New_York 2026-11-01, #28). On every other day all three agree.
///
/// Two exceptions no Telegram date reaches: a day whose local date is split in
/// two by a clock change (Newfoundland before 2011 set its clocks back from
/// 00:01 to 23:01) ends at the end of its first part, and dates before the
/// Gregorian reform (1582) follow Foundation's Julian/Gregorian calendar.
public func parseUntilDate(_ s: String?) throws -> Date? {
    try parseUntilDate(s, timeZone: .current)
}

/// `parseUntilDate(_:)` in a given zone (#16).
public func parseUntilDate(_ s: String?, timeZone: TimeZone) throws -> Date? {
    guard let s = s, !s.isEmpty else { return nil }
    guard let day = calendarDay(s, timeZone: timeZone),
          let interval = day.calendar.dateInterval(of: .day, for: day.noon) else {
        throw DateParseError(input: s, expected: "YYYY-MM-DD")
    }
    // DateInterval's end is the next day's first instant.
    return interval.end.addingTimeInterval(-1)
}
