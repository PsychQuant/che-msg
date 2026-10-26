# che-telegram-mcp Plugin

Claude Code plugin for Telegram — bundles **personal account (TDLib)** and **Bot API** MCP servers in one plugin. Credentials are stored in macOS Keychain, never in config files.

## Two paths, one plugin

This plugin ships two independent MCP servers. Pick the one(s) you need — wrappers lazy-download binaries, so an unused server costs you nothing.

| Server | Identity | What it can do | Binary size | When to use |
|--------|----------|----------------|-------------|-------------|
| `telegram-all` | **Your personal Telegram account** (via TDLib) | Read all your private chats, send as you, search full history, manage groups, dump chats to Markdown | ~223 MB | "I want my own Telegram automated" — reading conversations, drafting replies, archiving chats |
| `telegram-bot` | **A Telegram bot** (via Bot API) | Send/receive messages as a bot, manage chats the bot is in, get updates | ~16 MB | "I want a bot to post updates / take commands" — notifications, integrations, public chat moderation |

Most personal-automation users want **`telegram-all` only**. Bot integrations are a separate use case.

---

## Quick start — pick your track

### Track A — Personal account only (most common)

You want to read/send messages as **yourself**.

```bash
# 1. Add the marketplace and install the plugin
/plugin marketplace add PsychQuant/che-msg
/plugin install che-telegram-mcp@che-msg

# 2. Store API credentials (from https://my.telegram.org/apps).
#    Each command ends with -w, so security asks for the value (twice) instead of
#    taking it as an argument, which would stay in your shell history. Run these
#    in your own terminal, not through Claude's Bash tool.
security add-generic-password -a "che-telegram-all-mcp" -s "TELEGRAM_API_ID" -U -w
security add-generic-password -a "che-telegram-all-mcp" -s "TELEGRAM_API_HASH" -U -w

# Optional (0.9.0+): 2FA password (read by the server when Telegram asks for it, so you never type it into the conversation)
security add-generic-password -a "che-telegram-all-mcp" -s "TELEGRAM_2FA_PASSWORD" -U -w

# Optional (0.9.0+): phone number (read the same way, to skip the prompt)
security add-generic-password -a "che-telegram-all-mcp" -s "TELEGRAM_PHONE" -U -w

# 3. Authenticate (one-time; see below for which values you still type)
/che-telegram-mcp:auth
```

From che-telegram-all-mcp 0.9.0, the server reads the phone number and the 2FA password from these Keychain items itself, only while Telegram is waiting for them, and keeps no copy. The wrapper never passes them on. An environment variable of the same name takes precedence; `auth_run`'s own arguments take precedence over both, except that a value passed while the stored or environment value for that step is already being sent is not sent: the call returns the answer to that request. If the stored 2FA password is wrong, every `auth_run` sends it again, so update the Keychain item instead of retrying. Before 0.9.0 these two items were not read at all, and the phone number and the password had to be typed into the conversation; items you stored back then are used from 0.9.0 on, so check that they are still current.

What to expect once the items are stored:

