import Foundation

/// One message as the archive writes it.
struct ArchivedMessage: Equatable, Sendable {
    let ts: String
    /// The thread parent's `ts` for a thread reply; nil for a top-level message.
    let parentTS: String?
    let sender: String
    let body: String
}

/// The per-conversation per-day markdown file (spec: slack-chat-archive,
/// "Slack day file format"; design: 歸檔格式對齊 telegram-chat-archive).
/// The layout is che-telegram-all-mcp's `ArchiveDayFile` with the anchor
/// holding the message's `ts`:
///
///     ---
///     team_id: "T01"
///     conversation_id: "C01"
///     date: 2026-11-01
///     utc_offset: "+08:00"
///     ---
///
///     <!-- msg:1793498700.000100 -->
///     **10:05 Alex**：
///     hello
///
///     <!-- msg:1793498820.000200 -->
///     **10:07 我** ↳ thread:1793498700.000100：
///     thanks
///
/// The ids are quoted so that YAML reads them as strings whatever they are.
enum SlackDayFile {
    /// The latest second a ts may name: 9999-12-31 23:59:59 UTC, so every
    /// ts has a four-digit year.
    static let maxSeconds: Int64 = 253_402_300_799

    /// The whole seconds of a Slack `ts` (`1793498700.000100`), or nil when
    /// it is not ASCII digits with an optional `.` and digits, or names a
    /// second past `maxSeconds`. A message whose ts is nil here cannot be
    /// anchored and is not written.
    static func seconds(ofTS ts: String) -> Int64? {
        guard ToolArguments.isTimestamp(ts) else { return nil }
        let whole = ts.prefix { $0 != "." }
        guard whole.count <= 12, let seconds = Int64(whole), seconds <= maxSeconds else { return nil }
        return seconds
    }

    /// True when `a` is an earlier ts than `b`: seconds compared as numbers,
    /// then the fraction padded with zeros; equal values fall back to the
    /// text, so the order is total. Both must pass `seconds(ofTS:)`.
    static func precedes(_ a: String, _ b: String) -> Bool {
        let (secondsA, secondsB) = (seconds(ofTS: a) ?? 0, seconds(ofTS: b) ?? 0)
        if secondsA != secondsB { return secondsA < secondsB }
        let (fractionA, fractionB) = (fraction(a), fraction(b))
        let width = max(fractionA.count, fractionB.count)
        let (paddedA, paddedB) = (fractionA.padding(toLength: width, withPad: "0", startingAt: 0),
                                  fractionB.padding(toLength: width, withPad: "0", startingAt: 0))
        return paddedA != paddedB ? paddedA < paddedB : a < b
    }

    private static func fraction(_ ts: String) -> String {
        ts.firstIndex(of: ".").map { String(ts[ts.index(after: $0)...]) } ?? ""
    }

    /// The local date `YYYY-MM-DD` of `ts` at `offsetSeconds`.
    static func dayKey(ts: String, offsetSeconds: Int) -> String {
        format(ts, "yyyy-MM-dd", offsetSeconds)
    }

    /// `messages` grouped by their local date at `offsetSeconds`.
    static func byDay(_ messages: [ArchivedMessage], offsetSeconds: Int) -> [String: [ArchivedMessage]] {
        Dictionary(grouping: messages) { dayKey(ts: $0.ts, offsetSeconds: offsetSeconds) }
    }

    static func anchor(_ ts: String) -> String { "<!-- msg:\(ts) -->" }

    static func frontmatter(teamID: String, conversationID: String, day: String, utcOffset: String) -> String {
        "---\nteam_id: \"\(teamID)\"\nconversation_id: \"\(conversationID)\"\ndate: \(day)\nutc_offset: \"\(utcOffset)\"\n---\n\n"
    }

    /// One block: anchor, header, body, blank line. The header is
    /// `**HH:mm sender**：`, or `**HH:mm sender** ↳ thread:<parent_ts>：`
    /// for a reply. A line break in the sender becomes a space, and a body
    /// line shaped like an anchor or a header gets a leading backslash, so
    /// neither can pass for the start of another block.
    static func block(_ message: ArchivedMessage, offsetSeconds: Int) -> String {
        let time = format(message.ts, "HH:mm", offsetSeconds)
        let sender = message.sender
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let thread = message.parentTS.map { " ↳ thread:\($0)" } ?? ""
        let body = message.body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { isAnchorOrHeaderShaped($0) ? "\\" + $0 : String($0) }
            .joined(separator: "\n")
        return "\(anchor(message.ts))\n**\(time) \(sender)**\(thread)：\n\(body)\n\n"
    }

