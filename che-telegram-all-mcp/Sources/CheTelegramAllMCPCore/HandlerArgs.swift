import Foundation
import MCP

/// Parsed arguments for the `get_chat_history` MCP tool.
/// Isolated from the MCP handler so we can unit-test the parsing/validation
/// logic (including the #3 fromMsgId==0 auto-pagination rule) without a
/// live TDLib connection.
internal struct GetChatHistoryArgs {
    let chatId: Int64
    let limit: Int
    let fromMessageId: Int64
    let maxMessages: Int?
    let sinceDate: Date?
    let untilDate: Date?
}

/// Thrown when an MCP tool argument fails validation (required field missing,
/// out-of-range, invalid format). Handlers catch and convert to `errorResult`.
internal struct HandlerArgError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Parse and validate the args dictionary for `get_chat_history`.
///
/// Rules encoded here (each has a corresponding test in `ServerHandlerLogicTests`):
/// - `chat_id` is required (#4)
/// - `limit` defaults to 50
/// - `from_message_id` defaults to 0
/// - `max_messages` must be > 0 and <= 10_000 when provided (#6)
/// - **When `from_message_id == 0` and `max_messages` is not provided,
///   default `max_messages` to `limit`** — this triggers bulk pagination
///   in `TDLibClient.getChatHistory`, working around TDLib's partial
///   first-page issue (#3).
/// - `since_date` / `until_date` parse via `parseISODate` / `parseUntilDate`
///   which throw `DateParseError` on invalid format (#5).
internal func parseGetChatHistoryArgs(_ args: [String: Value]) throws -> GetChatHistoryArgs {
    guard let chatId = int64ArgValue(args, "chat_id") else {
        throw HandlerArgError(message: "chat_id is required")
    }
    let limit = args["limit"]?.intValue ?? 50
    let fromMessageId = int64ArgValue(args, "from_message_id") ?? 0

    let sinceDate = try parseISODate(args["since_date"]?.stringValue)
    let untilDate = try parseUntilDate(args["until_date"]?.stringValue)

    let explicit = args["max_messages"]?.intValue
    if let mm = explicit {
        try validateMaxMessagesCap(mm)
    }
    // #3 fix: when fromMsgId == 0 and caller didn't specify, default to limit
    // so we enter the bulk pagination path and avoid TDLib's partial first page.
    let maxMessages = explicit ?? (fromMessageId == 0 ? limit : nil)

    return GetChatHistoryArgs(
        chatId: chatId,
        limit: limit,
        fromMessageId: fromMessageId,
        maxMessages: maxMessages,
        sinceDate: sinceDate,
        untilDate: untilDate
    )
}

/// Parsed arguments for the `dump_chat_to_markdown` MCP tool (#13).
/// Mirrors the `GetChatHistoryArgs` pattern from #7 — extracts inline
/// validation out of `Server.swift` so the parsing/validation rules
/// (chat_id required, output_path required, 0/10_000 cap, ISO date
/// parsing) are unit-testable without a live TDLib connection.
internal struct DumpChatToMarkdownArgs {
    let chatId: Int64
    let outputPath: String
    let maxMessages: Int
    let sinceDate: Date?
    let untilDate: Date?
    let selfLabel: String
}

/// Parse and validate the args dictionary for `dump_chat_to_markdown`.
///
/// Rules encoded here:
/// - `chat_id` is required
/// - `output_path` is required
/// - `max_messages` defaults to 5000 (different from `get_chat_history`
///   which auto-derives from `limit` via the #3 fromMsgId==0 rule)
/// - `max_messages` must be > 0 and <= 10_000 (shared with
///   `parseGetChatHistoryArgs` via `validateMaxMessagesCap`)
/// - `since_date` / `until_date` parse via `parseISODate` /
///   `parseUntilDate` which throw `DateParseError` on invalid format
/// - `self_label` defaults to `"我"` (Mandarin "I/me")
internal func parseDumpChatToMarkdownArgs(_ args: [String: Value]) throws -> DumpChatToMarkdownArgs {
    guard let chatId = int64ArgValue(args, "chat_id") else {
        throw HandlerArgError(message: "chat_id is required")
    }
    guard let outputPath = args["output_path"]?.stringValue else {
        throw HandlerArgError(message: "output_path is required")
    }
    let maxMessages = args["max_messages"]?.intValue ?? 5000
    try validateMaxMessagesCap(maxMessages)

    let sinceDate = try parseISODate(args["since_date"]?.stringValue)
    let untilDate = try parseUntilDate(args["until_date"]?.stringValue)

    let selfLabel = args["self_label"]?.stringValue ?? "我"

    return DumpChatToMarkdownArgs(
        chatId: chatId,
        outputPath: outputPath,
        maxMessages: maxMessages,
        sinceDate: sinceDate,
        untilDate: untilDate,
        selfLabel: selfLabel
    )
}

/// Shared `max_messages` cap policy. Both `parseGetChatHistoryArgs` and
/// `parseDumpChatToMarkdownArgs` enforce the same 0 / 10_000 invariant
/// (#13). Single source of truth so a future cap policy change (e.g.
/// tightening to 5_000 or relaxing for paid tier) propagates atomically.
internal func validateMaxMessagesCap(_ value: Int) throws {
    if value <= 0 {
        throw HandlerArgError(message: "max_messages must be positive; got \(value)")
    }
    if value > 10_000 {
        throw HandlerArgError(
            message: "max_messages exceeds 10_000 cap; got \(value). Use since_date/until_date to narrow the range."
        )
    }
}

/// Module-level Int64 arg extraction. Single source of truth — formerly
/// duplicated as `int64Arg` in `Server.swift`; consolidated here per #15-C1
/// (DRY) so any future change (e.g. trimming whitespace, rejecting hex)
/// automatically applies to all 21+ handlers.
///
/// Resolution order:
/// 1. Native `.int(n)` → `Int64(n)`
/// 2. `.string(s)` fallback → `Int64(s)` (strict base-10, rejects hex/scientific/whitespace)
/// 3. Otherwise nil (key missing, .null, .bool, .double, .array, .object)
internal func int64ArgValue(_ args: [String: Value], _ key: String) -> Int64? {
    guard let value = args[key] else { return nil }
    if let n = value.intValue { return Int64(n) }
    if let s = value.stringValue { return Int64(s) }
    return nil
}