- The `/che-telegram-mcp:auth` skill logs in with `auth_run` ([#48](https://github.com/PsychQuant/che-msg/issues/48)): with 0.9.0 and both items stored, the login code is the only value you type. Without them, or with an earlier binary, Claude asks you for the phone number and the 2FA password, and a password typed there stays in the conversation transcript.
- After the login code is sent, `auth_run` can take up to 15 seconds to answer while the stored 2FA password is being sent, so that its answer is the state after the password, not a request for it.
- With the phone number stored, while the account is logged out, the first tool call that opens TDLib sends the stored phone number, and Telegram sends you a login code. That is the same as having `TELEGRAM_PHONE` in the environment. The `telegram-all` CLI never reads the Keychain ([#96](https://github.com/PsychQuant/che-msg/issues/96)).
- If the Keychain is locked, macOS may ask you to unlock it. The server waits up to 10 seconds for the value, so that first call can be slow; after that it carries on without the value.

Don't want the bot server spawning at startup? Add this to `.claude/settings.json` in your project (or `~/.claude/settings.json` for user-wide):

```json
{
  "disabledMcpjsonServers": ["telegram-bot"]
}
```

### Track B — Bot only

You want a **bot** to post messages or receive commands. No personal account.

```bash
# 1. Add the marketplace and install the plugin
/plugin marketplace add PsychQuant/che-msg
/plugin install che-telegram-mcp@che-msg

# 2. Store bot token (get one from @BotFather in Telegram)
security add-generic-password -a "che-telegram-bot-mcp" -s "TELEGRAM_BOT_TOKEN" -U -w

# 3. Disable the personal-account server (skip TDLib download entirely)
```

Add to `.claude/settings.json`:

```json
{
  "disabledMcpjsonServers": ["telegram-all"]
}
```

That's it — bot tools are now available without ever fetching the 223 MB TDLib binary.

### Track C — Both servers

You actually use both. Run all three keychain commands from Track A **plus** the one from Track B, then `/che-telegram-mcp:auth`. No `disabledMcpjsonServers` needed.

### Installed it from psychquant-claude-plugins before?

Up to 1.4.1 this plugin was published from the `psychquant-claude-plugins` marketplace. From 1.4.2 it ships from this repository's `che-msg` marketplace, next to the binaries it downloads. Switch over in your shell, uninstalling first — with both copies enabled, the session starts two `telegram-all` servers and lists every tool twice:

```bash
claude plugin uninstall che-telegram-mcp@psychquant-claude-plugins   # add --scope project if you installed it there
claude plugin marketplace add PsychQuant/che-msg
claude plugin install che-telegram-mcp@che-msg
```

Then restart Claude Code. Nothing has to be entered again: the binaries stay in `~/bin`, the credentials in Keychain and the TDLib login in `~/Library/Application Support/che-telegram-all-mcp/`, and none of them live in the plugin directory.

---

## How wrappers work

The plugin's wrappers (`bin/che-telegram-{all,bot}-mcp-wrapper.sh`) detect your installation in this order:

1. `~/bin/$BINARY_NAME`
2. `/usr/local/bin/$BINARY_NAME`
3. `~/.local/bin/$BINARY_NAME`
4. Source build at `~/Developer/che-msg/che-telegram-{all,bot}-mcp/.build/release/$BINARY_NAME`

If none are found on first invocation, the wrapper **lazy-downloads** the binary from the [GitHub release](https://github.com/PsychQuant/che-msg/releases) of the version it pins (`DESIRED_VERSION`) and caches it in `~/bin/`. It never downloads `releases/latest` instead: a version whose asset is missing is an error, and the installed binary is kept ([#50](https://github.com/PsychQuant/che-msg/issues/50)). A disabled server never triggers a download.

The download ([#56](https://github.com/PsychQuant/che-msg/issues/56)) is shared by both wrappers (`lib/download.sh`):

- It retries a transfer that stops (a connection reset, a dropped link) up to three more times, each resuming where the last one stopped, and gives up only when the transfer stalls (below 4 KB/s for 60 seconds), not after a fixed time. An HTTP error is not retried, so a release without the asset is reported at once, and neither is a failure that is not the network's (a bad certificate, a file that cannot be written).
- It keeps its files in a private directory, `~/bin/.che-telegram-mcp-download` (created with mode 700; if it is a symbolic link, not a directory, not yours, or has any other mode, nothing is downloaded and the message says to remove it: `rm -rf ~/bin/.che-telegram-mcp-download`, then reconnect, and it is created anew. It is not made private in place, because a file left in it while it was open to others could still be held open for writing). A lock, a log, a partial file or the finished download that is a symbolic link is never followed: a link is removed before use, and the finished file must be a regular file when it is checked and when it is moved into place.
- It writes to a partial file named after the version, `<Binary>.<version>.part` in that directory. A transfer cut off is resumed from there by the next start (`curl -C -`). A partial file of another version is removed, never joined to this one.
- An HTTP error installs nothing and writes no version record (`curl -f`). When the server says there is no such asset (404, 410), what was downloaded is removed; after any other HTTP error (a 5xx or 429, which curl has already retried, or a 401 or 403) it is kept and the next start tries again; the download log has the code.
- One process downloads at a time. The download holds a lock on `<Binary>.lock` in that directory (an `flock`, which the system releases when the download ends, however it ends) from the first byte until the binary is in place, so the file it checks is the file it installs. A download that finds the lock held stops at once and says `download already running`.
- It runs in the background, never on the startup path ([#67](https://github.com/PsychQuant/che-msg/issues/67)). Claude Code waits only about 30 seconds for a server to start, and the telegram-all binary is about 240 MB. With a binary the wrapper can run installed (for telegram-all, 0.7.0 or later), the wrapper starts it at once and the new version is used from the first start after it is installed; a session started meanwhile may lack the newest tools until it is reconnected with `/mcp`. With none, the wrapper waits up to 3 seconds for the download and then stops with a message that says it is downloading in the background (both wrappers write it to stderr, which Claude Code keeps in the server's MCP log, and answer `initialize` with it; see [When telegram-all does not start](#when-telegram-all-does-not-start) and [When telegram-bot does not start](#when-telegram-bot-does-not-start)). The download goes on after the wrapper exits, in a session of its own, and writes what it did to `~/bin/.che-telegram-mcp-download/<Binary>.log`. Reconnect with `/mcp` once it has finished. A partial file that is already complete and matches its sha256 is installed without downloading again.
- Nothing is installed until its sha256 is checked ([#50](https://github.com/PsychQuant/che-msg/issues/50)). Each wrapper pins the sha256 of its release asset next to `DESIRED_VERSION` (`SHA256_PIN`, for the version in `SHA256_PIN_VERSION`). The 0.8.0 pins are the sha256 digests GitHub lists for the 0.8.0 assets. A wrapper without a pin for its version downloads nothing and says so; the digest GitHub lists next to an asset is not used instead, because a replaced asset would match it too. A download that does not match is removed, and the installed binary and its version record stay as they were. With no sha256 to check against, nothing is downloaded.

### Auto-upgrade (v1.3.0+)

The wrapper pins a **`DESIRED_VERSION`** matching the binary the plugin expects and writes a `~/bin/.${BINARY_NAME}.version` sidecar each time it installs.

When the plugin is updated and the desired version is newer than the sidecar, the wrapper starts the download on the next MCP server spawn and runs the installed binary meanwhile; the download replaces the binary atomically (partial file → `mv`), and the next start uses it. If the download fails, the installed binary stays. It also downloads when no binary is installed, and re-downloads when the sidecar is missing or is not a plain `x.y.z`. A binary **newer** than the desired version is kept, also one installed while a download runs (the version record is read again right before the download is moved into place), so a session on an older plugin does not put its binary back over a newer one — as long as that session's wrapper has this check. Sessions started on plugin 1.7.0 or earlier still run the old wrapper, which re-downloads whenever the two versions differ; restart them after updating the plugin. The download decision reads only the sidecar, never the binary, so replace the two together. To go back from a newer binary to the desired version, install that version by hand (below), which writes both. Going below the desired version does not stick: once the sidecar says something older, the wrapper downloads the desired version again on the next start, so a fix for a bad release ships as a release with a higher version number. For telegram-all, falling back to the last installed binary works only for a binary of 0.7.0 or later: the wrapper does not run an older one (see [When telegram-all does not start](#when-telegram-all-does-not-start)). Source builds under `~/Developer/...` are never auto-replaced.

A **SessionStart hook** (`hooks/check-mcp.sh`) verifies on every session that:

- Both binaries are installed (or buildable from source) — printing the installed version next to `✓`
- Required Keychain entries exist
- Compares the sidecar against `releases/latest` and prints `⬆️` when a newer release is available (silent when offline / rate-limited), `ℹ` when the installed binary is newer than the latest release, and `⚠️` when the sidecar is not a plain `x.y.z` version

It prints `⚠️` warnings with copy-pasteable fix commands when something is missing. If you've disabled a server via `disabledMcpjsonServers`, you can ignore its warnings (the hook checks both servers regardless of disable state).

#### A slow link

On a link too slow for the first download to finish in a few seconds, you can let the first start wait for it. `CHE_TELEGRAM_MCP_INSTALL_WAIT` (whole seconds, up to 600; default 3) is how long a wrapper with no binary to run waits for its download. Claude Code gives up on a server after its own startup timeout, which the `MCP_TIMEOUT` environment variable sets in milliseconds, so raise both, for example `CHE_TELEGRAM_MCP_INSTALL_WAIT=240` in the `env` of `~/.claude/settings.json` and `MCP_TIMEOUT=300000 claude`. Without them nothing breaks: reconnect with `/mcp` once the download has finished.

### Manual install (if auto-download fails)

Download both binaries next to their final place, then check them:

```bash
mkdir -p ~/bin
curl -fL -C - https://github.com/PsychQuant/che-msg/releases/download/v0.9.0/CheTelegramAllMCP -o ~/bin/CheTelegramAllMCP.new
curl -fL -C - https://github.com/PsychQuant/che-msg/releases/download/v0.9.0/CheTelegramBotMCP -o ~/bin/CheTelegramBotMCP.new
shasum -a 256 ~/bin/CheTelegramAllMCP.new ~/bin/CheTelegramBotMCP.new
```

If a `curl` stops part-way, run the same line again: `-C -` continues where it stopped, and `-f` makes an HTTP error fail instead of saving the error page. Each value `shasum` prints must equal the wrapper's `SHA256_PIN` (in `bin/che-telegram-all-mcp-wrapper.sh` and `bin/che-telegram-bot-mcp-wrapper.sh`), which is also the sha256 the release page shows for that asset; from 0.9.0 on it is in the `.sha256` file attached to the release too. If one does not match, delete that `.new` file and download it again. Only when both match, move them into place and record the version:

```bash
chmod +x ~/bin/CheTelegramAllMCP.new ~/bin/CheTelegramBotMCP.new
mv ~/bin/CheTelegramAllMCP.new ~/bin/CheTelegramAllMCP
mv ~/bin/CheTelegramBotMCP.new ~/bin/CheTelegramBotMCP
echo 0.9.0 > ~/bin/.CheTelegramAllMCP.version
echo 0.9.0 > ~/bin/.CheTelegramBotMCP.version
```

Each file is moved into place in one step, so a session that is running the old binary keeps running it; writing over `~/bin/CheTelegramAllMCP` directly would change the file under that session. The last two lines record the installed version. Without them the wrapper keeps reading the old record, which no longer describes the binary: an older record makes it download again on the next start, and a newer one hides the version you installed.

> **Universal binary**: prebuilt binaries are Mach-O universal (arm64 + x86_64), so they run on both Apple Silicon and Intel Macs. Building from source: `git clone https://github.com/PsychQuant/che-msg.git && cd che-msg/che-telegram-all-mcp && swift build -c release`.

## Included Components

### MCP Servers

| Server | Identity | Read private chats | Full history | Search |
|--------|----------|-------------------|--------------|--------|
| `telegram-all` | Personal account (TDLib) | Yes | Yes | Yes |
| `telegram-bot` | Bot account (Bot API) | No (only chats the bot is in) | No (24h fetch window) | No |

### Skills

| Skill | Description |
|-------|-------------|
| `telegram-messaging` | Routes Claude to the right server (all vs bot) and walks through auth, reading, sending, search, history. Claude loads it automatically when you ask about Telegram |
| `auth` | `/che-telegram-mcp:auth` — walk through one-time authentication for personal account |
| `chats` | `/che-telegram-mcp:chats` — show recent Telegram conversations |
| `search` | `/che-telegram-mcp:search` — search Telegram message history |
| `send` | `/che-telegram-mcp:send` — send a message to a chat |
| `archive-telegram` | `/che-telegram-mcp:archive-telegram` — archive the chats listed in `.claude/.telegram/config.yaml` into per-day Markdown files and media (see [Archiving chats](#archiving-chats-archive-telegram)) |

`auth`, `chats`, `search`, `send` and `archive-telegram` run only when you type them (`disable-model-invocation: true`); for natural-language requests Claude uses `telegram-messaging`. The same setting also means scheduled tasks whose prompt is one of these skills, and subagent skill preloads, no longer run them.

Each skill's `allowed-tools` lets Claude call the listed tools **without a permission prompt, but only in the turn where you invoked the skill** — the grant clears as soon as you send your next message (invoking the skill again re-applies it):

| Skill | Pre-approved | Not pre-approved |
|-------|--------------|------------------|
| `auth` | `auth_status`, `auth_run`, `auth_set_parameters`, `auth_send_phone`, `auth_send_code`, `auth_send_password` | **`logout`** — it resets the local session, so Claude asks you first |
| `chats` | `auth_status`, `get_chats` | — |
| `search` | `auth_status`, `search_chats`, `search_messages`, `get_chat_history` | — |
| `send` | `auth_status`, `search_chats` | **`send_message`** — a sent message cannot be recalled, so it is left out on purpose |
| `archive-telegram` | `auth_status` | **`archive_chat_to_markdown`**, **`download_message_media`** — they write files, so they keep their prompt |

For `auth` this mostly covers the first turn: once Claude asks for the SMS code (or, without the Keychain items, the phone number or the 2FA password) and you reply, the grant has already cleared, so the `auth_run` call that sends it, and any step tool, goes through your normal permission settings unless you re-invoke `/che-telegram-mcp:auth` with the value.

Leaving `send_message` out means it goes through your normal [permission settings](https://code.claude.com/docs/en/permissions). If you want to be asked before Claude sends or changes anything, whatever mode you are in, add ask rules to `permissions.ask` in your settings: Claude Code never auto-approves a tool matched by an explicit ask rule, not even in auto or `bypassPermissions` mode, and in `dontAsk` mode it refuses the call instead of asking. Hooks can still approve such a call without asking you: for example a `PermissionRequest` hook — in your settings, in a plugin's `hooks.json`, or in a skill's or agent's frontmatter — can answer the prompt, and an installed mod that handles `tool.check` can approve the call (permissions docs, *Extend permissions with hooks*; permission-modes docs).

- `/che-telegram-mcp:send` does not tie itself to one server, so cover `send_message` on both: `mcp__plugin_che-telegram-mcp_telegram-all__send_message` and `mcp__plugin_che-telegram-mcp_telegram-bot__send_message`.
- The other tools that send, change or delete something — and that `telegram-messaging` can reach from a natural-language request — need ask rules of their own. On `telegram-all`: everything in the Write, Manage and Group lists below, plus `logout`, `dump_chat_to_markdown`, `archive_chat_to_markdown` and `download_message_media` (they write files) and the Auth list's login steps — `auth_run`, `auth_set_parameters`, `auth_send_phone`, `auth_send_code` and `auth_send_password` — which send codes and change the login. On `telegram-bot`: every tool except `get_me`, `get_chat`, `get_chat_administrators`, `get_chat_member_count`, `get_chat_member` and `get_my_commands` (`get_updates` with an offset drops pending updates for good).
- Or add a whole-server rule, `mcp__plugin_che-telegram-mcp_telegram-all` or `mcp__plugin_che-telegram-mcp_telegram-bot`, to be asked for every call to that server, reads and the skills' pre-approved lookups included.

Without such a rule, what happens depends on the [permission mode](https://code.claude.com/docs/en/permission-modes) and your allow rules:

- **Manual** (config value `default`) and `acceptEdits`: Claude Code asks before sending, unless an allow rule matches `send_message`.
- **auto**: a classifier reviews the call instead of you, and there is normally no prompt; an allow rule that matches skips the classifier too. Auto falls back to asking after repeated classifier blocks. Auto is the mode interactive terminal and VS Code sessions start in unless you configure another: on every plan and provider since Claude Code v2.1.284 per the changelog (the permission-modes page says v2.1.283), and earlier on Pro, Max and Team plans.
- `bypassPermissions`: no prompt.
- `dontAsk`: the call is refused unless an allow rule matches it; with one, it is sent without a prompt.
- The remaining modes (`plan`, and any added later): see the permission-modes page.

Whenever no prompt appears, the only remaining guard is the skill's own instruction to confirm the recipient and text with you first.

> v1.4.0: these four moved from `commands/` to skills; examples use the full name `/che-telegram-mcp:<name>`. Each skill sets a frontmatter `name` (as the 1.3.2 commands did), so the bare `/auth` still works as long as no other command or skill uses that name. `auth`, `chats`, `search` and `send` are common names: if another command or skill — built in, your own, or another plugin's — already uses one of them, the bare form may run that one instead, which is why the full name is shown. Up to 1.3.2 they were commands that Claude could also invoke on its own, and their `allowed-tools` named tools that do not exist, so nothing was ever pre-approved.

## Usage Examples

```
/che-telegram-mcp:auth                            → Set up personal account (one-time)
/che-telegram-mcp:chats                           → See recent conversations
/che-telegram-mcp:search 會議紀錄                   → Search across chats
/che-telegram-mcp:send @alice "see you tomorrow"  → Send a message
/che-telegram-mcp:archive-telegram                → Archive the chats in .claude/.telegram/config.yaml
```

Or just ask naturally:

- "What did Bob say in the project group last week?"
- "Send 'on my way' to Alice"
- "Dump my chat with Carol from January to a Markdown file"
- "Show me the last 50 messages from the dev channel"

## Archiving chats (`/archive-telegram`)

`/che-telegram-mcp:archive-telegram` keeps an archive of chosen chats that grows with each run, like `/archive-mail` does for Apple Mail ([#69](https://github.com/PsychQuant/che-msg/issues/69)). List the chats by `chat_id` (find them with `get_chats` or `search_chats`) in `.claude/.telegram/config.yaml` in your workspace:

```yaml
output_dir: archives/telegram     # relative to the workspace, or absolute
since: 2026-01-01                 # optional: where the first run starts (default: the whole history)
max_media_mb: 50                  # optional: skip larger media (default: no limit)
chats:
  - chat_id: 123456789
    label: 專案群組               # optional, used only in the report
```

Without this file the skill shows the template and does nothing else. `output_dir` must not be empty and must not contain `..` or start with `~` (the skill does not expand `~`; write the absolute path instead) ([#76](https://github.com/PsychQuant/che-msg/issues/76)). Each run writes, per chat:

- `archives/telegram/<chat_id>/YYYY-MM-DD.md` — one block per message, anchored by `<!-- msg:<message_id> -->`. Re-runs merge into these files; nothing already there is rewritten, except blocks written from the local cache (see below). Owner-only (0600).
- `archives/telegram/<chat_id>/media/<message_id>/` — the photo, video, document, audio, voice note, video note, animation or sticker. The message's line links to that directory.

The bookmark of each chat (the newest archived message id) is kept in `.claude/.telegram/state/archives/<slug>/index.json`. It moves forward only when the run read the whole new range from a synced TDLib and the end-of-run check passed: every day file the run wrote, and the day file holding its newest message (`newest_message_file`, which a re-run may not have rewritten), exists and belongs to that chat, and the latter holds the newest message's anchor. When the tool reports that the archive was written at another `utc_offset`, the skill adopts the recorded offset and tries once more. Otherwise it stays, and the next run fetches the same range again — the merge drops what is already there. The report says why a bookmark did not move: a Telegram rate limit (with the wait in seconds), TDLib not synced yet, or a failed check.

While another session holds TDLib the skill stops instead of archiving from TDLib's local cache: a cache run downloads no media, and its blocks have no sender names, captions or audio links. Ask for a cache archive explicitly if you want one anyway; those blocks are marked provisional (`<!-- provisional: local-cache -->` on the line after the anchor), and the next run through TDLib replaces them with the full ones and reports how many it upgraded ([#72](https://github.com/PsychQuant/che-msg/issues/72)). Nothing else that is already in a day file is rewritten. It also stops when `output_dir` sits in a git repository without being ignored, and when two `output_dir` values would share one index.

Media that failed to download are retried on the next run, unless Telegram says the message no longer exists; the report counts those separately and drops them from the retry list ([#75](https://github.com/PsychQuant/che-msg/issues/75)). A day file the tool cannot merge into safely — a symbolic link, FIFO or directory named like a day, or a file with CRLF or CR line endings that a run has new messages for — stops that chat, and the report names the file ([#76](https://github.com/PsychQuant/che-msg/issues/76)). Media skipped by `max_media_mb` are listed with their size; fetch one later with `download_message_media` (`chat_id`, `message_id`, `output_dir`), which also works on its own to save any single message's media ([#17](https://github.com/PsychQuant/che-msg/issues/17)).

When a group is upgraded to a supergroup its `chat_id` changes (to a `-100…` id): put the new id in the config. The old directory stays.

> **Privacy.** Archives and media are other people's messages and files, verbatim. Do not commit them to any repository — the skill refuses to run while `output_dir` is inside a git repository and not ignored. Media keep the sender's file name and extension: treat them as untrusted files. Newly saved media carry the macOS quarantine attribute, so Gatekeeper checks an app or script before it opens from Finder. The skill's report gives only counts, file names and message ids, never message text, captions or sender names.

Needs `che-telegram-all-mcp` 0.8.0 or later (the release that adds `archive_chat_to_markdown` and `download_message_media`).

## Available Tools

### `telegram-all` (Personal Account, TDLib) — 30 tools

**Auth (6)**: `auth_status`, `auth_run`, `auth_set_parameters`, `auth_send_phone`, `auth_send_code`, `auth_send_password`

**Read (8)**: `get_me`, `get_chats`, `get_chat`, `get_chat_history`, `search_chats`, `search_messages`, `get_chat_members`, `get_contacts`

**Write (5)**: `send_message`, `edit_message`, `delete_messages`, `forward_messages`, `mark_as_read`

**Manage (4)**: `pin_message`, `unpin_message`, `set_chat_title`, `set_chat_description`

**Group (2)**: `create_group`, `add_chat_member`

**Export (1)**: `dump_chat_to_markdown` — one-shot export with optional `since_date` / `until_date` / `max_messages`

**Archive (2)**: `archive_chat_to_markdown` — incremental per-day archive with media and a content-free manifest; `download_message_media` — save one message's media (see [Archiving chats](#archiving-chats-archive-telegram))

**Other (2)**: `logout`, `get_user`

> v0.5.0 added `auth_run` — a single tool drives the entire auth state machine. See [v0.5.0 release notes](https://github.com/PsychQuant/che-msg/releases/tag/v0.5.0).

### `telegram-bot` (Bot API) — 31 tools

`get_me`, `get_updates`, `send_message`, `forward_message`, `get_chat`, `get_chat_administrators`, `get_chat_member_count`, `get_chat_member`, `set_chat_title`, `set_chat_description`, `pin_chat_message`, `unpin_chat_message`, `unpin_all_chat_messages`, `ban_chat_member`, `unban_chat_member`, `restrict_chat_member`, `promote_chat_member`, `leave_chat`, `delete_message`, `edit_message_text`, `copy_message`, `send_photo`, `send_document`, `send_video`, `send_audio`, `send_sticker`, `send_location`, `send_poll`, `set_my_commands`, `get_my_commands`, `delete_my_commands`

## Multiple sessions

`telegram-all` uses [TDLib](https://core.telegram.org/tdlib), which lets only one process at a time open its database. `telegram-bot` is not affected (the Bot API is HTTP-based and stateless, so any number of Claude Code sessions can run it).

Several Claude Code sessions can enable `telegram-all` together. Each session starts its own server, and the servers share TDLib this way:

- A server opens TDLib only when a tool first needs it, and closes it again once no call has used it for the idle timeout, so another session can open it. The timeout is `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` in seconds: 600 by default, `0` keeps TDLib open for the server's whole life.
- While another session's server holds TDLib, `get_chats`, `search_chats`, `get_chat_history`, `search_messages` and `dump_chat_to_markdown` are answered from TDLib's local cache, and `archive_chat_to_markdown` archives from it without downloading media or advancing bookmarks (`bookmark_safe: false`). The result has a second part that starts with `source: local-cache`, names the process holding TDLib, counts the records that could not be decoded, and gives for each chat the date of its newest cached message. The cache holds only the messages TDLib has loaded, so newer messages can exist on Telegram.
- `get_me`, `get_user`, `get_contacts`, `get_chat` and `get_chat_members` return `{"type":"local_reader_unsupported",…}`. Sending, editing, `download_message_media`, `auth_*`, `logout` and every other tool return `{"type":"tdlib_in_use","lock_holder_pid":…}`: use the session that holds TDLib, or wait until it has been idle for its timeout.

To change the timeout, set the variable for the MCP server, for example in `~/.claude/settings.json`:

```json
{ "env": { "CHE_TELEGRAM_ALL_IDLE_TIMEOUT": "300" } }
```

A value that is not a whole number of seconds (or is negative) falls back to 600 and prints one warning.

### When telegram-all does not start

The wrapper stops before starting the server only in the cases below. It writes the reason to stderr and answers Claude Code's `initialize` request with the same reason as a JSON-RPC error. If Claude Code's first request is a request for another method, such as the `server/discover` probe recent builds send first, it gets a "method not found" answer (a batch gets "Invalid Request", a notification no answer), and the reason is only on stderr. The wrapper reads the request with `jq` 1.7 or later, which macOS includes as `/usr/bin/jq` (it tries that one first, then the `jq` on `PATH`; an older `jq` can change a large numeric request id). Without one it cannot tell requests apart and answers any first line with the startup error carrying no request id. Whether `/mcp` shows the message depends on the Claude Code build: the builds checked in [#59](https://github.com/PsychQuant/che-msg/issues/59) showed only `CONNECTION_CLOSED`. The reason is in the server's MCP log, as a `Server stderr:` entry. On macOS, Claude Code writes that log to `~/Library/Caches/claude-cli-nodejs/<project>/mcp-logs-plugin-che-telegram-mcp-telegram-all/`, where `<project>` is the directory Claude Code was started in with each `/` and `.` written as `-` (`/Users/me/.claude` becomes `-Users-me--claude`); the newest `.jsonl` file there is the latest start. For more detail, start Claude Code with `claude --debug=mcp --debug-file <path>`, which writes its MCP debug lines to `<path>`.

The cases, and what to do:

- **API credentials missing**: store `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` in the Keychain as in step 2 of [Track A](#track-a--personal-account-only-most-common), then reconnect with `/mcp`.
- **Still downloading**: on a first install the binary is not there yet; the message says it is downloading in the background (with its size). Reconnect with `/mcp` in a few minutes, once `~/bin/.che-telegram-mcp-download/CheTelegramAllMCP.log` says it was installed ([#67](https://github.com/PsychQuant/che-msg/issues/67)). On a slow link, see [A slow link](#a-slow-link).
- **Binary not available**: the download failed or found no release asset. The message says why: the transfer was interrupted (reconnect with `/mcp` and the next start resumes it), the server has no such release asset (HTTP 404 or 410), the server answered another HTTP error (the next start tries again), the download did not match its sha256 (it was removed), the plugin has no sha256 for the version or its pin is malformed (update or reinstall the plugin), or another session is downloading it. Reconnect, or install it by hand as in [Manual install](#manual-install-if-auto-download-fails), then reconnect.
- **Binary too old**: the binary found is older than 0.7.0 — typically the previous version, kept because the download of the new one failed, or an old copy outside `~/bin` (such as `~/.local/bin`), which the wrapper never upgrades. The message names the binary and why it was not upgraded. Binaries before 0.6.0 open TDLib without coordinating with other sessions, and 0.6.x binaries send Telegram's log-out from `logout`, which deletes the local database, so the wrapper runs neither. Install the current one by hand as in [Manual install](#manual-install-if-auto-download-fails), then reconnect.
- **Plugin incomplete**: the plugin's `lib/startup-error.sh` or `lib/download.sh` cannot be read (a damaged or partial copy of the plugin). Reinstall the plugin, then reconnect with `/mcp`. When `lib/startup-error.sh` is the file that cannot be read, the wrapper cannot read Claude Code's first request, so its JSON-RPC error carries `id` null, which Claude Code discards; the reason is then only in the MCP log.

Another session using `telegram-all` is never a reason: the wrapper takes no lock on the server (only one around its download) and stops only the server it started itself.

### When telegram-bot does not start

On a first install the bot wrapper may stop before the server starts. It then writes the reason to stderr and answers `initialize` with it, as telegram-all does ([#67](https://github.com/PsychQuant/che-msg/issues/67)); find it in the server's MCP log as [When telegram-all does not start](#when-telegram-all-does-not-start) describes, in `mcp-logs-plugin-che-telegram-mcp-telegram-bot/`:

- **Still downloading**: the binary is not there yet and is downloading in the background (about 18 MB). Reconnect with `/mcp` in a minute, once `~/bin/.che-telegram-mcp-download/CheTelegramBotMCP.log` says it was installed.
- **Binary not available**: the download failed. The message says why, for the same reasons as for telegram-all (see [When telegram-all does not start](#when-telegram-all-does-not-start)). Reconnect, or install it by hand as in [Manual install](#manual-install-if-auto-download-fails).

A missing bot token stops it too, in the same way: the answer to `initialize` names `TELEGRAM_BOT_TOKEN`, and the setup command is on stderr (the server's MCP log). Store `TELEGRAM_BOT_TOKEN` in the Keychain as in step 2 of [Track B](#track-b--bot-only), then reconnect. So does an incomplete plugin, as for telegram-all (**Plugin incomplete** in [When telegram-all does not start](#when-telegram-all-does-not-start)).

### When telegram-all stops syncing

If answers carry a second text item starting `sync: not-synced`, or `auth_status` reports `"sync_stalled": true`, TDLib is logged in but is not receiving anything from Telegram — most often because Telegram invalidated the session after it was used in two places at once ([#63](https://github.com/PsychQuant/che-msg/issues/63)). Reads then return old data. Only time spent updating counts toward a stall; without a network the note just says to check the connection. Recover in this order: call `logout` (a local reset: it sends no log-out request to Telegram, closes TDLib and renames its database directory to `tdlib.invalidated-<UTC timestamp>`; nothing is deleted); **then** end the stalled session and any unknown one in Telegram → Settings → Devices (not before — a session ended while TDLib still runs on its directory can make TDLib clear that directory); then log in again with `auth_run`. `logout` does not revoke anything on Telegram's side, and the renamed directory still holds a working auth key. The skill tells Claude to ask you before calling `logout`. Details: the che-telegram-all-mcp README, section "When telegram-all stops syncing".

### Sessions still running plugin v1.4.x or earlier

Up to v1.4.x the wrapper took a lock before starting the server, and a second session's wrapper refused to start ("Another instance of CheTelegramAllMCP is already running"). A session started with such a wrapper keeps its lock directory `~/.cache/che-telegram-all-mcp.lock` while it runs; newer servers treat TDLib as held by it until that wrapper exits, so the two never open TDLib at once. Restart that session to move it to the new behaviour.

A v1.4.x wrapper that was killed outright (or a Mac that lost power) leaves that lock directory behind. Newer servers ignore it once its `owner.pid` no longer belongs to a running `che-telegram-all-mcp-wrapper.sh`. To remove it by hand, first make sure no session still runs a v1.4.x wrapper, then:

```bash
rm -rf ~/.cache/che-telegram-all-mcp.lock
```

## Requirements

- **macOS 26 or later** ([#91](https://github.com/PsychQuant/che-msg/issues/91)). The binaries after v0.8.0 are built for macOS 26 and need parts of the Swift runtime that come with it, such as the `OutputSpan` type in `libswiftCore`; an earlier `libswiftCore` lacks it, so dyld most likely stops them at launch with "Symbol not found". The v0.8.0 binaries say macOS 13, but they load `libswiftCompatibilitySpan.dylib`, which macOS 13–15 do not have, so they most likely do not start there either unless Xcode 26 or later is installed. Neither was tested on those systems.

## Permissions

This plugin requires:

- **macOS Keychain** access for credential storage
- **Network** access for the Telegram API
- **Disk** access for TDLib's local database (`~/Library/Application Support/che-telegram-all-mcp/`) — only used by `telegram-all`

## Version

Plugin version: 1.8.0 (currently pins `che-telegram-all-mcp` v0.9.0 + `che-telegram-bot-mcp` v0.9.0 binaries; the wrapper upgrades a binary whose version record is older than the pin)

### Changelog

**1.7.0** (2026-10-14)

- **`/che-telegram-mcp:archive-telegram`** ([#69](https://github.com/PsychQuant/che-msg/issues/69)): archive the chats listed in `.claude/.telegram/config.yaml` into per-day Markdown files with their media, keeping a bookmark per chat; see [Archiving chats](#archiving-chats-archive-telegram).
- telegram-all gains `archive_chat_to_markdown` and `download_message_media` ([#17](https://github.com/PsychQuant/che-msg/issues/17)). Binaries 0.8.0 (`DESIRED_VERSION`).

**1.6.0** (2026-10-10)

- **telegram-all says when it is not synced** ([#63](https://github.com/PsychQuant/che-msg/issues/63)): read answers carry a `sync: not-synced` note, `auth_status` reports `sync_stalled`, and the skill reports a stalled session to you. See [When telegram-all stops syncing](#when-telegram-all-stops-syncing).
- **`logout` is a local reset**: no log-out request to Telegram, nothing deleted; Claude asks you first. Recovery order: `logout`, then end the old session in Telegram → Settings → Devices, then `auth_run`.
- The telegram-all wrapper runs only binary 0.7.0 or later. Binaries 0.7.0 (`DESIRED_VERSION`).

**1.5.0** (2026-10-09)

- **Several sessions at once**: telegram-all no longer refuses to start in a second Claude Code session. The server opens TDLib only when a tool needs it, closes it after `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` seconds idle, and while another session holds it answers the read tools from TDLib's local cache. See [Multiple sessions](#multiple-sessions) and [che-msg#58](https://github.com/PsychQuant/che-msg/issues/58).
- The wrapper takes no lock, keeps no shared PID file and stops only its own binary; missing credentials, a missing binary or a binary older than 0.6.0 (which would open TDLib without coordinating) now answer `initialize` with their reason. Claude Code may still show only `CONNECTION_CLOSED`; the reason is in the server's MCP log (see [When telegram-all does not start](#when-telegram-all-does-not-start)).
- Binaries 0.6.0 (`DESIRED_VERSION`).

**1.4.2** (2026-10-08)

- **Moved to the `che-msg` marketplace**: the plugin now ships from [PsychQuant/che-msg](https://github.com/PsychQuant/che-msg), the repository that builds and releases its binaries. Install with `/plugin marketplace add PsychQuant/che-msg` and `/plugin install che-telegram-mcp@che-msg`; if you installed from psychquant-claude-plugins, follow [the steps above](#installed-it-from-psychquant-claude-plugins-before). See [che-msg#42](https://github.com/PsychQuant/che-msg/issues/42).
- The telegram-all wrapper's lock-refused error now links to this README in che-msg.
- No change to the skills or binaries; the wrappers still pin `DESIRED_VERSION` 0.5.0.

**1.4.1** (2026-10-08)

- **Docs corrected**: the permission note for `send` no longer says that "the default permission mode asks" — on recent Claude Code (every plan since v2.1.284 per the changelog, Pro, Max and Team plans earlier) interactive sessions start in auto mode, which normally does not ask (it does when an ask rule matches, and after repeated classifier blocks). It now names the modes as Claude Code does, says what an allow rule changes, and recommends ask rules as the one setting that asks in any mode, unless a `PermissionRequest` hook or a mod approves the call: for `send_message` on both servers (`send` does not tie itself to one) and for every other tool that sends or changes something, listed per server; or a whole-server ask rule. The bare-name note no longer says that `search` and `send` collide with other plugins: whether a name collides depends on what else is installed. The bare names work as in 1.4.0. See [#138](https://github.com/PsychQuant/psychquant-claude-plugins/issues/138).
- No change to the skills, wrappers or binaries.

**1.4.0** (2026-10-06)

- **`commands/` → skills**: `auth`, `chats`, `search`, `send` are now `skills/<name>/SKILL.md`, invoked as `/che-telegram-mcp:<name>`. They set `disable-model-invocation: true`, so — unlike the 1.3.2 commands — Claude no longer invokes them on its own. See [#138](https://github.com/PsychQuant/psychquant-claude-plugins/issues/138).
- **`allowed-tools` now actually apply**: the old entries named `mcp__che-telegram-mcp__*`, which matches no tool. The corrected names pre-approve the tools in the table above; `send` leaves `send_message` out on purpose.
- **Wrapper tests moved out of the shipped plugin** to `tests/che-telegram-mcp/` in the marketplace repo, so only the two wrappers remain in `bin/` (and on the Bash tool's `PATH`). The wrappers stay in `bin/` because the harness-devtools release tooling finds them there.
- SessionStart hook quotes `${CLAUDE_PLUGIN_ROOT}`; `plugin.json` states the real tool counts (telegram-all 28, telegram-bot 31).

**1.3.2** (2026-05-22)

- **Lock-refused branch emits MCP JSON-RPC error envelope to stdout** (refs [che-msg#31](https://github.com/PsychQuant/che-msg/issues/31)). When a second Claude Code session tries to spawn `telegram-all` while a stale session still holds the TDLib lock, the wrapper now writes a `{"jsonrpc":"2.0","id":<matches initialize request>,"error":{...}}` envelope to stdout before exit. The wrapper reads the first line of stdin (2s timeout) to extract the JSON-RPC `initialize` request's `id` and responds with the matching id, so Claude Code's MCP client surfaces `error.message` (e.g. `"Another instance of CheTelegramAllMCP is already running (lock held by PID 11252). Use the existing Claude Code window, or kill the previous wrapper first."`) instead of generic `-32000 Server error`. Falls back to `id: null` only when stdin is empty (direct-shell debug). `error.data` carries `lockHolderPid`, `recoveryCommand`, and `docsUrl`.
- **Multi-session limitation README section** documents the TDLib upstream constraint + recovery cookbook + Strategy B/C explicit non-decisions.
- **Recovery cookbook hardened**: `pkill ... ; rm -rf ...` (semicolon, not `&&`) so cleanup runs even when no process exists to kill — the orphan-lock case is exactly when cleanup matters most. Also covers both `.lock` (mkdir mode) and `.lock.flock` (flock mode) paths.

**1.3.1** (2026-05-07)

- **Atomic-claim lock**: wrapper now uses `flock` (Linux) or `mkdir` (macOS fallback) to prevent two simultaneous wrappers from racing the TDLib lock. Second wrapper fail-fast with stderr message instead of silent SIGTERM cross-fire. Stale-lock cleanup removes orphaned locks whose owner PID is dead. New regression test (`test-wrapper-pid.sh` test 9). Resolves [#10](https://github.com/PsychQuant/psychquant-claude-plugins/issues/10).

**1.3.0** (2026-04-28)

- **Auto-upgrade wrappers**: each wrapper now pins a `DESIRED_VERSION` and writes a `~/bin/.${BINARY_NAME}.version` sidecar on install. When the plugin bumps the desired version, the wrapper detects the sidecar mismatch and atomically re-downloads (`.tmp` → `mv`) on next spawn. Source builds in `~/Developer/...` are never auto-replaced. Falls back to the existing binary on network failure (no brick).
- **SessionStart hook upgrade notice**: `check-mcp.sh` now reads the sidecar to display installed version, queries `releases/latest`, and prints `⬆️ v0.4.3 → v0.5.0 available` when behind upstream. Silent when offline or rate-limited.
- Pin telegram-bot binary at v0.5.0 (built from same monorepo as telegram-all v0.5.0).

**1.2.1** (2026-04-27)

- Fix `hooks/check-mcp.sh` source-build path: previously pointed at `~/Developer/che-mcps/che-msg/.build/release/...`, which doesn't exist (che-msg is a monorepo, the Swift packages live in sub-dirs `che-telegram-all-mcp/` and `che-telegram-bot-mcp/`). Now mirrors the wrapper's exact 5-path search (incl. `~/Developer/che-msg/<package>/.build/release/<binary>`).
- Fix `check-mcp.sh` build instruction: was `cd che-msg && swift build -c release` (no Package.swift at monorepo root), now `cd ~/Developer/che-msg/<package> && swift build -c release --product <binary>`.
- `check-mcp.sh` no longer warns about optional Keychain entries (`TELEGRAM_PHONE`, `TELEGRAM_2FA_PASSWORD`); they're shown only when present and silently skipped when absent.
- `check-mcp.sh` footer now documents `disabledMcpjsonServers` so users running only one server know how to suppress the other's warnings.

**1.2.0** (2026-04-27)

- Documentation restructure: explicit "Two paths, one plugin" framing with three quickstart tracks (personal-account only / bot only / both)
- README now documents how to disable an unused server via `disabledMcpjsonServers` in `settings.json`
- Skill (`telegram-messaging`) restructured to route between `telegram-all` and `telegram-bot` with server-specific tool guidance
- Skill `allowed-tools` removed: previous list used the wrong namespace prefix (`mcp__che-telegram-mcp__*` vs actual `mcp__plugin_che-telegram-mcp_telegram-{all,bot}__*`), so the allowlist was effectively ignored. Without it, plugin tools are accessible normally.

**1.1.0** (2026-04-16)

- Wrappers auto-download binaries from GitHub Release if not installed locally
- Wrapper PID tracking refinements (Test 7 SIGKILL race fix)
- Currently bundles `che-telegram-all-mcp` v0.4.3, which closes [PsychQuant/che-telegram-all-mcp#1](https://github.com/PsychQuant/che-telegram-all-mcp/issues/1) — TDLib auth error handling overhaul (structured `code`/`message` errors, snake_case decoder regression test, code 406 silent-ignore per protocol)

**1.0.2** (earlier)

- Wrapper PID tracking added

## Source

- Plugin source: [PsychQuant/che-msg](https://github.com/PsychQuant/che-msg/tree/main/plugins/che-telegram-mcp) (the `che-msg` marketplace; up to 1.4.1 it was published from the psychquant-claude-plugins marketplace)
- Binary source: the same repository, `che-telegram-all-mcp/` and `che-telegram-bot-mcp/` — also mirrored at [PsychQuant/che-telegram-all-mcp](https://github.com/PsychQuant/che-telegram-all-mcp) for the personal-account MCP

## Author

Created by **Che Cheng** ([@kiki830621](https://github.com/kiki830621))
