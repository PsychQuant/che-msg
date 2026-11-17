# telegram-history-export Specification

## Purpose

TBD - created by archiving change 'add-chat-history-export'. Update Purpose after archive.

## Requirements

### Requirement: Bulk chat history retrieval with bounded termination

The `TelegramAllLib.TDLibClient.getChatHistory` library method SHALL accept an optional `maxMessages: Int?` parameter. When `maxMessages` is non-nil, the method SHALL internally iterate TDLib `getChatHistory` calls from newest toward oldest, accumulating messages until any of the following termination conditions is met:

- The accumulated message count reaches `maxMessages`.
- A TDLib response returns an empty `messages` array (conversation start reached).
- The oldest message in the current batch has a `date` value strictly less than `sinceDate` (when `sinceDate` is non-nil).

The returned JSON array SHALL contain only messages that satisfy the date range filter, ordered newest first.

#### Scenario: Reach max message cap

- **WHEN** the caller invokes `getChatHistory(chatId:, maxMessages: 200)` on a chat with 1000 messages
- **THEN** the method performs repeated TDLib calls until 200 messages are accumulated
- **AND** returns a JSON array of exactly 200 messages ordered newest first

#### Scenario: Reach conversation start

- **WHEN** the caller invokes `getChatHistory(chatId:, maxMessages: 10000)` on a chat with only 42 messages total
- **THEN** the method terminates when TDLib returns an empty batch
- **AND** returns a JSON array of 42 messages

#### Scenario: Early termination by sinceDate

- **WHEN** the caller invokes `getChatHistory(chatId:, maxMessages: 10000, sinceDate: <2026-04-01>)` on a chat whose oldest included message is from 2026-04-10
- **THEN** the method stops paginating as soon as a batch contains any message with `date < 2026-04-01`
- **AND** the returned array excludes messages older than 2026-04-01


<!-- @trace
source: add-chat-history-export
updated: 2026-04-16
code:
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/MarkdownExporter.swift
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/README.md
  - che-telegram-all-mcp/Tests/E2ETests/DumpChatToMarkdownE2ETests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientDateFilterTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownSenderResolveTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/telegram-all/TelegramAllCLI.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownFormatTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ServerDumpChatToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientBackwardCompatTests.swift
  - che-telegram-all-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/MessageFilters.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownExporterContractTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientPaginationTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
-->

---
### Requirement: Client-side date range filtering independent of pagination

The `getChatHistory` library method SHALL apply `sinceDate` and `untilDate` filters on the Swift client side for every returned message regardless of whether `maxMessages` is nil or non-nil. A message MUST be included in the result if and only if `sinceDate <= message.date <= untilDate` (where unspecified bounds are treated as open).

Single-page retrieval combined with date filtering is a valid invocation and MUST NOT throw a parameter-conflict error.

#### Scenario: Single page plus date filter

- **WHEN** the caller invokes `getChatHistory(chatId:, limit: 100, sinceDate: <2026-04-10>, maxMessages: nil)`
- **THEN** the method performs a single TDLib call requesting 100 messages
- **AND** returns exactly the subset of the 100 fetched messages whose `date >= 2026-04-10`

#### Scenario: Until date bound

- **WHEN** the caller invokes `getChatHistory(chatId:, maxMessages: 5000, untilDate: <2026-04-15>)`
- **THEN** the returned array excludes messages whose `date > 2026-04-15`


<!-- @trace
source: add-chat-history-export
updated: 2026-04-16
code:
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/MarkdownExporter.swift
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/README.md
  - che-telegram-all-mcp/Tests/E2ETests/DumpChatToMarkdownE2ETests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientDateFilterTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownSenderResolveTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/telegram-all/TelegramAllCLI.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownFormatTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ServerDumpChatToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientBackwardCompatTests.swift
  - che-telegram-all-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/MessageFilters.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownExporterContractTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientPaginationTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
-->

---
### Requirement: Backward-compatible single-page retrieval

When `maxMessages`, `sinceDate`, and `untilDate` are all nil, the `getChatHistory` library method SHALL behave identically to its prior implementation: a single TDLib `getChatHistory` call with the given `limit` and `fromMessageId`, returning the raw batch as a JSON array. No new per-message processing MUST occur on this code path.

