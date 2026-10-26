## MODIFIED Requirements

### Requirement: Day file format

The tool SHALL write each archived message into the file `<output_dir>/<chat_id>/<YYYY-MM-DD>.md`, where the date is the message's local date at the effective `utc_offset`. Each file SHALL begin with a YAML frontmatter block holding `chat_id`, `date` and `utc_offset`. Each message SHALL be written as a line `<!-- msg:<message_id> -->`, then a line `**<HH:mm> <sender>**：`, then the message body and a blank line. A block written from TDLib's local cache SHALL have one more line between the anchor line and the header line: the provisional marker, which is exactly `<!-- provisional: local-cache -->` (no leading or trailing space). The marker SHALL appear in no other position, the anchor line SHALL be the same with or without it, and every block SHALL still start at its anchor line, so a reader that splits a day file at anchor lines finds the same blocks with or without markers and can tell a provisional block by its second line. The sender SHALL be `我` for outgoing messages, the resolved display name when one is known, and `User <user_id>` otherwise. A text message's body SHALL be its text. For a message whose type carries a file (`photo`, `video`, `document`, `audio`, `voice_note`, `video_note`, `animation`, `sticker`) the label SHALL be `[<type>](media/<message_id>/)`, a link to the message's media directory relative to the day file; for any other non-text type the label SHALL be `[<type>]`. The body of a non-text message SHALL be its label, followed by a space and the message's inline detail when it has one, and, for a poll, by its option lines. The detail of a non-text message is determined by its type: for `poll`, the inline detail is the poll's `question` (its own line breaks kept), followed by one line `- <option>` for each non-empty entry of `options`, in order, with line breaks inside an option written as spaces; for `sticker`, the inline detail is its `emoji`; for `location`, the inline detail is `<latitude>,<longitude>` when both are finite numbers, each written in plain decimal notation with the fewest digits that reproduce TDLib's value exactly (no rounding and no exponent); for any other non-text type, the inline detail is its `caption`. An absent or empty inline detail SHALL be treated as none. A message read from TDLib's local cache has no caption and no poll, sticker or location detail, so its body is its label alone. The link SHALL be written whether or not the file has been downloaded yet. A body line that begins with `<!--`, or that begins like a block header (`**` followed by a time such as `9:00` or `09:00`), SHALL be written with a leading backslash, and a line break in a sender name SHALL be written as a space, so that neither can pass for the start of another block and message text cannot pass for the provisional marker. Blocks already in a day file are kept under the merge rule, so a block written before details were kept keeps its bare label. Directories the tool creates SHALL be accessible by the owner only (0700) and day files SHALL be readable and writable by the owner only (0600).

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

#### Scenario: Text that looks like the marker

- **WHEN** message 40, read through TDLib, has a body line `<!-- provisional: local-cache -->`
- **THEN** that line is written as `\<!-- provisional: local-cache -->`, and the block of message 40 is not provisional

### Requirement: Merge and idempotent rewrite

When a day file already exists, the tool SHALL read the message blocks it holds, keep every existing block unchanged except that a call whose source is `tdlib` SHALL replace each provisional block (a block whose second line is the provisional marker) of a message it archives with that message's block as it writes it now, add only messages whose anchor id is not already present, order all blocks by ascending message id, and replace the file atomically by writing a temporary file in the same directory and renaming it over the original. Replacing a provisional block is an upgrade. A call whose source is `local-cache` SHALL NOT replace any block, and no call SHALL replace a block that is not provisional. A provisional block is owned by the tool: an upgrade discards anything added to it by hand. When a call neither adds a message to a day file nor upgrades a block in it, that file SHALL be left untouched; in particular, running the tool again with the same arguments and no new messages SHALL leave every file byte-identical when the source is `local-cache` or when no provisional block of an archived message remains. The tool SHALL NOT delete a file or remove a block. The tool SHALL open a day file (a file named `YYYY-MM-DD.md` in `<output_dir>/<chat_id>/`) without following a symbolic link and without waiting for a writer, and SHALL read it only when it is a regular file. Before reading any message, when a day file records a `utc_offset` that differs from the call's (compared as an offset, so `-00:00` equals `+00:00`), or cannot be read, has no readable `utc_offset`, or uses CRLF line endings in its frontmatter, the tool SHALL refuse the call with an error naming `utc_offset` (and the recorded offset when it is readable); when a day file is not a regular file (a symbolic link, including one whose target does not exist, a FIFO, a device or a directory), the tool SHALL refuse the call with an error naming the day file and saying that it is not a regular file. In both cases the tool SHALL NOT write any day file or media file. When a day file the call is about to merge into contains a carriage return anywhere in its text, the tool SHALL refuse the call at that point with an error naming the day file and saying that it contains a carriage return, SHALL leave that file byte-identical, and SHALL keep the day files it already wrote in that call; this check is made when the file is merged rather than before reading any message, so that the check before reading reads only the start of each day file. A day file that is not a regular file when it is merged SHALL be refused the same way. Other files in that directory SHALL be ignored.

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

