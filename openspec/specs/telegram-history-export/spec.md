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

- **WHEN** an MCP client invokes `dump_chat_to_markdown(chat_id: 489601378, output_path: "/tmp/chat.md", max_messages: 1000, since_date: "2026-04-01")`
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
- Non-text message types MUST render as bracketed placeholders on a single line: `[photo]`, `[voice]`, `[video]`, `[sticker]`, `[document]`, `[location]`, `[other]`.
- Consecutive messages from the same sender MUST each retain their own timestamp line; the implementation MUST NOT merge them into a single block.

#### Scenario: Text message formatting

- **WHEN** an outgoing text message "到了嗎" is sent at 2026-04-14 14:32 local time
- **AND** `self_label` is `"我"`
- **THEN** the Markdown output contains `**14:32 我**：\n到了嗎` under the `## 2026-04-14` heading

#### Scenario: Photo placeholder

- **WHEN** a message of type `messagePhoto` is encountered
- **THEN** the Markdown body for that message is exactly `[photo]`

#### Scenario: Day heading chronological order

- **WHEN** the exported range spans 2026-04-12 through 2026-04-14
- **THEN** day headings appear in the order `## 2026-04-12`, `## 2026-04-13`, `## 2026-04-14`


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
### Requirement: Output path validation and error reporting

Before fetching messages, the `dump_chat_to_markdown` implementation SHALL verify that the parent directory of `output_path` exists and is writable by the current process. If validation fails, the implementation MUST throw a distinguishable error (not a generic IO error) with the invalid path included in the error payload, and MUST NOT issue any TDLib calls for message retrieval.

#### Scenario: Parent directory missing

- **WHEN** `dump_chat_to_markdown(output_path: "/nonexistent/dir/chat.md")` is invoked
- **THEN** the tool returns an error result naming the invalid path `/nonexistent/dir/chat.md`
- **AND** no TDLib message fetch is attempted

#### Scenario: Writable path succeeds

- **WHEN** `dump_chat_to_markdown(output_path: "/tmp/chat.md")` is invoked and `/tmp` is writable
- **THEN** validation passes and message fetching proceeds


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