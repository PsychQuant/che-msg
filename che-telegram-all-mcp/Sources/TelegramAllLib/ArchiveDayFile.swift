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
        /// A day file in the chat directory has no readable `utc_offset`.
        case unreadableOffset(day: String)
        /// A day file in the chat directory is a symbolic link, FIFO, socket, device or directory (#76).
        case notRegularFile(day: String)
        /// A day file to merge into contains a carriage return; the merge splits lines on LF only (#76).
        case carriageReturn(day: String)

        public var errorDescription: String? {
            switch self {
            case .unreadableOffset(let day):
                return "day file \(day).md has no readable utc_offset in its frontmatter (or cannot be read, or uses "
                    + "CRLF line endings); this archive cannot be merged into safely (move the file aside or restore it)"
            case .notRegularFile(let day):
                return "day file \(day).md is not a regular file (a symbolic link, FIFO, socket, device or directory); this "
                    + "archive cannot be merged into safely (replace it with the file itself or move it aside)"
            case .carriageReturn(let day):
                return "day file \(day).md contains a carriage return (CRLF or CR line endings, as another editor may "
                    + "write them); this archive cannot be merged into safely (convert it to LF line endings or move it aside)"
            case .offsetMismatch(let existing, let requested):
                return "utc_offset \(requested) differs from \(existing), the offset this archive's day files were "
                    + "written with; archive this chat with utc_offset \(existing)"
            }
        }
    }

    /// Seconds east of UTC for `+HH:MM` / `-HH:MM` up to ±18:00 (the range Foundation's
    /// `TimeZone(secondsFromGMT:)` accepts), or nil when malformed or out of range.
    public static func offsetSeconds(_ text: String) -> Int? {
        let chars = Array(text.unicodeScalars)   // by scalar: a combining mark is not part of a digit
        let isDigit: (Unicode.Scalar) -> Bool = { ("0"..."9").contains($0) }
        let number: (ArraySlice<Unicode.Scalar>) -> Int? = { Int(String(String.UnicodeScalarView($0))) }
        guard chars.count == 6, chars[0] == "+" || chars[0] == "-", chars[3] == ":",
              chars[1...2].allSatisfy(isDigit), chars[4...5].allSatisfy(isDigit),
              let hours = number(chars[1...2]), let minutes = number(chars[4...5]),
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

    /// The body line(s) of `message` (its JSON object): its text; for a type that carries a file,
    /// `[type](media/<id>/)`; otherwise `[type]` — each followed by the message's detail, as
    /// `MessageBody` defines it (a caption, a poll's question and options, a sticker's emoji, a
    /// location's coordinates; #82). The link does not depend on whether the file has been downloaded.
    public static func body(of message: [String: Any], messageId: Int64) -> String {
        let type = (message["type"] as? String) ?? "other"
        let label = fileTypes.contains(type) ? "[\(type)](\(mediaLink(messageId)))" : "[\(type)]"
        return MessageBody.render(message, placeholder: label)
    }

    /// The anchor line that starts each message block.
    public static func anchor(_ id: Int64) -> String { "<!-- msg:\(id) -->" }

    /// The line right after the anchor of a block written from TDLib's local cache (#72). Such a
    /// block lacks what the local reader cannot give, so a later write through TDLib replaces it.
    /// Kept out of the anchor so that every reader, v0.8.0's parser included, still finds each
    /// block start at its unchanged anchor line.
    public static let provisionalMarker = "<!-- provisional: local-cache -->"

    /// True when `blockText` (a block as `parseBlocks` returns it) has as its second line exactly
    /// the scalars of the marker.
    static func isProvisional(_ blockText: String) -> Bool {
        let scalars = blockText.unicodeScalars
        guard let firstEnd = scalars.firstIndex(of: "\n") else { return false }
        let second = scalars[scalars.index(after: firstEnd)...].prefix { $0 != "\n" }
        return second.elementsEqual(provisionalMarker.unicodeScalars)
    }

    /// One message block: anchor, the provisional marker when `provisional`, `**HH:mm sender**：`,
    /// body, blank line. A body line that starts like an anchor (or the marker) is escaped so that
    /// it never reads back as one.
    public static func block(_ message: ArchiveMessage, offsetSeconds: Int, provisional: Bool = false) -> String {
        let time = formatter("HH:mm", offsetSeconds).string(from: message.date)
        // The sender sits on the header line: a line break in it would start a new line that
        // the parser could read as an anchor, so line breaks become spaces. Line breaks and line
        // starts are found by scalar, as every reader of the file finds them.
        let sender = ScalarText.replacingLineBreaks(in: message.sender, with: " ")
        let body = ScalarText.lines(ScalarText.replacingLineBreaks(in: message.body, with: "\n"))
            .map { isAnchorOrHeaderShaped($0) ? "\\" + $0 : $0 }
            .joined(separator: "\n")
        let marker = provisional ? provisionalMarker + "\n" : ""
        return "\(anchor(message.id))\n\(marker)**\(time) \(sender)**：\n\(body)\n\n"
    }

    /// A body line that starts like an anchor, or begins like a block header (`**` and a time,
    /// as in `**HH:mm name**：`), is escaped with a leading backslash so it cannot pass for the
    /// start of another message to the parser or to a reader.
    private static func isAnchorOrHeaderShaped(_ line: String) -> Bool {
        ScalarText.starts(line, with: "<!--") || ScalarText.startsLikeHeader(line)
    }

    /// Refuses when a day file in `directory` was written at another offset, or has no readable one.
    public static func checkOffsets(directory: URL, utcOffset: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }   // first run: nothing written yet
        let names = try fm.contentsOfDirectory(atPath: directory.path)
        // Only files named like a day are day files; anything else the user keeps there is left alone.
        for name in names.sorted()
        where name.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}\.md$"#, options: .regularExpression) != nil {
            let day = String(name.dropLast(3))
            guard let data = try readDayFile(directory.appendingPathComponent(name), day: day, limit: 512) else {
                throw WriteError.unreadableOffset(day: day)
            }
            try checkOffset(recordedIn: String(decoding: data, as: UTF8.self), day: day, utcOffset: utcOffset)
        }
    }

    /// The bytes of day file `file` (at most `limit`), or nil when there is no file of that name.
    /// The file is opened without following a symbolic link and without waiting for a writer — a
    /// FIFO named like a day file would otherwise block while the call holds the chat's lock — and
    /// only a regular file is read (#76).
    static func readDayFile(_ file: URL, day: String, limit: Int? = nil) throws -> Data? {
        let fd = open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            // Name what is at the day file's own name: a link (ELOOP under O_NOFOLLOW) or a socket
            // (EOPNOTSUPP) is not a regular file; a path that fails above it (a loop of links in a
            // parent directory) or a regular file that cannot be opened is unreadable.
            var info = stat()
            if lstat(file.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG { throw WriteError.notRegularFile(day: day) }
            throw WriteError.unreadableOffset(day: day)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw WriteError.unreadableOffset(day: day) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw WriteError.notRegularFile(day: day) }
        // The flag was for the open only; a read of a regular file does not block either way.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        do {
            if let limit { return try handle.read(upToCount: limit) ?? Data() }
            return try handle.readToEnd() ?? Data()
        } catch {
            throw WriteError.unreadableOffset(day: day)
        }
    }

    /// Refuses `utcOffset` for a day file whose frontmatter (`text`) records another offset or none.
    /// Offsets are compared in seconds, so `-00:00` equals `+00:00`.
    static func checkOffset(recordedIn text: String, day: String, utcOffset: String) throws {
        guard let recorded = recordedOffset(text), let seconds = offsetSeconds(recorded) else {
            throw WriteError.unreadableOffset(day: day)
        }
        if seconds != offsetSeconds(utcOffset) {
            throw WriteError.offsetMismatch(existing: recorded, requested: utcOffset)
        }
    }

    /// The `utc_offset` recorded in a day file's frontmatter, or nil.
    /// Only a well-formed offset inside the leading frontmatter is returned, so nothing else from
    /// the file can reach an error message.
    /// Lines are split on LF only, as the tool writes them: a file with CRLF frontmatter was edited
    /// elsewhere and the merge parser would not read its blocks, so it reads as unreadable.
    static func recordedOffset(_ text: String) -> String? {
        let lines = ScalarText.lines(text)
        guard let first = lines.first, ScalarText.equals(first, "---") else { return nil }
        for line in lines.dropFirst().prefix(8) {
            if ScalarText.equals(line, "---") { break }
            guard ScalarText.starts(line, with: "utc_offset: ") else { continue }
            let value = String(String.UnicodeScalarView(line.unicodeScalars.dropFirst("utc_offset: ".unicodeScalars.count)))
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            return offsetSeconds(value) == nil ? nil : value
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
    /// ordered by id. Existing blocks keep their exact text, except that when the messages come
    /// through TDLib (`provisional` false) a provisional block of one of them is replaced by its
    /// block as written now (#72); messages from the local cache (`provisional` true) are added
    /// with the marker and replace nothing. `added` lists the new ids, `upgraded` the replaced ones.
    public static func merged(existing: String?, chatId: Int64, day: String, utcOffset: String,
                              messages: [ArchiveMessage], provisional: Bool = false)
        -> (content: String, added: [Int64], upgraded: [Int64]) {
        let offset = offsetSeconds(utcOffset) ?? 0
        let parts = split(existing ?? "")
        var blocks: [Int64: String] = [:]
        for block in parts.blocks where blocks[block.id] == nil {
            blocks[block.id] = block.text.unicodeScalars.last == "\n" ? block.text : block.text + "\n"
        }
        var added: [Int64] = []
        var upgraded: [Int64] = []
        var handled: Set<Int64> = []
        for message in messages where handled.insert(message.id).inserted {
            if let current = blocks[message.id] {
                guard !provisional, isProvisional(current) else { continue }
                blocks[message.id] = block(message, offsetSeconds: offset)
                upgraded.append(message.id)
            } else {
                blocks[message.id] = block(message, offsetSeconds: offset, provisional: provisional)
                added.append(message.id)
            }
        }
        let body = blocks.keys.sorted().map { blocks[$0]! }.joined()
        return (frontmatter(chatId: chatId, day: day, utcOffset: utcOffset) + parts.preamble + body, added, upgraded)
    }

    /// Writes the day file for `day` under `directory` (created when missing), merging with
    /// the file already there as `merged` does, by writing a temporary file in the same directory
    /// and renaming it over the original. Leaves an existing file untouched when nothing is added
    /// or upgraded, and refuses one that is not a regular file, or that contains a carriage return
    /// and would be rewritten (a message it lacks, or a provisional block to upgrade).
    /// Returns the ids of the messages added and of the provisional blocks upgraded.
    @discardableResult
    public static func write(directory: URL, chatId: Int64, day: String, utcOffset: String,
                             messages: [ArchiveMessage], provisional: Bool = false) throws
        -> (added: [Int64], upgraded: [Int64]) {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("\(day).md")
        // Read through the same checks as `checkOffsets`: the file can have changed since (the
        // lock only keeps other archives out), and a dangling link must not read as "no file".
        let existing = try readDayFile(file, day: day).map { data -> String in
            guard let text = String(data: data, encoding: .utf8) else { throw WriteError.unreadableOffset(day: day) }
            return text
        }
        if let existing { try checkOffset(recordedIn: existing, day: day, utcOffset: utcOffset) }
        // The parser splits lines on LF, and "\r\n" is one Character: merging into a CRLF body would
        // find no anchors and add every message again. Checked by scalar, for the touched day only,
        // so the check before reading stays a 512-byte read per file. A file this call would not
        // change is left as it is (its anchors and markers read with CRLF as a line end; a lone CR
        // stays inside its line, so it cannot make text pass for either); a file it would rewrite —
        // to add a message, or to upgrade a provisional block (#72) — is refused (#76).
        if let existing, existing.unicodeScalars.contains("\r") {
            let wouldWrite = merged(existing: ScalarText.replacingCRLF(in: existing), chatId: chatId,
                                    day: day, utcOffset: utcOffset, messages: messages, provisional: provisional)
            guard wouldWrite.added.isEmpty, wouldWrite.upgraded.isEmpty else { throw WriteError.carriageReturn(day: day) }
            return ([], [])
        }
        let (content, added, upgraded) = merged(existing: existing, chatId: chatId, day: day, utcOffset: utcOffset,
                                                messages: messages, provisional: provisional)
        if added.isEmpty && upgraded.isEmpty && existing != nil { return ([], []) }
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
        return (added, upgraded)
    }

    /// Frontmatter dropped; text between it and the first anchor kept as `preamble`. Lines are
    /// found by LF scalar; every index used to cut the text sits right after an LF, which always
    /// ends a `Character`.
    private static func split(_ content: String) -> (preamble: String, blocks: [(id: Int64, text: String)]) {
        var rest = Substring(content)
        if let body = afterFrontmatter(rest) { rest = body }
        let scalars = rest.unicodeScalars
        var starts: [(id: Int64, index: Substring.Index)] = []
        var lineStart = scalars.startIndex
        while lineStart < scalars.endIndex {
            let lineEnd = scalars[lineStart...].firstIndex(of: "\n") ?? scalars.endIndex
            if let id = anchorId(scalars[lineStart..<lineEnd]) { starts.append((id, lineStart)) }
            lineStart = lineEnd < scalars.endIndex ? scalars.index(after: lineEnd) : scalars.endIndex
        }
        guard let first = starts.first else { return (String(rest), []) }
        var blocks: [(id: Int64, text: String)] = []
        for (n, start) in starts.enumerated() {
            let end = n + 1 < starts.count ? starts[n + 1].index : rest.endIndex
            blocks.append((start.id, String(rest[start.index..<end])))
        }
        return (String(rest[rest.startIndex..<first.index]), blocks)
    }

    /// The text after a leading frontmatter block (`---` lines) and one blank line, or nil when
    /// `content` does not start with frontmatter.
    private static func afterFrontmatter(_ content: Substring) -> Substring? {
        let scalars = content.unicodeScalars
        guard scalars.starts(with: "---\n".unicodeScalars) else { return nil }
        let close = Array("\n---\n".unicodeScalars)
        var i = scalars.index(scalars.startIndex, offsetBy: 4)   // after the opening line
        while i < scalars.endIndex {
            guard scalars[i...].starts(with: close) else { i = scalars.index(after: i); continue }
            var after = scalars.index(i, offsetBy: close.count)
            if after < scalars.endIndex, scalars[after] == "\n" { after = scalars.index(after: after) }
            return content[after...]
        }
        return nil
    }

    /// The id of an anchor line: exactly the scalars `<!-- msg:`, ASCII digits, ` -->`.
    private static func anchorId(_ line: Substring.UnicodeScalarView.SubSequence) -> Int64? {
        let scalars = Array(line)
        let head = Array("<!-- msg:".unicodeScalars), tail = Array(" -->".unicodeScalars)
        guard scalars.count > head.count + tail.count, scalars.starts(with: head),
              scalars.suffix(tail.count).elementsEqual(tail) else { return nil }
        let digits = scalars[head.count..<(scalars.count - tail.count)]
        guard digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int64(String(String.UnicodeScalarView(digits)))
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
