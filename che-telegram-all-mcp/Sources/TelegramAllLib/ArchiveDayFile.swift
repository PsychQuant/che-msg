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
    public enum WriteError: Error, LocalizedError, Equatable {
        /// The day file was written at another UTC offset; its times and day would disagree.
        case offsetMismatch(existing: String, requested: String)

        public var errorDescription: String? {
            switch self {
            case .offsetMismatch(let existing, let requested):
                return "utc_offset \(requested) differs from \(existing), the offset this archive's day files were "
                    + "written with; archive this chat with utc_offset \(existing)"
            }
        }
    }

    /// Seconds east of UTC for `+HH:MM` / `-HH:MM` up to ±18:00 (the range Foundation's
    /// `TimeZone(secondsFromGMT:)` accepts), or nil when malformed or out of range.
    public static func offsetSeconds(_ text: String) -> Int? {
        let chars = Array(text)
        let isDigit: (Character) -> Bool = { ("0"..."9").contains($0) }
        guard chars.count == 6, chars[0] == "+" || chars[0] == "-", chars[3] == ":",
              chars[1...2].allSatisfy(isDigit), chars[4...5].allSatisfy(isDigit),
              let hours = Int(String(chars[1...2])), let minutes = Int(String(chars[4...5])),
              minutes <= 59, hours * 3600 + minutes * 60 <= 18 * 3600 else { return nil }
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
        // The sender sits on the header line: a line break in it would start a new line that
        // the parser could read as an anchor, so line breaks become spaces.
        let sender = message.sender
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let body = message.body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { isAnchorOrHeaderShaped($0) ? "\\" + $0 : String($0) }
            .joined(separator: "\n")
        return "\(anchor(message.id))\n**\(time) \(sender)**：\n\(body)\n\n"
    }

    /// A body line that starts like an anchor, or reads like a block header
    /// (`**HH:mm name**：`), is escaped with a leading backslash so it cannot pass for the
    /// start of another message to the parser or to a reader.
    private static func isAnchorOrHeaderShaped(_ line: Substring) -> Bool {
        line.hasPrefix("<!--")
            || line.range(of: #"^\*\*[0-9]{2}:[0-9]{2} .*\*\*：$"#, options: .regularExpression) != nil
    }

    /// The `utc_offset` recorded in a day file's frontmatter, or nil.
    static func recordedOffset(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(8)
        where line.hasPrefix("utc_offset: ") {
            return line.dropFirst("utc_offset: ".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
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
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("\(day).md")
        let existing = fm.fileExists(atPath: file.path) ? try String(contentsOf: file, encoding: .utf8) : nil
        if let existing, let recorded = recordedOffset(existing), recorded != utcOffset {
            throw WriteError.offsetMismatch(existing: recorded, requested: utcOffset)
        }
        let (content, added) = merged(existing: existing, chatId: chatId, day: day, utcOffset: utcOffset,
                                      messages: messages)
        if added.isEmpty && existing != nil { return [] }
        let temporary = directory.appendingPathComponent(".\(day).md.\(UUID().uuidString).tmp")
        do {
            // Owner-only from the start: archives hold other people's messages.
            guard fm.createFile(atPath: temporary.path, contents: Data(content.utf8),
                                attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            if existing == nil {
                try fm.moveItem(at: temporary, to: file)
            } else {
                _ = try fm.replaceItemAt(file, withItemAt: temporary, options: .usingNewMetadataOnly)
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
