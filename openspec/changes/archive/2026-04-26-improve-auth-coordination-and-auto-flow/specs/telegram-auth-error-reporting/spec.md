## ADDED Requirements

### Requirement: Auto-fire failure surfacing via auth_status

When an auto-fire authentication path (`autoSetParametersIfAvailable`, `autoSendPhoneIfAvailable`, `autoSendPasswordIfAvailable`) catches a `TDError.tdlibError(code:message:)` thrown by the underlying TDLib request, the client SHALL retain the most recent such error in a lock-protected `lastAutoFireError` field, and the MCP `auth_status` tool SHALL serialize that error in its `last_error` response field as a structured payload with the same `{type, code, message}` shape used elsewhere in this capability.

When a new auto-fire attempt begins (the next TDLib state-machine event triggers a fresh auto-fire path), the client MUST clear `lastAutoFireError` before invoking the new TDLib request, so that callers do not observe stale errors from prior attempts.

When `authState` advances to `ready`, `lastAutoFireError` MUST be cleared.

#### Scenario: FLOOD_WAIT during auto-fire surfaces in auth_status

- **WHEN** `autoSendPhoneIfAvailable` catches `TDError.tdlibError(code: 420, message: "FLOOD_WAIT_30")` AND a caller subsequently invokes `auth_status`
- **THEN** the `auth_status` response includes `"last_error": {"type": "tdlib_error", "code": 420, "message": "FLOOD_WAIT_30"}`

#### Scenario: last_error clears when fresh auto-fire begins

- **WHEN** a previous auto-fire failure left `lastAutoFireError` populated AND TDLib broadcasts a new state that triggers a fresh auto-fire path
- **THEN** the new auto-fire path clears `lastAutoFireError` before issuing the TDLib request, so that a concurrent `auth_status` call does not observe the stale value

#### Scenario: code 406 silent-ignore does not populate last_error

- **WHEN** an auto-fire path catches `TDLibKit.Error{code: 406, ...}` and applies the protocol-mandated silent-ignore rule (defined in this capability's existing requirements)
- **THEN** `lastAutoFireError` remains unchanged — code 406 is not a user-surfaceable error
