## MODIFIED Requirements

### Requirement: Auto-fire chain covers params, phone, and password steps

When the TDLib authorization state advances to `WaitTdlibParameters`, `WaitPhoneNumber`, or `WaitPassword`, the client SHALL attempt automatic submission if the corresponding credential is available from one of its sources, taken in the order the table lists:

| TDLib state | Auto-fire credential sources (first one with a value wins) |
| --- | --- |
| `WaitTdlibParameters` | `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` in the process environment (both required; the Keychain is not consulted) |
| `WaitPhoneNumber` | `TELEGRAM_PHONE` in the process environment, then the Keychain item with account `che-telegram-all-mcp` and service `TELEGRAM_PHONE` |
| `WaitPassword` | `TELEGRAM_2FA_PASSWORD` in the process environment, then the Keychain item with account `che-telegram-all-mcp` and service `TELEGRAM_2FA_PASSWORD` |

The client SHALL consult the Keychain only when the process environment does not provide the value, and SHALL NOT run the Keychain lookup on TDLib's update-callback thread. The plugin wrapper SHALL NOT export `TELEGRAM_PHONE` or `TELEGRAM_2FA_PASSWORD` into the server's environment; the binary reads them from the Keychain itself, only when TDLib asks for them.

When no source provides a credential, the client MUST NOT attempt auto-fire and MUST leave the state unchanged so that an explicit caller can supply the value via `auth_run` or the corresponding individual MCP tool.

While a Keychain lookup for the current state is in progress, or after it found a value that is being submitted, authorization SHALL NOT count as settled. Once the lookup finds no value, fails, or times out, authorization SHALL count as settled for that state.

#### Scenario: phone auto-fire when env var is present

- **WHEN** TDLib broadcasts `WaitPhoneNumber` AND `TELEGRAM_PHONE=+886912345678` is in the process environment
- **THEN** the client invokes `sendPhoneNumber("+886912345678")` through the coalesced path within the same callback handler turn, without consulting the Keychain

#### Scenario: phone auto-fire from the Keychain when the env var is missing

- **WHEN** TDLib broadcasts `WaitPhoneNumber` AND no `TELEGRAM_PHONE` is set AND the Keychain item `che-telegram-all-mcp` / `TELEGRAM_PHONE` holds `+886912345678`
- **THEN** the client reads the item outside the callback thread and invokes `sendPhoneNumber("+886912345678")` through the coalesced path

#### Scenario: the environment wins over the Keychain

- **WHEN** TDLib broadcasts `WaitPassword` AND `TELEGRAM_2FA_PASSWORD=from-env` is set AND the Keychain item `TELEGRAM_2FA_PASSWORD` holds `from-keychain`
- **THEN** the client invokes `sendPassword("from-env")` and makes no Keychain lookup

#### Scenario: phone auto-fire is skipped when no source has a value

- **WHEN** TDLib broadcasts `WaitPhoneNumber` AND no `TELEGRAM_PHONE` is set AND the Keychain has no `TELEGRAM_PHONE` item
- **THEN** the client makes no `setAuthenticationPhoneNumber` call; `authState` remains `waitingForPhoneNumber` until an explicit caller invokes `auth_run(phone: ...)` or `auth_send_phone(phone: ...)`

#### Scenario: authorization is not settled while the Keychain lookup runs

- **WHEN** TDLib broadcasts `WaitPassword` AND no `TELEGRAM_2FA_PASSWORD` is set AND the Keychain lookup has started but not finished
- **THEN** `authorizationIsSettled` returns false, so a client opened on demand keeps waiting instead of answering "Not authenticated"

##### Example: settled by lookup status

| State | Env value | Keychain lookup status | Auto-fire error | Settled |
| --- | --- | --- | --- | --- |
| `waitingForPassword` | none | in progress | no | false |
| `waitingForPassword` | none | found, being submitted | no | false |
| `waitingForPassword` | none | no value | no | true |
| `waitingForPassword` | none | found, submission failed | yes | true |
| `waitingForPhoneNumber` | `+886900000000` | not needed | no | false |
| `waitingForCode` | none | not needed | no | true |

#### Scenario: a Keychain lookup that times out leaves the state unchanged

