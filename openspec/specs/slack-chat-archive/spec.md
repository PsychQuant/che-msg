# slack-chat-archive Specification

## Purpose

The `archive_conversation_to_markdown` tool, which writes a Slack conversation into one markdown file per local day in the same layout as the `telegram-chat-archive` capability. It exists so that Slack and Telegram archives can be read and processed the same way, while covering what is specific to Slack: message timestamps as identifiers, thread replies and file attachments.

## Requirements

### Requirement: Slack archive tool parameters

The server SHALL expose an MCP tool `archive_conversation_to_markdown` with the workspace selection of the `slack-mcp-tools` capability, a required string `conversation_id`, a required string `output_dir`, an optional string `after_ts`, an optional string `since_date` in the form `YYYY-MM-DD`, an optional string `utc_offset` in the form `+HH:MM` or `-HH:MM` and at most 18:00 either way, and an optional integer `thread_lookback_days` from 0 to 365 with default 30. `output_dir` SHALL be an absolute path. When both `after_ts` and `since_date` are given, `after_ts` SHALL take precedence. When `utc_offset` is absent, the server's local offset at the time of the call SHALL be used. An invalid argument SHALL produce `isError: true` with a message naming the argument and SHALL NOT write any file.

#### Scenario: Relative output directory is refused

- **WHEN** the tool is called with `output_dir` `archives/slack`
- **THEN** the result has `isError: true`, the message names `output_dir`, and no file is written


<!-- @trace
source: add-che-slack-mcp
updated: 2026-10-31
code:
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-archive/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-review/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-propose/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-analyze/SKILL.md
  - .agents/skills/spectra-verify/SKILL.md
-->

---
### Requirement: Slack day file format

The tool SHALL write each archived message into `<output_dir>/<team_id>/<conversation_id>/<YYYY-MM-DD>.md`, where the date is the message's local date at the effective `utc_offset`. Each file SHALL begin with a YAML frontmatter block holding `team_id`, `conversation_id`, `date` and `utc_offset`. Each message SHALL be written as a line `<!-- msg:<ts> -->`, then a header line, then the converted body and a blank line. The header SHALL be `**<HH:mm> <sender>**：` for a top-level message and `**<HH:mm> <sender>** ↳ thread:<parent_ts>：` for a thread reply. The sender SHALL be `我` for the user's own messages, the display name when one is known, `Bot <bot_id>` for a bot message, and `User <user_id>` otherwise. A body line that begins with `<!--`, or that begins with `**` followed by a time, SHALL be written with a leading backslash, and a line break in a sender name SHALL be written as a space. Directories the tool creates SHALL have mode 0700 and day files mode 0600.

#### Scenario: Reply lands in its own day

- **WHEN** a parent message `1793451600.000100` was posted on 2026-10-31 and its reply `1793494800.000200` on 2026-11-01, both at +08:00
- **THEN** the reply is written in `2026-11-01.md` under the header `↳ thread:1793451600.000100`, and `2026-10-31.md` holds the parent unchanged

##### Example: day file

- **GIVEN** workspace `T01`, conversation `C01`, `utc_offset` `+08:00`, a message `1793498700.000100` from `Alex` with text `hello` at 10:05 on 2026-11-01, and the user's own reply `1793498820.000200` in that thread at 10:07
- **WHEN** the tool archives them
- **THEN** `T01/C01/2026-11-01.md` contains, after the frontmatter, `<!-- msg:1793498700.000100 -->`, `**10:05 Alex**：`, `hello`, a blank line, `<!-- msg:1793498820.000200 -->`, `**10:07 我** ↳ thread:1793498700.000100：` and the reply text


<!-- @trace
source: add-che-slack-mcp
updated: 2026-10-31
code:
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-archive/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-review/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-propose/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-analyze/SKILL.md
  - .agents/skills/spectra-verify/SKILL.md
-->

---
### Requirement: Slack markup conversion

