## MODIFIED Requirements

### Requirement: Auto-fire failure surfacing via auth_status

When an auto-fire authentication path (setting the TDLib parameters from the environment, or sending the phone number or the 2FA password from the environment or the Keychain) catches a `TDError.tdlibError(code:message:)` thrown by the underlying TDLib request, the client SHALL retain the most recent such error in a lock-protected `lastAutoFireError` field, and the MCP `auth_status` tool SHALL serialize that error in its `last_error` response field as a structured payload with the same `{type, code, message}` shape used elsewhere in this capability. The error SHALL NOT contain the value that was sent.

When a new auto-fire attempt begins (the next TDLib state-machine event triggers a fresh auto-fire path, including one that first looks the value up in the Keychain), the client MUST clear `lastAutoFireError` before invoking the new TDLib request, so that callers do not observe stale errors from prior attempts.

When `authState` advances to `ready`, `lastAutoFireError` MUST be cleared.

#### Scenario: FLOOD_WAIT during auto-fire surfaces in auth_status

- **WHEN** the auto-fire of the phone number catches `TDError.tdlibError(code: 420, message: "FLOOD_WAIT_30")` AND a caller subsequently invokes `auth_status`
- **THEN** the `auth_status` response includes `"last_error": {"type": "tdlib_error", "code": 420, "message": "FLOOD_WAIT_30"}`

#### Scenario: a wrong 2FA password from the Keychain surfaces in auth_status

- **WHEN** the auto-fire sends the 2FA password read from the Keychain and TDLib rejects it with `TDError.tdlibError(code: 400, message: "PASSWORD_HASH_INVALID")`
- **THEN** `auth_status` reports that error in `last_error`, the response does not contain the password, and authorization counts as settled (nothing more is on its way)

#### Scenario: last_error clears when fresh auto-fire begins

- **WHEN** a previous auto-fire failure left `lastAutoFireError` populated AND TDLib broadcasts a new state that triggers a fresh auto-fire path
- **THEN** the new auto-fire path clears `lastAutoFireError` before issuing the TDLib request, so that a concurrent `auth_status` call does not observe the stale value

#### Scenario: code 406 silent-ignore does not populate last_error

- **WHEN** an auto-fire path catches `TDLibKit.Error{code: 406, ...}` and applies the protocol-mandated silent-ignore rule (defined in this capability's existing requirements)
- **THEN** `lastAutoFireError` remains unchanged — code 406 is not a user-surfaceable error