- **WHEN** TDLib broadcasts `WaitPhoneNumber` AND no `TELEGRAM_PHONE` is set AND the Keychain lookup does not finish within its time limit
- **THEN** the client makes no `setAuthenticationPhoneNumber` call, `authState` remains `waitingForPhoneNumber`, and authorization counts as settled

#### Scenario: the wrapper does not export the phone number or the 2FA password

- **WHEN** the plugin wrapper starts the server AND the Keychain holds all four items `TELEGRAM_API_ID`, `TELEGRAM_API_HASH`, `TELEGRAM_PHONE` and `TELEGRAM_2FA_PASSWORD`
- **THEN** the server's environment contains `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` and contains neither `TELEGRAM_PHONE` nor `TELEGRAM_2FA_PASSWORD`

### Requirement: SMS verification code is never auto-fired from environment

The client SHALL NOT read the SMS verification code from any environment variable, file, or persistent storage, including the Keychain. The code MUST be supplied by an explicit caller invocation (`auth_run(code: ...)` or `auth_send_code(code: ...)`) in a single one-shot delivery.

#### Scenario: TELEGRAM_AUTH_CODE env var is intentionally not honored

- **WHEN** the process environment contains `TELEGRAM_AUTH_CODE=12345` AND TDLib broadcasts `WaitCode`
- **THEN** the client makes no `checkAuthenticationCode` call; `authState` remains `waitingForCode` until an explicit caller supplies the code

#### Scenario: the Keychain is never consulted for the SMS code

- **WHEN** TDLib broadcasts `WaitCode` OR a caller invokes `auth_run()` without arguments while `authState == waitingForCode`
- **THEN** the client performs no Keychain lookup of any item

### Requirement: `auth_run` MCP tool drives the state machine

The MCP server SHALL expose an `auth_run` tool that advances the authentication state machine by one step per invocation. Callers invoke `auth_run` repeatedly (with optional arguments `phone`, `code`, `password`) until `state == "ready"`. On each invocation the tool consults the current `authState` and either: (a) consumes the matching argument if provided, (b) otherwise uses the credential from the process environment, or, for the phone number and the 2FA password only, from the Keychain item the auto-fire chain reads, or (c) returns a structured `next_step` hint identifying which argument is required. The Keychain SHALL be consulted only when neither the argument nor the environment provides the value. Because the lookup runs without holding the client's lock, the tool SHALL read `authState` again after it and use the Keychain value only while that state still asks for the credential it was read for; otherwise it SHALL route on the new state without the value. When the step it takes leads to a state whose phone number or 2FA password is being looked up or sent from the Keychain, the tool SHALL wait, for at most 15 seconds, for authorization to settle before it answers, rather than answering with a `next_step` hint that asks the caller for that value.

#### Scenario: auth_run advances from waitingForCode when caller provides code

- **WHEN** `authState == waitingForCode` AND caller invokes `auth_run(code: "12345")`
- **THEN** the server invokes `checkAuthenticationCode("12345")` through the coalesced path; on success `authState` advances to `waitingForPassword` or `ready`

#### Scenario: auth_run returns next_step hint when required arg is missing

- **WHEN** `authState == waitingForCode` AND caller invokes `auth_run()` with no arguments
- **THEN** the response payload contains `next_step.required_args == ["code"]` and a human-readable hint identifying the phone number Telegram targeted

#### Scenario: auth_run is idempotent at ready state

- **WHEN** `authState == ready` AND caller invokes `auth_run()`
- **THEN** the server returns success with `next_step == null` and makes no TDLib call

#### Scenario: a Keychain value read after the state moved on is not sent

- **WHEN** `auth_run` is called with no arguments at `waitingForPassword`, starts a Keychain lookup, and the background auto-fire submits the password and the state becomes `ready` before the lookup returns
- **THEN** `auth_run` does not send the password again and answers from the `ready` state

#### Scenario: auth_run uses the Keychain when neither argument nor environment has the value

- **WHEN** `authState == waitingForPassword` AND caller invokes `auth_run()` AND no `TELEGRAM_2FA_PASSWORD` is set AND the Keychain item `TELEGRAM_2FA_PASSWORD` holds a value
- **THEN** the server invokes `sendPassword` with the Keychain value through the coalesced path

