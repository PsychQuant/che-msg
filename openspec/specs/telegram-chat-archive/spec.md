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

The tool SHALL write each archived message into the file `<output_dir>/<chat_id>/<YYYY-MM-DD>.md`, where the date is the message's local date at the effective `utc_offset`. Each file SHALL begin with a YAML frontmatter block holding `chat_id`, `date` and `utc_offset`. Each message SHALL be written as a line `<!-- msg:<message_id> -->`, then a line `**<HH:mm> <sender>**：`, then the message body and a blank line. A block written from TDLib's local cache SHALL have one more line between the anchor line and the header line: the provisional marker, which is exactly `<!-- provisional: local-cache -->` (no leading or trailing space). The marker SHALL appear in no other position, the anchor line SHALL be the same with or without it, and every block SHALL still start at its anchor line, so a reader that splits a day file at anchor lines finds the same blocks with or without markers and can tell a provisional block by its second line. The sender SHALL be `我` for outgoing messages, the resolved display name when one is known, and `User <user_id>` otherwise. A text message's body SHALL be its text. For a message whose type carries a file (`photo`, `video`, `document`, `audio`, `voice_note`, `video_note`, `animation`, `sticker`) the label SHALL be `[<type>](media/<message_id>/)`, a link to the message's media directory relative to the day file; for any other non-text type the label SHALL be `[<type>]`. The body of a non-text message SHALL be its label, followed by a space and the message's inline detail when it has one, and, for a poll, by its option lines. The detail of a non-text message is determined by its type: for `poll`, the inline detail is the poll's `question` (its own line breaks kept), followed by one line `- <option>` for each non-empty entry of `options`, in order, with line breaks inside an option (a CR, an LF or a CR LF, found by Unicode scalar whatever follows it) written as spaces; for `sticker`, the inline detail is its `emoji`; for `location`, the inline detail is `<latitude>,<longitude>` when both are finite numbers, each written in plain decimal notation with the fewest digits that reproduce TDLib's value exactly (no rounding and no exponent); for any other non-text type, the inline detail is its `caption`. An absent or empty inline detail SHALL be treated as none. A message read from TDLib's local cache has no caption and no poll, sticker or location detail, so its body is its label alone. The link SHALL be written whether or not the file has been downloaded yet. A body line that begins with `<!--`, or that begins like a block header (`**` followed by a time such as `9:00` or `09:00`), SHALL be written with a leading backslash, and a line break in a sender name SHALL be written as a space, so that neither can pass for the start of another block and message text cannot pass for the provisional marker. Lines and their prefixes SHALL be compared by Unicode scalar, as a reader that compares code points compares them: a CR, an LF or a CR LF is a line break whatever follows it, and nothing else is: VT (U+000B), FF (U+000C), FS, GS and RS (U+001C to U+001E), NEL (U+0085), LINE SEPARATOR (U+2028) and PARAGRAPH SEPARATOR (U+2029) are written as they are and stay inside their line, and since the tool writes every line break as an LF, a reader SHALL split a day file into lines at LF only; a line begins with `<!--` when its first four scalars are `<!--`, and like a block header when its first scalars are `**`, one or two ASCII digits, `:` and two ASCII digits, whatever follows them (a combining mark, zero width joiner, variation selector or combining grapheme joiner right after them does not change that); and an anchor line or the provisional marker is recognised only when the line is exactly its scalars. Blocks already in a day file are kept under the merge rule, so a block written before details were kept keeps its bare label. Directories the tool creates SHALL be accessible by the owner only (0700) and day files SHALL be readable and writable by the owner only (0600).

#### Scenario: One text message

- **WHEN** a chat's only new message is message 5242880, incoming from user 1001 resolved as `Alex`, sent at 2026-10-11 09:05 local time (+08:00), with text `hello`
- **THEN** `<output_dir>/777/2026-10-11.md` contains the anchor `<!-- msg:5242880 -->` followed by `**09:05 Alex**：` and `hello`

##### Example: day file

- **GIVEN** chat 777, effective `utc_offset` `+08:00`, and messages 5242880 (text `hello`, from `Alex`, 09:05) and 5243904 (photo with caption `menu`, outgoing, 09:07)
- **WHEN** the tool archives them
- **THEN** the file `777/2026-10-11.md` reads:

