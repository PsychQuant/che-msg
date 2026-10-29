import Foundation
import MCP

/// `archive_conversation_to_markdown`'s checked arguments (spec:
/// slack-chat-archive, "Slack archive tool parameters").
struct ArchiveRequest: Equatable, Sendable {
    let conversationID: String
    /// Absolute and standardized (`..` resolved), not yet created.
    let outputDir: URL
    /// Only messages after this ts; takes precedence over `sinceSeconds`.
    let afterTS: String?
    /// The start of `since_date` at `utcOffset`, in seconds since 1970
    /// (never below 0); nil when `since_date` was not given or `after_ts`
    /// was.
    let sinceSeconds: Int64?
    /// The effective offset, as written into the day files.
    let utcOffset: String
    let offsetSeconds: Int
    /// The lookback window in days (spec: "Thread replies and lookback");
    /// 0 checks no earlier thread again.
    let threadLookbackDays: Int

    /// The lower bound the arguments set, as a ts; `ArchiveScope` lists the
    /// history from it, or from earlier for the lookback window.
    var oldest: String? { afterTS ?? sinceSeconds.map(String.init) }
}

extension SlackToolHandler {
    /// `thread_lookback_days`: the spec's range and default.
    static let threadLookbackDays = IntegerBounds(range: 0...365, defaultValue: 30)

    /// The checked arguments. Without `utc_offset`, the server's offset at
    /// the time of the call (`localOffsetSeconds`) is used; `since_date` is
    /// midnight at the effective offset, so a day means the same as in the
    /// day files.
    static func archiveRequest(_ args: ToolArguments, localOffsetSeconds: Int) throws(ToolFailure) -> ArchiveRequest {
        let conversationID = try args.id("conversation_id", conversationIDMeaning)
        let outputDir = try args.absoluteDirectory("output_dir")
        let afterTS = try args.optionalTimestamp("after_ts")
        let given = try args.optionalUTCOffset("utc_offset")
        let offsetSeconds = given.flatMap(SlackDayFile.offsetSeconds) ?? localOffsetSeconds
        let utcOffset = given ?? SlackDayFile.formatOffset(localOffsetSeconds)
        let since = try args.optionalDate("since_date", offsetSeconds: offsetSeconds)
        let lookback = try args.integer("thread_lookback_days", threadLookbackDays)
        return ArchiveRequest(conversationID: conversationID, outputDir: outputDir, afterTS: afterTS,
                              sinceSeconds: afterTS == nil ? since : nil, utcOffset: utcOffset,
                              offsetSeconds: offsetSeconds, threadLookbackDays: lookback)
    }
}

extension ToolArguments {
    /// The longest path accepted, in UTF-8 bytes (macOS `PATH_MAX`).
    static let maxPathBytes = 1024

    /// A required absolute directory path. A relative path is refused
    /// rather than resolved against the server's working directory, which
    /// the caller cannot see; `~` is not expanded.
    func absoluteDirectory(_ name: String) throws(ToolFailure) -> URL {
        guard case let .string(path)? = values[name], path.hasPrefix("/"), !path.contains("\0"),
              path.utf8.count <= Self.maxPathBytes
        else {
            throw ToolFailure("\(name) is required and must be an absolute path (starting with /) of at most "
                              + "\(Self.maxPathBytes) bytes; a relative path or ~ is not accepted.")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// `+HH:MM` or `-HH:MM`, at most 18:00 either way; nil when omitted.
    func optionalUTCOffset(_ name: String) throws(ToolFailure) -> String? {
        let refusal = ToolFailure("\(name) must be a string +HH:MM or -HH:MM, at most 18:00 either way, "
                                  + "such as \"+08:00\".")
        switch values[name] {
        case nil, .null?: return nil
        case let .string(value)? where SlackDayFile.offsetSeconds(value) != nil: return value
        default: throw refusal
        }
    }

    /// A real calendar date `YYYY-MM-DD`, as the seconds since 1970 of its
    /// midnight at `offsetSeconds` (0 for an earlier date); nil when omitted.
    func optionalDate(_ name: String, offsetSeconds: Int) throws(ToolFailure) -> Int64? {
        let refusal = ToolFailure("\(name) must be a date written as a string YYYY-MM-DD, such as \"2026-11-01\".")
        switch values[name] {
        case nil, .null?:
            return nil
        case let .string(value)?:
            let parts = value.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, zip(parts, [4, 2, 2]).allSatisfy({ part, width in
                      part.count == width && part.allSatisfy { $0.isASCII && $0.isNumber }
                  }),
                  let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
            else { throw refusal }
            var calendar = Calendar(identifier: .gregorian)
            guard let zone = TimeZone(secondsFromGMT: offsetSeconds) else { throw refusal }
            calendar.timeZone = zone
            let components = DateComponents(calendar: calendar, timeZone: zone, year: year, month: month, day: day)
            guard components.isValidDate, let midnight = calendar.date(from: components) else { throw refusal }
            return max(0, Int64(midnight.timeIntervalSince1970))
        default:
            throw refusal
        }
    }
}
