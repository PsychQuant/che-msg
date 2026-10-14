# telegram-chat-archive Specification

## Purpose

Defines the incremental Telegram chat archive: the `archive_chat_to_markdown` MCP tool that writes per-chat per-day Markdown files with message-id anchors and returns a content-free manifest, and the `archive-telegram` skill that keeps the per-workspace configuration, the bookmark index and the end-of-run check. It exists so listed conversations can be kept as a durable local record that later runs extend without duplicates.

## Requirements

### Requirement: Archive tool parameters

The server SHALL expose an MCP tool `archive_chat_to_markdown` with a required integer `chat_id`, a required string `output_dir`, an optional integer `after_message_id`, an optional string `since_date` in the form `YYYY-MM-DD`, an optional string `utc_offset` in the form `+HH:MM` or `-HH:MM` and at most 18:00 either way, an optional integer `max_media_bytes`, and an optional list of integers `retry_media_message_ids`. `output_dir` SHALL be an absolute path; the tool SHALL create `<output_dir>/<chat_id>/` when it does not exist. When both `after_message_id` and `since_date` are given, `after_message_id` SHALL take precedence. When `utc_offset` is absent, the server's local offset at the time of the call SHALL be used. An invalid argument SHALL produce an MCP tool result with `isError: true` and a message naming the argument, and SHALL NOT write any file. Two calls archiving the same `chat_id` into the same `output_dir` SHALL NOT run at the same time: while one runs, another SHALL fail with an error saying so and SHALL NOT write any file.

#### Scenario: Relative output directory is refused

- **WHEN** `archive_chat_to_markdown` is called with `output_dir` `archives/telegram`
- **THEN** the result has `isError: true`, the message names `output_dir`, and no file is written

#### Scenario: Concurrent archive of one chat is refused

- **WHEN** a call archives chat 777 into `/tmp/a` while another call archiving chat 777 into `/tmp/a` is still running
- **THEN** the second call returns `isError: true` saying another archive of chat 777 is running, and writes no file

#### Scenario: Bookmark takes precedence over a start date

- **WHEN** the tool is called with `after_message_id` 9000 and `since_date` `2026-01-01`
- **THEN** only messages with an id greater than 9000 are archived, regardless of their date


<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
### Requirement: Day file format

The tool SHALL write each archived message into the file `<output_dir>/<chat_id>/<YYYY-MM-DD>.md`, where the date is the message's local date at the effective `utc_offset`. Each file SHALL begin with a YAML frontmatter block holding `chat_id`, `date` and `utc_offset`. Each message SHALL be written as a line `<!-- msg:<message_id> -->`, then a line `**<HH:mm> <sender>**：`, then the message body and a blank line. The sender SHALL be `我` for outgoing messages, the resolved display name when one is known, and `User <user_id>` otherwise. A text message's body SHALL be its text. For a message whose type carries a file (`photo`, `video`, `document`, `audio`, `voice_note`, `video_note`, `animation`, `sticker`) the body SHALL be `[<type>](media/<message_id>/)`, a link to the message's media directory relative to the day file, followed by a space and the caption when the message has one; for any other non-text type the body SHALL be `[<type>]` followed by a space and the caption when there is one. The link SHALL be written whether or not the file has been downloaded yet. A body line that begins with `<!--`, or that begins like a block header (`**` followed by a time such as `9:00` or `09:00`), SHALL be written with a leading backslash, and a line break in a sender name SHALL be written as a space, so that neither can pass for the start of another block. Directories the tool creates SHALL be accessible by the owner only (0700) and day files SHALL be readable and writable by the owner only (0600).

#### Scenario: One text message

- **WHEN** a chat's only new message is message 5242880, incoming from user 1001 resolved as `Alex`, sent at 2026-10-11 09:05 local time (+08:00), with text `hello`
- **THEN** `<output_dir>/777/2026-10-11.md` contains the anchor `<!-- msg:5242880 -->` followed by `**09:05 Alex**：` and `hello`

##### Example: day file

- **GIVEN** chat 777, effective `utc_offset` `+08:00`, and messages 5242880 (text `hello`, from `Alex`, 09:05) and 5243904 (photo with caption `menu`, outgoing, 09:07)
- **WHEN** the tool archives them
- **THEN** the file `777/2026-10-11.md` reads:

