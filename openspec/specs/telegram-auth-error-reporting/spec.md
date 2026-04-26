# telegram-auth-error-reporting Specification

## Purpose

Defines the contract for how `che-telegram-all-mcp` surfaces TDLib authentication errors to MCP callers (typically AI agents). Establishes structured error fields (`code: Int`, `message: String`) instead of opaque strings, codifies the TDLib-protocol-mandated silent-ignore rule for error code 406, and locks down the JSON decoder configuration that previously regressed (v0.2.0 lacked `.convertFromSnakeCase`, freezing `authState`). Out of scope: chat / message / contact operation error reporting — those have no formal contract yet.

## Requirements

### Requirement: Structured TDLib error propagation

The Telegram authentication client SHALL convert any `TDLibKit.Error` thrown by an authentication call (`setParameters`, `sendPhoneNumber`, `sendAuthCode`, `sendPassword`) into a `TDError.tdlibError` value that carries both the original numeric `code` (Int) and `message` (String) as separately addressable fields. The client MUST NOT stringify, truncate, or otherwise erase the original `code` or `message` before propagation.

#### Scenario: TDLib returns FLOOD_WAIT during phone submission

- **WHEN** `sendPhoneNumber("+886912345678")` is called and TDLib returns `Error{code: 420, message: "FLOOD_WAIT_30"}`
- **THEN** the client throws `TDError.tdlibError` with `code == 420` and `message == "FLOOD_WAIT_30"`, both retrievable as discrete values

##### Example: error mapping

| TDLibKit.Error           | TDError.tdlibError                        |
| ------------------------ | ----------------------------------------- |
| `code: 420, msg: "FLOOD_WAIT_30"` | `code: 420, message: "FLOOD_WAIT_30"` |
| `code: 400, msg: "PHONE_CODE_INVALID"` | `code: 400, message: "PHONE_CODE_INVALID"` |
| `code: 500, msg: "Internal"`     | `code: 500, message: "Internal"`           |


<!-- @trace
source: improve-tdlib-auth-error-handling
updated: 2026-04-25
code:
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibAuthErrorTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ErrorResponses.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthErrorResponseTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/JSONDecoderRegressionTests.swift
-->

---
### Requirement: TDLib error code 406 silent-ignore rule

When a `TDLibKit.Error` thrown by an authentication call has `code == 406`, the client SHALL NOT propagate the error to the caller. The client MUST treat the call as silently completed and MUST NOT display, log to user-facing output, or process the `message` field. This requirement reflects the TDLib protocol contract documented in `Sources/TDLibKit/Generated/Models/Error.swift`: "If the error code is 406, the error message must not be processed in any way and must not be displayed to the user."

#### Scenario: code 406 returned during setParameters

- **WHEN** `setParameters(apiId: <id>, apiHash: <hash>)` is called and TDLib returns `Error{code: 406, message: <any>}`
- **THEN** the client returns normally without throwing, and no `TDError` value carrying code 406 is observable to any caller

#### Scenario: code 406 distinguished from other 4xx codes

- **WHEN** TDLib returns `Error{code: 400, message: "ANY"}`
- **THEN** the client throws `TDError.tdlibError(code: 400, message: "ANY")` — only code 406 triggers silent-ignore


<!-- @trace
source: improve-tdlib-auth-error-handling
updated: 2026-04-25
code:
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibAuthErrorTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ErrorResponses.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthErrorResponseTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/JSONDecoderRegressionTests.swift
-->

---
### Requirement: MCP response error serialization

The MCP server SHALL serialize `TDError.tdlibError(code:message:)` raised by an authentication tool handler as a structured JSON content payload that includes the discrete `code` and `message` fields. The MCP response MUST set `isError: true`. The structured payload MUST be a JSON object with at minimum the fields `type` (string identifying the error class), `code` (integer), and `message` (string).

#### Scenario: auth_send_phone surfaces FLOOD_WAIT to caller

