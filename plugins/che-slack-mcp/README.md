# che-slack-mcp Plugin

Claude Code plugin for Slack. Claude reads, searches, sends and archives messages **as you**, in every Slack workspace you import — including workspaces someone else administers, where installing a Slack app or Slack's own MCP server needs an administrator's approval.

It works with the same session your browser or the Slack desktop app uses: a `xoxc-` token plus the `d` cookie for each workspace. You import them once with the `slack-all` command-line tool; they are stored in the macOS Keychain and nowhere else (see [Risks](#risks) for who can read them there). The plugin's wrapper reads no credential and exports none — the server reads the Keychain itself on each tool call.

Read [Risks](#risks) before you import a workspace.

---

## Quick start

```bash
# 1. Add the marketplace and install the plugin
/plugin marketplace add PsychQuant/che-msg
/plugin install che-slack-mcp@che-msg
```

2. Get `slack-all` (see [Get slack-all](#get-slack-all)) and import your workspaces in a terminal — not through Claude, because the import waits for you to copy and press Enter:

```bash
slack-all auth import                  # from a browser signed in to app.slack.com
slack-all auth import --from-desktop   # or from the Slack desktop app
```

3. Restart Claude Code (or reconnect with `/mcp`), then ask, for example, "list my Slack workspaces".

The server binary `CheSlackMCP` 0.9.0 ships with the che-msg release v0.9.0; the wrapper downloads it on first use (see [How the wrapper works](#how-the-wrapper-works)).

## Get slack-all

`slack-all` is built from source; the plugin does not download it, and for now no release carries it ([#112](https://github.com/PsychQuant/che-msg/issues/112)). You need macOS 13 or later and a Swift 6 toolchain (Xcode 16, or its Command Line Tools).

```bash
git clone https://github.com/PsychQuant/che-msg.git ~/Developer/che-msg
cd ~/Developer/che-msg/che-slack-mcp
swift build -c release
.build/release/slack-all --help
```

The same build produces `.build/release/CheSlackMCP`. Built at this path, the wrapper uses it instead of downloading one. Run `.build/release/slack-all` from there, or copy it to a directory on your `PATH`.

## Import your workspaces

Each workspace is checked with Slack's `auth.test` before it is stored; only the ones that pass are kept. Neither import prints a token or cookie.

### From the browser (`slack-all auth import`)

1. Run `slack-all auth import`. It prints one line of JavaScript.
2. Open https://app.slack.com in the browser where you are signed in, open its JavaScript console (Safari: turn on *Show features for web developers* in Settings → Advanced, then Develop → Show JavaScript Console), paste the line and press Return. It copies the list of workspaces signed in on that browser to the clipboard. Press Enter in the terminal.
3. Copy the value of the cookie named `d`: Safari's Storage tab, or Chrome's Application tab, under Cookies for app.slack.com. The console cannot read it (it is `HttpOnly`). Press Enter in the terminal.

The clipboard is cleared at the end. The command exits 0 when at least one workspace was imported.

### From the Slack desktop app (`slack-all auth import --from-desktop`)

`slack-all auth import --from-desktop` reads the workspaces the Slack desktop app (Mac App Store or slack.com download) is signed in to, from temporary copies of its `Cookies` and `Local Storage/leveldb`, which it deletes before it ends.

- **Only workspaces signed in to the desktop app are found.** Sign in to the others in the desktop app first, or import them from the browser.
- macOS asks once whether `security` may use the Keychain item "Slack Safe Storage", the key Slack encrypts its cookie with. Click **Allow**, not **Always Allow**: Always Allow would let any program read Slack's cookie key through `security` from then on. (The plugin's own items are different: see [Risks](#risks).)

### Check and remove

```bash
slack-all auth status              # every imported workspace and whether its session is still valid
slack-all auth remove T0123ABCD    # by team id, or by domain: slack-all auth remove myteam
```

`slack-all auth remove` deletes that workspace's token and cookie from the Keychain and drops it from the index.

The index has room for about 28 workspaces with typical names (a 20-character name and a 15-character domain), 21 with long ones (50 and 21 characters), and 20 when names are 20 Chinese or Japanese characters: it is written as one `security -i` command, which takes at most 4094 bytes. An import that could go past that stops before it calls `auth.test` or writes anything, and says how many workspaces the index would list. Remove workspaces you no longer use with `slack-all auth remove` (or sign out of some in the browser or the desktop app, so the import finds fewer), then import again.

The Keychain items all have the account `che-slack-mcp`: `SLACK_WORKSPACES` (the index: team id, domain, name and user id, no credential), and `SLACK_TOKEN_<TEAM_ID>` and `SLACK_COOKIE_<TEAM_ID>` for each workspace.

When a session stops working (you signed out, or Slack ended it), the tools say so and name the workspace; import it again.

## Tools

One server, `slack`, serves every imported workspace. Every tool except `list_workspaces` takes an optional `workspace`: a team id (`T0123ABCD`) or a domain (`myteam` for myteam.slack.com), matched whole and ignoring case. With one workspace imported you can leave it out; with several, a call without it is refused and the answer lists them.

| Tool | What it does |
|------|--------------|
| `list_workspaces` | The imported workspaces (team id, domain, name), from the Keychain index; does not call Slack |
| `auth_status` | Checks each session (or one) with `auth.test` and says what to do about an invalid one |
| `list_conversations` | Channels, private channels, direct messages and group DMs you are a member of |
| `get_conversation_history` | A conversation's top-level messages, newest first (`limit` 1–200, `oldest`, `latest`) |
| `get_thread_replies` | A thread: the parent, then its replies |
| `get_user` | A user's display name, real name and whether it is a bot |
| `search_messages` | Slack's search; the query is passed unchanged, so `in:#general`, `from:@name`, `before:2026-01-01` work |
| `send_message` | Posts a message **as you**, optionally as a reply in a thread (`thread_ts`); its members see it at once |
| `archive_conversation_to_markdown` | Writes a conversation into one markdown file per day under an absolute `output_dir` (see [Archiving](#archiving)) |

Errors come back as tool results that say which workspace and what happened: the session is no longer valid (import again), Slack keeps rate limiting, the workspace is restricted by Enterprise Grid, another Slack error, or a network error.

## Permissions

The plugin pre-approves nothing: it ships no skill with `allowed-tools`, so every call goes through your [permission settings](https://code.claude.com/docs/en/permissions). The table says which tools you can pre-approve yourself.

| Tool | Pre-approve | Why |
|------|-------------|-----|
| `list_workspaces` | Yes | Reads the Keychain index only |
| `auth_status` | Yes | Calls `auth.test`; changes nothing |
| `list_conversations` | Yes | Reads |
| `get_conversation_history` | Yes | Reads |
| `get_thread_replies` | Yes | Reads |
| `get_user` | Yes | Reads |
| `search_messages` | Yes | Reads |
| `send_message` | **No** | Posts as you; everyone in the conversation sees it at once, and this plugin has no tool to delete it |
| `archive_conversation_to_markdown` | **No** | Writes other people's messages to files under any absolute path you or Claude give it |

To stop being asked for the reads, add them to `permissions.allow` in `~/.claude/settings.json` (or a project's `.claude/settings.json`):

```json
{
  "permissions": {
    "allow": [
      "mcp__plugin_che-slack-mcp_slack__list_workspaces",
      "mcp__plugin_che-slack-mcp_slack__auth_status",
      "mcp__plugin_che-slack-mcp_slack__list_conversations",
      "mcp__plugin_che-slack-mcp_slack__get_conversation_history",
      "mcp__plugin_che-slack-mcp_slack__get_thread_replies",
      "mcp__plugin_che-slack-mcp_slack__get_user",
      "mcp__plugin_che-slack-mcp_slack__search_messages"
    ]
  }
}
```

To be asked before every message Claude sends and every archive it writes, **whatever mode you are in**, add ask rules:

```json
{
  "permissions": {
    "ask": [
      "mcp__plugin_che-slack-mcp_slack__send_message",
      "mcp__plugin_che-slack-mcp_slack__archive_conversation_to_markdown"
    ]
  }
}
```

Claude Code never auto-approves a tool matched by an explicit ask rule, not even in auto or `bypassPermissions` mode; in `dontAsk` mode it refuses the call instead of asking. Hooks can still approve such a call without asking you — a `PermissionRequest` hook in your settings, a plugin or a skill, or an installed mod (see the permissions and permission-modes docs). A whole-server rule, `mcp__plugin_che-slack-mcp_slack`, asks for every call to this server, reads included.

Without an ask rule, what happens to `send_message` and `archive_conversation_to_markdown` depends on the [permission mode](https://code.claude.com/docs/en/permission-modes) and your allow rules:

- **Manual** (config value `default`) and `acceptEdits`: Claude Code asks, unless an allow rule matches the tool.
- **auto**: a classifier reviews the call instead of you, and there is normally no prompt; an allow rule that matches skips the classifier too. Auto is the mode interactive terminal and VS Code sessions start in unless you configure another (Claude Code v2.1.283 or later on every plan; earlier, on Pro, Max and Team plans).
- `bypassPermissions`: no prompt.
- `dontAsk`: refused unless an allow rule matches it; with one, it runs without a prompt.
- Other modes (`plan`, and any added later): see the permission-modes page.

So in auto mode a message can be sent without a prompt: add the ask rule above if you want to see every message before it goes out.

## Archiving

`archive_conversation_to_markdown` writes `<output_dir>/<team_id>/<conversation_id>/<YYYY-MM-DD>.md`, one file per local day, in the same layout as che-telegram-mcp's archives: YAML frontmatter, then one block per message anchored by `<!-- msg:<ts> -->`. Thread replies go in the file of their own day, marked `↳ thread:<parent_ts>`. Directories are owner-only (0700), files 0600.

- **Re-runs add only what is new.** A `manifest.json` next to the day files records the newest message archived (no message text, names or file names); the next run starts after it. A message already in a day file is left as it was archived first, as in the Telegram archive: an edited message keeps its archived text, and a re-run with nothing new leaves the files unchanged. The same holds for a sender's name: a message archived while the name could not be looked up keeps `User <user_id>`; move the conversation's day files aside to archive it again.
- **Thread replies** are fetched again for threads started in the last `thread_lookback_days` days (default 30). A late reply in an older thread is not picked up; run once with a larger `thread_lookback_days` to catch up. In a busy channel the window can be longer than one call's page limit: the result then has `lookback_complete: false` and a note saying the rest of the window was not checked, while `complete` stays true once every new message is written. A smaller `thread_lookback_days` lists fewer messages.
- **Files are not downloaded.** An attachment is written as `[file: <name>](<permalink>)`.
- **Rate limits, and the page limit before every new message is written,** stop a run early without an error (`complete: false`): what was written stays, the bookmark does not move, and the manifest records where the unfinished range continues, so the next run picks up from there and only moves the bookmark once that range is complete. An `after_ts` or `since_date` range continues the same way when you call again with the same argument; a range that starts after the bookmark never moves it. Threads longer than one call's reply limit are likewise continued after the last reply archived, even when they started before the `thread_lookback_days` window.
- Only one archive of a conversation into one `output_dir` runs at a time.

> **Privacy.** An archive holds other people's messages, verbatim. Keep `output_dir` out of every repository you push anywhere.

## Risks

- **The session token is your signed-in session.** Anyone who has the token and the `d` cookie can act as you in that workspace. They stay in the Keychain and never appear in tool arguments, tool results, the environment, the command line or any output. They are not hidden from programs running as you: `slack-all` writes them with `security`, so `security` itself can read them back without a prompt — and so can any program you run that calls it, including a command Claude runs for you in a terminal. Telegram's items in che-telegram-mcp work the same way. Remove a workspace you no longer use with `slack-all auth remove`.
- **Enterprise Grid.** Organisations on Slack Enterprise Grid may detect automated use of a session, end it, and notify their administrators. When Slack answers with an Enterprise Grid restriction the tools say so; use Slack's official MCP server for such a workspace instead.
- **Rate and pacing.** Requests to one workspace start at least 350 ms apart, at most 3 at a time; when Slack rate limits, the server waits as Slack asks and retries up to 3 times. These defaults were not measured in this project. They lower the chance of tripping Slack's anomaly detection, they cannot remove it. If a session gets signed out, slow down first by setting `SLACK_MCP_MIN_INTERVAL_MS` (0–60000) and `SLACK_MCP_MAX_CONCURRENCY` (1–10) for the server, for example in `~/.claude/settings.json`: `{ "env": { "SLACK_MCP_MIN_INTERVAL_MS": "1000", "SLACK_MCP_MAX_CONCURRENCY": "1" } }`. A value outside its range is ignored with a warning.
- **Slack's API Terms.** Archiving touches Slack's API Terms of Service, which speak of archiving Slack data; whether they cover a personal archive of conversations you take part in is not clear. Whether to use `archive_conversation_to_markdown` is your decision. This version never downloads files, which keeps an archive further from a bulk export.

## How the wrapper works

`bin/che-slack-mcp-wrapper.sh` looks for `CheSlackMCP` in this order:

1. `~/bin/CheSlackMCP`
2. `/usr/local/bin/CheSlackMCP`
3. `~/.local/bin/CheSlackMCP`
4. A source build at `~/Developer/che-msg/che-slack-mcp/.build/release/CheSlackMCP`

If none is there, it downloads the asset `CheSlackMCP` of the pinned release (`DESIRED_VERSION`, now v0.9.0) into `~/bin`, removes the quarantine flag and records the version in `~/bin/.CheSlackMCP.version`. When the plugin later pins another version, the copy in `~/bin` is downloaded again; if that fails, the existing binary is kept. The wrapper asks only for the pinned release, never for the latest one, and never replaces a binary outside `~/bin`.

It then starts the binary with nothing added to its environment. It does not read the Keychain and does not check whether any workspace is imported: with none imported, the server still starts and its tools tell you to run `slack-all auth import`.

### When slack does not start

The wrapper stops before starting the server only when there is no binary at all and it could not install one: the download of v0.9.0 failed (no network, or the release does not exist yet), the downloaded file could not be moved into `~/bin`, or another start held the install lock for more than 60 seconds. `/mcp` then shows that reason. When a binary is already there, any of these only prints a warning and the existing binary starts. Install the binary by hand, or build it as in [Get slack-all](#get-slack-all), then reconnect with `/mcp`.

### Manual install

```bash
mkdir -p ~/bin
curl -fL https://github.com/PsychQuant/che-msg/releases/download/v0.9.0/CheSlackMCP -o ~/bin/CheSlackMCP
chmod +x ~/bin/CheSlackMCP
xattr -dr com.apple.quarantine ~/bin/CheSlackMCP
echo 0.9.0 > ~/bin/.CheSlackMCP.version
```

The last line records the installed version; without it the wrapper downloads the binary again on the next start.

## Version

Plugin version 0.1.0. Pins `CheSlackMCP` 0.9.0, which ships with the che-msg release v0.9.0. See [CHANGELOG.md](CHANGELOG.md).

## Source

- Plugin: [PsychQuant/che-msg](https://github.com/PsychQuant/che-msg/tree/main/plugins/che-slack-mcp), the `che-msg` marketplace
- Server and `slack-all`: the same repository, [`che-slack-mcp/`](https://github.com/PsychQuant/che-msg/tree/main/che-slack-mcp)
