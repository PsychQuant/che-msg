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

Requires Swift 5.9+ and macOS 13+.

> **First build will download ~300MB** of TDLibFramework binary. This is normal.

```bash
git clone https://github.com/PsychQuant/che-msg.git
cd che-msg/che-telegram-all-mcp
swift build -c release
```

Binary location: `.build/release/CheTelegramAllMCP`

## Installation

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
| `TELEGRAM_PHONE` | No | Phone number in international format (e.g., `+886912345678`). Auto-fired when state is `waitingForPhoneNumber`. Useful for SSH / remote setup. |
| `TELEGRAM_2FA_PASSWORD` | No | 2FA password. Auto-fired when state is `waitingForPassword`. |
| `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` | No | Seconds TDLib may stay idle before the server closes it and releases the lock (default `600`; `0` keeps it open). A non-numeric or negative value falls back to 600 with a warning on stderr. |

> SMS verification code is **never** auto-fired from environment — it must be supplied via `auth_run(code: "...")` or `auth_send_code(code: "...")` in a one-shot delivery.
>
> If env vars are not set, you can still drive the flow manually via `auth_run` (or the per-step `auth_set_parameters` / `auth_send_phone` / `auth_send_password` tools).

## Authentication Flow

Authentication is a **one-time process**. After the first login, TDLib stores the session locally and you won't need to authenticate again.

### Recommended: `auth_run` (single tool, repeat until ready)

Set env vars for the steps you want auto-fired (`TELEGRAM_API_ID` / `TELEGRAM_API_HASH` / `TELEGRAM_PHONE` / `TELEGRAM_2FA_PASSWORD`), then call `auth_run` repeatedly:

```
auth_run                 →  fires auto-set params (if env present)
auth_run                 →  fires auto-send phone (if env present)
auth_run(code: "12345")  →  caller MUST supply SMS code
auth_run                 →  fires auto-send 2FA password (if env present)
auth_run                 →  state == "ready"
```

