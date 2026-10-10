## ADDED Requirements

### Requirement: Server tracks whether TDLib is synced with Telegram

The server SHALL record every `updateConnectionState` that TDLib reports while it is open, and SHALL treat TDLib as **synced** only while the latest reported state is `connectionStateReady`. The server SHALL keep an **unsynced duration**: the total number of seconds TDLib has been open in this server process since TDLib last reported `connectionStateReady`. Time during which TDLib is closed SHALL NOT be counted. The unsynced duration SHALL reset to 0 whenever TDLib reports `connectionStateReady`. The server SHALL also keep an **updating duration**: the total number of seconds TDLib has reported `connectionStateUpdating` since it last reported `connectionStateReady`, counted the same way (only while open, kept across idle closes, reset to 0 on `connectionStateReady`); time in any other state (for example `connectionStateWaitingForNetwork`) SHALL NOT count toward it. Durations SHALL be measured with a monotonic clock, so a change of the system time cannot make them negative or jump. The server SHALL NOT read or interpret the message of any error with code 406 to decide whether TDLib is synced.

#### Scenario: Ready resets the unsynced duration

- **WHEN** TDLib reports `connectionStateUpdating`, stays in it for 30 seconds, then reports `connectionStateReady`
- **THEN** TDLib is synced and the unsynced duration is 0

#### Scenario: Offline time does not count toward the updating duration

- **WHEN** TDLib reports `connectionStateWaitingForNetwork` for 200 seconds, then `connectionStateUpdating` for 30 seconds
- **THEN** the unsynced duration is 230 seconds and the updating duration is 30 seconds

#### Scenario: Unsynced time accumulates across an idle close

- **WHEN** TDLib is opened, stays in `connectionStateUpdating` for 80 seconds, is closed after the idle timeout, and is opened again and stays in `connectionStateUpdating` for another 50 seconds
- **THEN** the unsynced duration is 130 seconds; the time TDLib was closed is not counted

##### Example: unsynced duration over time

| Event (seconds since server start) | Connection state | TDLib open | Unsynced duration after the event |
| --- | --- | --- | --- |
| 0 open | connecting | yes | 0 |
| 5 | updating | yes | 5 |
| 85 idle close | — | no | 85 |
| 600 open | updating | yes | 85 |
| 650 | updating | yes | 135 |
| 660 | ready | yes | 0 |

### Requirement: First use waits a bounded time for TDLib to sync

When the server opens TDLib to answer a tool call and authorization has settled at `ready`, the server SHALL wait until TDLib reports `connectionStateReady` or until 10 seconds have passed, whichever comes first, before handling the call. When authorization is not `ready`, the server SHALL NOT wait for the connection state. The wait SHALL apply only to the call that opened TDLib; calls made while TDLib is already open SHALL NOT wait.

#### Scenario: Sync completes within the bound

- **WHEN** a call opens TDLib, authorization is `ready`, and TDLib reports `connectionStateReady` after 2 seconds
- **THEN** the call is handled after about 2 seconds and its answer carries no sync note

#### Scenario: Sync does not complete within the bound

- **WHEN** a call opens TDLib, authorization is `ready`, and TDLib stays in `connectionStateUpdating`
- **THEN** the call is handled after 10 seconds and its answer carries the sync note

### Requirement: Answers from TDLib state when TDLib is not synced

When one of the read tools — `get_chats`, `search_chats`, `get_chat_history`, `search_messages`, `dump_chat_to_markdown`, `get_me`, `get_user`, `get_contacts`, `get_chat`, `get_chat_members` — is answered by the TDLib client, authorization is `ready`, the call succeeds, and TDLib is not synced at the time of answering, the result SHALL contain a second text item after the tool's own content. The item SHALL begin with the line `sync: not-synced` and SHALL state the latest connection state, the unsynced duration in whole seconds, and that messages and changes newer than what TDLib last received can be absent from the result. When the latest connection state is `connectionStateWaitingForNetwork` or `connectionStateConnectingToProxy`, the item SHALL also state that TDLib reports no connection to Telegram and to check the network or proxy. When the session is stalled (the latest connection state is `connectionStateUpdating` and the updating duration has reached 120 seconds), the item SHALL also state that a session invalidated by Telegram is the likely cause and that the remedy, after asking the user, is `logout` followed by `auth_run`. Other tools (authentication tools, `logout`, and tools that change data) SHALL NOT carry this item. When TDLib is synced, or the call fails, the result SHALL NOT contain this item. Results from the local cache (TDLib held by another process) keep their own source note and SHALL NOT carry this item.

