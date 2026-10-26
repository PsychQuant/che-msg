## MODIFIED Requirements

### Requirement: Merge and idempotent rewrite

When a day file already exists, the tool SHALL read the message blocks it holds, keep every existing block unchanged, add only messages whose anchor id is not already present, order all blocks by ascending message id, and replace the file atomically by writing a temporary file in the same directory and renaming it over the original. Running the tool again with the same arguments and no new messages SHALL leave every file byte-identical. The tool SHALL NOT delete a file or remove a block. The tool SHALL open a day file (a file named `YYYY-MM-DD.md` in `<output_dir>/<chat_id>/`) without following a symbolic link and without waiting for a writer, and SHALL read it only when it is a regular file. Before reading any message, when a day file records a `utc_offset` that differs from the call's (compared as an offset, so `-00:00` equals `+00:00`), or cannot be read, has no readable `utc_offset`, or uses CRLF line endings in its frontmatter, the tool SHALL refuse the call with an error naming `utc_offset` (and the recorded offset when it is readable); when a day file is not a regular file (a symbolic link, including one whose target does not exist, a FIFO, a device or a directory), the tool SHALL refuse the call with an error naming the day file and saying that it is not a regular file. In both cases the tool SHALL NOT write any day file or media file. When a day file the call is about to merge into contains a carriage return anywhere in its text, the tool SHALL refuse the call at that point with an error naming the day file and saying that it contains a carriage return, SHALL leave that file byte-identical, and SHALL keep the day files it already wrote in that call; this check is made when the file is merged rather than before reading any message, so that the check before reading reads only the start of each day file. A day file that is not a regular file when it is merged SHALL be refused the same way. Other files in that directory SHALL be ignored.

#### Scenario: Older messages arrive after newer ones

- **WHEN** a day file holds messages 30 and 50, and a later call archives messages 40 and 50 for the same day
- **THEN** the file holds 30, 40 and 50 in that order, and message 50 appears once

#### Scenario: Merge at another offset

- **WHEN** `777/2026-10-10.md` was written with `utc_offset` `+08:00` and a call with `+09:00` would archive messages of 2026-10-10 and 2026-10-11
- **THEN** the call fails with a message naming `utc_offset` and `+08:00` before reading any message, `2026-10-10.md` is byte-identical to before, and `2026-10-11.md` is not created

#### Scenario: Re-run without new messages

- **WHEN** the tool is called twice in a row with the same arguments and no message was sent in between
- **THEN** the second call reports zero new messages and every file is byte-identical to its state after the first call

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

### Requirement: Content-free manifest

A successful call SHALL return a single JSON object with the fields `files` (paths, relative to `output_dir`, of the day files this call added messages to), `new_messages`, `media_messages` (the number of new messages whose type carries a file), `newest_message_id` (the largest message id archived in this call, or null), `newest_message_file` (the path, relative to `output_dir`, of the day file holding that message whether or not this call wrote it; null exactly when `newest_message_id` is null), `source` (`tdlib` or `local-cache`), `complete` and `bookmark_safe`. When `complete` is false the object SHALL include `stopped_reason`, and when `bookmark_safe` is false it SHALL include `bookmark_unsafe_reason`. The object SHALL also include `media_downloaded` (the number of media files saved by this call), `media_skipped` (a list of `{"message_id","size"}` for files over `max_media_bytes`), `media_failed_ids` (message ids whose download failed, each listed once, without ids whose retry succeeded in the same call and without ids listed in `media_gone_ids`), `media_pending_local_cache` (the number of media messages that could not be downloaded because the source is the local cache), `undated_messages_skipped` (the number of messages in range that were not written because the source gave them no date), and, when `retry_media_message_ids` was given with at least one id and the source is `tdlib`, `media_retried_ids` and `media_gone_ids` (listed ids whose message no longer exists, as defined by the media retry rule). The result SHALL NOT contain message text, captions, file names or sender names.

#### Scenario: Manifest after a first run

- **WHEN** a first run archives 120 messages over 3 days, 4 of them photos, with TDLib synced
- **THEN** the result is `{"files":["777/2026-10-09.md","777/2026-10-10.md","777/2026-10-11.md"],"newest_message_file":"777/2026-10-11.md","new_messages":120,"media_messages":4,"media_downloaded":4,"media_skipped":[],"media_failed_ids":[],"media_pending_local_cache":0,"undated_messages_skipped":0,"newest_message_id":<id>,"source":"tdlib","complete":true,"bookmark_safe":true}`

### Requirement: Archive from the local cache

While another process holds TDLib, the tool SHALL read messages through the local reader, write day files under the same rules, download no media, count the media messages it archived in `media_pending_local_cache`, and return `source: "local-cache"` and `bookmark_safe: false` with `bookmark_unsafe_reason: "local-cache"`. Incoming senders SHALL be labelled `User <user_id>` because the local reader does not resolve names. Blocks written this way SHALL be kept unchanged by later calls under the merge rule, so they keep those labels and lack captions; the tool's description and the README SHALL say so. A message the local reader returns without a date SHALL NOT be written, because its day is unknown, and SHALL be counted in `undated_messages_skipped`; it is not lost, because such a run never advances the bookmark and a later TDLib run of the same range adds it.

#### Scenario: Another session holds TDLib

- **WHEN** `archive_chat_to_markdown` is called while process 4242 holds TDLib
- **THEN** day files are written from the local cache, the manifest has `source: "local-cache"` and `bookmark_safe: false`, and no TDLib client is created in the server process

#### Scenario: Cache record without a date

- **WHEN** the local reader returns messages 30 and 20 for chat 777 and message 20 has no date
- **THEN** only message 30 is written, the manifest has `undated_messages_skipped: 1` and `new_messages: 1`, and `bookmark_safe` is false

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

### Requirement: archive-telegram end-of-run check and report

After all calls, the skill SHALL check, for each manifest, for the files in `files` together with `newest_message_file`, that each exists and its leading frontmatter `chat_id` equals the chat's id, and that when `newest_message_id` is not null the line `<!-- msg:<newest_message_id> -->` is present in `newest_message_file` — using searches that report only which files match, never the matching text; a failed check SHALL be reported for that chat and SHALL keep its bookmark unchanged. The skill SHALL report per chat the label or `chat_id`, the new message count, the media count, the media downloaded, skipped (with sizes), failed, and no longer retried because the message no longer exists (the length of `media_gone_ids`, when the manifest has it), the number of messages skipped for lack of a date (`undated_messages_skipped`, when it is greater than zero), whether the bookmark advanced and why not, and any stop reason. The report SHALL NOT quote message text, captions or sender names.

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