##### Example: source precedence

| Caller argument | Environment | Keychain | Value sent |
| --- | --- | --- | --- |
| `+886911111111` | `+886922222222` | `+886933333333` | `+886911111111` |
| none | `+886922222222` | `+886933333333` | `+886922222222` |
| none | none | `+886933333333` | `+886933333333` |
| none | none | none | nothing; `next_step.required_args == ["phone"]` |

## ADDED Requirements

### Requirement: Keychain credential lookup is bounded and keeps no copy

The client SHALL read a Keychain credential by running `/usr/bin/security find-generic-password` at that absolute path with the account `che-telegram-all-mcp`, the credential's service name and `-g`, and with no argument derived from caller input. With `-g`, `security` writes the item's attributes to standard output and its value to standard error as one `password:` line. The client SHALL read only that line: `password: "<text>"` gives the text between the outer quotes, and `password: 0x<hex>  "<escaped>"` gives the hex digits decoded as UTF-8. (`-w` is not used: it prints a value that contains any non-ASCII or control byte as bare hex, which cannot be told apart from an ASCII value made of hex digits, so a 2FA password such as `密碼` would be submitted as its hex.) The child process SHALL have its standard input connected to the null device, so it can never read the MCP server's standard input, and its standard output SHALL be discarded. A lookup SHALL finish within 10 seconds: when the child has not exited by then, the client SHALL terminate it and treat the credential as absent. Exit status 44 (item not found), any other non-zero exit status, an empty value, standard error with no `password:` line or with one in neither form, hex that is not valid UTF-8, and standard error longer than 64 KiB SHALL each be treated as absent. The value SHALL be used only for the submission it was read for: the client SHALL NOT keep it in a stored property, cache it, write it to a log or to standard error, or include it in an error message or a tool response. When a lookup times out, fails with an exit status other than 44, or exits 0 without a value it can read, the client SHALL write one line to standard error naming the credential and the reason, without the value.

#### Scenario: an item that does not exist is absent

- **WHEN** `/usr/bin/security` exits with status 44 for `TELEGRAM_PHONE`
- **THEN** the lookup reports absent and writes nothing to standard error

#### Scenario: a lookup that does not finish in time is terminated

- **WHEN** the child process for `TELEGRAM_2FA_PASSWORD` has not exited 10 seconds after it started (for example, a locked Keychain waiting for an unlock dialog)
- **THEN** the client terminates the child, the lookup reports that it timed out, the credential is treated as absent, and standard error receives one line naming `TELEGRAM_2FA_PASSWORD` and the time limit

##### Example: outcomes of a lookup

| Child's standard error, exit status | Lookup result | Client's standard error |
| --- | --- | --- |
| `password: "secret"`, exit 0 | found `secret` | nothing |
| `password: "end""`, exit 0 | found `end"` | nothing |
| `password: 0x636166C3A9  "caf\303\251"`, exit 0 | found `café` | nothing |
| `password: 0x610A62  "a\012b"`, exit 0 | found `a` newline `b` | nothing |
| `password: "6361"`, exit 0 | found `6361` (quoted text is never decoded) | nothing |
| `password: ` with nothing after it, exit 0 | absent | nothing |
| no `password:` line, exit 0 | absent (unavailable) | one line naming the credential and the reason |
| `password: 0xFF  "\377"`, exit 0 | absent (unavailable, not UTF-8) | one line naming the credential and the reason, not the value |
| exit 44 | absent | nothing |
| exit 51 | absent (unavailable) | one line naming the credential and exit status 51 |
| still running after 10 s | absent (timed out, child terminated) | one line naming the credential and the time limit |

#### Scenario: a non-ASCII value is read exactly

- **WHEN** a scratch keychain file holds `TELEGRAM_2FA_PASSWORD` with the value `密碼pässwörd` and the client reads it through `/usr/bin/security`
- **THEN** the lookup reports found with exactly `密碼pässwörd`

#### Scenario: the value never appears in any output

- **WHEN** a lookup finds `+886912345678` and the subsequent `sendPhoneNumber` call fails with a TDLib error
- **THEN** neither standard error, the recorded auto-fire error, the `auth_status` response, nor a textual description of the lookup result contains `+886912345678`
