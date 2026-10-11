import Foundation

/// One message as the archive writes it (PsychQuant/che-msg#69).
public struct ArchiveMessage: Equatable, Sendable {
    public let id: Int64
    public let date: Date
    public let sender: String
    public let body: String

    public init(id: Int64, date: Date, sender: String, body: String) {
        self.id = id
        self.date = date
        self.sender = sender
        self.body = body
    }
}

/// The per-chat per-day Markdown file of the Telegram archive
/// (telegram-chat-archive, "Day file format").
public enum ArchiveDayFile {
    /// Seconds east of UTC for `+HH:MM` / `-HH:MM`, or nil when malformed.
    public static func offsetSeconds(_ text: String) -> Int? {
        let chars = Array(text)
        guard chars.count == 6, chars[0] == "+" || chars[0] == "-", chars[3] == ":",
              let hours = Int(String(chars[1...2])), let minutes = Int(String(chars[4...5])),
              chars[1...2].allSatisfy(\.isASCII), chars[4...5].allSatisfy(\.isASCII),
              hours <= 23, minutes <= 59 else { return nil }
        let seconds = hours * 3600 + minutes * 60
        return chars[0] == "-" ? -seconds : seconds
    }

    /// The local date `YYYY-MM-DD` of `date` at `offsetSeconds`.
    public static func dayKey(for date: Date, offsetSeconds: Int) -> String {
        formatter("yyyy-MM-dd", offsetSeconds).string(from: date)
    }

    /// Message types that carry a downloadable file.
    public static let fileTypes: Set<String> = [
        "photo", "video", "document", "audio", "voice_note", "video_note", "animation", "sticker",
    ]

    /// The media directory of a message, relative to its day file.
    public static func mediaLink(_ messageId: Int64) -> String { "media/\(messageId)/" }

    /// The body line(s) for a message of `type`: its text; for a type that carries a file,
    /// `[type](media/<id>/)`; otherwise `[type]` — each followed by the caption when there is
    /// one. The link does not depend on whether the file has been downloaded.
    public static func body(type: String, text: String?, caption: String?, messageId: Int64) -> String {
        if type == "text" { return text ?? "" }
        let label = fileTypes.contains(type) ? "[\(type)](\(mediaLink(messageId)))" : "[\(type)]"
        if let caption, !caption.isEmpty { return "\(label) \(caption)" }
        return label
    }

    /// The anchor line that starts each message block.
    public static func anchor(_ id: Int64) -> String { "<!-- msg:\(id) -->" }

    /// One message block: anchor, `**HH:mm sender**：`, body, blank line. A body line that
    /// starts like an anchor is escaped so that it never reads back as one.
    public static func block(_ message: ArchiveMessage, offsetSeconds: Int) -> String {
        let time = formatter("HH:mm", offsetSeconds).string(from: message.date)
        let body = message.body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("<!--") ? "\\" + $0 : String($0) }
            .joined(separator: "\n")
        return "\(anchor(message.id))\n**\(time) \(message.sender)**：\n\(body)\n\n"
    }

    /// The frontmatter block of a day file.
    public static func frontmatter(chatId: Int64, day: String, utcOffset: String) -> String {
        "---\nchat_id: \(chatId)\ndate: \(day)\nutc_offset: \"\(utcOffset)\"\n---\n\n"
    }

    /// The whole day file for `messages`, all on `day`, ordered by message id.
    public static func render(chatId: Int64, day: String, utcOffset: String,
                              messages: [ArchiveMessage]) -> String {
        let offset = offsetSeconds(utcOffset) ?? 0
        return frontmatter(chatId: chatId, day: day, utcOffset: utcOffset)
            + messages.sorted { $0.id < $1.id }.map { block($0, offsetSeconds: offset) }.joined()
    }

    /// The message blocks of an existing day file, in file order, each with its exact text.
    /// A block starts at a line that is exactly an anchor and runs to the next such line.
    public static func parseBlocks(_ content: String) -> [(id: Int64, text: String)] {
        split(content).blocks
    }

    /// `existing` with every message of `messages` whose anchor it lacks added, all blocks
    /// ordered by id; existing blocks keep their exact text. `added` lists the new ids.
    public static func merged(existing: String?, chatId: Int64, day: String, utcOffset: String,
                              messages: [ArchiveMessage]) -> (content: String, added: [Int64]) {
        let offset = offsetSeconds(utcOffset) ?? 0
        let parts = split(existing ?? "")
        var blocks: [Int64: String] = [:]
        for block in parts.blocks where blocks[block.id] == nil {
            blocks[block.id] = block.text.hasSuffix("\n") ? block.text : block.text + "\n"
        }
        var added: [Int64] = []
        for message in messages where blocks[message.id] == nil {
            blocks[message.id] = block(message, offsetSeconds: offset)
            added.append(message.id)
        }
        let body = blocks.keys.sorted().map { blocks[$0]! }.joined()
        return (frontmatter(chatId: chatId, day: day, utcOffset: utcOffset) + parts.preamble + body, added)
    }

    /// Writes the day file for `day` under `directory` (created when missing), merging with
    /// the file already there, by writing a temporary file in the same directory and renaming
    /// it over the original. Leaves an existing file untouched when nothing is added.
    /// Returns the ids of the messages added.
    @discardableResult
    public static func write(directory: URL, chatId: Int64, day: String, utcOffset: String,
                             messages: [ArchiveMessage]) throws -> [Int64] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(day).md")
        let existing = fm.fileExists(atPath: file.path) ? try String(contentsOf: file, encoding: .utf8) : nil
        let (content, added) = merged(existing: existing, chatId: chatId, day: day, utcOffset: utcOffset,
                                      messages: messages)
        if added.isEmpty && existing != nil { return [] }
        let temporary = directory.appendingPathComponent(".\(day).md.\(UUID().uuidString).tmp")
        do {
            try Data(content.utf8).write(to: temporary)
            if existing == nil {
                try fm.moveItem(at: temporary, to: file)
            } else {
                _ = try fm.replaceItemAt(file, withItemAt: temporary)
            }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        return added
    }

    /// Frontmatter dropped; text between it and the first anchor kept as `preamble`.
    private static func split(_ content: String) -> (preamble: String, blocks: [(id: Int64, text: String)]) {
        var rest = Substring(content)
        if rest.hasPrefix("---\n"), let end = rest.dropFirst(4).range(of: "\n---\n") {
            rest = rest[end.upperBound...]
            if rest.hasPrefix("\n") { rest = rest.dropFirst() }
        }
        var starts: [(id: Int64, index: Substring.Index)] = []
        var lineStart = rest.startIndex
        while lineStart < rest.endIndex {
            let lineEnd = rest[lineStart...].firstIndex(of: "\n") ?? rest.endIndex
            if let id = anchorId(rest[lineStart..<lineEnd]) { starts.append((id, lineStart)) }
            lineStart = lineEnd < rest.endIndex ? rest.index(after: lineEnd) : rest.endIndex
        }
        guard let first = starts.first else { return (String(rest), []) }
        var blocks: [(id: Int64, text: String)] = []
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].index : rest.endIndex
            blocks.append((start.id, String(rest[start.index..<end])))
        }
        return (String(rest[rest.startIndex..<first.index]), blocks)
    }

    private static func anchorId(_ line: Substring) -> Int64? {
        guard line.hasPrefix("<!-- msg:"), line.hasSuffix(" -->") else { return nil }
        let digits = line.dropFirst("<!-- msg:".count).dropLast(" -->".count)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(digits)
    }

    private static func formatter(_ format: String, _ offsetSeconds: Int) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        f.dateFormat = format
        return f
    }
}