The body SHALL be the message text with Slack markup converted to markdown: a user mention `<@U123>` becomes `@` followed by that user's display name, or `@U123` when unknown; a channel mention `<#C123|general>` becomes `#general`; a link `<https://x.example|label>` becomes `[label](https://x.example)`; a bare link `<https://x.example>` becomes `https://x.example`; and the entities `&amp;`, `&lt;` and `&gt;` become `&`, `<` and `>`. Each file attached to a message SHALL be appended on its own line as `[file: <name>](<permalink>)`. The tool SHALL NOT download files.

#### Scenario: Mixed markup

- **WHEN** a message's text is `<@U9> see <#C7|general> and <https://x.example|the doc> &amp; more` and `U9` resolves to `Kim`
- **THEN** the body is `@Kim see #general and [the doc](https://x.example) & more`

##### Example: conversion cases

| Slack text | Markdown body |
| --- | --- |
| `<@U9>` with `U9` unknown | `@U9` |
| `<#C7\|general>` | `#general` |
| `<https://x.example>` | `https://x.example` |
| `a &lt; b` | `a < b` |
| message with file `plan.pdf`, permalink `https://t.slack.com/files/U9/F1/plan.pdf` and no text | `[file: plan.pdf](https://t.slack.com/files/U9/F1/plan.pdf)` |


<!-- @trace
source: add-che-slack-mcp
updated: 2026-10-31
code:
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-archive/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-review/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-propose/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-analyze/SKILL.md
  - .agents/skills/spectra-verify/SKILL.md
-->

---
### Requirement: Incremental archive and manifest

The tool SHALL keep `<output_dir>/<team_id>/<conversation_id>/manifest.json` holding the newest archived top-level `ts`, the newest archived reply `ts` per thread parent within the lookback window, the time of the last run, and message counts, and no message text, sender name or file name. Without `after_ts` and `since_date`, a run SHALL write only top-level messages newer than the manifest's newest top-level `ts`. When `thread_lookback_days` is greater than 0, the run SHALL also list the top-level messages inside the lookback window, only to read their `latest_reply` for the "Thread replies and lookback" requirement, and SHALL NOT write those listed messages again. Listing the lookback window SHALL NOT by itself make `complete` false: a run whose walk has reached its lower bound and that stops at the per-call page limit while still listing the window SHALL report `complete` as if the listing had finished. Every result SHALL report `lookback_complete`: true when the walk listed everything down to the start of the lookback window, or down to its lower bound when the window starts later or is 0 days, and false otherwise. When `lookback_complete` is false and `complete` is true, the result SHALL say that the thread parents in the rest of the window were not checked for new replies and that a smaller `thread_lookback_days` lists fewer messages. A message whose `<!-- msg:<ts> -->` block is already in its day file SHALL be left unchanged when it is archived again, as telegram-chat-archive does: the day file keeps what was archived first, so an edited message keeps its archived text and a renamed sender keeps the archived name, and running the tool twice leaves every day file byte-identical. A message not yet in its day file SHALL be inserted in `ts` order. Slack's `has_more: true` without a next cursor SHALL be treated as a walk that stopped before its lower bound, for the history and for a thread's replies, so that the newest top-level `ts` and a reply bookmark never move past messages not read. When the history walk has already listed a message below its lower bound, so that only the lookback window is left, the walk SHALL end as it does at the per-call page limit inside the window: `complete` keeps its value and `lookback_complete` is false. When a run stops before its walk reaches its lower bound, because of the per-call page limit or a rate limit, the manifest SHALL record where that walk continues: the newest top-level `ts` the walk started from and the oldest top-level `ts` it wrote. The next run SHALL first continue that walk below the recorded oldest `ts`, passing it to Slack as `latest`, down to the lower bound, and only when the walk reaches the lower bound SHALL the manifest's newest top-level `ts` advance, to the newest `ts` of that walk. A run SHALL NOT advance the newest top-level `ts` past messages it has not read. When `after_ts` or `since_date` is given, the run SHALL advance the newest top-level `ts` only when that lower bound is at or before the existing newest top-level `ts`, or when there is none, and only once its walk reaches that lower bound; a range that starts after the bookmark SHALL leave the bookmark unchanged. An explicit range whose walk stops before its lower bound SHALL be recorded together with that lower bound, and a later call with the same `after_ts` or `since_date` SHALL continue below where it stopped. The call whose walk reaches that lower bound SHALL report `complete: false` and keep the record with the newest top-level `ts` the range has written; the next call with the same lower bound SHALL write only messages newer than that `ts`, and once it reaches it SHALL drop the record and report `complete: true`. A call with another lower bound SHALL neither continue nor drop the record, and SHALL replace it only when its own walk stops before its lower bound.

