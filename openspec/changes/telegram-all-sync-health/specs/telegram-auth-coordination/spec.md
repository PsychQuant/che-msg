## MODIFIED Requirements

### Requirement: `auth_status` response includes structured next-step hint

The MCP `auth_status` tool SHALL return a JSON response containing the current `state` (matching `TDLibClient.AuthState` raw value), a `next_step` field, a `last_error` field, and three sync fields:

- `connection_state`: the latest TDLib connection state name (for example `connectionStateReady`, `connectionStateUpdating`), or `null` when TDLib has reported none since it was opened;
- `unsynced_seconds`: the server's unsynced duration in whole seconds (time TDLib has been open since it last reported `connectionStateReady`, as defined by the `telegram-tdlib-lifecycle` capability);
- `sync_stalled`: `true` exactly when `state == ready`, the latest connection state is `connectionStateUpdating`, and the server's updating duration (as defined by the `telegram-tdlib-lifecycle` capability) is at least 120 seconds; otherwise `false`. Time without a network connection never makes a session stalled.

`next_step` SHALL be either: (a) `null` when `state == closed`, or when `state == ready` and `sync_stalled` is `false`; (b) when `state == ready` and `sync_stalled` is `true`, the object `{"tool": "logout", "required_args": [], "hint": <string>}` whose hint states how long TDLib has been updating without finishing, that a session invalidated by Telegram is the likely cause, that the user must be asked before calling `logout` (it resets the local session and a new login needs a code), and that the remedy is `logout` followed by `auth_run`; or (c) in every other state, a JSON object with `tool` (string identifying the recommended MCP tool to call next), `required_args` (array of argument names), and `hint` (human-readable string identifying any context the caller needs).

#### Scenario: next_step is null at ready while synced

- **WHEN** caller invokes `auth_status` AND `authState == ready` AND TDLib's latest connection state is `connectionStateReady`
- **THEN** the response is `{"state": "ready", "next_step": null, "last_error": null, "connection_state": "connectionStateReady", "unsynced_seconds": 0, "sync_stalled": false}`

#### Scenario: next_step describes auth_run as the next tool

- **WHEN** caller invokes `auth_status` AND `authState == waitingForCode`
- **THEN** the response payload includes `"next_step": {"tool": "auth_run", "required_args": ["code"], "hint": "..."}` and `"sync_stalled": false`

#### Scenario: stalled sync at ready points to logout

- **WHEN** caller invokes `auth_status` AND `authState == ready` AND TDLib has stayed in `connectionStateUpdating` for 130 seconds (unsynced and updating durations both 130)
- **THEN** the response includes `"sync_stalled": true`, `"unsynced_seconds": 130`, `"connection_state": "connectionStateUpdating"`, and `"next_step": {"tool": "logout", "required_args": [], "hint": "..."}` whose hint says to ask the user first and names `logout` and then `auth_run`

#### Scenario: offline at ready is not stalled

- **WHEN** caller invokes `auth_status` AND `authState == ready` AND TDLib has reported `connectionStateWaitingForNetwork` for 300 seconds
- **THEN** the response includes `"sync_stalled": false`, `"unsynced_seconds": 300`, and `"next_step": null`

##### Example: response shape

| State | Connection state | unsynced_seconds | sync_stalled | next_step |
| --- | --- | --- | --- | --- |
| `waitingForParameters` (no env vars) | any | any | `false` | `{"tool": "auth_run", "required_args": ["api_id", "api_hash"], "hint": "..."}` |
| `waitingForPhoneNumber` (no env) | any | any | `false` | `{"tool": "auth_run", "required_args": ["phone"], "hint": "..."}` |
| `waitingForCode` | any | any | `false` | `{"tool": "auth_run", "required_args": ["code"], "hint": "..."}` |
| `waitingForPassword` (no env) | any | any | `false` | `{"tool": "auth_run", "required_args": ["password"], "hint": "..."}` |
| `ready` | `connectionStateReady` | 0 | `false` | `null` |
| `ready` | `connectionStateUpdating` | 60 | `false` | `null` |
| `ready` | `connectionStateUpdating` | 130 | `true` | `{"tool": "logout", "required_args": [], "hint": "..."}` |
| `ready` | `connectionStateWaitingForNetwork` | 300 | `false` | `null` |
