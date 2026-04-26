# Changelog

## [Unreleased]

### Added
- **`auth_run` MCP tool — state-machine driver**: A single tool drives the auth flow by one step per call. Optional args `phone` / `code` / `password` route to the matching TDLib method based on current `authState`. When env vars are present (`TELEGRAM_API_ID`/`HASH`, `TELEGRAM_PHONE`, `TELEGRAM_2FA_PASSWORD`), auto-fire handles those steps; SMS verification code is **never** auto-fired (one-shot delivery rule, must be supplied via the `code` arg). Replaces the per-step manual workflow with a single agent-friendly entry point. The legacy `auth_set_parameters` / `auth_send_phone` / `auth_send_code` / `auth_send_password` tools remain as escape hatches.
- **`auth_status` structured response**: returns `{state, next_step, last_error}` where `next_step` is either `null` (ready/closed) or `{tool, required_args, hint}` describing the next caller action. `last_error` surfaces auto-fire failures (e.g., `FLOOD_WAIT_30`) as `{type, code, message}` so AI agents can recover programmatically.
- **`autoSendPhoneIfAvailable()`**: third step of the auto-fire chain. When TDLib advances to `WaitPhoneNumber` and `TELEGRAM_PHONE` is in the process environment, the client invokes `sendPhoneNumber(...)` through the coalesced path. Combined with existing `autoSetParametersIfAvailable` and `autoSendPasswordIfAvailable`, the chain now covers params + phone + password (3 of 4 auth steps); SMS code remains caller-only.
- **`TaskFieldHolder` + `coalesceTask(holder:body:)`** (`Sources/TelegramAllLib/AuthCoalescing.swift`): Coalesced Task pattern — concurrent callers of the same auth method share a single in-flight TDLib request and observe the same outcome. Eliminates the auto-fire vs manual race that previously triggered duplicate TDLib calls when both fired in the same window.
- **`decideAutoFire(state:env...)` + `AutoFireAction`** (`Sources/TelegramAllLib/AutoFire.swift`): pure routing function for the auto-fire chain — testable without `ProcessInfo` mocking or `TDLibClient` instantiation.
- **`decideAuthRunAction(state:phone:code:password:env...)` + `AuthRunAction`** (`Sources/CheTelegramAllMCPCore/AuthResponses.swift`): pure routing function for the `auth_run` MCP tool — testable without server instance.
- **`authStatusResult(state:lastError:)`** (`Sources/CheTelegramAllMCPCore/AuthResponses.swift`): structured response builder for `auth_status` and `auth_run`.
- **`TDLibClient.getLastAutoFireError()` accessor**: returns the most recent `TDError.tdlibError` from an auto-fire path; cleared automatically when a fresh auto-fire begins or `authState` advances to `.ready`.
- **6 new test files / 46 new test cases**: `AuthCoalescingTests` (concurrency contract), `AuthStateLockingTests` (lock primitive), `AuthRunHandlerTests` (state-machine routing), `AuthStatusNextStepTests` (response shape), `AutoFireChainTests` (env-driven auto-fire decisions), tool-count regression updates.
- **New capability spec**: `openspec/specs/telegram-auth-coordination/` (added by spectra change `improve-auth-coordination-and-auto-flow`); modified `openspec/specs/telegram-auth-error-reporting/` to cover auto-fire failure surfacing.

### Changed
- **BREAKING — `TDLibClient.authState` direct access removed**: was `public private(set) var authState: AuthState`, now `private var authState`. Callers MUST use `getAuthState() -> AuthState` (lock-protected). Internal-only API; no public consumers outside this package. All call sites updated (Server, CLI, E2ETests).
- **`OSAllocatedUnfairLock` protects all mutable auth state**: `authState`, `cachedApiId`, `cachedApiHash`, `lastAutoFireError`, and the four per-method task holders. Reads via `getAuthState()` are atomic — never observe a torn enum value. Replaces the implicit single-thread assumption that conflicted with TDLib's process-global callback thread.
- **Auto-fire paths use `do/catch` instead of `try?`**: caught `TDError.tdlibError(...)` is persisted to `lastAutoFireError` for surfacing via `auth_status`. Previous `try?` discarded all errors silently, so `FLOOD_WAIT` / invalid credentials never reached the caller.

