import Foundation

/// Orchestrates exporting a Telegram chat's history to a Markdown file.
///
/// Workflow:
///   1. Validate output_path parent directory exists and is writable.
///   2. Fetch messages via `TDLibClient.getChatHistory` (with pagination + date filter).
///   3. Batch-resolve sender user_ids → display names (with fallback).
///   4. Render Markdown (day-grouped headings + `HH:mm sender: text` lines).
///   5. Write file, return summary metadata JSON string.
public struct MarkdownExporter {

    /// Error cases distinct enough for callers to branch on.
    public enum ExportError: LocalizedError {
        case outputPathNotWritable(path: String)
        case invalidDateFormat(String)

        public var errorDescription: String? {
            switch self {
            case .outputPathNotWritable(let path):
                return "Output path is not writable: \(path)"
            case .invalidDateFormat(let value):
                return "Invalid date format: \(value)"
            }
        }
    }

    private let client: TDLibClient

    public init(client: TDLibClient) {
        self.client = client
    }

    /// Main entry point. Returns a JSON string with summary metadata.
    public func dumpChatToMarkdown(
        chatId: Int64,
        outputPath: String,
        maxMessages: Int = 5000,
        sinceDate: Foundation.Date? = nil,
        untilDate: Foundation.Date? = nil,
        selfLabel: String = "我"
    ) async throws -> String {
        try validateOutputPath(outputPath)

        // Fetch the chat for title, type (for secret chat warning), and context.
        let chatJSON = try await client.getChat(chatId: chatId)
        let chatDict = jsonObject(chatJSON) ?? [:]
        let chatTitle = (chatDict["title"] as? String) ?? "Chat \(chatId)"
        let isSecret = (chatDict["type"] as? String) == "secret"

        // Fetch messages with bulk pagination + date filter.
        let messagesJSON = try await client.getChatHistory(
            chatId: chatId,
            limit: 100,
            fromMessageId: 0,
            maxMessages: maxMessages,
            sinceDate: sinceDate,
            untilDate: untilDate
        )
        let messages = jsonArray(messagesJSON) ?? []

        // Batch-resolve sender names.
        let senderNames = await resolveSenderNames(in: messages) { userId in
            try await self.client.getUser(userId: userId)
        }

        // Format Markdown.
        let markdown = formatMarkdown(
            messages: messages,
            senderNames: senderNames,
            selfLabel: selfLabel,
            chatTitle: chatTitle,
            chatId: chatId,
            sinceDate: sinceDate,
            untilDate: untilDate,
            exportedAt: Foundation.Date()
        )

        // Write file.
        try markdown.write(toFile: outputPath, atomically: true, encoding: .utf8)

        // Build summary metadata.
        return buildSummaryJSON(
            path: outputPath,
            messages: messages,
            senderNames: senderNames,
            sinceDate: sinceDate,
            untilDate: untilDate,
            isSecretChat: isSecret
        )
    }

    // MARK: - JSON plumbing (internal so tests can exercise)

    internal func jsonObject(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    internal func jsonArray(_ s: String) -> [[String: Any]]? {
        guard let data = s.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return arr
    }
}

// MARK: - Pure helpers (file-scope `internal` for test access)

/// Check that `outputPath`'s parent directory exists and is writable.
/// Throws `ExportError.outputPathNotWritable` on failure.
internal func validateOutputPath(_ path: String) throws {
    let url = URL(fileURLWithPath: path)
    let parent = url.deletingLastPathComponent()
    let fm = FileManager.default
    var isDir: ObjCBool = false
    let exists = fm.fileExists(atPath: parent.path, isDirectory: &isDir)
    if !exists || !isDir.boolValue || !fm.isWritableFile(atPath: parent.path) {
        throw MarkdownExporter.ExportError.outputPathNotWritable(path: path)
    }
}

/// Given messages with `sender.user_id` fields and a lookup closure returning a user JSON
/// (or throwing), build a `[userId: displayName]` cache. Throws by sender are caught and
/// replaced with fallback `User <id>` labels — the overall operation MUST NOT abort.
///
/// The lookup closure receives the user id and returns the JSON string produced by TDLib
/// `getUser` (same format as `TDLibClient.getUser`). Parseable fields `first_name` and
/// `last_name` are combined; if both are empty, falls back to `User <id>`.
internal func resolveSenderNames(
    in messages: [[String: Any]],
    lookup: (Int64) async throws -> String
) async -> [Int64: String] {
    var unique: Set<Int64> = []
    for msg in messages {
        if let sender = msg["sender"] as? [String: Any],
           let uid = userIdFromSender(sender) {
            unique.insert(uid)
        }
    }
    var cache: [Int64: String] = [:]
    for uid in unique {
        do {
            let json = try await lookup(uid)
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let first = (obj["first_name"] as? String) ?? ""
                let last = (obj["last_name"] as? String) ?? ""
                let full = [first, last].filter { !$0.isEmpty }.joined(separator: " ")
                cache[uid] = full.isEmpty ? "User \(uid)" : full
            } else {
                cache[uid] = "User \(uid)"
            }
        } catch {
            cache[uid] = "User \(uid)"
        }
    }
    return cache
}

