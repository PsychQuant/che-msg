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
    guard let chatId = try int64ArgValueStrict(args, "chat_id") else {
        throw HandlerArgError(message: "chat_id is required")
    }
    let limit = try parseLimit(args, default: 50)
    let fromMessageId = try int64ArgValueStrict(args, "from_message_id") ?? 0

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
    guard let chatId = try int64ArgValueStrict(args, "chat_id") else {
        throw HandlerArgError(message: "chat_id is required")
    }
    guard let outputPath = args["output_path"]?.stringValue else {
        throw HandlerArgError(message: "output_path is required")
    }
    // #23: closure of the default-5000 cap-bypass invariant.
    // `parseMaxMessages(args)` (no-default form) only validates explicit args.
    // `parseMaxMessagesWithDefault(args, default:)` flows the default through
    // `validateMaxMessagesCap` too — mutation-resistant: removing the cap
    // call inside the default branch makes `testParseMaxMessagesWithDefaultAppliesCapToDefaultPath`
    // (cap=11000 over the 10_000 ceiling) fail. If a future cap policy
    // tightens to e.g. 1000 for paid tier, this default-5000 path will throw.
    let maxMessages = try parseMaxMessagesWithDefault(args, default: 5000)

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

/// Like `parseMaxMessages` but applies `validateMaxMessagesCap` to the
/// fallback default too. Closes #23 properly + makes the cap invariant
/// mutation-resistant: deleting the `try validateMaxMessagesCap(defaultValue)`
/// call below would make `testParseMaxMessagesWithDefaultAppliesCapToDefaultPath`
/// (pass default=11000 over 10_000 cap, expect throw) start failing.
///
/// Pre-#23 fix: `parseMaxMessages(args) ?? 5000` silently bypassed the cap
/// on the default path. The previous "belt-and-suspenders" inline fix
/// (`try validateMaxMessagesCap(maxMessages)` after `??`) was structurally
/// correct but its test was a placebo — only asserted `maxMessages == 5000`
/// which holds whether the cap call is present or not (5000 < 10_000).
/// This signature extracts the default-path semantics into a function
/// whose contract IS the cap call, making it testable independently.
internal func parseMaxMessagesWithDefault(_ args: [String: Value], default defaultValue: Int) throws -> Int {
    if let raw = args["max_messages"] {
        guard let value = Int(raw, strict: false) else {
            throw HandlerArgError(message: "max_messages must be an integer")
        }
        try validateMaxMessagesCap(value)
        return value
    }
    // Default path also runs the cap — closes #23 latent-invariant.
    try validateMaxMessagesCap(defaultValue)
    return defaultValue
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

/// Shared `limit` cap policy. Closes the #25 verify F4 inconsistency:
/// `parseMaxMessages` enforced a 10_000 ceiling but `parseLimit` only
/// checked `> 0`, letting MCP callers pass `limit: 999_999_999` straight
/// to TDLib (`getChats` then iterates one `getChat` per id). Same 10_000
/// ceiling for parity — limits beyond that should use pagination.
internal func validateLimitCap(_ value: Int) throws {
    if value > 10_000 {
        throw HandlerArgError(
            message: "limit exceeds 10_000 cap; got \(value). Use pagination instead of a single large request."
        )
    }
}

/// Strict throwing Int64 arg extraction — the single source of truth for
/// scalar Int64 args (consolidated per #15-C1 DRY). Closes #22/#33: the former
/// non-strict `int64ArgValue` (removed in #33) silently returned nil on
/// `.string("not-numeric")`, causing callers to throw the misleading
/// "X is required" (the key WAS present, the value was the wrong type). Every
/// Server.swift handler now routes through this — directly, or via
/// `requiredInt64` / the grouped parsers below.
///
/// Resolution order (uses MCP SDK's `Int(_:strict:false)` for parity with
/// `parseMaxMessages`):
/// 1. Key absent → return `nil` (caller decides default vs. throw)
/// 2. Explicit `.null` → return `nil` (treat as absent)
/// 3. `.int(n)` → `Int64(n)`
/// 4. `.double(d)` where `Int(exactly: d) != nil` → `Int64(d)` (whole-number
///    doubles like `12345.0` accepted; matters for JS/Python encoders that
///    emit integers as doubles per JSON spec)
/// 5. `.string(s)` numeric → `Int64(s)` strict base-10
/// 6. `.string(s)` non-numeric → throws `"\(key) must be an integer; got \"\(s)\""`
///    (quoted value included for debug clarity — user's raw input is shown)
/// 7. `.bool`, `.array`, `.object`, fractional `.double` → throws `"\(key) must be an integer"`
///    (no quoted value — these have no meaningful string form to include)
internal func int64ArgValueStrict(_ args: [String: Value], _ key: String) throws -> Int64? {
    guard let raw = args[key] else { return nil }
    if case .null = raw { return nil }
    if let n = Int(raw, strict: false) {
        return Int64(n)
    }
    if let s = raw.stringValue {
        throw HandlerArgError(
            message: "\(key) must be an integer; got \"\(s)\""
        )
    }
    throw HandlerArgError(message: "\(key) must be an integer")
}

/// Parse and validate the optional `limit` arg with caller-supplied default.
///
/// Closes #25: previously
/// `args["limit"]?.intValue ?? defaultValue` silently fell back to the
/// default for any non-`.int` value — `.string("0")` / `.double(20.0)` /
/// non-numeric strings all silently produced the default. Mirrors the
/// `parseMaxMessages` shape (#8 A1) for consistency across numeric option
/// args.
///
/// Resolution order via MCP SDK's `Int(_:strict:false)`:
/// 1. Key absent → return `defaultValue` (validated against the cap)
/// 2. Explicit `.null` → return `defaultValue` (treat as absent; cap-validated)
/// 3. `.int(n)` / whole `.double(d)` / numeric `.string(s)` → `n`
/// 4. Anything else → throw `HandlerArgError`
///
/// Then validates `limit > 0` — zero or negative limits would silently
/// produce empty results upstream (debug hell).
///
/// The `defaultValue` itself also flows through `validateLimitCap` (parity
/// with `parseMaxMessagesWithDefault`, #23): a future callsite passing a
/// default over the cap must throw, not silently bypass it. Mutation-resistant
/// via `testLimitDefaultOverCapRejected`.
internal func parseLimit(_ args: [String: Value], default defaultValue: Int) throws -> Int {
    // Absent / explicit .null → default, but the default is still cap-validated
    // (see docstring + #23 design parity). The .null branch is mutation-guarded
    // by `testLimitNullUsesDefault`.
    func cappedDefault() throws -> Int {
        try validateLimitCap(defaultValue)
        return defaultValue
    }
    guard let raw = args["limit"] else { return try cappedDefault() }
    if case .null = raw { return try cappedDefault() }
    guard let value = Int(raw, strict: false) else {
        throw HandlerArgError(message: "limit must be an integer")
    }
    if value <= 0 {
        throw HandlerArgError(message: "limit must be positive; got \(value)")
    }
    try validateLimitCap(value)
    return value
}

// MARK: - Scalar Int64 arg parsers (#33 — Server.swift direct-callsite migration)

/// A required Int64 arg. Composes `int64ArgValueStrict`:
/// - present-but-junk → throws the #22/#33 type-mismatch message:
///   `"key must be an integer; got \"...\""` for a non-numeric `.string` (raw value
///   quoted), `"key must be an integer"` for `.bool` / `.array` / `.object` /
///   fractional `.double` (no meaningful string form to quote)
/// - absent / `.null` → throws `"key is required"` (preserves the prior guard
///   semantics — 19 of the 20 migrated scalar callsites are required; the 1
///   optional `reply_to_message_id` is handled by `parseSendMessageIds`)
///
/// This is the testable seam #33 extracts. The direct `int64ArgValue` callsites
/// were inline in `Server.handleToolCall`, a `private` method on a Server whose
/// only init boots a process-global TDLib receive loop — so they were NOT
/// unit-testable in place. Routing each handler's scalar Int64 parsing through
/// these module-level functions makes it falsifiable; mutation-resistant tests
/// live in `ServerHandlerLogicTests.swift`.
internal func requiredInt64(_ args: [String: Value], _ key: String) throws -> Int64 {
    guard let value = try int64ArgValueStrict(args, key) else {
        throw HandlerArgError(message: "\(key) is required")
    }
    return value
}

/// `chat_id` + `message_id`, both required. Used by `pin_message` /
/// `unpin_message` / `edit_message`. `chat_id` is validated first, so a
/// bad `chat_id` reports before `message_id` (per-field message — #33 replaces
/// the old combined `"chat_id and message_id are required"`).
internal struct ChatMessageIds {
    let chatId: Int64
    let messageId: Int64
}

internal func parseChatMessageIds(_ args: [String: Value]) throws -> ChatMessageIds {
    ChatMessageIds(
        chatId: try requiredInt64(args, "chat_id"),
        messageId: try requiredInt64(args, "message_id")
    )
}

/// `chat_id` + `user_id`, both required. Used by `add_chat_member`.
internal struct ChatUserIds {
    let chatId: Int64
    let userId: Int64
}

internal func parseChatUserIds(_ args: [String: Value]) throws -> ChatUserIds {
    ChatUserIds(
        chatId: try requiredInt64(args, "chat_id"),
        userId: try requiredInt64(args, "user_id")
    )
}

/// `chat_id` + `from_chat_id`, both required. Used by `forward_messages`.
internal struct ChatForwardIds {
    let chatId: Int64
    let fromChatId: Int64
}

internal func parseChatForwardIds(_ args: [String: Value]) throws -> ChatForwardIds {
    ChatForwardIds(
        chatId: try requiredInt64(args, "chat_id"),
        fromChatId: try requiredInt64(args, "from_chat_id")
    )
}

/// `chat_id` (required) + `reply_to_message_id` (optional). Used by
/// `send_message`. #33 behavior change: a junk `reply_to_message_id` now throws
/// instead of silently dropping the reply target; absent / `.null` still yields
/// `nil` (the legitimate "no reply" case is unchanged).
internal struct SendMessageIds {
    let chatId: Int64
    let replyToMessageId: Int64?
}

internal func parseSendMessageIds(_ args: [String: Value]) throws -> SendMessageIds {
    SendMessageIds(
        chatId: try requiredInt64(args, "chat_id"),
        replyToMessageId: try int64ArgValueStrict(args, "reply_to_message_id")
    )
}