### Notes
- Closes `che-telegram-all-mcp#2` (auto-set Task race fix) and `che-telegram-all-mcp#4` (SSH-friendly auto-flow), which were merged into a single SDD.
- `che-telegram-all-mcp#3` (cross-machine session sync) remains a separate effort.

## [0.4.3] - 2026-04-25

### Fixed
- **TDLib auth error masking — `che-telegram-all-mcp#1` Issue C primary**: Previously `TDLibClient.setParameters` / `sendPhoneNumber` / `sendAuthCode` / `sendPassword` propagated `TDLibKit.Error` as opaque `"TDLibKit.Error error 1"` strings via `Swift.Error.localizedDescription`, hiding the actual TDLib `code` and `message`. Callers could not distinguish flood-wait (code 420 `FLOOD_WAIT_X`), invalid code (400 `PHONE_CODE_INVALID`), or internal errors. Now wrapped in `do/catch` that maps `TDLibKit.Error` → `TDError.tdlibError(code: Int, message: String)` with discrete fields preserved.

### Changed
- **BREAKING — `TDLibClient.TDError.tdlibError` enum case shape**: from `tdlibError(String)` to `tdlibError(code: Int, message: String)`. Internal API only — no public consumers outside this package. All call sites updated.
- **MCP response error serialization for auth tools**: `Server.handleToolCall` now catches `TDError.tdlibError(code:message:)` separately from generic errors and serializes as structured JSON `{"type":"tdlib_error","code":<int>,"message":<string>}` with `isError: true`. AI agents can now parse error code + message without regex on free-text. Non-auth errors continue to use the existing plain-text `errorResult` helper.

