import Foundation
import MCP
import TelegramAllLib

/// Arguments of `archive_chat_to_markdown` and `download_message_media` (PsychQuant/che-msg#69).
/// Every refusal is a `HandlerArgError` naming the argument, raised before anything is read
/// or written.

internal struct DownloadMediaArgs: Equatable {
    let chatId: Int64
    let messageId: Int64
    let outputDir: URL
}

/// `archive_chat_to_markdown` arguments as an archive request. Without `utc_offset` the
/// server's offset at `now` in `timeZone` is used; `since_date` is midnight at that offset,
/// so "a day" means the same thing as in the day files.
internal func parseArchiveChatArgs(_ args: [String: Value], now: Date = Date(),
                                   timeZone: TimeZone = .current) throws -> ChatArchiver.Request {
    let chatId = try requiredInt64(args, "chat_id")
    let outputDir = try absoluteDirectoryArg(args, "output_dir")
    let afterMessageId = try int64ArgValueStrict(args, "after_message_id")
    if let afterMessageId, afterMessageId < 0 {
        throw HandlerArgError(message: "after_message_id must not be negative; got \(afterMessageId)")
    }
    let utcOffset: String
    if let given = try optionalStringArg(args, "utc_offset") {
        guard ArchiveDayFile.offsetSeconds(given) != nil else {
            throw HandlerArgError(message: "utc_offset must be +HH:MM or -HH:MM; got \"\(given)\"")
        }
        utcOffset = given
    } else {
        utcOffset = formatUTCOffset(timeZone.secondsFromGMT(for: now))
    }
    let since = try optionalStringArg(args, "since_date").map { try archiveDay($0, utcOffset: utcOffset) }
    let maxMediaBytes = try int64ArgValueStrict(args, "max_media_bytes")
    if let maxMediaBytes, maxMediaBytes < 0 {
        throw HandlerArgError(message: "max_media_bytes must not be negative; got \(maxMediaBytes)")
    }
    return ChatArchiver.Request(chatId: chatId, outputDir: outputDir, afterMessageId: afterMessageId, since: since,
                                utcOffset: utcOffset, maxMediaBytes: maxMediaBytes,
                                retryMediaMessageIds: try messageIdListArg(args, "retry_media_message_ids"))
}

internal func parseDownloadMediaArgs(_ args: [String: Value]) throws -> DownloadMediaArgs {
    let chatId = try requiredInt64(args, "chat_id")
    let messageId = try requiredInt64(args, "message_id")
    guard messageId > 0 else { throw HandlerArgError(message: "message_id must be positive; got \(messageId)") }
    return DownloadMediaArgs(chatId: chatId, messageId: messageId, outputDir: try absoluteDirectoryArg(args, "output_dir"))
}

/// `+HH:MM` / `-HH:MM` for `seconds` east of UTC.
internal func formatUTCOffset(_ seconds: Int) -> String {
    let minutes = abs(seconds) / 60
    return String(format: "%@%02d:%02d", seconds < 0 ? "-" : "+", minutes / 60, minutes % 60)
}

/// A string argument, nil when absent or null, refused when it is another type.
private func optionalStringArg(_ args: [String: Value], _ key: String) throws -> String? {
    guard let raw = args[key] else { return nil }
    if case .null = raw { return nil }
    guard let text = raw.stringValue else { throw HandlerArgError(message: "\(key) must be a string") }
    return text
}

/// A required absolute directory path. Relative paths are refused rather than resolved
/// against the server's working directory, which the caller cannot see.
private func absoluteDirectoryArg(_ args: [String: Value], _ key: String) throws -> URL {
    guard let path = try optionalStringArg(args, key) else { throw HandlerArgError(message: "\(key) is required") }
    guard path.hasPrefix("/") else {
        throw HandlerArgError(message: "\(key) must be an absolute path; got \"\(path)\"")
    }
    return URL(fileURLWithPath: path).standardizedFileURL
}

/// Midnight of `text` (`YYYY-MM-DD`, a real calendar date) at `utcOffset`.
private func archiveDay(_ text: String, utcOffset: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: ArchiveDayFile.offsetSeconds(utcOffset) ?? 0)
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: text), formatter.string(from: date) == text else {
        throw HandlerArgError(message: "since_date must be a date in the form YYYY-MM-DD; got \"\(text)\"")
    }
    return date
}

/// A list of positive message ids, nil when absent or null.
private func messageIdListArg(_ args: [String: Value], _ key: String) throws -> [Int64]? {
    guard let raw = args[key] else { return nil }
    if case .null = raw { return nil }
    guard let items = raw.arrayValue else { throw HandlerArgError(message: "\(key) must be a list of message ids") }
    return try items.enumerated().map { index, item in
        guard let id = Int(item, strict: false), id > 0 else {
            throw HandlerArgError(message: "\(key) must hold positive integer message ids; item \(index) is not one")
        }
        return Int64(id)
    }
}
