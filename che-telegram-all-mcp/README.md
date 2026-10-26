# che-telegram-all-mcp

Full Telegram client MCP Server powered by [TDLib](https://core.telegram.org/tdlib). Operate Telegram as **your personal account** — read all chats, send messages, manage groups, search history.

> **Looking for the simpler Bot-only version?** See [che-telegram-bot-mcp](../che-telegram-bot-mcp/).

## Bot vs All: What's the difference?

| Feature | `che-telegram-bot-mcp` | `che-telegram-all-mcp` |
|---------|----------------------|----------------------|
| Identity | Bot account | Your personal account |
| Read private chats | No | Yes |
| Read full chat history | No | Yes |
| Search messages | No | Yes |
| Contact list | No | Yes |
| Dependencies | URLSession only | TDLib (~300MB) |
| Auth | Bot token | Phone + verification code |

## Prerequisites

### 1. Get Telegram API Credentials

1. Go to [https://my.telegram.org](https://my.telegram.org)
2. Log in with your phone number
3. Go to **API Development Tools**
4. Create a new application → get `api_id` (number) and `api_hash` (string)

### 2. Build

Runs on macOS 26 or later ([#91](https://github.com/PsychQuant/che-msg/issues/91)). Built and tested with Xcode 27.1 (Swift 6.4); the manifests of the dependency versions in `Package.resolved` need at least Swift 6.0.

> **First build will download ~300MB** of TDLibFramework binary. This is normal.

```bash
git clone https://github.com/PsychQuant/che-msg.git
cd che-msg/che-telegram-all-mcp
swift build -c release
```

Binary location: `.build/release/CheTelegramAllMCP`

## Installation

> **Prefer the plugin.** The [`che-telegram-mcp` plugin](../plugins/che-telegram-mcp/README.md)'s wrapper reads `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` from the Keychain at launch, and from 0.9.0 the server reads `TELEGRAM_PHONE` and `TELEGRAM_2FA_PASSWORD` from the Keychain itself, only while Telegram waits for them. The options below run the server on its own. Keep the phone number and the 2FA password in the Keychain (the plugin README has the commands) rather than in the environment: a process's environment can be read by other processes of the same user (`ps -E`), and a value in `~/.claude.json` or the Claude Desktop config sits there in plain text. To keep the API credentials out of the configuration file, read them from the Keychain at launch ([#97](https://github.com/PsychQuant/che-msg/issues/97)):
>
> ```bash
> claude mcp add che-telegram-all-mcp -s user -- /bin/sh -c \
>   'id=$(security find-generic-password -a che-telegram-all-mcp -s TELEGRAM_API_ID -w) &&
>    hash=$(security find-generic-password -a che-telegram-all-mcp -s TELEGRAM_API_HASH -w) || exit 1
>    TELEGRAM_API_ID=$id TELEGRAM_API_HASH=$hash exec /path/to/che-telegram-all-mcp/.build/release/CheTelegramAllMCP'
> ```
>
> `find-generic-password … -w` prints the stored value for the launcher to read; it never takes a value. If an item is missing or the Keychain is locked, the launcher stops and `security`'s message is in the server's stderr. The launcher keeps the API credentials out of the configuration file; they are still in the server's environment while it runs.

### Option A: Claude Code CLI

```bash
claude mcp add che-telegram-all-mcp \
  -s user \
  -e TELEGRAM_API_ID=12345678 \
  -e TELEGRAM_API_HASH=your_api_hash_here \
  -- /path/to/che-telegram-all-mcp/.build/release/CheTelegramAllMCP
```

> With env vars set, API credentials are auto-configured on startup. You only need to authenticate your phone number once.

### Option B: Edit config directly

Add to `~/.claude.json`:

```json
{
  "mcpServers": {
    "che-telegram-all-mcp": {
      "type": "stdio",
      "command": "/path/to/.build/release/CheTelegramAllMCP",
      "env": {
        "TELEGRAM_API_ID": "12345678",
        "TELEGRAM_API_HASH": "your_api_hash_here"
      }
    }
  }
}
```

### Option C: Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "che-telegram-all-mcp": {
      "command": "/path/to/.build/release/CheTelegramAllMCP",
      "env": {
        "TELEGRAM_API_ID": "12345678",
        "TELEGRAM_API_HASH": "your_api_hash_here"
      }
    }
  }
}
```

### Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `TELEGRAM_API_ID` | Yes | Telegram API ID (numeric). Auto-fired when state is `waitingForParameters`. |
| `TELEGRAM_API_HASH` | Yes | Telegram API hash (string). Auto-fired alongside `TELEGRAM_API_ID`. |
| `TELEGRAM_PHONE` | No | Phone number in international format (e.g., `+886912345678`). Auto-fired when state is `waitingForPhoneNumber`. Useful for SSH / remote setup. When unset, the server reads the Keychain item of the same name (account `che-telegram-all-mcp`) at that moment (0.9.0 and later); the `telegram-all` CLI never reads the Keychain. |
| `TELEGRAM_2FA_PASSWORD` | No | 2FA password. Auto-fired when state is `waitingForPassword`. When unset, the server reads the Keychain item of the same name (account `che-telegram-all-mcp`) at that moment (0.9.0 and later). |
| `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` | No | Seconds TDLib may stay idle before the server closes it and releases the lock (default `600`; `0` keeps it open). A non-numeric or negative value falls back to 600 with a warning on stderr. |
| `CHE_TELEGRAM_ALL_EXPORT_ROOT` | No | Directory `dump_chat_to_markdown` may write into ([#21](https://github.com/PsychQuant/che-msg/issues/21)). When set, `output_path` must lie inside it once symbolic links are resolved, or the dump is refused before any message is read. A value that is not an absolute path to an existing directory refuses every dump (it is never ignored); `~` is not expanded, and the value is not trimmed, so one made only of spaces refuses every dump. Unset or set to the empty string: no restriction. Read once at startup. It does not restrict `archive_chat_to_markdown`, `download_message_media` or the CLI's `--dump-markdown`. |

> SMS verification code is **never** auto-fired, from the environment or the Keychain — it must be supplied via `auth_run(code: "...")` or `auth_send_code(code: "...")` in a one-shot delivery.
>
> The Keychain lookup runs `/usr/bin/security` with a 10-second limit, only when the environment has no value. When the lookup finds nothing, `auth_status` and `auth_run` say why in `keychain_lookup` (`not_stored`, `timed_out` (usually a locked Keychain) or `unavailable`), and the 2FA hint asks for the Keychain item before the `password` argument. The value is used for that one submission and never logged.
>
> If env vars are not set, you can still drive the flow manually via `auth_run` (or the per-step `auth_set_parameters` / `auth_send_phone` / `auth_send_password` tools).

## Authentication Flow

Authentication is a **one-time process**. After the first login, TDLib stores the session locally and you won't need to authenticate again.

### Recommended: `auth_run` (single tool, repeat until ready)

Store the phone number and the 2FA password as Keychain items (`TELEGRAM_PHONE`, `TELEGRAM_2FA_PASSWORD`, account `che-telegram-all-mcp`; 0.9.0 and later) and give the API credentials as above, then call `auth_run` repeatedly. Each value comes from the call's argument, then the environment, then the Keychain; environment values work too, but other processes of the same user can read them:

```
auth_run                 →  fires auto-set params (if env present)
auth_run                 →  fires auto-send phone (if env or Keychain has it)
auth_run(code: "12345")  →  caller MUST supply SMS code
auth_run                 →  fires auto-send 2FA password (if env or Keychain has it)
auth_run                 →  state == "ready"
```

Each call returns `{state, next_step, last_error, keychain_lookup, connection_state, unsynced_seconds, sync_stalled}` (the last three: see [When telegram-all stops syncing](#when-telegram-all-stops-syncing)). `next_step.required_args` tells you exactly which arg the next call needs. `last_error` surfaces auto-fire failures (e.g., `FLOOD_WAIT_30`). `keychain_lookup` is null unless TDLib waits for the phone number or the 2FA password and the last Keychain lookup for that step found nothing; it then says which item and why: `{"credential": "password", "outcome": "not_stored" | "timed_out" | "unavailable"}` (`timed_out` usually means a locked Keychain). It never contains the value. While TDLib waits for the 2FA password, `next_step.hint` asks for the Keychain item first and mentions the `password` argument last, because an argument passes through the conversation. While TDLib is logging out or closing, `state` is `closing` and `next_step` asks you to call `auth_status` again in a few seconds; `closed` means TDLib has finished closing.

### Legacy: per-step manual flow

```
Step 1: auth_set_parameters  →  Provide api_id and api_hash
Step 2: auth_send_phone      →  Provide your phone number (+886...)
Step 3: auth_send_code        →  Enter the code received in Telegram
Step 3b: auth_send_password   →  (Only if 2FA is enabled)
Done:   auth_status           →  Should show {state: "ready", next_step: null}
```

Session data is stored in: `~/Library/Application Support/che-telegram-all-mcp/tdlib/`

## Several sessions (0.6.0+)

Several Claude Code sessions can run this server at the same time ([#58](https://github.com/PsychQuant/che-msg/issues/58)). TDLib allows one process per database, so the servers share it:

- A server does not open TDLib at startup. It opens TDLib on the first call that needs it, taking the lock `~/.cache/che-telegram-all-mcp.tdlib.lock` (owner PID in `~/.cache/che-telegram-all-mcp.tdlib.owner`), and closes it after `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` seconds without calls, never during a call. It also closes TDLib and releases the lock when the MCP connection ends.
- While another process holds TDLib, five read tools — `get_chats`, `search_chats`, `get_chat_history`, `search_messages`, `dump_chat_to_markdown` — are answered from TDLib's local cache, read-only, and `archive_chat_to_markdown` archives from it (no media downloads, no sender names, `bookmark_safe: false`; see [Archive a chat](#archive-a-chat-incrementally)). The answer carries a second text item starting `source: local-cache`, naming the holder, the number of records that could not be decoded, and per chat the date of the newest cached message; the cache holds only what TDLib has loaded, so newer messages can exist on Telegram.
- `get_me`, `get_user`, `get_contacts`, `get_chat` and `get_chat_members` return `local_reader_unsupported`; write tools, `download_message_media`, `auth_*` and `logout` return `tdlib_in_use` with `lock_holder_pid`. Retry after the holder releases TDLib.
- The reader accepts only the TDLib version it was verified against (1.8.60); otherwise it returns `local_reader_unavailable` with reason `unsupported_tdlib_version` rather than guess.
- A wrapper from plugin che-telegram-mcp 1.4.x or older still holds its own lock directory (`~/.cache/che-telegram-all-mcp.lock`); 0.6.0 servers treat it as a holder while that wrapper runs.

The `telegram-all` CLI takes the same lock ([#61](https://github.com/PsychQuant/che-msg/issues/61)). While a session, or another `telegram-all` command, holds TDLib, a command opens nothing: it prints `TDLib is in use by process <PID>` (or `another process (unknown holder)` when the holder recorded no PID) on stderr and exits with status 1; try again once that session has gone idle. A command closes TDLib before it releases the lock; if TDLib does not close within 30 seconds, it keeps the lock until it exits and exits with status 1, even when the command itself succeeded. The CLI never reads the Keychain ([#96](https://github.com/PsychQuant/che-msg/issues/96)): give the phone number and the 2FA password with `auth-phone` and `auth-password`, or in the environment, which it still sends automatically.

## When telegram-all stops syncing

TDLib can stay logged in while it no longer receives anything from Telegram ([#63](https://github.com/PsychQuant/che-msg/issues/63)). The usual cause: Telegram has invalidated the session because the same TDLib session was used in two places at once (two processes, or a copy of the database directory on another machine). TDLib then keeps `authorizationStateReady` and stays in `connectionStateUpdating`, retrying in the background forever; without a check, every read returns old data.

How to tell:

- An answer from a read tool carries a second text item starting `sync: not-synced`, naming TDLib's connection state and how many seconds TDLib has been open without syncing. Without a network (`connectionStateWaitingForNetwork`, `connectionStateConnectingToProxy`) it says to check the network. The call that opens TDLib first waits up to 10 seconds for it to sync.
- `auth_status` returns `connection_state`, `unsynced_seconds` and `sync_stalled`. `sync_stalled` is `true` once TDLib has been logged in and **updating** for 120 seconds without finishing (counted across idle closes; time offline never counts). `next_step` then points to `logout`, with a hint to ask the user first.

To recover (a new login sends a code to your account, so it is always your action), in this order:

1. Call `logout`. It sends no log-out request to Telegram: it closes TDLib (up to 30 seconds) and renames the database directory to `tdlib.invalidated-<UTC timestamp>` next to it. If TDLib was already closed (idle), `logout` first opens it like any other call, which connects to Telegram and can take up to about a minute more. Nothing is deleted — the renamed directory is a backup of the local messages. It still holds a working auth key: do not move it back or copy it elsewhere while a new session is in use, or the duplicate happens again. Remove it by hand once the new session works.
2. **Then** open Telegram → Settings → Devices on your phone and end the stalled session and any session you do not recognise, so the new login is not invalidated the same way. Do this only after step 1: once a session is ended, TDLib still running on its directory can lose its authorization and clear that directory itself, and the backup would be empty.
3. Log in again with `auth_run`. `telegram-all auth-phone` / `auth-code` work only while no session holds TDLib: any telegram-all tool call after `logout` opens TDLib again and holds it until that session's idle close (600 seconds by default, never when `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` is 0) or until the session ends, and meanwhile the CLI exits with status 1, naming the holder. To log in with the CLI, end those sessions first or wait for their idle close.

## Errors from TDLib, and chats TDLib has not loaded

When TDLib answers a tool with an error, the tool returns `{"type": "tdlib_error", "code": <int>, "message": <string>}` with `isError: true`, for example `{"type":"tdlib_error","code":400,"message":"User not found"}`; the `telegram-all` CLI prints `TDLib error <code>: <message>` ([#71](https://github.com/PsychQuant/che-msg/issues/71)). A 406 comes with an empty message: TDLib asks that it never be shown.

TDLib reads only chats it has loaded, and after a new login it has loaded few. A tool given a `chat_id` (`get_chat`, `get_chat_history`, `search_messages`, `dump_chat_to_markdown`, the message, group and read-state tools, and the archive tools) first makes that chat known: when TDLib does not know it, the chat is created from its id as a user, basic group, supergroup or channel chat. That changes only TDLib's local state; nothing is sent to the chat. When TDLib has no information about the chat's user or group, the result keeps TDLib's original error and adds a `hint`:

```json
{"type": "tdlib_error", "code": 400, "message": "Chat not found",
 "hint": "TDLib has no information about chat -1001234567890, so it could not load the chat by its id. Call get_chats (CLI: telegram-all chats) with a limit large enough to reach this chat, so that TDLib loads it, then try again. get_chats reads only the main chat list, so it does not load a chat archived in Telegram."}
```

Any other failure comes back as TDLib reported it, without a hint: for example `{"type":"tdlib_error","code":400,"message":"Can't access the chat"}` for a private supergroup or channel the account has left or is banned from, a rate limit, or TDLib's own error for an id that no chat can be created from (a secret chat id: this server runs TDLib with secret chats off).

Whether TDLib can create a chat with a user or group it has never seen, on a database fresh from a new login, has not been checked on a live account yet; until it is, a chat id kept from an earlier session or a config file may still need that `get_chats` call first.

## Tools (30)

### Authentication (7)

| Tool | Description |
|------|-------------|
| `auth_set_parameters` | Set API credentials (api_id + api_hash) |
| `auth_send_phone` | Send phone number to start auth |
| `auth_send_code` | Enter verification code |
| `auth_send_password` | Enter 2FA password (if enabled) |
| `auth_status` | Check current auth state |
| `auth_run` | Run the whole login in one tool, repeated until ready |
| `logout` | Local reset: close TDLib and rename its database directory aside (no request to Telegram, nothing deleted); ask the user first |

### User Info (3)

| Tool | Description |
|------|-------------|
| `get_me` | Get your own profile |
| `get_user` | Get info about any user |
| `get_contacts` | List your contacts |

### Chat Operations (3)

| Tool | Description |
|------|-------------|
| `get_chats` | List recent conversations |
| `get_chat` | Get details about a chat |
| `search_chats` | Search chats by name |

### Messages (7)

| Tool | Description |
|------|-------------|
| `get_chat_history` | Read message history (single page, thin wrapper) |
| `dump_chat_to_markdown` | Export full chat history to a `.md` file (auto-paginates + date filter + sender resolve + Markdown format). Writes to `output_path` — absolute, ending in `.md`, no `..` component, inside `CHE_TELEGRAM_ALL_EXPORT_ROOT` when that is set — replacing an existing file, and returns summary metadata. |
| `send_message` | Send a text message |
| `edit_message` | Edit your message |
| `delete_messages` | Delete messages |
| `forward_messages` | Forward messages |
| `search_messages` | Search within a chat |

### Group Management (7)

| Tool | Description |
|------|-------------|
| `get_chat_members` | List group members |
| `pin_message` | Pin a message |
| `unpin_message` | Unpin a message |
| `set_chat_title` | Change chat title |
| `set_chat_description` | Change chat description |
| `create_group` | Create a new basic group |
| `add_chat_member` | Add a member to a group |

### Read State (1)

| Tool | Description |
|------|-------------|
| `mark_as_read` | Mark messages as read |

### Archive (2)

| Tool | Description |
|------|-------------|
| `archive_chat_to_markdown` | Archive a chat incrementally into per-day Markdown files and download its media under `output_dir`; returns a manifest without message text ([#69](https://github.com/PsychQuant/che-msg/issues/69)) |
| `download_message_media` | Download one message's media into the same layout and return its path and size ([#17](https://github.com/PsychQuant/che-msg/issues/17)) |

## Usage Examples

Once authenticated, you can ask Claude things like:

- "Show me my recent chats"
- "Read the last 20 messages from my chat with John"
- "Search for messages about 'meeting' in the team group"
- "Send 'I'll be late' to the family group"
- "Forward the last message from Alice to my Saved Messages"
- "Get my contact list"
- "Dump my chat with 小明 from 2026-04-01 to 2026-04-15 to `/tmp/example-chat.md`" → triggers `dump_chat_to_markdown`

### Dump chat to Markdown

The `dump_chat_to_markdown` tool writes a single Markdown file per invocation and returns summary metadata. Example AI-facing call shape:

```jsonc
dump_chat_to_markdown({
  "chat_id": 123456789,
  "output_path": "/tmp/example-chat.md",
  "max_messages": 5000,             // optional, default 5000
  "since_date": "2026-03-01",        // optional
  "until_date": "2026-04-15",        // optional
  "self_label": "我"                 // optional, default "我"
})
```

`output_path` must be an absolute path (`~` is not expanded) with no `..` component, ending in `.md` in any letter case; anything else is refused before a message is read, for example `Error: output_path must end in .md; got "/Users/me/.zshrc"`. An existing file at that path is replaced. With `CHE_TELEGRAM_ALL_EXPORT_ROOT` set, the path must also lie inside that directory once symbolic links are resolved ([#21](https://github.com/PsychQuant/che-msg/issues/21)).

Response (summary metadata only — no Markdown body):

```jsonc
{
  "path": "/tmp/example-chat.md",
  "message_count": 327,
  "date_range": { "since": "2026-03-01", "until": "2026-04-15" },
  "senders": [{ "user_id": 12345, "display_name": "小明 王" }, ...]
}
```

Output Markdown format (excerpt):

```markdown
# 對話：小明 王 (chat_id=123456789)
匯出時間：2026-04-15 23:40:00　訊息數：327　since 2026-03-01　until 2026-04-15

---

## 2026-04-14

**14:32 我**：
會議幾點開始？

**14:33 小明 王**：
下午兩點

**14:35 小明 王**：
[photo]

**14:36 小明 王**：
[photo] 今天的菜單

**14:37 小明 王**：
[poll] 晚餐吃什麼？
- 麵
- 飯

**14:38 小明 王**：
[location] 25.0478,121.5319
```

A media message renders as its placeholder, followed by its caption when it has one. A poll renders its question and then one `- <option>` line per answer option, a sticker its emoji, and a location `<latitude>,<longitude>` exactly as TDLib reports them — not rounded, never in exponent form ([#82](https://github.com/PsychQuant/che-msg/issues/82)). In TDLib mode the message JSON (`get_chat_history`, `search_messages`) carries the same details: `question` and `options` for a poll, `emoji` for a sticker, `latitude` and `longitude` for a location. A dump answered from the local cache (while another process holds TDLib) has no captions and none of these details, and audio there reads `[other]`.

### Archive a chat incrementally

`archive_chat_to_markdown` keeps an archive that grows with each run ([#69](https://github.com/PsychQuant/che-msg/issues/69)). The plugin's `/archive-telegram` skill drives it from a config file; the tool can also be called directly:

```
archive_chat_to_markdown({
  chat_id: 123456789,
  output_dir: "/path/to/project/archives/telegram",  // absolute
  after_message_id: 9000,          // bookmark: only newer messages (wins over since_date)
  since_date: "2026-01-01",        // first run without a bookmark (default: whole history)
  utc_offset: "+08:00",            // decides each message's day (default: the server's offset)
  max_media_bytes: 52428800,       // skip larger media (default: no limit)
  retry_media_message_ids: [7100]  // media that failed last time
})
```

It writes:

- `<output_dir>/<chat_id>/YYYY-MM-DD.md` — frontmatter `chat_id`, `date`, `utc_offset`, then one block per message: an anchor `<!-- msg:<message_id> -->` and `**HH:mm sender**：` followed by the text (a block written from the local cache has `<!-- provisional: local-cache -->` between the two, see **Other sessions**). Re-runs merge into the existing file: blocks already there are kept as they are (except provisional ones, which a run through TDLib replaces), new ones are added in message-id order, and the file is replaced atomically, so running twice changes nothing.
- `<output_dir>/<chat_id>/media/<message_id>/` — the message's photo (`photo.jpg`), video, document (original file name), audio, voice note, video note, animation or sticker, downloaded completely through TDLib and copied there. A media block reads `[photo](media/<message_id>/) caption`, so the link is right before the file arrives. A directory that already holds a file is not downloaded again. Polls, stickers and locations keep their details as in the dump — `[poll] <question>` followed by `- <option>` lines, `[sticker](media/<message_id>/) <emoji>`, `[location] <latitude>,<longitude>` ([#82](https://github.com/PsychQuant/che-msg/issues/82)); a block written before that keeps its bare `[poll]`, `[sticker](…)` or `[location]`, because blocks already in a day file are never rewritten.

The result is a manifest only — `files` (day files this call added messages to or upgraded provisional blocks in), `new_messages`, `media_messages` (new messages whose type carries a file), `upgraded_messages` (provisional blocks replaced, see below), `newest_message_id` and `newest_message_file` (the day file holding it, written this time or not — check the newest anchor there), `source`, `complete`, `bookmark_safe` (with `bookmark_unsafe_reason`), `media_downloaded`, `media_skipped` (`message_id` and `size`), `media_failed_ids`, `media_pending_local_cache`, `undated_messages_skipped` (messages from the local cache that had no date and were not written; a later TDLib run adds them), `media_retried_ids` and `media_gone_ids` when ids were retried, and `stopped_reason` / `retry_after_seconds` when it stopped early. It never contains message text.

**Bookmark rule.** Store `newest_message_id` as the next `after_message_id` only when `bookmark_safe` is `true`: the walk reached the previous bookmark (or `since_date`, or the start of the chat), the source was TDLib and TDLib was synced. Otherwise keep the old bookmark — the next run fetches the same range again and the merge drops what is already there. TDLib waits out short rate limits itself and reports a longer one as `429 "Too Many Requests: retry after N"`: a wait of up to 60 seconds is waited out once more; a longer one stops the run with `complete: false`, `stopped_reason: "flood_wait"` and `retry_after_seconds`, keeping the files written so far (a re-run walks from the newest message again; pages TDLib has already loaded come from its local database, see [#74](https://github.com/PsychQuant/che-msg/issues/74)). A failed media download is listed in `media_failed_ids` and does not affect the bookmark; pass those ids as `retry_media_message_ids` next time. A retried id whose message no longer exists comes back in `media_gone_ids` instead (at the pinned TDLib, `getMessage` answers a missing message with 404 `Not Found`; 400 `Message not found`, which other TDLib requests use, is accepted too), so it drops out of the next retry; any other failure, a rate limit included, stays in `media_failed_ids` ([#75](https://github.com/PsychQuant/che-msg/issues/75)).

**Other sessions.** While another process holds TDLib, the archive is written from TDLib's local cache: senders are `User <id>`, captions and poll, sticker and location details are missing, audio reads `[other]`, no media is downloaded (`media_pending_local_cache` counts it), and `bookmark_safe` is `false` with reason `local-cache`. Every block written this way is **provisional**: the line right after its anchor is exactly `<!-- provisional: local-cache -->`, then the usual header and body. The anchor itself is unchanged, so anything that splits a day file at `<!-- msg:<id> -->` lines (an older binary, the skill's check, a search) finds the same blocks and can tell a provisional one by its second line. Because the bookmark did not move, the next run through TDLib fetches the same range again: it adds missing messages, downloads the media, and replaces each provisional block with the full one (no marker); the manifest counts these in `upgraded_messages` (not in `new_messages`) and lists their day files in `files` ([#72](https://github.com/PsychQuant/che-msg/issues/72)). A run from the cache never replaces a block, and no run rewrites a block without the marker. A provisional block belongs to the tool: anything you add inside one is gone after the upgrade. Blocks below a bookmark are upgraded by running once with an older `after_message_id`. Blocks that v0.8.0 wrote from the cache have no marker and stay as they are. `/archive-telegram` still stops by default while another session holds TDLib, since a cache run downloads no media.

**Day files.** Written with the offset the archive started with: before reading anything, a call whose `utc_offset` (±18:00 at most) differs from a day file already in `<chat_id>/` — or meets a day file it cannot read, without a readable offset, or with CRLF line endings in its frontmatter — is refused, naming the recorded offset. A day file that is not a regular file (a symbolic link, FIFO, socket or directory) is refused at the same point, and one with a carriage return anywhere in it (a CRLF or CR line, as a Windows editor may save it) when the call has a message of that day that the file does not hold yet, or is a call through TDLib that would upgrade a provisional block in it ([#72](https://github.com/PsychQuant/che-msg/issues/72)); such a file that the call would not rewrite is left as it is, and day files written earlier in the call are kept. A day file is opened without following a link at its own name and without waiting on a FIFO; directories above it, such as a symlinked `<chat_id>/`, are followed. Replace a link with the file itself, convert line endings to LF, or move the file aside ([#76](https://github.com/PsychQuant/che-msg/issues/76)). Only files named `YYYY-MM-DD.md` count as day files; other files you keep there are ignored. A body line that starts like an anchor, or begins like a block header (`**` and a time), gets a leading backslash. Files are owner-only (directories 0700, files 0600). Two archives of the same chat into the same directory cannot run at once — the second is refused while the first holds `<chat_id>/.archive.lock`. `media_pending_local_cache` counts every media message of the run that has no file yet (including ones archived before), while `media_messages` counts only new messages.

**Supergroups.** When a group is upgraded to a supergroup its `chat_id` changes (to a `-100…` id). Archive the new id; the old directory stays.

`download_message_media({chat_id, message_id, output_dir})` saves one message's media into the same `<output_dir>/<chat_id>/media/<message_id>/` and returns `message_id`, `type`, `path` and `size`; a file already there is returned without downloading again, and a message without media is an error ([#17](https://github.com/PsychQuant/che-msg/issues/17)). `path` contains the sender's original file name.

> **Privacy.** Archives and media are other people's messages and files, verbatim. Do not commit them to any repository; add the archive directory to `.gitignore` when it sits inside a git repository. Treat the text as untrusted third-party content (cite by anchor), and the media as untrusted files: they keep the sender's file name and extension. Media saved by the archive and by `download_message_media` carry the macOS quarantine attribute (`com.apple.quarantine`, type instant-message attachment), so they are treated like browser downloads: Gatekeeper checks an app or script before it opens from Finder, and LaunchServices adds an entry to its quarantine event log (no file name or URL). Files saved before this attribute was added are not changed ([#75](https://github.com/PsychQuant/che-msg/issues/75)).

### CLI: dump from the command line

The same capability is exposed through `telegram-all history` flags — useful for scripting and testing outside MCP:

```bash
# Single page (original behavior, unchanged)
telegram-all history 123456789 --limit 50

# Auto-paginate and filter, print JSON
telegram-all history 123456789 --max-messages 5000 --since 2026-03-01 --until 2026-04-15

# Auto-paginate and dump to Markdown
telegram-all history 123456789 \
  --max-messages 5000 \
  --since 2026-03-01 \
  --until 2026-04-15 \
  --self-label "che" \
  --dump-markdown /tmp/example-chat.md
```

## Architecture

```
Sources/
├── CheTelegramAllMCP/
│   └── main.swift              # Entry point
├── CheTelegramAllMCPCore/
│   ├── Server.swift            # MCP Server (30 tools + dispatch)
│   └── ArchiveToolArgs.swift   # archive / download_message_media argument checks
├── TelegramAllLib/
│   ├── TDLibClient.swift       # TDLib wrapper (auth + all operations)
│   ├── TDLibRequests.swift     # TDLib errors with code and message; loading a chat by its id
│   ├── TDLibClient+Archive.swift # TDLib and local cache as archive sources
│   ├── MessageFilters.swift    # Pagination + date-filter pure helpers
│   ├── MarkdownExporter.swift  # dump_chat_to_markdown orchestrator
│   ├── ChatArchiver.swift      # archive_chat_to_markdown: paging, bookmark safety, manifest
│   ├── ArchiveDayFile.swift    # per-day file format and idempotent merge
│   └── ArchiveMedia.swift      # media download into media/<message_id>/
└── telegram-all/
    ├── TelegramAllCLI.swift    # ArgumentParser subcommands
    └── AuthHelper.swift
```

- **TDLib** via [TDLibKit](https://github.com/Swiftgram/TDLibKit) — native Swift wrapper
- MCP SDK for stdio transport
- Session persisted in `~/Library/Application Support/`

## Security Notes

- This MCP operates as **your personal Telegram account**. It can read all your private chats.
- API credentials and session are stored locally only.
- `logout` is a local reset only: the session stays valid on Telegram's side, and the renamed `tdlib.invalidated-*` directory still holds a working auth key and the cached messages. To revoke access, end the session in Telegram → Settings → Devices, then delete the `tdlib.invalidated-*` directories (and `tdlib/`, if you are done with this Mac) under `~/Library/Application Support/che-telegram-all-mcp/` by hand.
- Never share the TDLib database directory with others.
- `archive_chat_to_markdown`, `download_message_media` and `dump_chat_to_markdown` write other people's messages and files to disk. Keep their output out of public repositories.
- A chat participant chooses the text `dump_chat_to_markdown` writes, so a caller steered by such text could aim it at a file the shell or the system loads. The tool writes only absolute `.md` paths without `..`, which keeps it off shell and system files, but not off Markdown files that agents load as instructions — `CLAUDE.md`, `AGENTS.md`, `SKILL.md`, `~/.claude/commands/*.md` — nor off any other `.md` file it may write. Set `CHE_TELEGRAM_ALL_EXPORT_ROOT` to keep dumps inside one directory that holds none of these. The MCP client's confirmation of each tool call remains the last check.

## License

MIT
