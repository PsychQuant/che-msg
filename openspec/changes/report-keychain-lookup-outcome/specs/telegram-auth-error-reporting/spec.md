## ADDED Requirements

### Requirement: Keychain lookup outcome is reported without the value

When TDLib waits for the phone number or the 2FA password and the last Keychain lookup for that state produced no value, the MCP `auth_status` and `auth_run` responses SHALL include a `keychain_lookup` object `{"credential": "phone" | "password", "outcome": "not_stored" | "timed_out" | "unavailable"}`: `not_stored` when the item does not exist or is empty, `timed_out` when the lookup ran out of time (for example a locked Keychain), and `unavailable` when the lookup failed or its output could not be read. In every other case `keychain_lookup` SHALL be null. The outcome of a lookup SHALL apply only to the state it was started for: a state change SHALL clear it, and a later lookup for the same state, by the background auto-fire or by `auth_run`, SHALL replace it (a lookup that finds a value clears it). The object SHALL NOT contain the value, the output of `security`, or its exit status.

While TDLib waits for the 2FA password, the `next_step.hint` SHALL first tell the caller how to store the password in the Keychain or unlock it and then call `auth_run` again, and SHALL say that passing `password` as an argument sends it through the conversation. When `keychain_lookup` is not null, the hint for that credential SHALL begin with the outcome in words.

#### Scenario: a locked Keychain is reported as timed out

- **WHEN** TDLib waits for the 2FA password, no environment value is set, and the Keychain lookup runs out of time
- **THEN** `auth_status` returns `"keychain_lookup": {"credential": "password", "outcome": "timed_out"}` and a `next_step.hint` that begins by saying the Keychain did not answer in time and names a locked Keychain as the likely cause

#### Scenario: a state change clears the outcome

- **WHEN** a phone-number lookup reported `not_stored` and the caller then sends the phone number, so TDLib moves to waiting for the code
- **THEN** `auth_status` returns `"keychain_lookup": null`

#### Scenario: auth_run's own lookup replaces the outcome

- **WHEN** the background lookup for the 2FA password reported `timed_out`, the user unlocks the Keychain, and `auth_run` without arguments finds the password
- **THEN** `auth_run` sends the password and its response does not report `timed_out`

#### Scenario: the hint puts the Keychain first

- **WHEN** TDLib waits for the 2FA password and no lookup outcome is recorded
- **THEN** `next_step.required_args` is `["password"]` and `next_step.hint` names the Keychain item before it mentions the `password` argument, and says that the argument passes through the conversation

##### Example: outcome per lookup result

| Lookup result | `keychain_lookup.outcome` |
| ------------- | ------------------------- |
| item missing or empty | `not_stored` |
| no answer within the limit | `timed_out` |
| `security` failed or unreadable output | `unavailable` |
| value found | (field is null) |
