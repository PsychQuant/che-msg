## Purpose

The `archive_conversation_to_markdown` tool, which writes a Slack conversation into one markdown file per local day in the same layout as the `telegram-chat-archive` capability. It exists so that Slack and Telegram archives can be read and processed the same way, while covering what is specific to Slack: message timestamps as identifiers, thread replies and file attachments.

## ADDED Requirements

### Requirement: Slack archive tool parameters

The server SHALL expose an MCP tool `archive_conversation_to_markdown` with the workspace selection of the `slack-mcp-tools` capability, a required string `conversation_id`, a required string `output_dir`, an optional string `after_ts`, an optional string `since_date` in the form `YYYY-MM-DD`, an optional string `utc_offset` in the form `+HH:MM` or `-HH:MM` and at most 18:00 either way, and an optional integer `thread_lookback_days` from 0 to 365 with default 30. `output_dir` SHALL be an absolute path. When both `after_ts` and `since_date` are given, `after_ts` SHALL take precedence. When `utc_offset` is absent, the server's local offset at the time of the call SHALL be used. An invalid argument SHALL produce `isError: true` with a message naming the argument and SHALL NOT write any file.

#### Scenario: Relative output directory is refused

- **WHEN** the tool is called with `output_dir` `archives/slack`
- **THEN** the result has `isError: true`, the message names `output_dir`, and no file is written

### Requirement: Slack day file format

The tool SHALL write each archived message into `<output_dir>/<team_id>/<conversation_id>/<YYYY-MM-DD>.md`, where the date is the message's local date at the effective `utc_offset`. Each file SHALL begin with a YAML frontmatter block holding `team_id`, `conversation_id`, `date` and `utc_offset`. Each message SHALL be written as a line `<!-- msg:<ts> -->`, then a header line, then the converted body and a blank line. The header SHALL be `**<HH:mm> <sender>**：` for a top-level message and `**<HH:mm> <sender>** ↳ thread:<parent_ts>：` for a thread reply. The sender SHALL be `我` for the user's own messages, the display name when one is known, `Bot <bot_id>` for a bot message, and `User <user_id>` otherwise. A body line that begins with `<!--`, or that begins with `**` followed by a time, SHALL be written with a leading backslash, and a line break in a sender name SHALL be written as a space. Directories the tool creates SHALL have mode 0700 and day files mode 0600.

#### Scenario: Reply lands in its own day

- **WHEN** a parent message `1793451600.000100` was posted on 2026-10-31 and its reply `1793494800.000200` on 2026-11-01, both at +08:00
- **THEN** the reply is written in `2026-11-01.md` under the header `↳ thread:1793451600.000100`, and `2026-10-31.md` holds the parent unchanged

##### Example: day file

- **GIVEN** workspace `T01`, conversation `C01`, `utc_offset` `+08:00`, a message `1793498700.000100` from `Alex` with text `hello` at 10:05 on 2026-11-01, and the user's own reply `1793498820.000200` in that thread at 10:07
- **WHEN** the tool archives them
- **THEN** `T01/C01/2026-11-01.md` contains, after the frontmatter, `<!-- msg:1793498700.000100 -->`, `**10:05 Alex**：`, `hello`, a blank line, `<!-- msg:1793498820.000200 -->`, `**10:07 我** ↳ thread:1793498700.000100：` and the reply text

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

### Requirement: Incremental archive and manifest

The tool SHALL keep `<output_dir>/<team_id>/<conversation_id>/manifest.json` holding the newest archived top-level `ts`, the newest archived reply `ts` per thread parent within the lookback window, the time of the last run, and message counts, and no message text, sender name or file name. Without `after_ts` and `since_date`, a run SHALL fetch only top-level messages newer than the manifest's newest top-level `ts`. Re-archiving a message that is already in a day file SHALL replace its block in place, so that running the tool twice with no new messages leaves every day file byte-identical.

#### Scenario: Second run with no new messages

- **WHEN** the tool archives `C01` and then runs again with no new messages or replies
- **THEN** every day file is byte-identical after the second run and the manifest records the second run's time

### Requirement: Thread replies and lookback

For each thread parent fetched in the run, and for each thread parent whose `ts` is within the last `thread_lookback_days` days and whose `latest_reply` is newer than the reply `ts` recorded in the manifest, the tool SHALL fetch the replies with `conversations.replies` and archive the ones not yet written. Replies to thread parents older than the lookback window SHALL NOT be fetched.

#### Scenario: Late reply outside the window is not fetched

- **WHEN** `thread_lookback_days` is 30 and a thread whose parent is 45 days old receives a new reply
- **THEN** the run does not call `conversations.replies` for that parent and the reply is not archived

### Requirement: Archive concurrency and partial progress

Two calls archiving the same `conversation_id` of the same workspace into the same `output_dir` SHALL NOT run at the same time: the second SHALL fail with `isError: true` saying another archive of that conversation is running, and SHALL NOT write any file. When the client gives up on a `rateLimited` error during a run, the tool SHALL keep every day file written so far, set the manifest's newest top-level `ts` to the newest message whose block was fully written, and return a result that is not an error and reports that the run stopped early, how many messages were written, and that calling the tool again resumes from there.

#### Scenario: Rate limit stops a run midway

- **WHEN** a run has written messages up to `1793498700.000100` and the client then throws `rateLimited`
- **THEN** the written day files remain, the manifest's newest top-level `ts` is `1793498700.000100`, and the result says the run stopped early and can be resumed