#### Scenario: Legacy invocation unchanged

- **WHEN** existing code invokes `getChatHistory(chatId: 12345, limit: 50, fromMessageId: 0)` with no new parameters
- **THEN** the method performs exactly one TDLib call
- **AND** returns the raw messages JSON array without any additional filtering or transformation


<!-- @trace
source: add-chat-history-export
updated: 2026-04-16
code:
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/MarkdownExporter.swift
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/README.md
  - che-telegram-all-mcp/Tests/E2ETests/DumpChatToMarkdownE2ETests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientDateFilterTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownSenderResolveTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/telegram-all/TelegramAllCLI.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownFormatTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ServerDumpChatToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientBackwardCompatTests.swift
  - che-telegram-all-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/MessageFilters.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownExporterContractTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientPaginationTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
-->

---
### Requirement: `dump_chat_to_markdown` MCP tool

The `che-telegram-all-mcp` server SHALL register a new MCP tool named `dump_chat_to_markdown`. The tool schema MUST declare the following parameters:

- `chat_id` (integer, required): the Telegram chat identifier.
- `output_path` (string, required): absolute filesystem path where the Markdown file SHALL be written.
- `max_messages` (integer, optional): upper bound on messages to fetch.
- `since_date` (string, optional): ISO date `YYYY-MM-DD`, lower bound inclusive.
- `until_date` (string, optional): ISO date `YYYY-MM-DD`, upper bound inclusive.
- `self_label` (string, optional): label to use for outgoing messages; default `"我"`.

The tool SHALL NOT return the Markdown content in the response body. The response body SHALL be a JSON object containing `path`, `message_count`, `date_range`, and `senders` fields, plus an optional `warning` field.

#### Scenario: Successful dump

- **WHEN** an MCP client invokes `dump_chat_to_markdown(chat_id: 123456789, output_path: "/tmp/chat.md", max_messages: 1000, since_date: "2026-04-01")`
- **THEN** the server writes a Markdown file to `/tmp/chat.md`
- **AND** returns a JSON object with `path: "/tmp/chat.md"`, numeric `message_count`, a `date_range` object, and a `senders` array

#### Scenario: Missing required parameter

- **WHEN** an MCP client invokes `dump_chat_to_markdown(chat_id: 123)` without `output_path`
- **THEN** the server returns an error result indicating that `output_path` is required
- **AND** no file is created


<!-- @trace
source: add-chat-history-export
updated: 2026-04-16
code:
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/MarkdownExporter.swift
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/README.md
  - che-telegram-all-mcp/Tests/E2ETests/DumpChatToMarkdownE2ETests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientDateFilterTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownSenderResolveTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/telegram-all/TelegramAllCLI.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownFormatTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ServerDumpChatToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientBackwardCompatTests.swift
  - che-telegram-all-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/MessageFilters.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownExporterContractTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientPaginationTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
-->

---
### Requirement: `get_chat_history` MCP tool supports filtering and auto-pagination

The `get_chat_history` MCP tool SHALL expose six parameters: `chat_id`, `limit`, `from_message_id`, `since_date`, `until_date`, `max_messages`. Only `chat_id` is required; all others are optional.

When `from_message_id` is 0 (latest) and `max_messages` is not specified, the tool SHALL default `max_messages` to `limit` to trigger bulk pagination, working around TDLib's partial first-page behavior. When `from_message_id` is non-zero, the tool SHALL perform a single TDLib call (backward-compatible manual pagination).

> **History**: Prior to #3/#4, this tool was a thin wrapper with exactly three parameters. The constraint was relaxed to fix the first-page bug (#3) and expose TDLibClient's existing date filtering and pagination capabilities (#4).

#### Scenario: Schema with six properties

- **WHEN** an MCP client requests the tool list
- **THEN** the `get_chat_history` tool entry lists `chat_id`, `limit`, `from_message_id`, `since_date`, `until_date`, `max_messages` as properties

#### Scenario: Auto-pagination for latest messages

