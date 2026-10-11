# telegram-auth-coordination Specification

## Purpose

Defines the contract for coordinating concurrent authentication-method invocations and the auto-fire flow in `che-telegram-all-mcp`. Establishes lock-protected state, coalesced execution of the four authentication methods, an auto-fire chain that covers TDLib parameters / phone / password steps from environment, the explicit one-shot `auth_run` MCP tool that drives the state machine, and the structured `next_step` hint surfaced via `auth_status`. Out of scope: error reporting payload shape (covered by `telegram-auth-error-reporting`) and chat/message operations.

## Requirements

### Requirement: Coalesced execution of authentication methods

The Telegram authentication client SHALL coalesce concurrent invocations of the four authentication methods — `setParameters`, `sendPhoneNumber`, `sendAuthCode`, `sendPassword` — such that two callers invoking the same method while a prior call is in flight observe the same outcome (success or failure) without issuing a second TDLib request. The client MUST use a non-reentrant lock (e.g., `OSAllocatedUnfairLock`) to protect the in-flight task handle for each of the four methods, and MUST NOT hold the lock across a Swift Concurrency suspend point.

#### Scenario: two concurrent setParameters callers share one TDLib request

- **WHEN** caller A invokes `setParameters(apiId: 1, apiHash: "h")` and, while A's TDLib request is still in flight, caller B invokes `setParameters(apiId: 1, apiHash: "h")`
- **THEN** only one `setTdlibParameters` call is sent to TDLib, and both callers either complete successfully or both throw the same error mapped from the underlying TDLib response

##### Example: timeline

| Time | Event |
| ---- | ----- |
| t0 | Caller A acquires lock, sees no in-flight task, creates task T, releases lock |
| t1 | A awaits T's result |
| t2 | Caller B acquires lock, sees in-flight task T, releases lock |
| t3 | B awaits T's result (same task) |
| t4 | T completes (success or `TDError.tdlibError(...)`) |
| t5 | Both A and B observe T's outcome |

#### Scenario: auto-fire path coalesces with manual path

- **WHEN** the TDLib update broadcast triggers `autoSetParametersIfAvailable` AND a manual `auth_set_parameters` MCP call arrives before the auto-fire task completes
- **THEN** both code paths route through the same coalesced task — only one `setTdlibParameters` request reaches TDLib


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
### Requirement: Authentication state and credential cache are lock-protected

The Telegram authentication client SHALL protect read and write access to its mutable authentication state — `authState`, `cachedApiId`, `cachedApiHash`, `lastAutoFireError`, and the four in-flight task handles — using the same lock that coalesces method invocations. Reads MUST NOT observe partially-written state. The client SHALL NOT expose direct property access to these fields outside the lock; callers retrieve `authState` via a method that acquires the lock for the duration of the read.

#### Scenario: callback thread and stdio thread access authState

- **WHEN** the TDLib callback thread updates `authState` via `handleAuthStateUpdate` AND the stdio MCP handler thread reads `authState` to serialize an `auth_status` response in the same window
- **THEN** the read returns either the pre-update or post-update value atomically — never a torn value or a Swift data-race trap


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
### Requirement: Auto-fire chain covers params, phone, and password steps

When the TDLib authorization state advances to `WaitTdlibParameters`, `WaitPhoneNumber`, or `WaitPassword`, the client SHALL attempt automatic submission if the corresponding credential is present in the process environment or available via the wrapper-injected variable:

| TDLib state | Auto-fire credential source |
| --- | --- |
| `WaitTdlibParameters` | `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` (both required) |
| `WaitPhoneNumber` | `TELEGRAM_PHONE` |
| `WaitPassword` | `TELEGRAM_2FA_PASSWORD` |

When credentials are absent, the client MUST NOT attempt auto-fire and MUST leave the state unchanged so that an explicit caller can supply the value via `auth_run` or the corresponding individual MCP tool.

#### Scenario: phone auto-fire when env var is present

- **WHEN** TDLib broadcasts `WaitPhoneNumber` AND `TELEGRAM_PHONE=+886912345678` is in the process environment
- **THEN** the client invokes `sendPhoneNumber("+886912345678")` through the coalesced path within the same callback handler turn

#### Scenario: phone auto-fire is skipped when env var is missing

- **WHEN** TDLib broadcasts `WaitPhoneNumber` AND no `TELEGRAM_PHONE` is set
- **THEN** the client makes no `setAuthenticationPhoneNumber` call; `authState` remains `waitingForPhoneNumber` until an explicit caller invokes `auth_run(phone: ...)` or `auth_send_phone(phone: ...)`


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
### Requirement: SMS verification code is never auto-fired from environment