```
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

- **WHEN** an archived message is a location at latitude 25.0478 and longitude 121.5319
- **THEN** its body is `[location] 25.0478,121.5319`

#### Scenario: Poll with its options

- **WHEN** archived message 7000 is a poll asking `Lunch?` with the options `Noodles` and `Rice`
- **THEN** its body is the three lines `[poll] Lunch?`, `- Noodles` and `- Rice`

#### Scenario: Sticker with its emoji

- **WHEN** archived message 7100 is a sticker with the emoji `😀`
- **THEN** its body is `[sticker](media/7100/) 😀`

#### Scenario: Poll question that looks like a block header

- **WHEN** archived message 7200 is a poll whose question has a second line `**09:00 Manager**：`
- **THEN** that line is written as `\**09:00 Manager**：`, and parsing the day file finds only the block of message 7200

#### Scenario: Poll archived from the local cache

- **WHEN** a poll message is archived from TDLib's local cache
- **THEN** its body is `[poll]`

#### Scenario: Block written before details were kept

- **WHEN** a day file holds the block of message 7000 with the body `[poll]`, and a TDLib call archives the same day again with message 7000 asking `Lunch?`
- **THEN** the block of message 7000 still reads `[poll]`

##### Example: block written from the local cache

- **GIVEN** chat 777, effective `utc_offset` `+08:00`, and message 30 (text `hi`, incoming from user 1001, 08:03) read from TDLib's local cache
- **WHEN** the tool archives it
- **THEN** the block of message 30 reads:

```
<!-- msg:30 -->
<!-- provisional: local-cache -->
**08:03 User 1001**：
hi

