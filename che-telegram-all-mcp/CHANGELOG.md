# Changelog

## [Unreleased]

Parser-consistency cluster — closes the gap left by #8 (`parseMaxMessages`).

### Added

- **`int64ArgValueStrict` helper (#22)**: throwing variant of `int64ArgValue` for parsers in `HandlerArgs.swift`. On `.string("not-numeric")`, throws `"\(key) must be an integer; got \"\(s)\""` with quoted user input for debug clarity. On `.bool` / `.array` / `.object` / fractional `.double`, throws `"\(key) must be an integer"` (no-quote — no meaningful string form). Used by `parseGetChatHistoryArgs` for `chat_id` + `from_message_id` and by `parseDumpChatToMarkdownArgs` for `chat_id`. Non-strict `int64ArgValue` retained for ~20 direct `Server.swift` callsites tracked separately as #33.
- **`parseLimit` helper (#25)**: modeled on `parseMaxMessages`. Rejects non-numeric strings, zero/negative, and over-`validateLimitCap` (10_000) limits. Accepts whole-number doubles per MCP SDK's `Int(_:strict:false)` (JS / Python JSON encoders emit integers as doubles per JSON spec).
- **`validateLimitCap` shared policy (#25 verify F4)**: 10_000 upper bound, parity with `validateMaxMessagesCap`. Throws `"limit exceeds 10_000 cap; got \(value). Use pagination instead of a single large request."` Applies via `parseLimit`.
- **`parseMaxMessagesWithDefault(args, default:)` helper (#23 verify F2)**: variant that flows the default-value through `validateMaxMessagesCap`. Mutation-resistant: deleting the cap call on the default branch makes `testParseMaxMessagesWithDefaultAppliesCapToDefaultPath` (cap=11000 over 10_000 ceiling) fail. Replaces the earlier inline `?? 5000 + try validateMaxMessagesCap(maxMessages)` belt-and-suspenders pattern whose test was a placebo.

### Fixed

- **(#22) `chat_id` / `from_message_id` type-mismatch error message** — was misleading "X is required" (silent nil from non-strict `int64ArgValue`); now throws "X must be an integer; got \"...\"" with the user's raw value quoted. Parser-layer slice (3 callsites in `HandlerArgs.swift`). The remaining 20+ direct `int64ArgValue` callsites in `Server.swift` (e.g. `get_chat`, `send_message`, `pin_message`) retain the legacy silent-fallback behavior — tracked as #33 sister.
- **(#23) `parseDumpChatToMarkdownArgs` default-5000 path bypassed `validateMaxMessagesCap`** — the cap's docstring claimed single source of truth but the literal `?? 5000` fallback silently bypassed it. Now flows through `parseMaxMessagesWithDefault`; future cap policy tightening (e.g. 1000 for paid tier) will propagate to the default path atomically.
- **(#25) `Server.swift` 5 `limit ?? N` silent fallbacks** — `parseGetChatHistoryArgs:81`, `Server.swift:433/446/503/511` migrated to `try parseLimit(args, default: N)`. Same shape `parseMaxMessages` fixed at #8 (`.string("0")` / `.double(20.0)` no longer silent-fallback to default).
- **(catch-all observability)** `handleToolCall` outer catch (L591) uses `errorResultFromParse(error)` instead of `errorResult(error.localizedDescription)`. `HandlerArgError` + `DateParseError` now surface their human-readable `.description` to MCP clients via the catch-all path; other error types unchanged.

### Notes

Sister bug #33 documents the residual scope (20+ Server.swift direct `int64ArgValue` callsites with the same #22 bug shape). Cluster scope intentionally narrowed to parser-layer to keep this PR's review surface manageable.

## [0.5.5] - 2026-05-09

CLI fast-exit dispatcher + startup observability for `/mcp` reconnect diagnostics.

Health-check entry point + per-phase timing instrumentation. Does **not** directly fix Claude Code's `/mcp` "Failed to reconnect" symptom — the root cause is the interaction of wrapper-side cold-start latency, Claude Code's reconnect timeout, and 233MB universal Mach-O dynamic linking. This release equips wrappers and humans to diagnose which contributor dominates in their environment, and gives `psychquant-claude-plugins/che-telegram-mcp-wrapper.sh` a sub-second `--version` probe to replace its GitHub API curl on every spawn.

### Added
- **`--version` / `-v` flag (#29 S1)**: Prints `che-telegram-all-mcp 0.5.5` to stdout and exits 0 in <10ms warm / <1s cold, **before** `await CheTelegramAllMCPServer()` is constructed (no TDLib framework load, no Application Support directory creation, no MCP handler registration). Production benchmark vs. previous behavior: ≥10s → 0.008s warm, a >1000× speedup for wrapper / monitoring health checks.
- **`--help` / `-h` flag (#29 S2)**: Prints multi-line help to stdout and exits 0. Help text explicitly states "Primary mode is stdio JSON-RPC — connect via Claude Code's MCP plugin configuration, not by invoking interactively" so callers don't mistake the binary for an interactive CLI. Documents all supported environment variables including `CHE_TELEGRAM_LOG_STARTUP=1` for diagnostic discoverability.
- **`CHE_TELEGRAM_LOG_STARTUP=1` env-gated startup log (#29 S3)**: When set, `CheTelegramAllMCPServer.init` emits four lines to **stderr** (stdout is reserved for MCP JSON-RPC traffic) — `[startup] tdlib_init=N.NNNs`, `[startup] tools_define=N.NNNs`, `[startup] register_handlers=N.NNNs`, `[startup] total=N.NNNs`. Default off. `DispatchTime.now()` for monotonic timing with saturating subtract `&-` for clock-rewind defense.
- **Failure-path observability for startup log (#29 verify F2)**: `tdlib_init` phase wraps in `do/catch` — if `try await TDLibClient()` throws after a slow init, emits `[startup] tdlib_init_FAILED=N.NNNs` and `[startup] total_FAILED=N.NNNs` to stderr **before** re-throwing. Without this, the `if logStartup` block was unreachable on throw, leaving the failure path (the case the user is most likely diagnosing) silent.
- **`shouldLogStartup(env:)` testable predicate (#29 verify F4)**: Extracted env-var truthy check from `init` to a file-scope helper accepting an env dictionary explicitly. Strict `== "1"` contract — does not accept `"true"`, `"yes"`, `"TRUE"`, etc. Matches help text exactly to avoid documentation drift.

### Fixed
- **Unknown flag rejection (#29 verify F3)**: Previously, typos like `--versoin` fell through `default: return .runServer` and silently entered stdio MCP mode, hanging on stdin — exactly the failure pattern this PR set out to avoid. `CLIBootstrap.parse` now returns `.unknownFlag(_)` for any `-`-prefixed argument that doesn't match a recognized flag; `main.swift` writes `Error: unknown flag '<flag>'. Run with --help for usage.` to stderr and exits 2 (POSIX misuse convention, distinct from exit 1 = runtime error). Non-flag positional arguments (no leading `-`) still fall through to `.runServer` to preserve backward compat for callers passing paths or config names.

### Refactored
- **`logStartupDuration` visibility `private` → `internal` (#29 verify F4)**: Was file-scope `private`. Promoted to module-internal so `shouldLogStartup` predicate test in `CheTelegramAllMCPTests` can co-exist in the same module without exposing the helper publicly.
- **`CLIBootstrap` enum + parser in `CheTelegramAllMCPCore` (#29 S1+S2)**: Argv parsing extracted from `main.swift` (which now becomes a 4-case dispatch) into a pure `CLIBootstrap.parse(_: [String]) -> CLIAction` function in `CheTelegramAllMCPCore` so it is reachable by `CheTelegramAllMCPTests` for unit testing without spawning a subprocess. `CLIAction` is `Equatable` so tests can use `XCTAssertEqual`.

### Test
- **25 new tests in `CLIBootstrapTests`**: 10 parser tests (long/short version+help, no-args, non-flag positional, empty argv defensiveness, helpText invariants for version constant + stdio mention + env var name); 6 env predicate tests (`shouldLogStartup` strict `"1"` contract — true on `"1"`, false on unset / `""` / `"0"` / `"true"` / `"TRUE"`); 5 unknown-flag rejection tests (long typo, short typo, single `-`, case-sensitive `-V` ≠ `-v`); 4 subprocess integration tests via `Process` API + `Bundle(for:)` path resolution (asserts exit code + stdout / stderr for `--version`, `-v`, `--help`, and unknown flag exit 2). Subprocess tests skip cleanly when binary not built.
- **Test count: 180 → 216 (+36, all in `CheTelegramAllMCPTests`)**.

### Production leverage (out of repo)
This release alone does not change end-user experience. Real leverage requires the consumer side of the contract:
- **`psychquant-claude-plugins/.../che-telegram-all-mcp-wrapper.sh` should adopt `$BINARY --version` health check** instead of (or in addition to) the current `curl` to GitHub Releases API for version verification. The wrapper currently fork-execs `curl --max-time 30` twice on every spawn even when `$INSTALLED_VERSION == $DESIRED_VERSION` — replacing that with a sub-second binary call removes a major source of cold-start latency that contributes to Claude Code's `/mcp` "Failed to reconnect" symptom.
- **Sister concerns surfaced during diagnosis** (out of `che-msg` scope, tracked separately): wrapper should add a stderr log file at `~/Library/Logs/CheTelegramAllMCP/wrapper.log` for post-mortem debugging; Claude Code's MCP reconnect timeout vs. 233MB binary cold-start interaction warrants upstream feedback; potential TDLib lock-file detection if `~/Library/Application Support/che-telegram-all-mcp/tdlib/` accumulates stale state from crashed wrappers.

### Honest constraint
This PR is **observability + a fast health-check entry point**, not a direct fix for the reported `/mcp` reconnect timeout. Verifying `--version` exits 0, `[startup]` lines emit when env is set, and `--versoin` typos exit 2 — does **not** prove the original "Failed to reconnect" message goes away in production. That requires the wrapper-side change above plus deploy + multi-session reproduction, neither of which this repo can deliver alone. The honest scope is "build the diagnostic and integration surface that future fixes will plug into".

## [0.5.4] - 2026-04-27

Input hardening + handler glue testability + log-format polish.

### Fixed
- **`since_date <= until_date` sanity check (#10 C2)**: Inverted range previously silently filtered to empty result with no error feedback — opaque debugging experience. Now both `parseGetChatHistoryArgs` and `parseDumpChatToMarkdownArgs` throw `HandlerArgError("since_date must be earlier than until_date")` via shared `validateDateRange(_:_:)` helper. Nil-tolerant: only triggers when both bounds provided.
  - **Note (verify-DA F3 — error precedence)**: `validateDateRange` runs **before** `parseMaxMessages` in both parsers. If a request simultaneously has `since > until` AND invalid `max_messages`, callers in 0.5.4+ receive the date-range error first; in 0.5.3, they would have received the max_messages error. Behavior change for callers that depend on specific error message routing.
- **`DateParseError.description` input truncation (#10 C1)**: Reflected input is now capped at 128 chars + `"...(truncated)"` marker. Prevents response-size amplification when callers send pathologically large strings (e.g. 1MB blob → was 1MB error body, now ~150 bytes). Existing short-input contract assertions (`"2026/04/17"` etc.) unchanged since 10 chars < 128 threshold.
- **`errorResultFromParse` final message cap at 256 chars (verify-DA F2)**: Asymmetric protection gap — `DateParseError` self-truncates at 128 chars (#10 C1) but `HandlerArgError` had no such guard. Future `HandlerArgError(message: "invalid output_path: \(longPath)")` could reflect 1MB user input. Now `errorResultFromParse` caps any final message at 256 chars + `"...(truncated)"` belt-and-suspenders, regardless of source error type.

### Refactored
- **`errorResultFromParse(_:) -> CallTool.Result` shared helper (#14, subsumes #18)**: Server.swift's `get_chat_history` and `dump_chat_to_markdown` handlers each had a 3-line catch chain converting `HandlerArgError` / `DateParseError` to `errorResult`. Both now delegate to a single module-level helper in HandlerArgs.swift. Future handlers using parser pure functions (#7 / #13 pattern) can adopt the same one-liner. Defensive fallback to `localizedDescription` for unknown error types.
- **TDLibClient stderr warning ASCII (#9 B1)**: Replaced non-ASCII `→` with `->` in `getChatHistory` cap warning. Non-ASCII characters render as `?` in some log aggregators (fluent-bit, journalctl with pager); ASCII is universally safe.

### Test
- **6 new HandlerGlueTests (#14, subsumes #18)**: `testHandlerArgErrorBecomesIsErrorTrue`, `testDateParseErrorBecomesIsErrorTrue`, `testUnknownErrorFallsBackToLocalizedDescription`, `testGetChatHistoryGlueChatIdMissing`, `testDumpToMarkdownGlueOutputPathMissing`, `testGetChatHistoryGlueInvalidDate`. Lock the catch-chain wiring so refactors that change error type or routing trip immediately.
- **5 new since/until range tests (#10 C2)**: `testSinceAfterUntilThrows`, `testSinceEqualsUntilSameDayAccepted`, `testOnlySinceAccepted`, `testOnlyUntilAccepted`, `testDumpSinceAfterUntilThrows`.
- **4 new DateParseError truncation tests (#10 C1)**: boundary at 128/129 chars, no-truncate guarantee, short-input contract preserved.
- **2 new HandlerGlueTests for verify-DA F2** (in-scope fix): `testErrorResultFromParseCapsLongHandlerArgErrorMessage`, `testErrorResultFromParseAtCapNotTruncated`.
- Test count: 163 → **180** (+17).

### Won't fix (#9 B2 — superseded)
`DateParseError` visibility downgrade from `public` to `internal` was originally requested in #5/#6 verify, but `#8 A2` (commit `b7e7899`) intentionally promoted it to `public` so CLI and MCP can share the same type across `TelegramAllLib` / `CheTelegramAllMCPCore` boundary. Reverting would break CLI build.

## [0.5.3] - 2026-04-26

Type-safety + CLI-MCP parity hardening.

### Fixed
- **`max_messages` type enforcement (#8 A1, subsumes #20)**: `args["max_messages"]?.intValue ?? default` previously fell back to the default whenever the value was `.string("0")` or `.double(20000.0)` — the cap check (`<= 0` / `> 10_000`) was completely bypassed and the user's explicit (but type-mismatched) value was silently ignored. New `parseMaxMessages` helper uses MCP SDK's `Int(value, strict: false)` (Value.swift:320) which coerces `.int(n)` directly, `.double(d)` via `Int(exactly: d)` (whole-number doubles like `5000.0` accepted), and `.string(s)` via strict base-10 `Int(s)`. Anything else (`.double(0.5)`, `.bool`, `.array`, `.object`, `.null`, invalid string) throws `HandlerArgError("max_messages must be an integer")`. All accepted values pass through `validateMaxMessagesCap`. Affects both `parseGetChatHistoryArgs` and `parseDumpChatToMarkdownArgs`. Whole-number `.double` matters for cross-language MCP callers (Python `json.dumps(5000.0)` / JS schema-validated coerce) — verify-stage Devil's Advocate caught the prior implementation rejecting these as a regression.
- **CLI / MCP date parity (#8 A2)**: `telegram-all` CLI's `parseCLIDate` had two divergences from MCP — no regex pre-check (`DateFormatter` silently accepted `2026/04/17`) and `--until` parsed to start-of-day (excluded the day's later messages). Lifted `parseISODate` / `parseUntilDate` / `DateParseError` from `CheTelegramAllMCPCore` to `TelegramAllLib` (lower-level shared dep) and exposed as `public`. CLI now picks since-bound vs until-bound semantics via `endOfDay` flag in a 6-line wrapper.

### Test
- **9 new tests for `max_messages` type enforcement**: `testMaxMessagesAsStringAccepted` (`.string("100")` → 100), `testMaxMessagesAsStringZeroRejected` (no silent fallback), `testMaxMessagesAsStringInvalidRejected`, `testMaxMessagesAsWholeDoubleAccepted` (`.double(5000.0)` → 5000), `testMaxMessagesAsFractionalDoubleRejected` (`.double(0.5)` throws), `testMaxMessagesAsWholeDoubleOverCapRejected` (`.double(20000.0)` throws cap error not type error), plus `testDumpMaxMessagesAsStringZeroRejected`, `testDumpMaxMessagesAsDoubleOverCapRejected`, `testDumpMaxMessagesAsWholeDoubleAccepted` for dump parity.
- **Error message contract assertions (#11)**: 7 existing throws-based tests upgraded to assert exact error message text via the throws-error trailing closure. Future refactors that swap precise messages (e.g. `"max_messages must be positive; got 0"`) for vague ones (e.g. `"invalid arg"`) will now be caught — MCP callers may rely on substring match for error classification.
- **4 new backward-compat tests (#12)**: `testChatIdAsStringAccepted`, `testFromMessageIdAsStringAccepted`, `testChatIdAsStringInvalidThrows`, `testDumpChatIdAsStringAccepted` lock `int64ArgValue`'s dual-path acceptance of `.string("123")` for callers that quote integers in JSON.
- Test count: 150 → **163** (+13).

### Refactored
- **`DateParsing.swift` moved to `TelegramAllLib`** (#8 A2): separate file, public API, single source of truth for ISO-date parsing and end-of-day construction. Both `CheTelegramAllMCPCore` and `telegram-all` (CLI) now import from `TelegramAllLib`. No behavior change for MCP callers.

## [0.5.2] - 2026-04-26

Internal refactor and test hardening — no behavior change for MCP callers.

### Refactored
- **`parseDumpChatToMarkdownArgs` pure function (#13)**: `dump_chat_to_markdown` handler in `Server.swift` (lines 510-532) duplicated the entire validation block from `get_chat_history` — `chat_id` guard, `max_messages` 0/10_000 cap (verbatim), `parseISODate`/`parseUntilDate` with `DateParseError` catch — flagged in #7 verify by Devil's Advocate as silent-drift risk. Extracted `DumpChatToMarkdownArgs` struct + `parseDumpChatToMarkdownArgs(_ args:) throws` mirroring the #7 pattern; handler shrinks from 27 lines of inline validation to 15 lines of parse-then-call.
- **`validateMaxMessagesCap` shared helper (#13)**: The 0/10_000 cap rule was duplicated between `parseGetChatHistoryArgs` and `dump_chat_to_markdown`'s inline validation. Extracted to a module-level helper so future cap policy changes (e.g. tightening for free tier) propagate atomically to both handlers.

### Test
- **11 new `parseDumpChatToMarkdownArgs` tests** in `ServerHandlerLogicTests`: required-field guards (`chat_id`, `output_path`), defaults (`max_messages=5000`, `self_label="我"`), boundary parity with #15-C2 (`testDumpMaxMessagesAt10001Rejected`, `testDumpMaxMessagesAt10000Accepted`), symmetric downward parity with #15 DA finding (`testDumpMaxMessagesAt9999Accepted`), zero/negative rejection, invalid date format, `until_date` end-of-day with full year/month/day assertions (#15-C3 parity), and `testDumpExplicitSelfLabel` covering the override path.
- Test count: 139 → 150.

## [0.5.1] - 2026-04-26

Internal refactor and test hardening — no behavior change for MCP callers.

### Refactored
- **`int64ArgValue` consolidated as single source of truth (#15-C1)**: `Server.int64Arg` (private, 21+ callers) was a verbatim duplicate of `HandlerArgs.int64ArgValue` (private, 2 callers — added by #7 with a comment acknowledging the drift risk). Removed the Server copy, promoted the HandlerArgs one to `internal`, and updated all 21 Server call sites. Future tweaks (e.g. trimming whitespace, accepting hex prefix) now apply uniformly across all handlers.

### Test
- **`testMaxMessagesAt10001Rejected` upward boundary regression (#15-C2)**: Existing tests covered `10_000` (accept) and `50_000` (reject) but not the first off-by-one value `10_001`. An accidental `if mm > 10_001` change would have slipped through the gap. New test locks the `> 10_000` upper boundary.
- **`testMaxMessagesAt9999Accepted` downward boundary regression (#15 verify)**: Symmetric guard for downward mutations of the cap (e.g. `if mm > 9_998` would shrink the cap silently). Added during /idd-verify after Devil's Advocate flagged that the upward-only test left half the boundary exposed.
- **`testUntilDateUsesEndOfDay` extended with year/month/day assertions (#15-C3)**: Previously asserted only `hour=23/min=59/sec=59` — a TZ drift that shifted the parsed date to a different calendar day would still pass (same wall clock, wrong date). Now asserts the full date + time tuple. Note: this is a round-trip consistency test (producer + consumer both use `Calendar.current`), so it catches *asymmetric* TZ regressions but not symmetric ones — see #16 follow-up.

## [0.5.0] - 2026-04-26

### Added
- **`auth_run` MCP tool — state-machine driver**: A single tool drives the auth flow by one step per call. Optional args `phone` / `code` / `password` route to the matching TDLib method based on current `authState`. When env vars are present (`TELEGRAM_API_ID`/`HASH`, `TELEGRAM_PHONE`, `TELEGRAM_2FA_PASSWORD`), auto-fire handles those steps; SMS verification code is **never** auto-fired (one-shot delivery rule, must be supplied via the `code` arg). Replaces the per-step manual workflow with a single agent-friendly entry point. The legacy `auth_set_parameters` / `auth_send_phone` / `auth_send_code` / `auth_send_password` tools remain as escape hatches.
- **`auth_status` structured response**: returns `{state, next_step, last_error}` where `next_step` is either `null` (ready/closed) or `{tool, required_args, hint}` describing the next caller action. `last_error` surfaces auto-fire failures (e.g., `FLOOD_WAIT_30`) as `{type, code, message}` so AI agents can recover programmatically.
- **`autoSendPhoneIfAvailable()`**: third step of the auto-fire chain. When TDLib advances to `WaitPhoneNumber` and `TELEGRAM_PHONE` is in the process environment, the client invokes `sendPhoneNumber(...)` through the coalesced path. Combined with existing `autoSetParametersIfAvailable` and `autoSendPasswordIfAvailable`, the chain now covers params + phone + password (3 of 4 auth steps); SMS code remains caller-only.
- **`TaskFieldHolder` + `coalesceTask(holder:body:)`** (`Sources/TelegramAllLib/AuthCoalescing.swift`): Coalesced Task pattern — concurrent callers of the same auth method share a single in-flight TDLib request and observe the same outcome. Eliminates the auto-fire vs manual race that previously triggered duplicate TDLib calls when both fired in the same window.
- **`decideAutoFire(state:env...)` + `AutoFireAction`** (`Sources/TelegramAllLib/AutoFire.swift`): pure routing function for the auto-fire chain — testable without `ProcessInfo` mocking or `TDLibClient` instantiation.
- **`decideAuthRunAction(state:phone:code:password:env...)` + `AuthRunAction`** (`Sources/CheTelegramAllMCPCore/AuthResponses.swift`): pure routing function for the `auth_run` MCP tool — testable without server instance.
- **`authStatusResult(state:lastError:)`** (`Sources/CheTelegramAllMCPCore/AuthResponses.swift`): structured response builder for `auth_status` and `auth_run`.
- **`TDLibClient.getLastAutoFireError()` accessor**: returns the most recent `TDError.tdlibError` from an auto-fire path; cleared automatically when a fresh auto-fire begins or `authState` advances to `.ready`.
- **6 new test files / 46 new test cases**: `AuthCoalescingTests` (concurrency contract), `AuthStateLockingTests` (lock primitive), `AuthRunHandlerTests` (state-machine routing), `AuthStatusNextStepTests` (response shape), `AutoFireChainTests` (env-driven auto-fire decisions), tool-count regression updates.
- **New capability spec**: `openspec/specs/telegram-auth-coordination/` (added by spectra change `improve-auth-coordination-and-auto-flow`); modified `openspec/specs/telegram-auth-error-reporting/` to cover auto-fire failure surfacing.

### Changed
- **BREAKING — `TDLibClient.authState` direct access removed**: was `public private(set) var authState: AuthState`, now `private var authState`. Callers MUST use `getAuthState() -> AuthState` (lock-protected). Internal-only API; no public consumers outside this package. All call sites updated (Server, CLI, E2ETests).
- **`OSAllocatedUnfairLock` protects all mutable auth state**: `authState`, `cachedApiId`, `cachedApiHash`, `lastAutoFireError`, and the four per-method task holders. Reads via `getAuthState()` are atomic — never observe a torn enum value. Replaces the implicit single-thread assumption that conflicted with TDLib's process-global callback thread.
- **Auto-fire paths use `do/catch` instead of `try?`**: caught `TDError.tdlibError(...)` is persisted to `lastAutoFireError` for surfacing via `auth_status`. Previous `try?` discarded all errors silently, so `FLOOD_WAIT` / invalid credentials never reached the caller.

### Notes
- Closes `che-telegram-all-mcp#2` (auto-set Task race fix) and `che-telegram-all-mcp#4` (SSH-friendly auto-flow), which were merged into a single SDD.
- `che-telegram-all-mcp#3` (cross-machine session sync) remains a separate effort.

## [0.4.3] - 2026-04-25

### Fixed
- **TDLib auth error masking — `che-telegram-all-mcp#1` Issue C primary**: Previously `TDLibClient.setParameters` / `sendPhoneNumber` / `sendAuthCode` / `sendPassword` propagated `TDLibKit.Error` as opaque `"TDLibKit.Error error 1"` strings via `Swift.Error.localizedDescription`, hiding the actual TDLib `code` and `message`. Callers could not distinguish flood-wait (code 420 `FLOOD_WAIT_X`), invalid code (400 `PHONE_CODE_INVALID`), or internal errors. Now wrapped in `do/catch` that maps `TDLibKit.Error` → `TDError.tdlibError(code: Int, message: String)` with discrete fields preserved.

### Changed
- **BREAKING — `TDLibClient.TDError.tdlibError` enum case shape**: from `tdlibError(String)` to `tdlibError(code: Int, message: String)`. Internal API only — no public consumers outside this package. All call sites updated.
- **MCP response error serialization for auth tools**: `Server.handleToolCall` now catches `TDError.tdlibError(code:message:)` separately from generic errors and serializes as structured JSON `{"type":"tdlib_error","code":<int>,"message":<string>}` with `isError: true`. AI agents can now parse error code + message without regex on free-text. Non-auth errors continue to use the existing plain-text `errorResult` helper.

### Added
- **TDLib protocol code 406 silent-ignore rule**: per TDLib protocol contract ("If the error code is 406, the error message must not be processed in any way and must not be displayed to the user"), the four auth methods now silently swallow code 406 errors. Other TDLib codes propagate as structured `TDError.tdlibError`.
- **`TelegramAllLib.makeUpdateDecoder()`** (file-scope internal helper): factored out the `JSONDecoder` configuration used for TDLib `Update` payloads so a regression test can verify `keyDecodingStrategy == .convertFromSnakeCase` without instantiating `TDLibClient` (TDLib's receive loop is process-global).
- **`TelegramAllLib.mapTDLibError(_:)`** (file-scope internal helper): pure function for TDLibKit error → `TDError.tdlibError` mapping, including the code 406 silent-ignore branch. Testable without a live TDLib connection.
- **`CheTelegramAllMCPCore.tdlibErrorResult(code:message:)`** (file-scope internal helper): pure function constructing structured MCP error responses. Testable without instantiating the server.
- **New tests** (14 cases): `TDLibAuthErrorTests` (mapping + silent-ignore + non-TDLib passthrough), `JSONDecoderRegressionTests` (snake_case decode regression guard, locks down v0.2.0 critical bug fix), `AuthErrorResponseTests` (structured MCP response shape).
- **New capability spec**: `openspec/specs/telegram-auth-error-reporting/` (added by spectra change `improve-tdlib-auth-error-handling`).

### Notes
- Out of scope: auto-set `Task` race fix (`che-telegram-all-mcp#1` Issue C tertiary) tracked separately.
- Issues A + B from `che-telegram-all-mcp#1` were fixed in v0.3.0 (snake_case decoder); release of that fix as a prebuilt binary is a separate hotfix.

## [0.4.2] - 2026-04-17

### Refactored
- **Extract `parseGetChatHistoryArgs` pure function (#7)**: Argument parsing + validation logic for `get_chat_history` handler is now in `Sources/CheTelegramAllMCPCore/HandlerArgs.swift`, testable without a live TDLib connection. Handler became 16 lines (down from 35). Introduces `GetChatHistoryArgs` struct and `HandlerArgError` for structured validation failures. 11 new unit tests lock down the #3 fromMsgId==0 auto-pagination rule, #4 param wiring, and #5/#6 validation boundaries.

### Fixed
- **DST fall-back bug in `parseUntilDate`** (verification blocker from logic reviewer): Previously used `Calendar.date(byAdding: DateComponents(hour:23,min:59,sec:59), to: startOfDay)` which breaks on DST fall-back days (25-hour day) — messages at 23:00-23:59 were excluded, defeating the "whole day inclusive" contract. Now constructs end-of-day from wall-clock components (year/month/day + hour=23/min=59/sec=59) so Calendar resolves DST correctly.
- **Version string in `Server(version:)` synced**: Previously hard-coded `"0.2.0"`, now matches CHANGELOG `0.4.2`.
- **`mcpb/manifest.json` version synced** to `0.4.2`.

### Changed
- **`until_date` now includes the whole day (#5-A1)**: `"2026-04-17"` parses to 2026-04-17 23:59:59 local time instead of 00:00:00. Messages sent anywhere on 2026-04-17 are now included in the filter, matching the schema's "inclusive" description.
- **`parseISODate` throws on invalid format (#5-A2)**: Non-empty strings that don't match `YYYY-MM-DD` now throw `DateParseError` instead of silently returning nil. MCP handlers catch and return `errorResult("Date format invalid: ...")`. Regex pre-check (`^\d{4}-\d{2}-\d{2}$`) guards against `DateFormatter`'s lenient-even-when-disabled parsing of `/` separators.
- **`max_messages` hard-capped at 10_000 (#6-B1)**: `TDLibClient.getChatHistory` caps bulk pagination at 10_000 messages regardless of caller input. Warning logged to stderr when cap applied. Prevents runaway pagination from accidentally large values.
- **`max_messages <= 0` returns error (#6-B2)**: `get_chat_history` and `dump_chat_to_markdown` MCP handlers reject non-positive `max_messages` with clear error message, instead of silently returning an empty array.
- **Handler-level `max_messages > 10_000` explicit reject** (verification finding): Previously the cap only surfaced via stderr warning, which is invisible to MCP callers over stdio JSON-RPC. Handlers now reject with `errorResult("max_messages exceeds 10_000 cap...")` so callers see the constraint. TDLibClient internal cap kept as defense-in-depth.

### Added
- `Sources/CheTelegramAllMCPCore/DateParsing.swift` — new module with pure `parseISODate` and `parseUntilDate` functions (module-level internal, directly testable without server class).
- `DateParseError` type with descriptive message including the invalid input.
- 14 new unit tests in `DateParsingTests.swift`: nil/empty/valid/invalid inputs, semantic contract tests (end-of-day inclusion / next-day exclusion), semantic-invalid dates (`2026-13-01`, `2026-02-30`, `2025-02-29`), leap-year acceptance (`2024-02-29`), and DST fall-back regression guard.

### Removed
- Old `parseISODate` private method on `CheTelegramAllMCPServer` (replaced by module-level throwing version).

## [0.4.1] - 2026-04-16

### Fixed
- **`get_chat_history` first-call bug (#3)**: When `from_message_id` is 0, the MCP handler now defaults `maxMessages` to `limit`, triggering the bulk pagination path. This fixes the issue where the first call only returned 1 message due to TDLib's partial local cache.

### Changed
- **`get_chat_history` schema expanded (#4)**: Added three optional parameters: `since_date` (YYYY-MM-DD), `until_date` (YYYY-MM-DD), `max_messages` (integer). These wire through to `TDLibClient.getChatHistory`'s existing `sinceDate`/`untilDate`/`maxMessages` support, which was previously only accessible via `dump_chat_to_markdown` and the CLI.
- Updated `openspec/specs/telegram-history-export/spec.md` to reflect the expanded schema (previously mandated exactly three properties).

## [0.4.0] - 2026-04-15

### Added
- **New MCP tool `dump_chat_to_markdown`**: one-shot export of chat history to a Markdown file. Paginates TDLib internally, batch-resolves sender names, groups messages by day, and writes to a caller-supplied `output_path`. Returns summary metadata (`path`, `message_count`, `date_range`, `senders`) — does NOT return Markdown content in the MCP response (avoids context bloat). Supports `max_messages`, `since_date`, `until_date`, `self_label` parameters.
- **Library `TDLibClient.getChatHistory` extended** with three optional parameters: `maxMessages: Int?`, `sinceDate: Date?`, `untilDate: Date?`. When `maxMessages` is non-nil the method auto-paginates (newest → oldest) with `sinceDate` early-terminate. Date filters apply independently of `maxMessages` and may be combined with single-page fetches.
- **CLI `telegram-all history` flags**: `--max-messages`, `--since`, `--until`, `--dump-markdown <path>`, `--self-label`. Without `--dump-markdown` prints JSON as before; with the flag invokes the new exporter and prints summary metadata.
- **New test suites**: `TDLibClientBackwardCompatTests`, `TDLibClientPaginationTests`, `TDLibClientDateFilterTests`, `MarkdownFormatTests`, `MarkdownSenderResolveTests`, `MarkdownExporterContractTests`, `ServerDumpChatToolTests`.
- New capability spec: `openspec/specs/telegram-history-export/spec.md`.

### Changed
- Tool count: 26 → 27 (added `dump_chat_to_markdown`).
- `TDLibClient.getChatHistory` signature gained three optional parameters. Existing three-parameter call sites (`chatId:limit:fromMessageId:`) are fully source-compatible — the default-nil parameters preserve original single-page behavior byte-for-byte.

### Backward Compatibility
- Existing `get_chat_history` MCP tool schema is unchanged (still three properties `chat_id` / `limit` / `from_message_id`; still `chat_id` required only).
- Existing CLI `telegram-all history <chat_id>` still prints a single-page JSON array with no new flags required.

### Design Notes
- The middle-tier tool `get_chat_history_full` was deliberately NOT added — JSON-batch responses to MCP are never the AI's end goal (it always re-formats to Markdown), so the middle tier is dead surface. See `openspec/archive/*-add-chat-history-export/design.md`.

## [0.3.0] - 2026-04-13

### Added
- New `TelegramAllLib` Swift package target — standalone TDLib wrapper, no MCP SDK dependency
- New `telegram-all` CLI executable with 10 subcommands:
  - Auth: `auth-status`, `auth-phone`, `auth-code`, `auth-password`
  - Read: `me`, `chats`, `history`, `search`, `contacts`
  - Write: `send`
- Unit tests (`TelegramAllLibTests`, `CheTelegramAllMCPTests`)
- E2E tests (`E2ETests`) for read/write operations against real Telegram accounts

### Changed
- **Architecture**: `TDLibClient.swift` extracted from `CheTelegramAllMCPCore` into independent `TelegramAllLib` target. MCP server is now a thin wrapper.
- **MCP SDK** upgraded from 0.10.2 → 0.12.0 (fixes Swift 6.3 concurrency compatibility)
- Server.swift updated to new `.text(text:annotations:_meta:)` API

### Fixed
- **Critical**: `JSONDecoder` now uses `.convertFromSnakeCase` strategy. Previously, all TDLib updates failed to decode (snake_case keys vs Swift camelCase), causing `authState` to never update from `waitingForParameters`. This made all read/write operations falsely report "Not authenticated".
- TDLib verbose stdout logging suppressed via `td_execute("setLogVerbosityLevel", 0)` at init.

## [0.2.0] - 2026-02-10

### Added
- Auto-authentication via environment variables (`TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `TELEGRAM_2FA_PASSWORD`)
- New tools: `create_group`, `add_chat_member`

### Changed
- TDLib parameters are now auto-set on startup when env vars are present (no manual `auth_set_parameters` call needed)
- Tool count: 26 → 28

## [0.1.0] - 2026-02-08

### Added
- Initial release with TDLib integration
- Authentication: `auth_set_parameters`, `auth_send_phone`, `auth_send_code`, `auth_send_password`, `auth_status`, `logout`
- User info: `get_me`, `get_user`, `get_contacts`
- Chat operations: `get_chats`, `get_chat`, `search_chats`
- Messages: `get_chat_history`, `send_message`, `edit_message`, `delete_messages`, `forward_messages`, `search_messages`
- Group management: `get_chat_members`, `pin_message`, `unpin_message`, `set_chat_title`, `set_chat_description`
- Read state: `mark_as_read`