#### Scenario: Second run with no new messages

- **WHEN** the tool archives `C01` and then runs again with no new messages or replies
- **THEN** every day file is byte-identical after the second run and the manifest records the second run's time

#### Scenario: Edited message keeps its archived text

- **WHEN** a message's block was archived with the text `before`, Slack now returns that message edited to `after`, and a call archives it again
- **THEN** the block still holds `before` and the day file is byte-identical to what it was

#### Scenario: has_more without a cursor does not move the bookmark

- **WHEN** a history page answers `has_more: true` with no `next_cursor`
- **THEN** the run reports `complete: false`, records where the walk continues, and leaves the manifest's newest top-level `ts` unchanged

#### Scenario: Busy lookback window does not keep complete false

- **WHEN** the manifest has a newest top-level `ts`, 10 top-level messages are newer than it, 12000 older top-level messages fall inside the 30-day lookback window, and no thread is recorded as cut
- **THEN** the call writes the 10 messages, stops listing the window at the page limit, moves the manifest's newest top-level `ts` to the newest of the 10, records no continuation, and reports `complete: true` and `lookback_complete: false` with a note about `thread_lookback_days`

#### Scenario: Explicit range newer than the bookmark keeps the bookmark

- **WHEN** the manifest's newest top-level `ts` is `1789995600.000100` (2026-09-21 21:00 at +08:00) and a call gives `since_date` `2026-10-25` with `utc_offset` `+08:00`
- **THEN** messages from 2026-10-25 on are written and the manifest's newest top-level `ts` is still `1789995600.000100`

#### Scenario: Explicit range continues on the next call

- **WHEN** a call with `since_date` `2026-01-01` on a conversation with 15000 top-level messages since then stops at the 50-page limit after writing the newest 10000
- **THEN** a second call with the same `since_date` requests only history older than the oldest message written, writes the remaining 5000 and reports `complete: false`, and a third call with the same `since_date` requests only history newer than the newest message the first call wrote and reports `complete: true`

#### Scenario: Unfinished walk continues on the next call

- **WHEN** a first archive of a conversation with 12000 top-level messages stops at the 50-page limit after writing the newest 10000
- **THEN** the manifest records the oldest written `ts` as the point to continue from and leaves the newest top-level `ts` unset, and the next call requests only history older than that `ts`, writes the remaining 2000, and then sets the newest top-level `ts` to the newest of the 12000


<!-- @trace
source: add-che-slack-mcp
updated: 2026-10-31
code:
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-archive/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-review/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-propose/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-analyze/SKILL.md
  - .agents/skills/spectra-verify/SKILL.md
-->

---
### Requirement: Thread replies and lookback

For each thread parent fetched in the run, and for each thread parent whose `ts` is within the last `thread_lookback_days` days and whose `latest_reply` is newer than the reply `ts` recorded in the manifest, the tool SHALL fetch the replies with `conversations.replies` and archive the ones not yet written. When the manifest records a reply `ts` for that parent, the replies SHALL be requested starting after it, passing it to Slack as `oldest`, so that a thread longer than one call's reply page limit is archived over successive calls. A thread whose replies were cut short by that limit SHALL keep its reply bookmark in the manifest whatever its parent's age, and later runs SHALL continue it until all its replies are written, also when the parent is older than the lookback window or `thread_lookback_days` is 0; while such a thread remains, a run SHALL report `complete: false`. This holds also when a rate limit then stops the run: a thread cut short in that run whose replies were written before the stop SHALL be recorded with the newest reply written, although the run moves no other reply bookmark. A thread whose parent Slack answers `thread_not_found` for when it is continued SHALL leave the manifest's record of cut threads, and the call SHALL NOT be an error. Otherwise, replies to thread parents older than the lookback window SHALL NOT be fetched. A thread parent listed only for the lookback window SHALL have its replies fetched only when its block is already in its day file or the thread is recorded as cut; a parent that was never archived, for example because an earlier call started at `since_date` or `after_ts` after it, SHALL NOT have its replies fetched. A reply that was also sent to the conversation appears in the history among its top-level messages and SHALL be archived with them, as a reply block, whether or not its parent is archived.