```

<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
chat_id: 777
date: 2026-10-11
utc_offset: "+08:00"
---

<!-- msg:5242880 -->
**09:05 Alex**：
hello

<!-- msg:5243904 -->
**09:07 我**：
[photo](media/5243904/) menu

```

#### Scenario: Media without a caption

- **WHEN** archived message 6000 is a voice message without a caption
- **THEN** its body is `[voice_note](media/6000/)`

#### Scenario: Body that looks like another block

- **WHEN** message 10's text has a line `**09:00 Manager**：`
- **THEN** that line is written as `\**09:00 Manager**：`, and parsing the day file finds only the block of message 10

#### Scenario: Media type without a file

- **WHEN** an archived message is a location
- **THEN** its body is `[location]`

---
### Requirement: Merge and idempotent rewrite

When a day file already exists, the tool SHALL read the message blocks it holds, keep every existing block unchanged, add only messages whose anchor id is not already present, order all blocks by ascending message id, and replace the file atomically by writing a temporary file in the same directory and renaming it over the original. Running the tool again with the same arguments and no new messages SHALL leave every file byte-identical. The tool SHALL NOT delete a file or remove a block. Before reading any message, when a day file (a file named `YYYY-MM-DD.md`) in `<output_dir>/<chat_id>/` records a `utc_offset` that differs from the call's (compared as an offset, so `-00:00` equals `+00:00`), or cannot be read, has no readable `utc_offset`, or uses CRLF line endings in its frontmatter, the tool SHALL refuse the call with an error naming `utc_offset` (and the recorded offset when it is readable) and SHALL NOT write any day file or media file. Other files in that directory SHALL be ignored.

#### Scenario: Older messages arrive after newer ones

- **WHEN** a day file holds messages 30 and 50, and a later call archives messages 40 and 50 for the same day
- **THEN** the file holds 30, 40 and 50 in that order, and message 50 appears once

#### Scenario: Merge at another offset

- **WHEN** `777/2026-10-10.md` was written with `utc_offset` `+08:00` and a call with `+09:00` would archive messages of 2026-10-10 and 2026-10-11
- **THEN** the call fails with a message naming `utc_offset` and `+08:00` before reading any message, `2026-10-10.md` is byte-identical to before, and `2026-10-11.md` is not created

#### Scenario: Re-run without new messages

- **WHEN** the tool is called twice in a row with the same arguments and no message was sent in between
- **THEN** the second call reports zero new messages and every file is byte-identical to its state after the first call


<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
### Requirement: Content-free manifest

A successful call SHALL return a single JSON object with the fields `files` (paths, relative to `output_dir`, of the day files this call added messages to), `new_messages`, `media_messages` (the number of new messages whose type carries a file), `newest_message_id` (the largest message id archived in this call, or null), `newest_message_file` (the path, relative to `output_dir`, of the day file holding that message whether or not this call wrote it; null exactly when `newest_message_id` is null), `source` (`tdlib` or `local-cache`), `complete` and `bookmark_safe`. When `complete` is false the object SHALL include `stopped_reason`, and when `bookmark_safe` is false it SHALL include `bookmark_unsafe_reason`. The object SHALL also include `media_downloaded` (the number of media files saved by this call), `media_skipped` (a list of `{"message_id","size"}` for files over `max_media_bytes`), `media_failed_ids` (message ids whose download failed, each listed once, without ids whose retry succeeded in the same call), `media_pending_local_cache` (the number of media messages that could not be downloaded because the source is the local cache), and, when `retry_media_message_ids` was given, `media_retried_ids`. The result SHALL NOT contain message text, captions, file names or sender names.

#### Scenario: Manifest after a first run

- **WHEN** a first run archives 120 messages over 3 days, 4 of them photos, with TDLib synced
- **THEN** the result is `{"files":["777/2026-10-09.md","777/2026-10-10.md","777/2026-10-11.md"],"newest_message_file":"777/2026-10-11.md","new_messages":120,"media_messages":4,"media_downloaded":4,"media_skipped":[],"media_failed_ids":[],"media_pending_local_cache":0,"newest_message_id":<id>,"source":"tdlib","complete":true,"bookmark_safe":true}`


