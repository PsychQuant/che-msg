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
public func parseISODate(_ s: String?, timeZone: TimeZone) throws -> Date? {
    guard let s = s, !s.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.isLenient = false

    // DateFormatter is surprisingly tolerant even with isLenient=false
    // (accepts "2026/04/17" and similar). Pre-check with a strict regex
    // before handing off to the formatter.
    let pattern = #"^\d{4}-\d{2}-\d{2}$"#
    guard s.range(of: pattern, options: .regularExpression) != nil,
          let date = formatter.date(from: s) else {
        throw DateParseError(input: s, expected: "YYYY-MM-DD")
    }
    return date
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
/// Implementation note: constructs end-of-day from wall-clock components
/// (year/month/day + hour=23/min=59/sec=59) rather than adding 23h59m59s
/// to start-of-day. The additive approach breaks on DST fall-back days
/// (e.g. America/New_York 2026-11-01 has 25 hours; +23:59:59 from
/// 00:00:00 EDT lands at 22:59:59 EST, excluding the real 23:00-23:59
/// window). Wall-clock construction lets Calendar resolve DST naturally.
///
/// The calendar is still `Calendar.current` with only its zone set to
/// `timeZone`, so both parsers read one zone; the calendar system (#84) and
/// days without a midnight (#85) are unchanged here.
public func parseUntilDate(_ s: String?) throws -> Date? {
    try parseUntilDate(s, timeZone: .current)
}

/// `parseUntilDate(_:)` in a given zone (#16).
public func parseUntilDate(_ s: String?, timeZone: TimeZone) throws -> Date? {
    guard let startOfDay = try parseISODate(s, timeZone: timeZone) else { return nil }
    var calendar = Calendar.current
    calendar.timeZone = timeZone
    var components = calendar.dateComponents([.year, .month, .day], from: startOfDay)
    components.hour = 23
    components.minute = 59
    components.second = 59
    components.timeZone = timeZone
    return calendar.date(from: components)
}
