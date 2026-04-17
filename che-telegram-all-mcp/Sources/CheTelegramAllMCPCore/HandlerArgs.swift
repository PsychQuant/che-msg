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
        if mm <= 0 {
            throw HandlerArgError(message: "max_messages must be positive; got \(mm)")
        }
        if mm > 10_000 {
            throw HandlerArgError(
                message: "max_messages exceeds 10_000 cap; got \(mm). Use since_date/until_date to narrow the range."
            )
        }
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

/// Module-internal Int64 arg extraction, mirroring the Server's private helper
/// so parse function has no instance dependency.
private func int64ArgValue(_ args: [String: Value], _ key: String) -> Int64? {
    guard let value = args[key] else { return nil }
    if let n = value.intValue { return Int64(n) }
    if let s = value.stringValue { return Int64(s) }
    return nil
}