#### Scenario: Read while TDLib is updating

- **WHEN** `get_chats` is answered by the TDLib client while TDLib is in `connectionStateUpdating` with an unsynced duration of 40 seconds
- **THEN** the result's second text item begins with `sync: not-synced`, names `connectionStateUpdating`, states 40 seconds, and states that newer messages can be absent

#### Scenario: Read while synced

- **WHEN** `get_chats` is answered by the TDLib client while TDLib is in `connectionStateReady`
- **THEN** the result contains only the tool's own content

#### Scenario: Long stall names the remedy and asks for the user

- **WHEN** `get_chat_history` is answered by the TDLib client while TDLib is in `connectionStateUpdating` with an updating duration of 125 seconds
- **THEN** the second text item states that a session invalidated by Telegram is the likely cause, says to ask the user first, and names `logout` followed by `auth_run`

#### Scenario: Offline is not a stall

- **WHEN** `get_chats` is answered while TDLib is in `connectionStateWaitingForNetwork` with an unsynced duration of 300 seconds
- **THEN** the second text item says to check the network and does not name `logout`

#### Scenario: Non-read tools carry no note

- **WHEN** `auth_status` or `send_message` succeeds through the TDLib client while TDLib is not synced
- **THEN** the result contains only the tool's own content

##### Example: sync note lines

| Connection state | Unsynced / updating duration | Note contains |
| --- | --- | --- |
| connectionStateReady | 0 / 0 | (no note) |
| connectionStateUpdating | 40 / 40 | `sync: not-synced`, `connectionStateUpdating`, `40 s`, newer messages can be absent |
| connectionStateUpdating | 125 / 125 | the above with `125 s`, plus likely cause: session invalidated by Telegram, ask the user, `logout` then `auth_run` |
| connectionStateWaitingForNetwork | 300 / 0 | `sync: not-synced`, `connectionStateWaitingForNetwork`, `300 s`, newer messages can be absent, check the network; no `logout` |

### Requirement: Logout resets the local session without contacting Telegram

The `logout` tool SHALL NOT send a log-out request to Telegram. It SHALL close TDLib, waiting at most 30 seconds for TDLib to report `authorizationStateClosed`, then rename the TDLib database directory to `tdlib.invalidated-<UTC timestamp yyyyMMdd-HHmmss>` in the same parent directory, then release TDLib so that the next call opens a new client on a new, empty database directory. The server SHALL NOT delete the directory or any file in it. The response SHALL name the renamed directory and state that the old session stays in the account's device list until it is ended in a Telegram app, and that the renamed directory must not be moved back while a new session is in use. When TDLib does not close within 30 seconds, the tool SHALL fail, leave the directory unchanged, and keep TDLib held. When the directory cannot be renamed, the tool SHALL fail with the reason, leave the directory unchanged, and SHALL NOT release TDLib, so that no client reopens the old directory.

#### Scenario: Local reset succeeds

- **WHEN** `logout` is called and TDLib closes within 30 seconds
- **THEN** the database directory is renamed to `tdlib.invalidated-<timestamp>` with every file unchanged, TDLib is released, the response names that directory, and no request is sent to Telegram

#### Scenario: Offline logout does not hang

- **WHEN** `logout` is called while TDLib reports `connectionStateWaitingForNetwork`
- **THEN** the tool completes within the 30-second close bound, as no network round trip is involved

#### Scenario: TDLib does not close

- **WHEN** `logout` is called and TDLib reports no `authorizationStateClosed` within 30 seconds
- **THEN** the tool fails, the directory is unchanged, and TDLib remains held

#### Scenario: The directory cannot be renamed

- **WHEN** TDLib closes but `tdlib.invalidated-<timestamp>` already exists
- **THEN** the tool fails naming the reason, the directory and the existing target are unchanged, and TDLib is not released