<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
### Requirement: Only newer messages are fetched

The tool SHALL archive only messages with an id greater than `after_message_id` when it is given; otherwise only messages on or after the start of `since_date` at the effective `utc_offset` when it is given; otherwise the whole history available. It SHALL stop paging once it reaches a message at or below that bound.

#### Scenario: Incremental run

- **WHEN** the tool is called with `after_message_id` 5243904 and the chat has messages 5243904, 5244928 and 5245952
- **THEN** only 5244928 and 5245952 are archived and `newest_message_id` is 5245952


<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
### Requirement: Bookmark safety

`bookmark_safe` SHALL be true only when all of the following hold: paging reached the bound (the `after_message_id`, the start of `since_date`, or the beginning of the chat history); the source is `tdlib`; and TDLib reported `connectionStateReady` at the end of the call. Otherwise it SHALL be false with `bookmark_unsafe_reason` set to one of `incomplete`, `local-cache` or `not-synced`.

#### Scenario: TDLib not synced

- **WHEN** the call completes paging while TDLib reports `connectionStateUpdating`
- **THEN** `bookmark_safe` is false and `bookmark_unsafe_reason` is `not-synced`

##### Example: bookmark safety table

| Paging reached the bound | Source | Connection state at end | `bookmark_safe` | `bookmark_unsafe_reason` |
| --- | --- | --- | --- | --- |
| yes | tdlib | connectionStateReady | true | — |
| no | tdlib | connectionStateReady | false | incomplete |
| yes | tdlib | connectionStateUpdating | false | not-synced |
| yes | local-cache | — | false | local-cache |


<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
### Requirement: Rate limits keep partial progress

When TDLib answers a history request with a rate-limit error — `429 "Too Many Requests: retry after <n>"`, the form TDLib reports once its own waiting on a server `FLOOD_WAIT` gives up, or `FLOOD_WAIT_<n>` — and `n` is at most 60, the tool SHALL wait `n` seconds and retry that request once. When `n` is greater than 60, or the retry fails again, the tool SHALL stop paging and return the manifest with `complete: false`, `stopped_reason: "flood_wait"`, `retry_after_seconds: <n>` and `bookmark_safe: false`. Day files written before the stop SHALL be kept.

#### Scenario: Long rate limit

- **WHEN** a history request fails with `Too Many Requests: retry after 420` after 3 pages were written
- **THEN** the result has `complete: false`, `stopped_reason: "flood_wait"`, `retry_after_seconds: 420`, `bookmark_safe: false`, and the files from those 3 pages remain on disk


<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
### Requirement: Archive from the local cache

While another process holds TDLib, the tool SHALL read messages through the local reader, write day files under the same rules, download no media, count the media messages it archived in `media_pending_local_cache`, and return `source: "local-cache"` and `bookmark_safe: false` with `bookmark_unsafe_reason: "local-cache"`. Incoming senders SHALL be labelled `User <user_id>` because the local reader does not resolve names. Blocks written this way SHALL be kept unchanged by later calls under the merge rule, so they keep those labels and lack captions; the tool's description and the README SHALL say so.

#### Scenario: Another session holds TDLib

- **WHEN** `archive_chat_to_markdown` is called while process 4242 holds TDLib
- **THEN** day files are written from the local cache, the manifest has `source: "local-cache"` and `bookmark_safe: false`, and no TDLib client is created in the server process


<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
### Requirement: Media download into the archive