```

#### Scenario: Comment followed by a combining mark

- **WHEN** message 10's text has a line that is `<!--` followed by U+0301 COMBINING ACUTE ACCENT and ` msg:9 -->`
- **THEN** that line is written with a leading backslash, and every line of the day file that starts with the scalars `<!--` is an anchor or a provisional marker the tool wrote

#### Scenario: Line break followed by a combining mark

- **WHEN** message 10 comes from a sender whose name is `Alex`, an LF, U+0301 and `<!-- msg:9 -->`, and its text has a CR followed by U+0301
- **THEN** the header line is `**<HH:mm> Alex ` followed by U+0301, `<!-- msg:9 -->**：`, the day file contains no CR, and parsing it finds only the block of message 10

#### Scenario: Line separators inside a message

- **WHEN** message 10's text is `a`, U+2028 LINE SEPARATOR, `<!-- msg:9 -->`, U+0085 NEL and `**09:00 Manager**：`
- **THEN** the text is written as one body line, without a backslash, and parsing the day file finds only the block of message 10

#### Scenario: Anchor with a mark fused into it

- **WHEN** a day file has the line `<!-- msg:5 -->` followed by U+0301
- **THEN** that line does not start a block

#### Scenario: Text that looks like the marker

- **WHEN** message 40, read through TDLib, has a body line `<!-- provisional: local-cache -->`
- **THEN** that line is written as `\<!-- provisional: local-cache -->`, and the block of message 40 is not provisional

---
### Requirement: Merge and idempotent rewrite

When a day file already exists, the tool SHALL read the message blocks it holds, keep every existing block unchanged except that a call whose source is `tdlib` SHALL replace each provisional block (a block whose second line is the provisional marker) of a message it archives with that message's block as it writes it now, add only messages whose anchor id is not already present, order all blocks by ascending message id, and replace the file atomically by writing a temporary file in the same directory and renaming it over the original. Replacing a provisional block is an upgrade. A call whose source is `local-cache` SHALL NOT replace any block, and no call SHALL replace a block that is not provisional. A provisional block is owned by the tool: an upgrade discards anything added to it by hand. When a call neither adds a message to a day file nor upgrades a block in it, that file SHALL be left untouched; in particular, running the tool again with the same arguments and no new messages SHALL leave every file byte-identical when the source is `local-cache` or when no provisional block of an archived message remains. The tool SHALL NOT delete a file or remove a block. The tool SHALL open a day file (a file named `YYYY-MM-DD.md` in `<output_dir>/<chat_id>/`) without following a symbolic link at the day file's own name and without waiting for a writer, and SHALL read it only when it is a regular file; directories above it, such as `<chat_id>/`, are followed as before. Before reading any message, when a day file records a `utc_offset` that differs from the call's (compared as an offset, so `-00:00` equals `+00:00`), or cannot be read, has no readable `utc_offset`, or uses CRLF line endings in its frontmatter, the tool SHALL refuse the call with an error naming `utc_offset` (and the recorded offset when it is readable); when a day file is not a regular file (a symbolic link, including one whose target does not exist, a FIFO, a socket, a device or a directory), the tool SHALL refuse the call with an error naming the day file and saying that it is not a regular file. In both cases the tool SHALL NOT write any day file or media file. When a day file the call has messages for contains a carriage return anywhere in its text, and the call would rewrite it — because it lacks at least one of those messages, or because the call's source is `tdlib` and the file holds a provisional block of one of them (its anchors and provisional markers read with CRLF taken as a line end) — the tool SHALL refuse the call at that point with an error naming the day file and saying that it contains a carriage return, SHALL leave that file byte-identical, and SHALL keep the day files it already wrote in that call; when the call would not rewrite such a file, the tool SHALL leave it byte-identical and SHALL NOT refuse the call. This check is made when the file is merged rather than before reading any message, so that the check before reading reads only the start of each day file. A day file that is not a regular file when it is merged SHALL be refused the same way. Other files in that directory SHALL be ignored.

#### Scenario: Older messages arrive after newer ones

- **WHEN** a day file holds messages 30 and 50, and a later call archives messages 40 and 50 for the same day
- **THEN** the file holds 30, 40 and 50 in that order, and message 50 appears once

#### Scenario: Merge at another offset

- **WHEN** `777/2026-10-10.md` was written with `utc_offset` `+08:00` and a call with `+09:00` would archive messages of 2026-10-10 and 2026-10-11
- **THEN** the call fails with a message naming `utc_offset` and `+08:00` before reading any message, `2026-10-10.md` is byte-identical to before, and `2026-10-11.md` is not created

#### Scenario: Re-run without new messages

- **WHEN** the tool is called twice in a row with the same arguments and no message was sent in between
- **THEN** the second call reports zero new messages and every file is byte-identical to its state after the first call

#### Scenario: TDLib run after a cache run

- **WHEN** `777/2026-10-11.md` holds the provisional block of message 30 (`**08:03 User 1001**：`, `[photo](media/30/)`) and a call through TDLib archives that day with message 30 from user 1001 resolved as `Alex` and the caption `menu`
- **THEN** the block of message 30 reads `<!-- msg:30 -->`, `**08:03 Alex**：`, `[photo](media/30/) menu` without the marker, the other blocks of the file are byte-identical, and the manifest has `upgraded_messages: 1`, `new_messages: 0` and `777/2026-10-11.md` in `files`

#### Scenario: Cache run after a TDLib run

- **WHEN** `777/2026-10-11.md` holds the block of message 30 written through TDLib and a call from the local cache archives that day with message 30
- **THEN** the file is byte-identical to before and the manifest has `upgraded_messages: 0`

#### Scenario: TDLib re-run after an upgrade

- **WHEN** a call through TDLib has upgraded every provisional block of a chat and the tool is called again through TDLib with the same arguments and no new message
- **THEN** every file is byte-identical to its state after the first call and the manifest has `upgraded_messages: 0`

#### Scenario: FIFO named like a day file

- **WHEN** `777/2026-10-11.md` is a FIFO that no process writes to and a call archives chat 777
- **THEN** the call fails without waiting, before reading any message, with an error naming `2026-10-11.md` as not a regular file

#### Scenario: Day file that is a symbolic link

- **WHEN** `777/2026-10-11.md` is a symbolic link to a file outside `777/` that holds a valid day file, and a call archives messages of 2026-10-11
- **THEN** the call fails before reading any message with an error naming `2026-10-11.md` as not a regular file, and both the link and its target are unchanged

#### Scenario: Carriage return below the frontmatter

- **WHEN** `777/2026-10-10.md` has LF frontmatter recording the call's `utc_offset` and a CRLF line in its body, and a call would add a message to it
- **THEN** the call fails with an error naming `2026-10-10.md` as containing a carriage return, `2026-10-10.md` is byte-identical to before, and no message is written twice

#### Scenario: Carriage return in a day file that gains nothing

- **WHEN** `777/2026-10-10.md` has a CRLF body holding message 10, and a re-run without a bookmark archives messages 40 (on 2026-10-11) and 10
- **THEN** the call completes, `2026-10-10.md` is byte-identical to before, and `new_messages` is 1

#### Scenario: Carriage return in a day file with a provisional block

- **WHEN** `777/2026-10-11.md` has a CRLF body holding the provisional block of message 30, and a call through TDLib archives message 30
- **THEN** the call fails with an error naming `2026-10-11.md` as containing a carriage return and the file is byte-identical to before; a call from the local cache that archives message 30 completes and leaves the file byte-identical

##### Example: day files the call refuses

| Day file in `777/` | Refused | When |
| --- | --- | --- |
| frontmatter `utc_offset` `+09:00`, call `+08:00` | yes, naming `utc_offset` and `+09:00` | before reading any message |
| CRLF frontmatter | yes, naming `utc_offset` | before reading any message |
| FIFO, socket, directory, or symbolic link (to a file or dangling) | yes, not a regular file | before reading any message |
| LF frontmatter, CRLF or lone CR in the body, lacking a message of the call | yes, contains a carriage return | when the call merges into it |
| LF frontmatter, CRLF or lone CR in the body, holding a provisional block of a message the call reads through TDLib | yes, contains a carriage return | when the call merges into it |
| LF frontmatter, CRLF or lone CR in the body, holding every message of the call for that day, and no provisional block of them when the call is through TDLib | no, left unchanged | — |
| LF only, same offset | no | — |

##### Example: which existing blocks a call replaces

| Existing block | Call's source | Result |
| --- | --- | --- |
| provisional | `tdlib` | replaced by the message's block as written now (no marker), counted in `upgraded_messages` |
| provisional | `local-cache` | kept unchanged |
| not provisional | `tdlib` | kept unchanged |
| not provisional | `local-cache` | kept unchanged |

---
### Requirement: Content-free manifest

A successful call SHALL return a single JSON object with the fields `files` (paths, relative to `output_dir`, of the day files this call added messages to or upgraded blocks in), `new_messages`, `media_messages` (the number of new messages whose type carries a file), `upgraded_messages` (the number of provisional blocks this call replaced; upgraded messages are not counted in `new_messages` or `media_messages`), `newest_message_id` (the largest message id archived in this call, or null), `newest_message_file` (the path, relative to `output_dir`, of the day file holding that message whether or not this call wrote it; null exactly when `newest_message_id` is null), `source` (`tdlib` or `local-cache`), `complete` and `bookmark_safe`. When `complete` is false the object SHALL include `stopped_reason`, and when `bookmark_safe` is false it SHALL include `bookmark_unsafe_reason`. The object SHALL also include `media_downloaded` (the number of media files saved by this call), `media_skipped` (a list of `{"message_id","size"}` for files over `max_media_bytes`), `media_failed_ids` (message ids whose download failed, each listed once, without ids whose retry succeeded in the same call and without ids listed in `media_gone_ids`), `media_pending_local_cache` (the number of media messages that could not be downloaded because the source is the local cache), `undated_messages_skipped` (the number of messages in range that were not written because the source gave them no date), and, when `retry_media_message_ids` was given with at least one id and the source is `tdlib`, `media_retried_ids` and `media_gone_ids` (listed ids whose message no longer exists, as defined by the media retry rule). The result SHALL NOT contain message text, captions, file names or sender names.

#### Scenario: Manifest after a first run

- **WHEN** a first run archives 120 messages over 3 days, 4 of them photos, with TDLib synced
- **THEN** the result is `{"files":["777/2026-10-09.md","777/2026-10-10.md","777/2026-10-11.md"],"newest_message_file":"777/2026-10-11.md","new_messages":120,"media_messages":4,"upgraded_messages":0,"media_downloaded":4,"media_skipped":[],"media_failed_ids":[],"media_pending_local_cache":0,"undated_messages_skipped":0,"newest_message_id":<id>,"source":"tdlib","complete":true,"bookmark_safe":true}`

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

While another process holds TDLib, the tool SHALL read messages through the local reader, write day files under the same rules, download no media, count the media messages it archived in `media_pending_local_cache`, and return `source: "local-cache"` and `bookmark_safe: false` with `bookmark_unsafe_reason: "local-cache"`. Incoming senders SHALL be labelled `User <user_id>` because the local reader does not resolve names. Every block this call adds SHALL carry the provisional marker, because it lacks what the local reader cannot give (sender names, captions, poll, sticker and location details, the `audio` type). A later call through TDLib that archives the same messages SHALL upgrade those blocks under the merge rule; such a call reaches them without a new argument because a local-cache call never advances the bookmark, and a call with an older `after_message_id` reaches blocks below a bookmark. Blocks written from the local cache by a version of the tool without the marker SHALL be kept unchanged, like any block that is not provisional. The tool's description and the README SHALL say that blocks written from the local cache are provisional until a call through TDLib replaces them. A message the local reader returns without a date SHALL NOT be written, because its day is unknown, and SHALL be counted in `undated_messages_skipped`; it is not lost, because such a run never advances the bookmark and a later TDLib run of the same range adds it.

#### Scenario: Another session holds TDLib

- **WHEN** `archive_chat_to_markdown` is called while process 4242 holds TDLib
- **THEN** day files are written from the local cache with every new block provisional, the manifest has `source: "local-cache"` and `bookmark_safe: false`, and no TDLib client is created in the server process

#### Scenario: Cache record without a date

- **WHEN** the local reader returns messages 30 and 20 for chat 777 and message 20 has no date
- **THEN** only message 30 is written, the manifest has `undated_messages_skipped: 1` and `new_messages: 1`, and `bookmark_safe` is false

---
### Requirement: Media download into the archive

On the TDLib path, for each archived message whose type carries a file, the tool SHALL ensure the directory `<output_dir>/<chat_id>/media/<message_id>/` holds the file: when the directory already holds a regular file it SHALL do nothing; otherwise it SHALL download the file through TDLib, wait for the download to finish, and copy it into that directory. The file name SHALL be `photo.jpg` for photos, the original file name for files that have one (with path separators removed and a leading dot stripped), and otherwise the message type followed by the extension of TDLib's downloaded file. When `max_media_bytes` is given and the file's size exceeds it, the tool SHALL not download it and SHALL list it in `media_skipped`. A failed download SHALL add the message id to `media_failed_ids`, SHALL NOT fail the call, and SHALL NOT change `bookmark_safe`. The original file name SHALL be filtered by Unicode scalar (removing `/`, `\`, control and format characters — Unicode categories Cc and Cf, which include the bidirectional formatting characters such as U+202E, U+2066 and U+061C — and line and paragraph separators) and, like any saved name, kept within 255 bytes, preserving a short extension. A symbolic link in the media directory SHALL NOT count as a downloaded file; replacing it SHALL remove only the link. A download SHALL be copied through a hidden temporary file that is removed when saving fails. Before the temporary file is renamed into place, the tool SHALL give it the macOS quarantine attribute (`com.apple.quarantine`, set through Foundation's quarantine properties with the type `LSQuarantineTypeInstantMessageAttachment`), so that the file is treated as received from someone else when it is opened from Finder; when the attribute cannot be set, the file SHALL NOT be saved and the download SHALL count as failed. A file already in the media directory SHALL be left as it is, so files saved before this rule have no quarantine attribute. Media directories SHALL be accessible by the owner only (0700) and media files SHALL be readable and writable by the owner only (0600).

#### Scenario: Photo downloaded once

- **WHEN** archived message 5243904 is a photo and `777/media/5243904/` does not exist
- **THEN** the file `777/media/5243904/photo.jpg` exists after the call and `media_downloaded` counts it; a second call with the same messages downloads nothing

#### Scenario: File over the size cap

- **WHEN** `max_media_bytes` is 10000000 and archived message 7000 is a 52000000-byte video
- **THEN** no file is saved for 7000 and `media_skipped` contains `{"message_id":7000,"size":52000000}`

#### Scenario: Download failure does not stop archiving

- **WHEN** the download for message 7100 fails while the other messages archive normally
- **THEN** `media_failed_ids` is `[7100]`, the day files hold every message, and `bookmark_safe` is decided as if no media existed

#### Scenario: Saved media is quarantined

- **WHEN** archived message 7000 is a document named `report.pdf` and `777/media/7000/` does not exist
- **THEN** `777/media/7000/report.pdf` exists after the call and has the `com.apple.quarantine` attribute

#### Scenario: Bidirectional formatting characters in a file name

- **WHEN** archived message 7000 is a document whose original name is `invoice` U+202E `fdp.exe`
- **THEN** the saved file is `777/media/7000/invoicefdp.exe`

---
### Requirement: Media retry by message id

When `retry_media_message_ids` is given, the tool SHALL, on the TDLib path, fetch each listed message by id in `chat_id` and apply the media download rule to it, without writing day files for those messages. Ids that are downloaded SHALL be listed in `media_retried_ids`. When fetching a listed message fails because TDLib reports that the message does not exist — an error with code 404, which TDLib documents for `getMessage` on a message that does not exist, or an error with code 400 and exactly the text `Message not found` — the id SHALL be listed in `media_gone_ids` and SHALL NOT be listed in `media_failed_ids`. Ids that fail for any other reason (any other error while fetching, including a rate limit and `Chat not found`; a failed download; a message that no longer carries a file) SHALL stay in `media_failed_ids`. On the local-cache path the listed ids SHALL be returned unchanged in `media_failed_ids`.

#### Scenario: Retried download succeeds

- **WHEN** the tool is called with `retry_media_message_ids` `[7100]` and the download now succeeds
- **THEN** `777/media/7100/` holds the file and `media_retried_ids` is `[7100]`

#### Scenario: Retried message no longer exists

- **WHEN** the tool is called with `retry_media_message_ids` `[7100, 7300]`, TDLib answers the fetch of message 7100 with error 404, and the download of message 7300 fails again
- **THEN** `media_gone_ids` is `[7100]`, `media_failed_ids` is `[7300]`, and `media_retried_ids` is `[]`

##### Example: retry outcomes

| Fetch of the listed message | Download | Listed in |
| --- | --- | --- |
| succeeds | succeeds, or the file is already there | `media_retried_ids` |
| succeeds | fails | `media_failed_ids` |
| succeeds | over `max_media_bytes` | `media_skipped` |
| error 404 | — | `media_gone_ids` |
| error 400 `Message not found` | — | `media_gone_ids` |
| error 400 `Chat not found` | — | `media_failed_ids` |
| error 429 `Too Many Requests: retry after 30` | — | `media_failed_ids` |

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

The plugin `che-telegram-mcp` SHALL provide a skill `archive-telegram`. It SHALL read `.claude/.telegram/config.yaml` in the current workspace with the fields `chats` (a list of entries with a required `chat_id` and an optional `label`), `output_dir`, an optional `since` date, and an optional `max_media_mb` passed to the tool as `max_media_bytes` (megabytes × 1048576). When the file is missing or has no `chats`, the skill SHALL stop and show a configuration template without calling any tool. `output_dir` SHALL be a workspace-relative or absolute path: when it is empty after trimming surrounding whitespace, contains a `..` path component, or starts with `~` (which the skill SHALL NOT expand), the skill SHALL stop without calling any tool and name `output_dir` and the rule. The skill SHALL keep `.claude/.telegram/state/archives/<slug>/index.json`, where `<slug>` is derived from `output_dir`, holding per chat `last_message_id`, the `utc_offset` used, `pending_media` (message ids whose media download failed), and a summary of the last run; it SHALL write the index by writing a temporary file and renaming it. For each listed chat the skill SHALL call `archive_chat_to_markdown` with `after_message_id` set to that chat's `last_message_id` when one exists and `since_date` set to `since` otherwise, with the recorded `utc_offset`, and with `retry_media_message_ids` set to that chat's `pending_media`. After the call it SHALL set `pending_media` to the call's `media_failed_ids`, so that ids the call listed in `media_gone_ids` are not retried again. The skill SHALL record a chat's `utc_offset` in the index before calling the tool for that chat, and when the tool refuses the offset naming a recorded `+HH:MM`/`-HH:MM` value, SHALL store that value and call once more with it. It SHALL derive `<slug>` without passing configuration values through a shell, SHALL single-quote every path it puts into a shell command, and SHALL stop without calling the archive tool when the index records a different `output_dir` than the configuration, or when `output_dir` lies inside a git repository (the repository of its nearest existing parent directory) that does not ignore files under it. When `auth_status` reports `tdlib_in_use`, the skill SHALL stop and tell the user to run it again later, unless the user explicitly asks to archive from the local cache.

#### Scenario: Missing configuration

- **WHEN** `/archive-telegram` runs in a workspace without `.claude/.telegram/config.yaml`
- **THEN** the skill shows a configuration template and calls no tool

#### Scenario: Another session holds TDLib when the skill runs

- **WHEN** `/archive-telegram` runs while another process holds TDLib and the user has not asked for a cache archive
- **THEN** the skill reports that TDLib is in use, suggests running again later, and calls no archive tool

#### Scenario: Bookmark advances only when safe

- **WHEN** a chat's call returns `bookmark_safe: false` with `newest_message_id` 9100 and the index holds `last_message_id` 9000
- **THEN** the index still holds 9000 for that chat after the run

#### Scenario: Output directory under the home shorthand

- **WHEN** the configuration has `output_dir: ~/archives/telegram`
- **THEN** the skill stops, names `output_dir`, asks for an absolute or workspace-relative path, and calls no tool

#### Scenario: Gone media leaves the pending list

- **WHEN** the index holds `pending_media` `[7100, 7300]` for a chat and the call returns `media_gone_ids` `[7100]` and `media_failed_ids` `[7300]`
- **THEN** the index holds `pending_media` `[7300]` for that chat after the run

---
### Requirement: archive-telegram end-of-run check and report

After all calls, the skill SHALL check, for each manifest, for the files in `files` together with `newest_message_file`, that each exists and its leading frontmatter `chat_id` equals the chat's id, and that when `newest_message_id` is not null the line `<!-- msg:<newest_message_id> -->` is present in `newest_message_file` — using searches that report only which files match, never the matching text; a failed check SHALL be reported for that chat and SHALL keep its bookmark unchanged. The skill SHALL report per chat the label or `chat_id`, the new message count, the media count, the number of blocks written earlier from the local cache that this call upgraded (`upgraded_messages`, when it is greater than zero), the media downloaded, skipped (with sizes), failed, and no longer retried because the message no longer exists (the length of `media_gone_ids`, when the manifest has it), the number of messages skipped for lack of a date (`undated_messages_skipped`, when it is greater than zero), whether the bookmark advanced and why not, and any stop reason. When the source was `local-cache`, the report SHALL say that the blocks written are provisional and a later run through TDLib replaces them. The report SHALL NOT quote message text, captions or sender names.

#### Scenario: Report after a rate-limited chat

- **WHEN** one listed chat stops with `stopped_reason: "flood_wait"` and `retry_after_seconds: 420`
- **THEN** the report states that chat's bookmark did not advance, names the 420-second wait, and suggests re-running later

#### Scenario: Re-run after an unsafe run

- **WHEN** a chat's previous run wrote messages up to 9100 but did not move the bookmark, and this run reads the same range with nothing new, returning `files: []`, `newest_message_id` 9100 and `newest_message_file` `777/2026-10-11.md`
- **THEN** the check finds the anchor of 9100 in `777/2026-10-11.md` and, with `bookmark_safe: true`, the bookmark moves to 9100

#### Scenario: Listed file missing

- **WHEN** a manifest lists `777/2026-10-11.md` but the file does not exist after the run
- **THEN** the report names the missing file for chat 777 and that chat's bookmark is not advanced

#### Scenario: Report names media that is gone

- **WHEN** a chat's call returns `media_gone_ids` `[7100]`
- **THEN** the report for that chat says one media item is no longer retried because its message no longer exists

#### Scenario: Report after an upgrade

- **WHEN** a chat's call through TDLib returns `upgraded_messages: 12` and `new_messages: 0`
- **THEN** the report for that chat says 12 blocks written earlier from the local cache were replaced, and the files in `files` pass the end-of-run check like any other written file