- **WHEN** an MCP client invokes `get_chat_history(chat_id: 123, limit: 50)` (from_message_id defaults to 0)
- **THEN** the server uses bulk pagination (maxMessages=50) to ensure up to 50 messages are returned
- **AND** returns the message JSON array

#### Scenario: Manual pagination unchanged

- **WHEN** an MCP client invokes `get_chat_history(chat_id: 123, limit: 50, from_message_id: 999)`
- **THEN** the server performs one TDLib call
- **AND** returns the raw message JSON array without auto-pagination


<!-- @trace
source: add-chat-history-export
updated: 2026-04-16
code:
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/MarkdownExporter.swift
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/README.md
  - che-telegram-all-mcp/Tests/E2ETests/DumpChatToMarkdownE2ETests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientDateFilterTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownSenderResolveTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/telegram-all/TelegramAllCLI.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownFormatTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ServerDumpChatToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientBackwardCompatTests.swift
  - che-telegram-all-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/MessageFilters.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownExporterContractTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientPaginationTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
-->

---
### Requirement: Batch sender resolution with fallback

Before formatting Markdown output, the `dump_chat_to_markdown` implementation SHALL collect the set of unique `sender.user_id` values referenced by the fetched messages, then resolve each unique id to a display name by invoking TDLib `getUser` at most once per unique id. Resolved names MUST be cached for the duration of the dump operation.

When a `getUser` call fails for any reason (blocked user, deleted account, privacy restriction, network error), the implementation SHALL substitute a fallback display name formatted as `User <id>` (where `<id>` is the numeric user id). The dump operation MUST NOT abort because of an individual `getUser` failure.

#### Scenario: One call per unique sender

- **WHEN** the dump operation processes 1000 messages from a chat with 3 unique senders
- **THEN** exactly 3 `getUser` calls are issued
- **AND** all 1000 messages use the cached names

#### Scenario: Sender resolution failure

- **WHEN** `getUser(user_id: 999)` returns an error for a sender referenced in the messages
- **THEN** messages from user 999 are rendered with display name `User 999`
- **AND** the dump operation completes successfully


<!-- @trace
source: add-chat-history-export
updated: 2026-04-16
code:
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/MarkdownExporter.swift
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/README.md
  - che-telegram-all-mcp/Tests/E2ETests/DumpChatToMarkdownE2ETests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientDateFilterTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownSenderResolveTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/telegram-all/TelegramAllCLI.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownFormatTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ServerDumpChatToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientBackwardCompatTests.swift
  - che-telegram-all-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/MessageFilters.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownExporterContractTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientPaginationTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
-->

---
### Requirement: Markdown output format

The Markdown file produced by `dump_chat_to_markdown` SHALL conform to the following structure:

- A level-1 heading with chat identifier, e.g. `# 對話：<chat title> (chat_id=<id>)`.
- A metadata line listing export timestamp, total message count, and active date range.
- A horizontal rule (`---`) separating metadata from content.
- Level-2 headings per calendar day in local timezone, formatted `## YYYY-MM-DD`, in chronological order (oldest day first within the exported range).
- Each message rendered as `**HH:mm <sender>**：` followed by a newline and the message body on the next line(s).
- Outgoing messages MUST use the configured `self_label` value as `<sender>`.
- Non-text message types MUST render as bracketed placeholders: `[photo]`, `[voice]`, `[video]`, `[video_note]`, `[sticker]`, `[document]`, `[location]`, `[animation]`, `[poll]`, `[audio]`, `[other]`. The placeholder MUST be followed by a space and the message's inline detail when it has one, and, for a poll, by its option lines. The detail of a non-text message is determined by its type: for `poll`, the inline detail is the poll's `question` (its own line breaks kept), followed by one line `- <option>` for each non-empty entry of `options`, in order, with line breaks inside an option (a CR, an LF or a CR LF, found by Unicode scalar whatever follows it) written as spaces; for `sticker`, the inline detail is its `emoji`; for `location`, the inline detail is `<latitude>,<longitude>` when both are finite numbers, each written in plain decimal notation with the fewest digits that reproduce TDLib's value exactly (no rounding and no exponent); for any other non-text type, the inline detail is its `caption` (photo, video, voice note, document, animation, audio), with the caption's own line breaks kept. An absent or empty inline detail MUST be treated as none. A dump answered from TDLib's local cache has no captions and no poll, sticker or location details, because that reader does not decode them (the `telegram-local-reader` capability omits a field it cannot determine).
- Consecutive messages from the same sender MUST each retain their own timestamp line; the implementation MUST NOT merge them into a single block.

