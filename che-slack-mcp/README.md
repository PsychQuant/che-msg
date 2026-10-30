# che-slack-mcp

Swift native MCP server for Slack, signed in as **you**. It uses the session your browser or the Slack desktop app already has — a `xoxc-` token plus the `d` cookie for each workspace — so it reaches every workspace you are a member of, including ones whose administrators have not approved a Slack app or Slack's own MCP server.

Through Claude you can list your conversations, read and search messages, send messages, and archive a conversation into one markdown file per day. One server process serves every imported workspace.

Credentials live only in the macOS Keychain. They are imported with the `slack-all` CLI and read by the server on each tool call; they never pass through tool arguments, the environment or the command line. Read the risks in the [plugin README](../plugins/che-slack-mcp/README.md#risks) first.

## Build

Requires macOS 13+ and a Swift 6 toolchain (Xcode 16 or its Command Line Tools).

```bash
git clone https://github.com/PsychQuant/che-msg.git
cd che-msg/che-slack-mcp
swift build -c release
```

Binaries: `.build/release/CheSlackMCP` (the MCP server) and `.build/release/slack-all` (the CLI).

## Import workspaces (`slack-all`)

Run these in a terminal; the imports wait for you to copy something and press Enter.

| Command | What it does |
|---------|--------------|
| `slack-all auth import` | Prints a line to paste into the JavaScript console of app.slack.com, which copies every workspace signed in on that browser; then asks you to copy the `d` cookie. Each workspace is checked with `auth.test` and only the ones that pass are stored. The clipboard is cleared at the end. |
| `slack-all auth import --from-desktop` | Reads the workspaces signed in to the Slack desktop app from temporary copies of its `Cookies` and `Local Storage/leveldb` (deleted before it ends), decrypting the cookie with the Keychain item "Slack Safe Storage". When macOS asks, click Allow, not Always Allow. Only workspaces signed in to the desktop app are found. |
| `slack-all auth status` | Lists the imported workspaces and whether each session is still valid. |
| `slack-all auth remove <workspace>` | Deletes a workspace's token and cookie from the Keychain and drops it from the index; takes a team id (`T0123ABCD`) or a domain (`myteam`). |

No command prints a token or cookie. Exit status: `auth import` 0 when at least one workspace was imported; `auth status` 0 when at least one is imported and every one is valid.

### Keychain layout

| Account | Service | Value |
|---------|---------|-------|
| `che-slack-mcp` | `SLACK_WORKSPACES` | The index: team id, domain, name and user id of each workspace (JSON, base64-encoded); no credential |
| `che-slack-mcp` | `SLACK_TOKEN_<TEAM_ID>` | That workspace's `xoxc-` token |
| `che-slack-mcp` | `SLACK_COOKIE_<TEAM_ID>` | That workspace's `d` cookie |

Values are written with `security -i` from stdin, so they never appear in a process's arguments, and read with `security find-generic-password` (10 s timeout, nothing cached).

`security -i` reads a command line of at most 4094 bytes, and the index is written in one, which limits how many workspaces it can list. Measured (`IndexCapacityTests`), with 11-character team and user ids unless noted:

| Entries | Workspaces that fit |
|---------|---------------------|
| Short: 9-character ids (`T0123ABCD`), 8-character domain, 10-character name | 35 |
| Typical: 15-character domain, 20-character name | 28 |
| Long: 21-character domain, 50-character name | 21 |
| 15-character domain, name of 20 Chinese or Japanese characters | 20 |

Before an import calls `auth.test` or writes anything, it checks that the index it could leave (the workspaces already imported plus every one it found in the browser or the desktop app) fits. When it would not, the import writes nothing and says how many workspaces the index would list. `slack-all auth remove` frees room.

## Installation

### Option A: the Claude Code plugin (recommended)

```bash
claude plugin marketplace add PsychQuant/che-msg
claude plugin install che-slack-mcp@che-msg
```

The plugin's wrapper downloads `CheSlackMCP` from the che-msg release v0.9.0, or uses a build at `~/Developer/che-msg/che-slack-mcp/.build/release/CheSlackMCP`. See [plugins/che-slack-mcp](../plugins/che-slack-mcp/).

### Option B: Claude Code CLI

```bash
claude mcp add che-slack-mcp -s user -- /path/to/che-slack-mcp/.build/release/CheSlackMCP
```

No `-e` is needed: the server reads the Keychain itself.

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `SLACK_MCP_MIN_INTERVAL_MS` | No | Minimum time between the starts of two requests to one workspace, 0–60000 (default `350`) |
| `SLACK_MCP_MAX_CONCURRENCY` | No | Requests in flight per workspace, 1–10 (default `3`) |

A value outside its range is ignored with one warning on stderr. The defaults come from another Slack MCP server and were not measured here; they lower the chance of Slack ending the session as automated, they cannot remove it.

## Tools (9)

Every tool except `list_workspaces` takes an optional `workspace`: a team id or domain, matched whole and ignoring case. It may be left out when exactly one workspace is imported; otherwise a call without it, or with one that matches nothing, is an error that lists the imported workspaces.

### Workspaces

| Tool | Description |
|------|-------------|
| `list_workspaces` | Imported workspaces (team id, domain, name), from the index; does not call Slack |
| `auth_status` | `auth.test` for one or every workspace, with an error class and what to do for each invalid one |

### Read

| Tool | Description |
|------|-------------|
| `list_conversations` | Public and private channels, DMs and group DMs you are a member of |
| `get_conversation_history` | Top-level messages, newest first; `limit` 1–200 (default 50), `oldest`, `latest` |
| `get_thread_replies` | The parent message, then its replies, oldest first |
| `get_user` | Display name, real name, and whether the account is a bot |
| `search_messages` | Slack search; the query is passed unchanged; `count` 1–100 (default 20) |

### Write

| Tool | Description |
|------|-------------|
| `send_message` | Posts as you; `thread_ts` replies in a thread; `text` 1–40000 characters; returns the new message's `ts` |

### Archive

| Tool | Description |
|------|-------------|
| `archive_conversation_to_markdown` | Writes `<output_dir>/<team_id>/<conversation_id>/<YYYY-MM-DD>.md`, one file per local day |

## Errors

Every failure is a tool result with `isError: true`, in one of five classes:

| Class | When | What the message says |
|-------|------|-----------------------|
| Session invalid | `invalid_auth`, `not_authed`, `token_revoked`, `account_inactive` | Which workspace, and to import it again with `slack-all auth import` or `slack-all auth import --from-desktop` |
| Rate limited | HTTP 429 or `ratelimited`, after 3 retries | When to try again |
| Enterprise Grid | An `enterprise_…` error or `team_is_restricted` | That Enterprise Grid may end automated sessions; use Slack's official MCP server for that workspace |
| Other Slack error | Any other `ok: false` | Slack's error string |
| Network | The request did not complete | The network error |

## Archive format

Each day file starts with YAML frontmatter (`team_id`, `conversation_id`, `date`, `utc_offset`) and holds one block per message: `<!-- msg:<ts> -->`, a header `**HH:mm sender**：` (a thread reply adds `↳ thread:<parent_ts>`), then the text with Slack markup turned into markdown (`<@U123>` → `@name`, `<#C123|general>` → `#general`, `<https://x|label>` → `[label](https://x)`). The sender is `我` for your own messages, else the user's display name, `Bot <bot_id>` or `User <user_id>`. Attachments are written as `[file: <name>](<permalink>)`; nothing is downloaded. Directories are 0700, files 0600.

A `manifest.json` per conversation records the newest message archived and the latest reply of recent thread parents — never message text, names or file names. Without `after_ts` or `since_date`, a run writes only what is newer than the manifest and re-fetches replies for thread parents of the last `thread_lookback_days` days (default 30, 0–365). A message archived again replaces its own block. A run cut short by rate limiting, or by the per-call page limit before it has written every new message, returns `complete: false` without an error: the files written stay, the bookmark does not move, and the manifest records where the unfinished range continues, so calling again until `complete` is true picks up from there. Listing the lookback window counts in the same page limit but does not make `complete` false: every result has `lookback_complete`, false when the call did not list the whole window, and a complete call then adds a `note` that the thread parents in the rest of the window were not checked for new replies; a smaller `thread_lookback_days` lists fewer messages. An `after_ts` or `since_date` range continues the same way when called again with the same argument, and moves the bookmark only when it starts at or before it. A thread longer than one call's reply limit is continued on later runs too, even when its parent is older than the lookback window.

## Architecture

| Target | Role | Depends on |
|--------|------|------------|
| `SlackWebLib` | Slack Web API client, errors, pacing, Keychain read and write | Foundation only |
| `CheSlackMCPCore` | MCP tools, workspace selection, archive | SlackWebLib + MCP SDK |
| `SlackAllCore` | Clipboard and desktop imports, status, remove | SlackWebLib |
| `CheSlackMCP` | MCP server entry point | CheSlackMCPCore |
| `slack-all` | CLI | SlackAllCore + ArgumentParser |

## Testing

```bash
swift test
```

The tests run offline: Slack is a fake transport, the Keychain a scratch keychain file, and the desktop import reads synthetic fixtures encrypted with a test key.

## License

MIT