- **WHEN** `auth_send_phone` tool is invoked and the underlying client throws `TDError.tdlibError(code: 420, message: "FLOOD_WAIT_30")`
- **THEN** the MCP response has `isError == true` and contains a JSON content block with `{"type": "tdlib_error", "code": 420, "message": "FLOOD_WAIT_30"}`

##### Example: MCP response shape

- **GIVEN** auth tool throws `TDError.tdlibError(code: 420, message: "FLOOD_WAIT_30")`
- **WHEN** the server formats the MCP response
- **THEN** the response payload contains `{"type": "tdlib_error", "code": 420, "message": "FLOOD_WAIT_30"}` and `isError` is `true`


<!-- @trace
source: improve-tdlib-auth-error-handling
updated: 2026-04-25
code:
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibAuthErrorTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ErrorResponses.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthErrorResponseTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/JSONDecoderRegressionTests.swift
-->

---
### Requirement: JSONDecoder snake_case invariant for TDLib updates

The `TDLibClient` SHALL configure the `JSONDecoder` used to decode TDLib `Update` broadcast payloads with `keyDecodingStrategy = .convertFromSnakeCase`. This configuration is a regression-protected invariant: a unit test MUST verify that a representative snake_case payload (`updateAuthorizationState` carrying `authorization_state`) decodes successfully through the client's update decode path.

#### Scenario: snake_case authorization update decodes

- **WHEN** the update decode path receives JSON `{"@type":"updateAuthorizationState","authorization_state":{"@type":"authorizationStateWaitTdlibParameters"}}`
- **THEN** the decoder produces an `Update.updateAuthorizationState` value whose `authorizationState` field is `.authorizationStateWaitTdlibParameters`, with no thrown error


<!-- @trace
source: improve-tdlib-auth-error-handling
updated: 2026-04-25
code:
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibAuthErrorTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ErrorResponses.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthErrorResponseTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/JSONDecoderRegressionTests.swift
-->

---
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

<!-- @trace
source: improve-auth-coordination-and-auto-flow
updated: 2026-04-26
-->


<!-- @trace
source: improve-auth-coordination-and-auto-flow
updated: 2026-04-26
code:
  - che-telegram-all-mcp/Sources/TelegramAllLib/AutoFire.swift
  - .agents/skills/spectra-debug/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/CheTelegramAllMCPTests.swift
  - .agents/skills/spectra-archive/SKILL.md
  - che-telegram-all-mcp/Tests/E2ETests/TelegramE2ETests.swift
  - .agents/skills/spectra-ask/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AutoFireChainTests.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthCoalescingTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthStatusNextStepTests.swift
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthRunHandlerTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/AuthResponses.swift
  - che-telegram-all-mcp/Sources/telegram-all/TelegramAllCLI.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/AuthCoalescing.swift
  - che-telegram-all-mcp/README.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Tests/E2ETests/DumpChatToMarkdownE2ETests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/AuthStateLockingTests.swift
  - .agents/skills/spectra-ingest/SKILL.md
-->

---
### Requirement: Authentication scope of structured error contract

The structured error contract defined by this specification SHALL apply only to the authentication methods of the TDLib client: `setParameters`, `sendPhoneNumber`, `sendAuthCode`, and `sendPassword`. Non-authentication client methods (chat operations, message operations, contact lookups, etc.) are out of scope for this specification.

#### Scenario: chat operation error path unchanged

- **WHEN** `getChats(limit: 50)` throws a TDLib error
- **THEN** the error propagation behavior of `getChats` is NOT required by this specification — only the four named authentication methods are covered

<!-- @trace
source: improve-tdlib-auth-error-handling
updated: 2026-04-25
code:
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-archive/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibAuthErrorTests.swift
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibClientTests.swift
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/ErrorResponses.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-ask/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthErrorResponseTests.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/JSONDecoderRegressionTests.swift
-->