On the TDLib path, for each archived message whose type carries a file, the tool SHALL ensure the directory `<output_dir>/<chat_id>/media/<message_id>/` holds the file: when the directory already holds a regular file it SHALL do nothing; otherwise it SHALL download the file through TDLib, wait for the download to finish, and copy it into that directory. The file name SHALL be `photo.jpg` for photos, the original file name for files that have one (with path separators removed and a leading dot stripped), and otherwise the message type followed by the extension of TDLib's downloaded file. When `max_media_bytes` is given and the file's size exceeds it, the tool SHALL not download it and SHALL list it in `media_skipped`. A failed download SHALL add the message id to `media_failed_ids`, SHALL NOT fail the call, and SHALL NOT change `bookmark_safe`. The original file name SHALL be filtered by Unicode scalar (removing `/`, `\`, control and line-separator characters) and, like any saved name, kept within 255 bytes, preserving a short extension. A symbolic link in the media directory SHALL NOT count as a downloaded file; replacing it SHALL remove only the link. A download SHALL be copied through a hidden temporary file that is removed when saving fails. Media directories SHALL be accessible by the owner only (0700) and media files SHALL be readable and writable by the owner only (0600).

#### Scenario: Photo downloaded once

- **WHEN** archived message 5243904 is a photo and `777/media/5243904/` does not exist
- **THEN** the file `777/media/5243904/photo.jpg` exists after the call and `media_downloaded` counts it; a second call with the same messages downloads nothing

#### Scenario: File over the size cap

- **WHEN** `max_media_bytes` is 10000000 and archived message 7000 is a 52000000-byte video
- **THEN** no file is saved for 7000 and `media_skipped` contains `{"message_id":7000,"size":52000000}`

#### Scenario: Download failure does not stop archiving

- **WHEN** the download for message 7100 fails while the other messages archive normally
- **THEN** `media_failed_ids` is `[7100]`, the day files hold every message, and `bookmark_safe` is decided as if no media existed


<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
### Requirement: Media retry by message id

When `retry_media_message_ids` is given, the tool SHALL, on the TDLib path, fetch each listed message by id in `chat_id` and apply the media download rule to it, without writing day files for those messages. Ids that are downloaded SHALL be listed in `media_retried_ids`; ids that fail again SHALL stay in `media_failed_ids`. On the local-cache path the listed ids SHALL be returned unchanged in `media_failed_ids`.

#### Scenario: Retried download succeeds

- **WHEN** the tool is called with `retry_media_message_ids` `[7100]` and the download now succeeds
- **THEN** `777/media/7100/` holds the file and `media_retried_ids` is `[7100]`


<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
### Requirement: Single message media download tool

The server SHALL expose an MCP tool `download_message_media` with a required integer `chat_id`, a required integer `message_id` and a required absolute path `output_dir`. It SHALL save the message's media under `<output_dir>/<chat_id>/media/<message_id>/` using the media download rule and return a JSON object with `message_id`, `type`, `path` (the absolute path of the saved file) and `size`, without message text or caption. When the file already exists it SHALL return its path without downloading again. A message without a file SHALL produce `isError: true` with a message saying so. While another process holds TDLib the tool SHALL return the `tdlib_in_use` error.

#### Scenario: Viewing one photo

- **WHEN** `download_message_media` is called for message 5243904 (a photo) in chat 777 with `output_dir` `/tmp/view`
- **THEN** the result has `path` `/tmp/view/777/media/5243904/photo.jpg` and that file exists

#### Scenario: Text message

- **WHEN** `download_message_media` is called for a text message
- **THEN** the result has `isError: true` and no file is written


<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
### Requirement: archive-telegram skill configuration and index

The plugin `che-telegram-mcp` SHALL provide a skill `archive-telegram`. It SHALL read `.claude/.telegram/config.yaml` in the current workspace with the fields `chats` (a list of entries with a required `chat_id` and an optional `label`), `output_dir`, an optional `since` date, and an optional `max_media_mb` passed to the tool as `max_media_bytes` (megabytes × 1048576). When the file is missing or has no `chats`, the skill SHALL stop and show a configuration template without calling any tool. The skill SHALL keep `.claude/.telegram/state/archives/<slug>/index.json`, where `<slug>` is derived from `output_dir`, holding per chat `last_message_id`, the `utc_offset` used, `pending_media` (message ids whose media download failed), and a summary of the last run; it SHALL write the index by writing a temporary file and renaming it. For each listed chat the skill SHALL call `archive_chat_to_markdown` with `after_message_id` set to that chat's `last_message_id` when one exists and `since_date` set to `since` otherwise, with the recorded `utc_offset`, and with `retry_media_message_ids` set to that chat's `pending_media`. After the call it SHALL set `pending_media` to the call's `media_failed_ids`. The skill SHALL record a chat's `utc_offset` in the index before calling the tool for that chat, and when the tool refuses the offset naming a recorded `+HH:MM`/`-HH:MM` value, SHALL store that value and call once more with it. It SHALL derive `<slug>` without passing configuration values through a shell, SHALL single-quote every path it puts into a shell command, and SHALL stop without calling the archive tool when the index records a different `output_dir` than the configuration, or when `output_dir` lies inside a git repository (the repository of its nearest existing parent directory) that does not ignore files under it. When `auth_status` reports `tdlib_in_use`, the skill SHALL stop and tell the user to run it again later, unless the user explicitly asks to archive from the local cache.

#### Scenario: Missing configuration

- **WHEN** `/archive-telegram` runs in a workspace without `.claude/.telegram/config.yaml`
- **THEN** the skill shows a configuration template and calls no tool

#### Scenario: Another session holds TDLib when the skill runs

- **WHEN** `/archive-telegram` runs while another process holds TDLib and the user has not asked for a cache archive
- **THEN** the skill reports that TDLib is in use, suggests running again later, and calls no archive tool

#### Scenario: Bookmark advances only when safe

- **WHEN** a chat's call returns `bookmark_safe: false` with `newest_message_id` 9100 and the index holds `last_message_id` 9000
- **THEN** the index still holds 9000 for that chat after the run


<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->

---
### Requirement: archive-telegram end-of-run check and report

After all calls, the skill SHALL check, for each manifest, for the files in `files` together with `newest_message_file`, that each exists and its leading frontmatter `chat_id` equals the chat's id, and that when `newest_message_id` is not null the line `<!-- msg:<newest_message_id> -->` is present in `newest_message_file` — using searches that report only which files match, never the matching text; a failed check SHALL be reported for that chat and SHALL keep its bookmark unchanged. The skill SHALL report per chat the label or `chat_id`, the new message count, the media count, the media downloaded, skipped (with sizes) and failed, whether the bookmark advanced and why not, and any stop reason. The report SHALL NOT quote message text, captions or sender names.

#### Scenario: Report after a rate-limited chat

- **WHEN** one listed chat stops with `stopped_reason: "flood_wait"` and `retry_after_seconds: 420`
- **THEN** the report states that chat's bookmark did not advance, names the 420-second wait, and suggests re-running later

#### Scenario: Re-run after an unsafe run

- **WHEN** a chat's previous run wrote messages up to 9100 but did not move the bookmark, and this run reads the same range with nothing new, returning `files: []`, `newest_message_id` 9100 and `newest_message_file` `777/2026-10-11.md`
- **THEN** the check finds the anchor of 9100 in `777/2026-10-11.md` and, with `bookmark_safe: true`, the bookmark moves to 9100

#### Scenario: Listed file missing

- **WHEN** a manifest lists `777/2026-10-11.md` but the file does not exist after the run
- **THEN** the report names the missing file for chat 777 and that chat's bookmark is not advanced

<!-- @trace
source: archive-telegram
updated: 2026-10-14
code:
  - README.md
  - CLAUDE.md
  - .agents/skills/spectra-verify/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-bot-mcp/README.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient+Archive.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ArchiveToolTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MessageMediaFileTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LocalCacheArchiveTests.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .claude-plugin/marketplace.json
  - AGENTS.md
  - che-telegram-all-mcp/README.md
  - plugins/che-telegram-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
  - tests/che-telegram-mcp/test-plugin-layout.sh
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ArchiveToolArgs.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ChatArchiver.swift
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/ToolRoutingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveDayFile.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveDayFileTests.swift
  - che-telegram-bot-mcp/CHANGELOG.md
  - plugins/che-telegram-mcp/skills/archive-telegram/SKILL.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/TelegramAllLib/ArchiveMedia.swift
  - che-telegram-bot-mcp/mcpb/manifest.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveTDLibErrorTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ArchiveMediaTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/ChatArchiverTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LocalReaderResponses.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/mcpb/manifest.json
  - .agents/skills/spectra-review/SKILL.md
-->