#### Scenario: Text message formatting

- **WHEN** an outgoing text message "會議幾點開始？" is sent at 2026-04-14 14:32 local time
- **AND** `self_label` is `"我"`
- **THEN** the Markdown output contains `**14:32 我**：\n會議幾點開始？` under the `## 2026-04-14` heading

#### Scenario: Photo placeholder

- **WHEN** a message of type `messagePhoto` with no caption (TDLib's caption text is empty) is encountered
- **THEN** the Markdown body for that message is exactly `[photo]`

#### Scenario: Caption kept

- **WHEN** a message of type `messagePhoto` has the caption `menu`
- **THEN** the Markdown body for that message is exactly `[photo] menu`

#### Scenario: Poll with its options

- **WHEN** a poll message asks `Lunch?` with the options `Noodles` and `Rice`
- **THEN** the Markdown body for that message is exactly `[poll] Lunch?\n- Noodles\n- Rice`

#### Scenario: Sticker and location details

- **WHEN** a sticker message has the emoji `😀` and a location message is at latitude 25.0478 and longitude 121.5319
- **THEN** their Markdown bodies are exactly `[sticker] 😀` and `[location] 25.0478,121.5319`

#### Scenario: Coordinate near zero

- **WHEN** a location message is at latitude 0.00001 and longitude -0.5
- **THEN** the Markdown body for that message is exactly `[location] 0.00001,-0.5`

#### Scenario: Poll from the local cache

- **WHEN** `dump_chat_to_markdown` is answered from TDLib's local cache and the chat holds a poll message
- **THEN** the Markdown body for that message is exactly `[poll]`

#### Scenario: Day heading chronological order

- **WHEN** the exported range spans 2026-04-12 through 2026-04-14
- **THEN** day headings appear in the order `## 2026-04-12`, `## 2026-04-13`, `## 2026-04-14`

---
### Requirement: Output path validation and error reporting

Before fetching messages, the `dump_chat_to_markdown` implementation SHALL validate `output_path` in two stages. If either stage fails, the tool MUST return an error result and MUST NOT issue any TDLib call or local-cache read for message retrieval (PsychQuant/che-msg#21).

First, argument parsing SHALL refuse an `output_path` that:

- is not an absolute path, that is, does not begin with `/` (`~` is not expanded, and an empty string is refused);
- contains a `..` path component (a component that is exactly `..`; names such as `..md` are allowed);
- does not end in `.md` in any letter case (`.md`, `.MD`, `.Md`, `.mD`; a trailing `/` is not a match).

The rules SHALL be checked in that order, and the error message SHALL name the failed rule and quote the given value.

In every check of this requirement, a path SHALL be read as the operating system reads it: by Unicode scalar. A path is absolute when its first scalar is `/` (U+002F); its components are separated at every `/` scalar, including a `/` followed by a combining mark or another scalar that joins it into one user-perceived character (for example U+0301, U+200D, U+FE0F, U+034F); and components are compared scalar for scalar, not by canonical equivalence.

Second, before writing, the implementation SHALL verify that the parent directory of `output_path` exists and is writable by the current process. If it is not, the implementation MUST throw a distinguishable error (not a generic IO error) with the invalid path included in the error payload.

When the server process starts with the environment variable `CHE_TELEGRAM_ALL_EXPORT_ROOT` set to a non-empty value, the implementation SHALL also, before the parent-directory check, restrict `output_path` to that root:

- The root SHALL be resolved with symbolic links followed. A root that is not an absolute path to an existing directory SHALL make every dump fail with an error naming the configured root; the setting MUST NOT be ignored.
- `output_path` SHALL be resolved by following symbolic links on its longest existing prefix (an existing symbolic link counts as existing, even when it points nowhere) and appending the remaining components.
- The dump SHALL be refused, with an error naming both the path and the configured root, when the resolved path does not lie strictly inside the resolved root, when a remaining component is `..`, when the existing prefix cannot be resolved (for example a dangling symbolic link or a loop), when a prefix cannot be examined for any reason other than not existing, or when the path contains a NUL character.

When `CHE_TELEGRAM_ALL_EXPORT_ROOT` is unset or empty, no root restriction SHALL apply. The value SHALL NOT be trimmed: a value made only of spaces is not empty, is not an absolute path, and so refuses every dump. The server SHALL read the variable once, at startup.

Both write paths of `dump_chat_to_markdown` SHALL apply these checks: TDLib mode, and the local-cache reader used while another process holds TDLib. The root restriction SHALL NOT apply to `archive_chat_to_markdown` or `download_message_media`, whose `output_dir` is chosen per workspace, and none of these checks SHALL apply to the `telegram-all history --dump-markdown` CLI flag.

#### Scenario: Parent directory missing

- **WHEN** `dump_chat_to_markdown(output_path: "/nonexistent/dir/chat.md")` is invoked and `CHE_TELEGRAM_ALL_EXPORT_ROOT` is unset
- **THEN** the tool returns an error result naming the invalid path `/nonexistent/dir/chat.md`
- **AND** no TDLib message fetch is attempted

#### Scenario: Writable path succeeds

- **WHEN** `dump_chat_to_markdown(output_path: "/tmp/chat.md")` is invoked, `/tmp` is writable, and `CHE_TELEGRAM_ALL_EXPORT_ROOT` is unset
- **THEN** validation passes and message fetching proceeds

#### Scenario: Relative path refused

- **WHEN** `dump_chat_to_markdown(chat_id: 123, output_path: "chat.md")` is invoked
- **THEN** the tool returns an error result `Error: output_path must be an absolute path; got "chat.md"`
- **AND** no message is fetched and no file is written

#### Scenario: Traversal component refused

- **WHEN** `dump_chat_to_markdown(chat_id: 123, output_path: "/tmp/exports/../../Users/me/notes.md")` is invoked
- **THEN** the tool returns an error result stating that `output_path` must not contain `..` components, quoting the given value
- **AND** no message is fetched

#### Scenario: Traversal hidden behind a combining mark refused

- **WHEN** `dump_chat_to_markdown(chat_id: 123, output_path: "/tmp/.." + "/" + U+0301 + "esc.md")` is invoked, where the second `/` and U+0301 form one user-perceived character
- **THEN** the tool returns an error result stating that `output_path` must not contain `..` components
- **AND** nothing is written to `/` + U+0301 + `esc.md`

#### Scenario: Non-Markdown target refused

- **WHEN** `dump_chat_to_markdown(chat_id: 123, output_path: "/Users/me/.zshrc")` is invoked
- **THEN** the tool returns an error result `Error: output_path must end in .md; got "/Users/me/.zshrc"`
- **AND** `/Users/me/.zshrc` is left unchanged

#### Scenario: Upper-case extension accepted

- **WHEN** `dump_chat_to_markdown(chat_id: 123, output_path: "/tmp/CHAT.MD")` is invoked and `/tmp` is writable
- **THEN** argument parsing accepts the path and message fetching proceeds

#### Scenario: Path inside the export root accepted

- **WHEN** the server started with `CHE_TELEGRAM_ALL_EXPORT_ROOT=/Users/me/exports`, the directory `/Users/me/exports/2026` exists, and `dump_chat_to_markdown(chat_id: 123, output_path: "/Users/me/exports/2026/chat.md")` is invoked
- **THEN** validation passes and message fetching proceeds

#### Scenario: Path outside the export root refused

- **WHEN** the server started with `CHE_TELEGRAM_ALL_EXPORT_ROOT=/Users/me/exports` and `dump_chat_to_markdown(chat_id: 123, output_path: "/tmp/chat.md")` is invoked
- **THEN** the tool returns an error result naming `/tmp/chat.md` and the root `/Users/me/exports`
- **AND** no message is fetched and no file is written

#### Scenario: Symbolic link escape refused

- **WHEN** the server started with `CHE_TELEGRAM_ALL_EXPORT_ROOT=/Users/me/exports`, `/Users/me/exports/link` is a symbolic link to `/Users/me/.config`, and `dump_chat_to_markdown(chat_id: 123, output_path: "/Users/me/exports/link/chat.md")` is invoked
- **THEN** the tool returns an error result naming the path and the root
- **AND** nothing is written under `/Users/me/.config`

#### Scenario: Root escape hidden behind a combining mark refused

- **WHEN** the server started with `CHE_TELEGRAM_ALL_EXPORT_ROOT=/Users/me/exports`, `/Users/me/exports/link` is a symbolic link to `/Users/me/.config`, and `dump_chat_to_markdown` is invoked with `output_path` `/Users/me/exports/link` + "/" + U+0301 + `x.md`
- **THEN** the tool returns an error result naming the path and the root
- **AND** nothing is written under `/Users/me/.config`

#### Scenario: Unusable export root refuses every dump

- **WHEN** the server started with `CHE_TELEGRAM_ALL_EXPORT_ROOT=exports` (a relative path), with a value made only of spaces, or with the path of a directory that does not exist, and `dump_chat_to_markdown` is invoked with any `output_path`
- **THEN** the tool returns an error result naming the configured root
- **AND** no message is fetched

#### Scenario: Local-cache dump honours the export root

- **WHEN** another process holds TDLib, the server started with `CHE_TELEGRAM_ALL_EXPORT_ROOT=/Users/me/exports`, and `dump_chat_to_markdown(chat_id: 123, output_path: "/tmp/chat.md")` is invoked
- **THEN** the tool returns an error result naming the path and the root
- **AND** the local cache is not read and no file is written

---
### Requirement: Secret chat history warning

When the target chat type is `chatTypeSecret`, the `dump_chat_to_markdown` implementation SHALL still attempt to fetch and export whatever messages TDLib returns locally, and MUST include a `warning` field in the JSON response explaining that secret chat history is device-local and the export is partial.

#### Scenario: Secret chat dump

- **WHEN** `dump_chat_to_markdown` targets a chat whose type is `chatTypeSecret`
- **THEN** the tool completes with whatever local messages are available
- **AND** the response JSON object contains a `warning` field stating that secret chats store history only on-device and the dump is partial

<!-- @trace
source: add-chat-history-export
updated: 2026-04-16
code:
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/MarkdownExporter.swift
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/README.md
  - che-telegram-all-mcp/Tests/E2ETests/DumpChatToMarkdownE2ETests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientDateFilterTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownSenderResolveTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/telegram-all/TelegramAllCLI.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownFormatTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ServerDumpChatToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientBackwardCompatTests.swift
  - che-telegram-all-mcp/CHANGELOG.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/MessageFilters.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownExporterContractTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientPaginationTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
-->

---
### Requirement: Message objects carry poll, sticker and location details

In TDLib mode, every message object the server returns (from `get_chat_history`, `search_messages` and any other tool that returns messages) SHALL carry, besides `id`, `chat_id`, `date`, `sender`, `is_outgoing` and `type`: for `type` `poll`, `question` (the text of the poll's question) and `options` (an array holding the text of each answer option, in the poll's order); for `type` `sticker`, `emoji`; for `type` `location`, `latitude` and `longitude` as JSON numbers, as TDLib reports them. Vote counts, the chosen options and a quiz's correct answer SHALL NOT be included. Message objects answered from TDLib's local cache omit these fields, because the local reader does not decode them.

#### Scenario: Poll options in the message JSON

- **WHEN** `get_chat_history` returns message 7000, a poll asking `Lunch?` with the options `Noodles` and `Rice`
- **THEN** its message object has `"type":"poll"`, `"question":"Lunch?"` and `"options":["Noodles","Rice"]`

#### Scenario: Location in the message JSON

- **WHEN** `get_chat_history` returns a location message at latitude 25.0478 and longitude 121.5319
- **THEN** its message object has `"type":"location"`, `"latitude":25.0478` and `"longitude":121.5319`