    private static func isAnchorOrHeaderShaped(_ line: Substring) -> Bool {
        line.hasPrefix("<!--") || line.range(of: #"^\*\*[0-9]{1,2}:[0-9]{2}"#, options: .regularExpression) != nil
    }

    /// The day file holding only `messages`.
    static func render(teamID: String, conversationID: String, day: String, utcOffset: String,
                       messages: [ArchivedMessage]) -> String {
        merged(existing: nil, teamID: teamID, conversationID: conversationID, day: day, utcOffset: utcOffset,
               messages: messages).content
    }

    /// `existing` (a day file's text, or nil) with `messages` merged in by
    /// ts (spec: "Incremental archive and manifest"; as in
    /// che-telegram-all-mcp): a message whose ts already has a block is left
    /// out, so the block keeps what was archived first, an edited message
    /// its archived text and a renamed sender the archived name; any other
    /// is added, the first of a ts given twice; blocks are ordered by ts.
    /// With nothing added, `existing` is returned byte for byte. Otherwise
    /// the existing blocks and the text between the frontmatter and the
    /// first anchor are kept, a last block without a final line break gets
    /// one, and the frontmatter is written anew. When an anchor appears
    /// twice in `existing`, the first block is kept. `added` lists the ts
    /// that had no block.
    static func merged(existing: String?, teamID: String, conversationID: String, day: String, utcOffset: String,
                       messages: [ArchivedMessage]) -> (content: String, added: [String]) {
        let offset = offsetSeconds(utcOffset) ?? 0
        let parts = split(existing ?? "")
        var blocks: [String: String] = [:]
        for block in parts.blocks where blocks[block.ts] == nil {
            blocks[block.ts] = block.text.hasSuffix("\n") ? block.text : block.text + "\n"
        }
        var added: [String] = []
        for message in messages where blocks[message.ts] == nil {
            added.append(message.ts)
            blocks[message.ts] = block(message, offsetSeconds: offset)
        }
        if let existing, added.isEmpty { return (existing, []) }
        let body = blocks.keys.sorted(by: precedes).map { blocks[$0]! }.joined()
        return (frontmatter(teamID: teamID, conversationID: conversationID, day: day, utcOffset: utcOffset)
                + parts.preamble + body, added)
    }

    /// The ts of every block in `content`, a day file's text.
    static func anchoredTS(_ content: String) -> Set<String> {
        Set(split(content).blocks.map(\.ts))
    }

    /// The frontmatter dropped; text between it and the first anchor kept
    /// as `preamble`; each block runs from an anchor line to the next.
    private static func split(_ content: String) -> (preamble: String, blocks: [(ts: String, text: String)]) {
        var rest = Substring(content)
        if rest.hasPrefix("---\n"), let end = rest.dropFirst(4).range(of: "\n---\n") {
            rest = rest[end.upperBound...]
            if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        }
        var starts: [(ts: String, index: Substring.Index)] = []
        var lineStart = rest.startIndex
        while lineStart < rest.endIndex {
            let lineEnd = rest[lineStart...].firstIndex(of: "\n") ?? rest.endIndex
            if let ts = anchorTS(rest[lineStart..<lineEnd]) { starts.append((ts, lineStart)) }
            lineStart = lineEnd < rest.endIndex ? rest.index(after: lineEnd) : rest.endIndex
        }
        guard let first = starts.first else { return (String(rest), []) }
        var blocks: [(ts: String, text: String)] = []
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].index : rest.endIndex
            blocks.append((start.ts, String(rest[start.index..<end])))
        }
        return (String(rest[rest.startIndex..<first.index]), blocks)
    }

    /// The ts of a line that is exactly an anchor, or nil.
    private static func anchorTS(_ line: Substring) -> String? {
        guard line.hasPrefix("<!-- msg:"), line.hasSuffix(" -->") else { return nil }
        let ts = String(line.dropFirst("<!-- msg:".count).dropLast(" -->".count))
        return seconds(ofTS: ts) == nil ? nil : ts
    }

    // MARK: - Offsets and time

    /// Seconds east of UTC for `+HH:MM` / `-HH:MM` up to ±18:00, or nil.
    static func offsetSeconds(_ text: String) -> Int? {
        let chars = Array(text)
        let isDigit: (Character) -> Bool = { ("0"..."9").contains($0) }
        guard chars.count == 6, chars[0] == "+" || chars[0] == "-", chars[3] == ":",
              chars[1...2].allSatisfy(isDigit), chars[4...5].allSatisfy(isDigit),
              let hours = Int(String(chars[1...2])), let minutes = Int(String(chars[4...5])),
              minutes <= 59, hours * 3600 + minutes * 60 <= 18 * 3600 else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return chars[0] == "-" ? -seconds : seconds
    }

    /// `+HH:MM` / `-HH:MM` for `seconds` east of UTC.
    static func formatOffset(_ seconds: Int) -> String {
        let minutes = abs(seconds) / 60
        return String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", minutes / 60, minutes % 60)
    }

    private static func format(_ ts: String, _ pattern: String, _ offsetSeconds: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        formatter.dateFormat = pattern
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds(ofTS: ts) ?? 0)))
    }
}