Each call returns `{state, next_step, last_error, connection_state, unsynced_seconds, sync_stalled}` (the last three: see [When telegram-all stops syncing](#when-telegram-all-stops-syncing)). `next_step.required_args` tells you exactly which arg the next call needs. `last_error` surfaces auto-fire failures (e.g., `FLOOD_WAIT_30`).

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
- `get_me`, `get_user`, `get_contacts`, `get_chat` and `get_chat_members` return `local_reader_unsupported`; write tools, `download_message_media`, `auth_*` and `logout` return `tdlib_in_use` with `lock_holder_pid`. Retry after the holder goes idle.
- The reader accepts only the TDLib version it was verified against (1.8.60); otherwise it returns `local_reader_unavailable` with reason `unsupported_tdlib_version` rather than guess.
- A wrapper from plugin che-telegram-mcp 1.4.x or older still holds its own lock directory (`~/.cache/che-telegram-all-mcp.lock`); 0.6.0 servers treat it as a holder while that wrapper runs.

The `telegram-all` CLI does not take this lock yet ([#61](https://github.com/PsychQuant/che-msg/issues/61)); do not run it while a session holds TDLib.

## When telegram-all stops syncing

TDLib can stay logged in while it no longer receives anything from Telegram ([#63](https://github.com/PsychQuant/che-msg/issues/63)). The usual cause: Telegram has invalidated the session because the same TDLib session was used in two places at once (two processes, or a copy of the database directory on another machine). TDLib then keeps `authorizationStateReady` and stays in `connectionStateUpdating`, retrying in the background forever; without a check, every read returns old data.

How to tell:

- An answer from a read tool carries a second text item starting `sync: not-synced`, naming TDLib's connection state and how many seconds TDLib has been open without syncing. Without a network (`connectionStateWaitingForNetwork`, `connectionStateConnectingToProxy`) it says to check the network. The call that opens TDLib first waits up to 10 seconds for it to sync.
- `auth_status` returns `connection_state`, `unsynced_seconds` and `sync_stalled`. `sync_stalled` is `true` once TDLib has been logged in and **updating** for 120 seconds without finishing (counted across idle closes; time offline never counts). `next_step` then points to `logout`, with a hint to ask the user first.

To recover (a new login sends a code to your account, so it is always your action), in this order:

1. Call `logout`. It sends no log-out request to Telegram: it closes TDLib (up to 30 seconds) and renames the database directory to `tdlib.invalidated-<UTC timestamp>` next to it. If TDLib was already closed (idle), `logout` first opens it like any other call, which connects to Telegram and can take up to about a minute more. Nothing is deleted — the renamed directory is a backup of the local messages. It still holds a working auth key: do not move it back or copy it elsewhere while a new session is in use, or the duplicate happens again. Remove it by hand once the new session works.
2. **Then** open Telegram → Settings → Devices on your phone and end the stalled session and any session you do not recognise, so the new login is not invalidated the same way. Do this only after step 1: once a session is ended, TDLib still running on its directory can lose its authorization and clear that directory itself, and the backup would be empty.
3. Log in again with `auth_run` (or `telegram-all auth-phone` / `auth-code`).

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
| `dump_chat_to_markdown` | Export full chat history to a `.md` file (auto-paginates + date filter + sender resolve + Markdown format). Writes to `output_path`, returns summary metadata. |
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
```

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

- `<output_dir>/<chat_id>/YYYY-MM-DD.md` — frontmatter `chat_id`, `date`, `utc_offset`, then one block per message: an anchor `<!-- msg:<message_id> -->` and `**HH:mm sender**：` followed by the text. Re-runs merge into the existing file: blocks already there are kept as they are, new ones are added in message-id order, and the file is replaced atomically, so running twice changes nothing.
- `<output_dir>/<chat_id>/media/<message_id>/` — the message's photo (`photo.jpg`), video, document (original file name), audio, voice note, video note, animation or sticker, downloaded completely through TDLib and copied there. A media block reads `[photo](media/<message_id>/) caption`, so the link is right before the file arrives. A directory that already holds a file is not downloaded again.

The result is a manifest only — `files`, `new_messages`, `media_messages`, `newest_message_id`, `source`, `complete`, `bookmark_safe` (with `bookmark_unsafe_reason`), `media_downloaded`, `media_skipped` (`message_id` and `size`), `media_failed_ids`, `media_pending_local_cache`, `media_retried_ids`, and `stopped_reason` / `retry_after_seconds` when it stopped early. It never contains message text.

**Bookmark rule.** Store `newest_message_id` as the next `after_message_id` only when `bookmark_safe` is `true`: the walk reached the previous bookmark (or `since_date`, or the start of the chat), the source was TDLib and TDLib was synced. Otherwise keep the old bookmark — the next run fetches the same range again and the merge drops what is already there. TDLib waits out short rate limits itself and reports a longer one as `429 "Too Many Requests: retry after N"`: a wait of up to 60 seconds is waited out once more; a longer one stops the run with `complete: false`, `stopped_reason: "flood_wait"` and `retry_after_seconds`, keeping the files written so far (a re-run walks from the newest message again; pages TDLib has already loaded come from its local database, see [#74](https://github.com/PsychQuant/che-msg/issues/74)). A failed media download is listed in `media_failed_ids` and does not affect the bookmark; pass those ids as `retry_media_message_ids` next time.

**Other sessions.** While another process holds TDLib, the archive is written from TDLib's local cache: senders are `User <id>`, captions are missing, audio reads `[other]`, no media is downloaded (`media_pending_local_cache` counts it), and `bookmark_safe` is `false` with reason `local-cache`. The next TDLib run fetches the range again, adds missing messages and downloads the media, but **does not rewrite blocks already written** — the cache-written ones stay as they are ([#72](https://github.com/PsychQuant/che-msg/issues/72)). `/archive-telegram` therefore stops while another session holds TDLib.

**Day files.** Written with the offset the archive started with: merging at another `utc_offset` (±18:00 at most) is refused and names the recorded offset. A body line that starts like an anchor or reads like a block header (`**HH:mm name**：`) gets a leading backslash. Files are owner-only (directories 0700, files 0600). Two archives of the same chat into the same directory cannot run at once — the second is refused while the first holds `<chat_id>/.archive.lock`. `files` in the manifest lists the day files this call wrote.

**Supergroups.** When a group is upgraded to a supergroup its `chat_id` changes (to a `-100…` id). Archive the new id; the old directory stays.

`download_message_media({chat_id, message_id, output_dir})` saves one message's media into the same `<output_dir>/<chat_id>/media/<message_id>/` and returns `message_id`, `type`, `path` and `size`; a file already there is returned without downloading again, and a message without media is an error ([#17](https://github.com/PsychQuant/che-msg/issues/17)). `path` contains the sender's original file name.

> **Privacy.** Archives and media are other people's messages and files, verbatim. Do not commit them to any repository; add the archive directory to `.gitignore` when it sits inside a git repository. Treat the text as untrusted third-party content (cite by anchor), and the media as untrusted files: they keep the sender's file name and extension.

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

## License

MIT