### Added
- **TDLib protocol code 406 silent-ignore rule**: per TDLib protocol contract ("If the error code is 406, the error message must not be processed in any way and must not be displayed to the user"), the four auth methods now silently swallow code 406 errors. Other TDLib codes propagate as structured `TDError.tdlibError`.
- **`TelegramAllLib.makeUpdateDecoder()`** (file-scope internal helper): factored out the `JSONDecoder` configuration used for TDLib `Update` payloads so a regression test can verify `keyDecodingStrategy == .convertFromSnakeCase` without instantiating `TDLibClient` (TDLib's receive loop is process-global).
- **`TelegramAllLib.mapTDLibError(_:)`** (file-scope internal helper): pure function for TDLibKit error → `TDError.tdlibError` mapping, including the code 406 silent-ignore branch. Testable without a live TDLib connection.
- **`CheTelegramAllMCPCore.tdlibErrorResult(code:message:)`** (file-scope internal helper): pure function constructing structured MCP error responses. Testable without instantiating the server.
- **New tests** (14 cases): `TDLibAuthErrorTests` (mapping + silent-ignore + non-TDLib passthrough), `JSONDecoderRegressionTests` (snake_case decode regression guard, locks down v0.2.0 critical bug fix), `AuthErrorResponseTests` (structured MCP response shape).
- **New capability spec**: `openspec/specs/telegram-auth-error-reporting/` (added by spectra change `improve-tdlib-auth-error-handling`).

### Notes
- Out of scope: auto-set `Task` race fix (`che-telegram-all-mcp#1` Issue C tertiary) tracked separately.
- Issues A + B from `che-telegram-all-mcp#1` were fixed in v0.3.0 (snake_case decoder); release of that fix as a prebuilt binary is a separate hotfix.

## [0.4.2] - 2026-04-17

### Refactored
- **Extract `parseGetChatHistoryArgs` pure function (#7)**: Argument parsing + validation logic for `get_chat_history` handler is now in `Sources/CheTelegramAllMCPCore/HandlerArgs.swift`, testable without a live TDLib connection. Handler became 16 lines (down from 35). Introduces `GetChatHistoryArgs` struct and `HandlerArgError` for structured validation failures. 11 new unit tests lock down the #3 fromMsgId==0 auto-pagination rule, #4 param wiring, and #5/#6 validation boundaries.

### Fixed
- **DST fall-back bug in `parseUntilDate`** (verification blocker from logic reviewer): Previously used `Calendar.date(byAdding: DateComponents(hour:23,min:59,sec:59), to: startOfDay)` which breaks on DST fall-back days (25-hour day) — messages at 23:00-23:59 were excluded, defeating the "whole day inclusive" contract. Now constructs end-of-day from wall-clock components (year/month/day + hour=23/min=59/sec=59) so Calendar resolves DST correctly.
- **Version string in `Server(version:)` synced**: Previously hard-coded `"0.2.0"`, now matches CHANGELOG `0.4.2`.
- **`mcpb/manifest.json` version synced** to `0.4.2`.

### Changed
- **`until_date` now includes the whole day (#5-A1)**: `"2026-04-17"` parses to 2026-04-17 23:59:59 local time instead of 00:00:00. Messages sent anywhere on 2026-04-17 are now included in the filter, matching the schema's "inclusive" description.
- **`parseISODate` throws on invalid format (#5-A2)**: Non-empty strings that don't match `YYYY-MM-DD` now throw `DateParseError` instead of silently returning nil. MCP handlers catch and return `errorResult("Date format invalid: ...")`. Regex pre-check (`^\d{4}-\d{2}-\d{2}$`) guards against `DateFormatter`'s lenient-even-when-disabled parsing of `/` separators.
- **`max_messages` hard-capped at 10_000 (#6-B1)**: `TDLibClient.getChatHistory` caps bulk pagination at 10_000 messages regardless of caller input. Warning logged to stderr when cap applied. Prevents runaway pagination from accidentally large values.
- **`max_messages <= 0` returns error (#6-B2)**: `get_chat_history` and `dump_chat_to_markdown` MCP handlers reject non-positive `max_messages` with clear error message, instead of silently returning an empty array.
- **Handler-level `max_messages > 10_000` explicit reject** (verification finding): Previously the cap only surfaced via stderr warning, which is invisible to MCP callers over stdio JSON-RPC. Handlers now reject with `errorResult("max_messages exceeds 10_000 cap...")` so callers see the constraint. TDLibClient internal cap kept as defense-in-depth.

### Added
- `Sources/CheTelegramAllMCPCore/DateParsing.swift` — new module with pure `parseISODate` and `parseUntilDate` functions (module-level internal, directly testable without server class).
- `DateParseError` type with descriptive message including the invalid input.
- 14 new unit tests in `DateParsingTests.swift`: nil/empty/valid/invalid inputs, semantic contract tests (end-of-day inclusion / next-day exclusion), semantic-invalid dates (`2026-13-01`, `2026-02-30`, `2025-02-29`), leap-year acceptance (`2024-02-29`), and DST fall-back regression guard.

### Removed
- Old `parseISODate` private method on `CheTelegramAllMCPServer` (replaced by module-level throwing version).

## [0.4.1] - 2026-04-16

### Fixed
- **`get_chat_history` first-call bug (#3)**: When `from_message_id` is 0, the MCP handler now defaults `maxMessages` to `limit`, triggering the bulk pagination path. This fixes the issue where the first call only returned 1 message due to TDLib's partial local cache.

### Changed
- **`get_chat_history` schema expanded (#4)**: Added three optional parameters: `since_date` (YYYY-MM-DD), `until_date` (YYYY-MM-DD), `max_messages` (integer). These wire through to `TDLibClient.getChatHistory`'s existing `sinceDate`/`untilDate`/`maxMessages` support, which was previously only accessible via `dump_chat_to_markdown` and the CLI.
- Updated `openspec/specs/telegram-history-export/spec.md` to reflect the expanded schema (previously mandated exactly three properties).

## [0.4.0] - 2026-04-15

### Added
- **New MCP tool `dump_chat_to_markdown`**: one-shot export of chat history to a Markdown file. Paginates TDLib internally, batch-resolves sender names, groups messages by day, and writes to a caller-supplied `output_path`. Returns summary metadata (`path`, `message_count`, `date_range`, `senders`) — does NOT return Markdown content in the MCP response (avoids context bloat). Supports `max_messages`, `since_date`, `until_date`, `self_label` parameters.
- **Library `TDLibClient.getChatHistory` extended** with three optional parameters: `maxMessages: Int?`, `sinceDate: Date?`, `untilDate: Date?`. When `maxMessages` is non-nil the method auto-paginates (newest → oldest) with `sinceDate` early-terminate. Date filters apply independently of `maxMessages` and may be combined with single-page fetches.
- **CLI `telegram-all history` flags**: `--max-messages`, `--since`, `--until`, `--dump-markdown <path>`, `--self-label`. Without `--dump-markdown` prints JSON as before; with the flag invokes the new exporter and prints summary metadata.
- **New test suites**: `TDLibClientBackwardCompatTests`, `TDLibClientPaginationTests`, `TDLibClientDateFilterTests`, `MarkdownFormatTests`, `MarkdownSenderResolveTests`, `MarkdownExporterContractTests`, `ServerDumpChatToolTests`.
- New capability spec: `openspec/specs/telegram-history-export/spec.md`.

### Changed
- Tool count: 26 → 27 (added `dump_chat_to_markdown`).
- `TDLibClient.getChatHistory` signature gained three optional parameters. Existing three-parameter call sites (`chatId:limit:fromMessageId:`) are fully source-compatible — the default-nil parameters preserve original single-page behavior byte-for-byte.

### Backward Compatibility
- Existing `get_chat_history` MCP tool schema is unchanged (still three properties `chat_id` / `limit` / `from_message_id`; still `chat_id` required only).
- Existing CLI `telegram-all history <chat_id>` still prints a single-page JSON array with no new flags required.

### Design Notes
- The middle-tier tool `get_chat_history_full` was deliberately NOT added — JSON-batch responses to MCP are never the AI's end goal (it always re-formats to Markdown), so the middle tier is dead surface. See `openspec/archive/*-add-chat-history-export/design.md`.

## [0.3.0] - 2026-04-13

### Added
- New `TelegramAllLib` Swift package target — standalone TDLib wrapper, no MCP SDK dependency
- New `telegram-all` CLI executable with 10 subcommands:
  - Auth: `auth-status`, `auth-phone`, `auth-code`, `auth-password`
  - Read: `me`, `chats`, `history`, `search`, `contacts`
  - Write: `send`
- Unit tests (`TelegramAllLibTests`, `CheTelegramAllMCPTests`)
- E2E tests (`E2ETests`) for read/write operations against real Telegram accounts

### Changed
- **Architecture**: `TDLibClient.swift` extracted from `CheTelegramAllMCPCore` into independent `TelegramAllLib` target. MCP server is now a thin wrapper.
- **MCP SDK** upgraded from 0.10.2 → 0.12.0 (fixes Swift 6.3 concurrency compatibility)
- Server.swift updated to new `.text(text:annotations:_meta:)` API

### Fixed
- **Critical**: `JSONDecoder` now uses `.convertFromSnakeCase` strategy. Previously, all TDLib updates failed to decode (snake_case keys vs Swift camelCase), causing `authState` to never update from `waitingForParameters`. This made all read/write operations falsely report "Not authenticated".
- TDLib verbose stdout logging suppressed via `td_execute("setLogVerbosityLevel", 0)` at init.

## [0.2.0] - 2026-02-10

### Added
- Auto-authentication via environment variables (`TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `TELEGRAM_2FA_PASSWORD`)
- New tools: `create_group`, `add_chat_member`

### Changed
- TDLib parameters are now auto-set on startup when env vars are present (no manual `auth_set_parameters` call needed)
- Tool count: 26 → 28

## [0.1.0] - 2026-02-08

### Added
- Initial release with TDLib integration
- Authentication: `auth_set_parameters`, `auth_send_phone`, `auth_send_code`, `auth_send_password`, `auth_status`, `logout`
- User info: `get_me`, `get_user`, `get_contacts`
- Chat operations: `get_chats`, `get_chat`, `search_chats`
- Messages: `get_chat_history`, `send_message`, `edit_message`, `delete_messages`, `forward_messages`, `search_messages`
- Group management: `get_chat_members`, `pin_message`, `unpin_message`, `set_chat_title`, `set_chat_description`
- Read state: `mark_as_read`
