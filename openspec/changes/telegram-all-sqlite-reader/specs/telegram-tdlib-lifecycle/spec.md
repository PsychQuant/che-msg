## Purpose

Defines when the `che-telegram-all-mcp` server opens and closes its TDLib instance, how it decides whether another process holds TDLib, and how each MCP tool responds while TDLib is held elsewhere. It exists so that several Claude Code sessions can enable telegram-all at once without the first session to start blocking all others.

## ADDED Requirements

### Requirement: TDLib opens on first use, not at startup

The server SHALL NOT create a TDLib client or acquire the TDLib lock during startup. The server SHALL open TDLib only when a tool that needs TDLib is called and the TDLib lock is free.

#### Scenario: Server starts without holding TDLib

- **WHEN** the `che-telegram-all-mcp` server starts and no tool has been called
- **THEN** the lock file `~/.cache/che-telegram-all-mcp.tdlib.lock` is not locked by the server process and no TDLib client exists in that process

#### Scenario: First tool call with a free lock opens TDLib

- **WHEN** `get_chats` is called and no other process holds the TDLib lock
- **THEN** the server acquires the lock, writes its PID to `~/.cache/che-telegram-all-mcp.tdlib.owner`, opens TDLib, and returns the result produced by TDLib

### Requirement: TDLib closes after an idle period and releases the lock

The server SHALL close TDLib and release the TDLib lock after no tool call has used TDLib for the idle timeout. The idle timeout SHALL be read from the environment variable `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` in seconds, SHALL default to 600, and the value `0` SHALL disable idle closing. The server SHALL release the lock only after TDLib reports `authorizationStateClosed`.

#### Scenario: Idle timeout closes TDLib

- **WHEN** the server holds TDLib and no tool call has used TDLib for longer than the idle timeout
- **THEN** the server closes TDLib, waits for `authorizationStateClosed`, and releases the TDLib lock

#### Scenario: A call after idle close reopens TDLib

- **WHEN** a tool that needs TDLib is called after the server closed TDLib for idleness and the lock is free
- **THEN** the server reacquires the lock, reopens TDLib, and serves the call through TDLib

##### Example: idle close and reopen timeline

| Time (s) | Event | Server holds lock | TDLib open |
| -------- | ----- | ----------------- | ---------- |
| 0 | server starts | no | no |
| 10 | `get_chats` called | yes | yes |
| 400 | `get_chat_history` called | yes | yes |
| 1000 | idle check: 600 s since last call at 400 | released after `authorizationStateClosed` | no |
| 1200 | `search_messages` called, lock free | yes | yes |

#### Scenario: Close that does not finish keeps the lock

- **WHEN** TDLib does not report `authorizationStateClosed` within 30 seconds of an idle close request
- **THEN** the server keeps the TDLib lock, writes one line to stderr, and retries at the next idle check

##### Example: idle timeout values

| `CHE_TELEGRAM_ALL_IDLE_TIMEOUT` | Effective timeout | Notes |
| ------------------------------- | ----------------- | ----- |
| unset | 600 seconds | default |
| `120` | 120 seconds | custom |
| `0` | never closes | current always-open behavior |
| `abc` | 600 seconds | invalid value, one stderr warning |
| `-5` | 600 seconds | negative value, one stderr warning |

### Requirement: Lock ownership honors the legacy wrapper lock

The server SHALL treat TDLib as held by another process when either an exclusive non-blocking `flock` on `~/.cache/che-telegram-all-mcp.tdlib.lock` fails, or the legacy wrapper lock directory `~/.cache/che-telegram-all-mcp.lock` contains an `owner.pid` naming a live process other than the server. The server SHALL NOT open TDLib while TDLib is held by another process.

#### Scenario: Legacy wrapper lock with a live owner blocks opening

- **WHEN** `~/.cache/che-telegram-all-mcp.lock/owner.pid` contains the PID of a running process and a tool that needs TDLib is called
- **THEN** the server treats TDLib as held by that PID and does not open TDLib

#### Scenario: Legacy wrapper lock with a dead owner is ignored

- **WHEN** `~/.cache/che-telegram-all-mcp.lock/owner.pid` contains a PID with no running process and the flock is free
- **THEN** the server acquires the flock and opens TDLib

### Requirement: Tool routing while TDLib is held by another process

While another process holds TDLib, the server SHALL route each tool as follows: `get_chats`, `search_chats`, `get_chat_history`, `search_messages` and `dump_chat_to_markdown` SHALL be answered by the local reader; `get_me`, `get_user`, `get_contacts`, `get_chat` and `get_chat_members` SHALL return a `local_reader_unsupported` error; every other tool, including `send_message`, `auth_run` and `logout`, SHALL return a `tdlib_in_use` error. Each error SHALL be an MCP tool result with `isError: true` whose single content item is a JSON object with a `type` field.

#### Scenario: Write tool while TDLib is held elsewhere

- **WHEN** `send_message` is called while process 4242 holds TDLib
- **THEN** the result has `isError: true` and content `{"type":"tdlib_in_use","lock_holder_pid":4242,"message":...}`

#### Scenario: Unsupported read tool while TDLib is held elsewhere

- **WHEN** `get_user` is called while another process holds TDLib
- **THEN** the result has `isError: true` and content `{"type":"local_reader_unsupported","tool":"get_user","message":...}`

#### Scenario: Supported read tool while TDLib is held elsewhere

- **WHEN** `get_chat_history` is called while another process holds TDLib
- **THEN** the local reader answers the call and no TDLib client is created in the server process

##### Example: routing table

| Tool | TDLib free | TDLib held elsewhere |
| ---- | ---------- | -------------------- |
| `get_chats` | TDLib | local reader |
| `search_chats` | TDLib | local reader |
| `get_chat_history` | TDLib | local reader |
| `search_messages` | TDLib | local reader |
| `dump_chat_to_markdown` | TDLib | local reader |
| `get_me`, `get_user`, `get_contacts`, `get_chat`, `get_chat_members` | TDLib | `local_reader_unsupported` |
| `send_message`, `edit_message`, `delete_messages`, `forward_messages`, `pin_message`, `unpin_message`, `set_chat_title`, `set_chat_description`, `mark_as_read`, `create_group`, `add_chat_member` | TDLib | `tdlib_in_use` |
| `auth_set_parameters`, `auth_send_phone`, `auth_send_code`, `auth_send_password`, `auth_status`, `auth_run`, `logout` | TDLib | `tdlib_in_use` |

### Requirement: Wrapper starts the server regardless of other sessions

The plugin wrapper `che-telegram-all-mcp-wrapper.sh` SHALL NOT acquire a lock and SHALL NOT refuse to start because another session runs telegram-all. It SHALL start the server binary after its download and verification steps. The wrapper SHALL send signals only to the binary process it started itself and SHALL NOT read or write the shared PID file `~/.cache/che-telegram-all-mcp.pid`.

#### Scenario: Second session starts normally

- **WHEN** a second Claude Code session starts telegram-all while a first session's server holds TDLib
- **THEN** the second session's wrapper starts the server binary and the MCP connection succeeds

#### Scenario: Second wrapper leaves the first server running

- **WHEN** a second wrapper starts while a `CheTelegramAllMCP` process started by a first wrapper is running
- **THEN** the first `CheTelegramAllMCP` process is still running after the second wrapper has started its own binary

#### Scenario: Wrapper exit cleans up only its own binary

- **WHEN** a wrapper exits while two `CheTelegramAllMCP` processes are running, one of them started by that wrapper
- **THEN** the process started by that wrapper is terminated and the other process keeps running