The client SHALL NOT read the SMS verification code from any environment variable, file, or persistent storage. The code MUST be supplied by an explicit caller invocation (`auth_run(code: ...)` or `auth_send_code(code: ...)`) in a single one-shot delivery.

#### Scenario: TELEGRAM_AUTH_CODE env var is intentionally not honored

- **WHEN** the process environment contains `TELEGRAM_AUTH_CODE=12345` AND TDLib broadcasts `WaitCode`
- **THEN** the client makes no `checkAuthenticationCode` call; `authState` remains `waitingForCode` until an explicit caller supplies the code


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
### Requirement: `auth_run` MCP tool drives the state machine

The MCP server SHALL expose an `auth_run` tool that advances the authentication state machine by one step per invocation. Callers invoke `auth_run` repeatedly (with optional arguments `phone`, `code`, `password`) until `state == "ready"`. On each invocation the tool consults the current `authState` and either: (a) triggers the appropriate auto-fire path if credentials are available, (b) consumes the matching argument if provided, or (c) returns a structured `next_step` hint identifying which argument is required.

#### Scenario: auth_run advances from waitingForCode when caller provides code

- **WHEN** `authState == waitingForCode` AND caller invokes `auth_run(code: "12345")`
- **THEN** the server invokes `checkAuthenticationCode("12345")` through the coalesced path; on success `authState` advances to `waitingForPassword` or `ready`

#### Scenario: auth_run returns next_step hint when required arg is missing

- **WHEN** `authState == waitingForCode` AND caller invokes `auth_run()` with no arguments
- **THEN** the response payload contains `next_step.required_args == ["code"]` and a human-readable hint identifying the phone number Telegram targeted

#### Scenario: auth_run is idempotent at ready state

- **WHEN** `authState == ready` AND caller invokes `auth_run()`
- **THEN** the server returns success with `next_step == null` and makes no TDLib call


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

<!-- @trace
source: telegram-all-sync-health
updated: 2026-10-11
code:
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownSenderResolveTests.swift
  - .agents/skills/spectra-analyze/SKILL.md
  - che-telegram-bot-mcp/Sources/CheTelegramBotMCPCore/Server.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibSyncState.swift
  - .agents/skills/spectra-debug/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/AuthStatusNextStepTests.swift
  - CLAUDE.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/LogoutFlow.swift
  - .agents/skills/spectra-drift/SKILL.md
  - che-msg.code-workspace
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/CLIBootstrap.swift
  - che-telegram-all-mcp/README.md
  - .agents/skills/spectra-archive/SKILL.md
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/MarkdownFormatTests.swift
  - plugins/che-telegram-mcp/.claude-plugin/plugin.json
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/AuthResponses.swift
  - .agents/skills/spectra-audit/SKILL.md
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/LogoutFlowTests.swift
  - che-telegram-all-mcp/Tests/CheTelegramAllMCPTests/SyncNoteTests.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibSyncStateTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibSessionReset.swift
  - .claude-plugin/marketplace.json
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/LogoutResetTests.swift
  - che-telegram-all-mcp/Sources/TelegramAllLib/TDLibClient.swift
  - .agents/skills/spectra-propose/SKILL.md
  - che-telegram-all-mcp/mcpb/manifest.json
  - che-telegram-bot-mcp/CHANGELOG.md
  - .agents/skills/spectra-ingest/SKILL.md
  - che-telegram-bot-mcp/mcpb/manifest.json
  - plugins/che-telegram-mcp/README.md
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/SyncNote.swift
  - plugins/che-telegram-mcp/bin/che-telegram-bot-mcp-wrapper.sh
  - tests/che-telegram-mcp/test-wrapper-mcp-error.sh
  - che-telegram-all-mcp/Sources/CheTelegramAllMCPCore/Server.swift
  - che-telegram-all-mcp/Tests/TelegramAllLibTests/TDLibSyncWaitTests.swift
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-review/SKILL.md
  - .agents/skills/spectra-commit/SKILL.md
  - che-telegram-all-mcp/CHANGELOG.md
  - .agents/skills/spectra-verify/SKILL.md
  - AGENTS.md
  - plugins/che-telegram-mcp/bin/che-telegram-all-mcp-wrapper.sh
  - plugins/che-telegram-mcp/CHANGELOG.md
  - .agents/skills/spectra-discuss/SKILL.md
  - plugins/che-telegram-mcp/skills/telegram-messaging/SKILL.md
-->