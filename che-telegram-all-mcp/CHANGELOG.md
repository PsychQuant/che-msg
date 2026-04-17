# Changelog

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