##### Example: day files the call refuses

| Day file in `777/` | Refused | When |
| --- | --- | --- |
| frontmatter `utc_offset` `+09:00`, call `+08:00` | yes, naming `utc_offset` and `+09:00` | before reading any message |
| CRLF frontmatter | yes, naming `utc_offset` | before reading any message |
| FIFO, directory, or symbolic link (to a file or dangling) | yes, not a regular file | before reading any message |
| LF frontmatter, CRLF or lone CR in the body | yes, contains a carriage return | when the call merges into it |
| LF only, same offset | no | — |

##### Example: which existing blocks a call replaces

| Existing block | Call's source | Result |
| --- | --- | --- |
| provisional | `tdlib` | replaced by the message's block as written now (no marker), counted in `upgraded_messages` |
| provisional | `local-cache` | kept unchanged |
| not provisional | `tdlib` | kept unchanged |
| not provisional | `local-cache` | kept unchanged |

### Requirement: Content-free manifest

A successful call SHALL return a single JSON object with the fields `files` (paths, relative to `output_dir`, of the day files this call added messages to or upgraded blocks in), `new_messages`, `media_messages` (the number of new messages whose type carries a file), `upgraded_messages` (the number of provisional blocks this call replaced; upgraded messages are not counted in `new_messages` or `media_messages`), `newest_message_id` (the largest message id archived in this call, or null), `newest_message_file` (the path, relative to `output_dir`, of the day file holding that message whether or not this call wrote it; null exactly when `newest_message_id` is null), `source` (`tdlib` or `local-cache`), `complete` and `bookmark_safe`. When `complete` is false the object SHALL include `stopped_reason`, and when `bookmark_safe` is false it SHALL include `bookmark_unsafe_reason`. The object SHALL also include `media_downloaded` (the number of media files saved by this call), `media_skipped` (a list of `{"message_id","size"}` for files over `max_media_bytes`), `media_failed_ids` (message ids whose download failed, each listed once, without ids whose retry succeeded in the same call and without ids listed in `media_gone_ids`), `media_pending_local_cache` (the number of media messages that could not be downloaded because the source is the local cache), `undated_messages_skipped` (the number of messages in range that were not written because the source gave them no date), and, when `retry_media_message_ids` was given with at least one id and the source is `tdlib`, `media_retried_ids` and `media_gone_ids` (listed ids whose message no longer exists, as defined by the media retry rule). The result SHALL NOT contain message text, captions, file names or sender names.

#### Scenario: Manifest after a first run

- **WHEN** a first run archives 120 messages over 3 days, 4 of them photos, with TDLib synced
- **THEN** the result is `{"files":["777/2026-10-09.md","777/2026-10-10.md","777/2026-10-11.md"],"newest_message_file":"777/2026-10-11.md","new_messages":120,"media_messages":4,"upgraded_messages":0,"media_downloaded":4,"media_skipped":[],"media_failed_ids":[],"media_pending_local_cache":0,"undated_messages_skipped":0,"newest_message_id":<id>,"source":"tdlib","complete":true,"bookmark_safe":true}`

### Requirement: Archive from the local cache

While another process holds TDLib, the tool SHALL read messages through the local reader, write day files under the same rules, download no media, count the media messages it archived in `media_pending_local_cache`, and return `source: "local-cache"` and `bookmark_safe: false` with `bookmark_unsafe_reason: "local-cache"`. Incoming senders SHALL be labelled `User <user_id>` because the local reader does not resolve names. Every block this call adds SHALL carry the provisional marker, because it lacks what the local reader cannot give (sender names, captions, poll, sticker and location details, the `audio` type). A later call through TDLib that archives the same messages SHALL upgrade those blocks under the merge rule; such a call reaches them without a new argument because a local-cache call never advances the bookmark, and a call with an older `after_message_id` reaches blocks below a bookmark. Blocks written from the local cache by a version of the tool without the marker SHALL be kept unchanged, like any block that is not provisional. The tool's description and the README SHALL say that blocks written from the local cache are provisional until a call through TDLib replaces them. A message the local reader returns without a date SHALL NOT be written, because its day is unknown, and SHALL be counted in `undated_messages_skipped`; it is not lost, because such a run never advances the bookmark and a later TDLib run of the same range adds it.

#### Scenario: Another session holds TDLib

- **WHEN** `archive_chat_to_markdown` is called while process 4242 holds TDLib
- **THEN** day files are written from the local cache with every new block provisional, the manifest has `source: "local-cache"` and `bookmark_safe: false`, and no TDLib client is created in the server process

#### Scenario: Cache record without a date

- **WHEN** the local reader returns messages 30 and 20 for chat 777 and message 20 has no date
- **THEN** only message 30 is written, the manifest has `undated_messages_skipped: 1` and `new_messages: 1`, and `bookmark_safe` is false

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
