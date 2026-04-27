import Foundation
import MCP
import TelegramAllLib

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

/// Single source of truth for converting parse-stage errors to a `CallTool.Result`
/// with `isError: true`. Replaces the duplicated catch chain pattern in
/// `Server.swift` for `get_chat_history` and `dump_chat_to_markdown` handlers.
///
/// Handles both error types (#5 `DateParseError` from TelegramAllLib, #4
/// `HandlerArgError` from this module). Anything else falls back to
/// `localizedDescription` — defensive, but should not be hit in practice
/// since both parsers only throw these two types.
///
/// Extracted per #14 / #18 to make the catch chain unit-testable without a
/// live `TDLibClient` instance. Per #14 verify-stage Devil's Advocate F2,
/// the final message is also capped at `messageLengthCap` (256 chars +
/// truncation marker) to plug the asymmetric protection gap — `DateParseError`
/// already self-truncates input at 128 chars (#10 C1), but `HandlerArgError`
/// has no such guard. This belt-and-suspenders cap protects against future
/// HandlerArgError messages that might reflect long user input.
internal let messageLengthCap = 256

internal func errorResultFromParse(_ error: Error) -> CallTool.Result {
    let rawMessage: String
    if let e = error as? HandlerArgError {
        rawMessage = e.description
    } else if let e = error as? DateParseError {
        rawMessage = e.description
    } else {
        rawMessage = error.localizedDescription
    }
    let message: String
    if rawMessage.count > messageLengthCap {
        message = String(rawMessage.prefix(messageLengthCap)) + "...(truncated)"
    } else {
        message = rawMessage
    }
    return CallTool.Result(
        content: [.text(text: "Error: \(message)", annotations: nil, _meta: nil)],
        isError: true
    )
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
    try validateDateRange(sinceDate, untilDate)

    let explicit = try parseMaxMessages(args)
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
    let maxMessages = try parseMaxMessages(args) ?? 5000

    let sinceDate = try parseISODate(args["since_date"]?.stringValue)
    let untilDate = try parseUntilDate(args["until_date"]?.stringValue)
    try validateDateRange(sinceDate, untilDate)

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

/// Parse and validate the optional `max_messages` arg.
///
/// Subsumes #20 + closes #8 A1: previously
/// `args["max_messages"]?.intValue ?? default` silently fell back to the
/// default when the value was a `.string("0")` or `.double(20000.0)`,
/// completely bypassing the cap check. The user's explicit (but
/// type-mismatched) request was silently ignored.
///
/// Resolution order via MCP SDK's `Int(_:strict:false)` (Value.swift:320):
/// 1. Key absent → return `nil` (caller applies its own default).
/// 2. `.int(n)` → `n`.
/// 3. `.double(d)` where `Int(exactly: d) != nil` → `n` (whole-number
///    doubles like `5000.0` are accepted; this matters for JS / Python
///    callers whose JSON encoders emit integers as `5000.0` per JSON
///    spec).
/// 4. `.string(s)` → `Int(s)` strict base-10 parse.
/// 5. Anything else (`.double(0.5)`, `.bool`, `.array`, `.object`,
///    `.null`, or invalid string) → throw `HandlerArgError`.
///
/// All accepted values pass through `validateMaxMessagesCap` — no value
/// can leak through that bypasses the 0 / 10_000 invariant.
internal func parseMaxMessages(_ args: [String: Value]) throws -> Int? {
    guard let raw = args["max_messages"] else { return nil }
    guard let value = Int(raw, strict: false) else {
        throw HandlerArgError(message: "max_messages must be an integer")
    }
    try validateMaxMessagesCap(value)
    return value
}

/// Sanity check the `since_date <= until_date` invariant (#10 C2).
/// Both bounds nil-tolerant: only checks when both are provided.
///
/// Pre-#10, an inverted range silently filtered to empty result with no
/// error feedback — debugging hell. Throws loudly so the caller sees the
/// mistake immediately.
internal func validateDateRange(_ since: Date?, _ until: Date?) throws {
    if let s = since, let u = until, s > u {
        throw HandlerArgError(message: "since_date must be earlier than until_date")
    }
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