internal func userIdFromSender(_ sender: [String: Any]) -> Int64? {
    if let n = sender["user_id"] as? NSNumber { return n.int64Value }
    return nil
}

/// Render messages as Markdown per the output format contract.
internal func formatMarkdown(
    messages: [[String: Any]],
    senderNames: [Int64: String],
    selfLabel: String,
    chatTitle: String,
    chatId: Int64,
    sinceDate: Foundation.Date?,
    untilDate: Foundation.Date?,
    exportedAt: Foundation.Date
) -> String {
    var out = "# 對話：\(chatTitle) (chat_id=\(chatId))\n"

    let isoNow = DateFormatter.exportTimestamp.string(from: exportedAt)
    var meta: [String] = ["匯出時間：\(isoNow)", "訊息數：\(messages.count)"]
    if let s = sinceDate {
        meta.append("since \(DateFormatter.isoDay.string(from: s))")
    }
    if let u = untilDate {
        meta.append("until \(DateFormatter.isoDay.string(from: u))")
    }
    out += meta.joined(separator: "　") + "\n\n---\n\n"

    // Group messages by local calendar day. Sort oldest → newest.
    let grouped = groupMessagesByDay(messages)
    let sortedDays = grouped.keys.sorted()

    for day in sortedDays {
        out += "## \(day)\n\n"
        let dayMessages = grouped[day] ?? []
        // Within a day, sort oldest → newest (messages come newest-first from TDLib).
        let sorted = dayMessages.sorted {
            (messageDate($0) ?? Foundation.Date()) < (messageDate($1) ?? Foundation.Date())
        }
        for msg in sorted {
            out += renderSingleMessage(msg, senderNames: senderNames, selfLabel: selfLabel)
        }
        out += "\n"
    }

    return out
}

internal func groupMessagesByDay(_ messages: [[String: Any]]) -> [String: [[String: Any]]] {
    var result: [String: [[String: Any]]] = [:]
    for msg in messages {
        guard let date = messageDate(msg) else { continue }
        let key = DateFormatter.isoDay.string(from: date)
        result[key, default: []].append(msg)
    }
    return result
}

internal func renderSingleMessage(
    _ msg: [String: Any],
    senderNames: [Int64: String],
    selfLabel: String
) -> String {
    guard let date = messageDate(msg) else { return "" }
    let hm = DateFormatter.hourMinute.string(from: date)
    let isOutgoing = (msg["is_outgoing"] as? Bool) ?? false
    let senderLabel: String
    if isOutgoing {
        senderLabel = selfLabel
    } else if let sender = msg["sender"] as? [String: Any],
              let uid = userIdFromSender(sender) {
        senderLabel = senderNames[uid] ?? "User \(uid)"
    } else {
        senderLabel = "Unknown"
    }

    let body = messageBody(msg)
    return "**\(hm) \(senderLabel)**：\n\(body)\n\n"
}

/// Produce the rendered body for a message dict: either its text, or a placeholder
/// such as `[photo]`, `[voice]`, `[video]` for non-text media types.
internal func messageBody(_ msg: [String: Any]) -> String {
    let type = (msg["type"] as? String) ?? "other"
    switch type {
    case "text":
        return (msg["text"] as? String) ?? ""
    case "photo": return "[photo]"
    case "video": return "[video]"
    case "voice_note": return "[voice]"
    case "video_note": return "[video_note]"
    case "sticker": return "[sticker]"
    case "document": return "[document]"
    case "location": return "[location]"
    case "animation": return "[animation]"
    case "poll": return "[poll]"
    default: return "[other]"
    }
}

internal func buildSummaryJSON(
    path: String,
    messages: [[String: Any]],
    senderNames: [Int64: String],
    sinceDate: Foundation.Date?,
    untilDate: Foundation.Date?,
    isSecretChat: Bool
) -> String {
    var summary: [String: Any] = [
        "path": path,
        "message_count": messages.count,
        "senders": senderNames.map { ["user_id": $0.key, "display_name": $0.value] },
    ]
    var dateRange: [String: Any] = [:]
    if let s = sinceDate { dateRange["since"] = DateFormatter.isoDay.string(from: s) }
    if let u = untilDate { dateRange["until"] = DateFormatter.isoDay.string(from: u) }
    summary["date_range"] = dateRange
    if isSecretChat {
        summary["warning"] = "Secret chat history is device-local; this export is partial. "
            + "Messages not synced to this device cannot be retrieved."
    }
    let data = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - DateFormatter cache (avoid repeated construction in hot paths)

private extension DateFormatter {
    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()
    static let hourMinute: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone.current
        return f
    }()
    static let exportTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone.current
        return f
    }()
}
