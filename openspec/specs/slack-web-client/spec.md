# slack-web-client Specification

## Purpose

A Foundation-only client that calls the Slack Web API as the signed-in user with a browser session credential (an `xoxc` token plus the `d` cookie). It exists so that every che-slack-mcp tool and CLI command shares one place for request authentication, error classification, pacing and rate-limit retry.

## Requirements

### Requirement: Session token request authentication

The client SHALL send every Web API call as an HTTPS POST to `https://slack.com/api/<method>` with the body encoded as `application/x-www-form-urlencoded`, the workspace's `xoxc` token in the form field `token`, and the header `Cookie: d=<cookie value>`. The client SHALL NOT place the token or the cookie in the URL. The client SHALL accept its transport as an injected dependency so that requests can be observed without network access. The production transport SHALL keep no HTTP state from Slack's answers: it SHALL NOT store a cookie Slack sets, on disk or in memory, SHALL NOT cache responses, and SHALL send no cookie other than the `d` cookie of the workspace being called. It SHALL NOT follow HTTP redirects: a redirect SHALL be classified as a network error, so that neither the `Cookie` header nor the form body with the token is sent to another URL.

#### Scenario: Cookies Slack sets are neither stored nor sent

- **WHEN** the production transport's session is created and the client builds a request
- **THEN** the session has no cookie storage, sets no cookies, accepts none and has no response cache, and the request has cookie handling turned off, so its only cookie is the `Cookie: d=<cookie value>` header the client wrote

#### Scenario: Request carries token in the body and cookie in a header

- **WHEN** the client calls `auth.test` for a workspace whose token is `xoxc-1` and whose cookie is `abc%2F`
- **THEN** the transport receives a POST to `https://slack.com/api/auth.test` whose body contains `token=xoxc-1`, whose `Cookie` header is `d=abc%2F`, and whose URL contains neither value

#### Scenario: A redirect is not followed

- **WHEN** a Web API call is answered with HTTP 302 to another host
- **THEN** no request is sent to that host and the call fails with a network error that contains neither the token nor the cookie


<!-- @trace
source: add-che-slack-mcp
updated: 2026-10-31
code:
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-archive/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-review/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-propose/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-analyze/SKILL.md
  - .agents/skills/spectra-verify/SKILL.md
-->

---
### Requirement: Slack error classification

The client SHALL map every failed call to exactly one of five classes: `sessionInvalid` when Slack returns `ok:false` with error `invalid_auth`, `not_authed`, `token_revoked` or `account_inactive`; `rateLimited` when the HTTP status is 429 or the error is `ratelimited`; `enterpriseRestricted` when the error begins with `enterprise_` or equals `team_is_restricted`; `slackError` carrying Slack's error string for any other `ok:false`; and `network` carrying the transport's description when the transport fails. A `sessionInvalid` or `enterpriseRestricted` error SHALL name the workspace it occurred in.

#### Scenario: Revoked session is classified

- **WHEN** Slack answers `{"ok":false,"error":"invalid_auth"}` for workspace `myteam`
- **THEN** the client throws `sessionInvalid` naming `myteam`

##### Example: classification table

| Response | Class |
| --- | --- |
| HTTP 200 `{"ok":false,"error":"token_revoked"}` | `sessionInvalid` |
| HTTP 429 with `Retry-After: 5` | `rateLimited` |
| HTTP 200 `{"ok":false,"error":"enterprise_is_restricted"}` | `enterpriseRestricted` |
| HTTP 200 `{"ok":false,"error":"channel_not_found"}` | `slackError("channel_not_found")` |
| transport throws a timeout | `network` |


<!-- @trace
source: add-che-slack-mcp
updated: 2026-10-31
code:
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-archive/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-review/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-propose/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-analyze/SKILL.md
  - .agents/skills/spectra-verify/SKILL.md
-->

---
### Requirement: Request pacing

For each workspace the client SHALL start a request no sooner than the minimum interval after the previous request to that workspace started, and SHALL have no more than the maximum concurrency of requests to that workspace in flight. The defaults SHALL be 350 milliseconds and 3, overridable by the environment variables `SLACK_MCP_MIN_INTERVAL_MS` (an integer from 0 to 60000) and `SLACK_MCP_MAX_CONCURRENCY` (an integer from 1 to 10). An override outside its range SHALL be ignored with a warning on standard error and the default SHALL apply.

#### Scenario: Consecutive requests are spaced

- **WHEN** two requests to one workspace are issued back to back with the default settings
- **THEN** the second request starts at least 350 milliseconds after the first

#### Scenario: Out-of-range override falls back

- **WHEN** `SLACK_MCP_MAX_CONCURRENCY` is `50`
- **THEN** a warning naming the variable is written to standard error and at most 3 requests run at once


<!-- @trace
source: add-che-slack-mcp
updated: 2026-10-31
code:
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-archive/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-review/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-propose/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-analyze/SKILL.md
  - .agents/skills/spectra-verify/SKILL.md
-->

---
### Requirement: Rate limit retry

On a `rateLimited` response the client SHALL wait for the number of seconds in the `Retry-After` header, or 1 second when the header is absent or not a non-negative integer, and SHALL retry the same call. After 3 retries of one call the client SHALL throw `rateLimited` with the last wait time.

#### Scenario: Retry succeeds after waiting

- **WHEN** the first attempt of a call answers HTTP 429 with `Retry-After: 2` and the second attempt succeeds
- **THEN** the call returns the second attempt's result and the second attempt started at least 2 seconds after the first answered


<!-- @trace
source: add-che-slack-mcp
updated: 2026-10-31
code:
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-archive/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-review/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-propose/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-analyze/SKILL.md
  - .agents/skills/spectra-verify/SKILL.md
-->

---
### Requirement: No credential in output

No error description, log line, debug description, tool result or exception message produced by the client SHALL contain a token or cookie value; where a value would appear the client SHALL write `<redacted>`.

#### Scenario: Debug description is redacted

- **WHEN** a credential pair for workspace `T0123ABCD` is formatted with `String(describing:)`
- **THEN** the output contains `T0123ABCD` and `<redacted>` and contains neither the token nor the cookie

<!-- @trace
source: add-che-slack-mcp
updated: 2026-10-31
code:
  - .agents/skills/spectra-ingest/SKILL.md
  - .agents/skills/spectra-drift/SKILL.md
  - .agents/skills/spectra-archive/SKILL.md
  - AGENTS.md
  - .agents/skills/spectra-commit/SKILL.md
  - .agents/skills/spectra-discuss/SKILL.md
  - .agents/skills/spectra-debug/SKILL.md
  - CLAUDE.md
  - .agents/skills/spectra-review/SKILL.md
  - che-msg.code-workspace
  - .agents/skills/spectra-propose/SKILL.md
  - .agents/skills/spectra-audit/SKILL.md
  - .agents/skills/spectra-apply/SKILL.md
  - .agents/skills/spectra-analyze/SKILL.md
  - .agents/skills/spectra-verify/SKILL.md
-->