#### Scenario: Late reply outside the window is not fetched

- **WHEN** `thread_lookback_days` is 30 and a thread whose parent is 45 days old receives a new reply
- **THEN** the run does not call `conversations.replies` for that parent and the reply is not archived

#### Scenario: Long thread outside the window continues

- **WHEN** on a first archive with `thread_lookback_days` 30 a parent posted 60 days ago has 1300 replies
- **THEN** the first call archives 1000 of them and reports `complete: false`, and the next call archives the remaining 300 although the parent is outside the window

#### Scenario: Thread cut before a rate limit continues

- **WHEN** on a first archive with `thread_lookback_days` 30 a parent posted 60 days ago has 1300 replies, its first 1000 are written, and a rate limit then stops the run on a later history page
- **THEN** the manifest records that thread as cut with its 1000th reply, and the calls that follow archive the remaining 300 although the parent is outside the window and below the point the walk continues from

#### Scenario: Lookback skips a parent that was never archived

- **WHEN** a first call archived with `since_date` `2026-10-25` and the next call without `since_date` lists, inside its lookback window, a thread parent posted on 2026-10-20 that has replies
- **THEN** no reply of that parent is fetched or written

#### Scenario: Cut thread whose parent is gone is dropped

- **WHEN** a thread recorded as cut is continued and Slack answers `thread_not_found` for its parent
- **THEN** the call is not an error, the thread is no longer recorded as cut, and later calls do not ask for it

#### Scenario: Long thread continues on the next call

- **WHEN** a thread inside the lookback window has 1300 replies and one call reads at most 1000 replies of a thread
- **THEN** the first call archives replies up to the 1000th and records its `ts`, and the next call requests only replies after that `ts` and archives the remaining 300


<!-- @trace
source: add-che-slack-mcp
updated: 2026-10-31
code:
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-archive/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-review/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-propose/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-analyze/SKILL.md
  - .agents/skills/spectra-verify/SKILL.md
-->

---
### Requirement: Archive concurrency and partial progress

Two calls archiving the same `conversation_id` of the same workspace into the same `output_dir` SHALL NOT run at the same time: the second SHALL fail with `isError: true` saying another archive of that conversation is running, and SHALL NOT write any file. When the client gives up on a `rateLimited` error during a run, the tool SHALL keep every day file written so far, SHALL leave the manifest's newest top-level `ts` unchanged, because Slack lists messages newest first and the unread range below the written ones would otherwise be skipped for good, SHALL record the oldest top-level `ts` written as the point the next run continues below (requirement "Incremental archive and manifest"), and SHALL return a result that is not an error and reports that the run stopped early, how many messages were written, and that calling the tool again continues from there.

#### Scenario: Rate limit stops a run midway

- **WHEN** the manifest's newest top-level `ts` is `1793451600.000100`, a run has written messages down from `1793498700.000100`, and the client then throws `rateLimited` before the walk reaches `1793451600.000100`
- **THEN** the written day files remain, the manifest's newest top-level `ts` is still `1793451600.000100`, the manifest records `1793498700.000100` as the point the next run continues below, and the result says the run stopped early and can be resumed

<!-- @trace
source: add-che-slack-mcp
updated: 2026-10-31
code:
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-archive/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-review/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-propose/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-analyze/SKILL.md
  - .agents/skills/spectra-verify/SKILL.md
-->