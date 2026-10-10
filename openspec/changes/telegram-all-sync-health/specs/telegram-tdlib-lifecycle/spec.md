## ADDED Requirements

### Requirement: Server tracks whether TDLib is synced with Telegram

The server SHALL record every `updateConnectionState` that TDLib reports while it is open, and SHALL treat TDLib as **synced** only while the latest reported state is `connectionStateReady`. The server SHALL keep an **unsynced duration**: the total number of seconds TDLib has been open in this server process since TDLib last reported `connectionStateReady`. Time during which TDLib is closed SHALL NOT be counted. The unsynced duration SHALL reset to 0 whenever TDLib reports `connectionStateReady`. The server SHALL NOT read or interpret the message of any error with code 406 to decide whether TDLib is synced.

#### Scenario: Ready resets the unsynced duration

- **WHEN** TDLib reports `connectionStateUpdating`, stays in it for 30 seconds, then reports `connectionStateReady`
- **THEN** TDLib is synced and the unsynced duration is 0

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

When a tool call is answered by the TDLib client, authorization is `ready`, the call succeeds, and TDLib is not synced at the time of answering, the result SHALL contain a second text item after the tool's own content. The item SHALL begin with the line `sync: not-synced` and SHALL state the latest connection state, the unsynced duration in whole seconds, and that messages and changes newer than what TDLib last received can be absent from the result. When the unsynced duration has reached 120 seconds, the item SHALL also state that a session invalidated by Telegram is the likely cause and that logging out and logging in again (`logout`, then `auth_run`) is the remedy. When TDLib is synced, or the call fails, the result SHALL NOT contain this item. Results from the local cache (TDLib held by another process) keep their own source note and SHALL NOT carry this item.

#### Scenario: Read while TDLib is updating

- **WHEN** `get_chats` is answered by the TDLib client while TDLib is in `connectionStateUpdating` with an unsynced duration of 40 seconds
- **THEN** the result's second text item begins with `sync: not-synced`, names `connectionStateUpdating`, states 40 seconds, and states that newer messages can be absent

#### Scenario: Read while synced

- **WHEN** `get_chats` is answered by the TDLib client while TDLib is in `connectionStateReady`
- **THEN** the result contains only the tool's own content

#### Scenario: Long stall names the remedy

- **WHEN** `get_chat_history` is answered by the TDLib client with an unsynced duration of 125 seconds
- **THEN** the second text item states that a session invalidated by Telegram is the likely cause and names `logout` followed by `auth_run`

##### Example: sync note lines

| Connection state | Unsynced duration | Note contains |
| --- | --- | --- |
| connectionStateReady | 0 | (no note) |
| connectionStateUpdating | 40 | `sync: not-synced`, `connectionStateUpdating`, `40 s`, newer messages can be absent |
| connectionStateUpdating | 125 | the above with `125 s`, plus likely cause: session invalidated by Telegram, `logout` then `auth_run` |
| connectionStateWaitingForNetwork | 15 | `sync: not-synced`, `connectionStateWaitingForNetwork`, `15 s`, newer messages can be absent |

### Requirement: Logout resets a session that no longer syncs

The `logout` tool SHALL ask TDLib to log out and SHALL report success once TDLib reports `authorizationStateClosed` or `authorizationStateWaitTdlibParameters` / `authorizationStateWaitPhoneNumber` after the request. When TDLib has not reported one of these states within 30 seconds, the server SHALL close TDLib, rename the TDLib database directory to `tdlib.invalidated-<UTC timestamp yyyyMMdd-HHmmss>` in the same parent directory, and report success with a note naming the renamed directory. The server SHALL NOT delete the directory. After a successful logout the next authentication SHALL start from a new, empty database directory.

#### Scenario: TDLib completes the logout

- **WHEN** `logout` is called and TDLib reports `authorizationStateClosed` within 30 seconds
- **THEN** the tool succeeds and no directory is renamed

#### Scenario: TDLib does not complete the logout

- **WHEN** `logout` is called on a session Telegram has invalidated and TDLib reports no closing state within 30 seconds
- **THEN** TDLib is closed, the database directory is renamed to `tdlib.invalidated-<timestamp>`, the tool succeeds with a note naming that directory, and no file is deleted
