## ADDED Requirements

### Requirement: An automatic credential is claimed and handed to TDLib in one step

When the client sends the phone number or the 2FA password on its own (from the process environment or the Keychain), it SHALL take that state's claim for the value and either join the method's coalesced task already in flight or create that task and hand its request (`setAuthenticationPhoneNumber` or `checkAuthenticationPassword`) to TDLibKit, in one step under the lock that records authorization state changes. The step MUST NOT suspend, and a request it creates SHALL have been handed to TDLibKit before that lock is released. The automatic value SHALL keep going through the coalesced path: an explicit call of the same method (`auth_run`, `auth_send_phone`, `auth_send_password`, the CLI) SHALL create or join the method's coalesced task under the same lock, so an explicit call made after the step joins the automatic request and observes its outcome instead of sending a second request, and an explicit call made before the step while TDLib waits for that same credential makes the claim fail, so that state gets no automatic value. A state change the client records before the step SHALL make the claim fail and no request SHALL be handed over for that value; a state change recorded after the step finds the request already handed to TDLibKit. A state change that TDLib has made but whose update has not yet reached the client cannot be ordered by the client: TDLib then answers the request with an error, which the client SHALL handle like any failed automatic submission. The client SHALL NOT rely on TDLib receiving requests in the order they were handed to TDLibKit, because TDLibKit does not guarantee that requests handed over in sequence reach TDLib in that order.

#### Scenario: a state change right after the claim finds the request already handed over

- **WHEN** TDLib waits for the phone number, `TELEGRAM_PHONE=+886900000417` is in the process environment, and the client records the state `waitingForCode` at the first moment another caller can take the client lock after the auto-fire claimed the value
- **THEN** one `setAuthenticationPhoneNumber("+886900000417")` request was handed to TDLibKit while the state was still `waitingForPhoneNumber`, and none is handed over after the state change

#### Scenario: a state change during the hand-off waits for it

- **WHEN** the auto-fire is handing the 2FA password's `checkAuthenticationPassword` request to TDLibKit and another thread records a state change at that moment
- **THEN** the state change is recorded only after the request has been handed over

#### Scenario: a state change before the claim sends nothing

- **WHEN** TDLib waits for the 2FA password, the Keychain lookup for `TELEGRAM_2FA_PASSWORD` is running, and the client records a state change before the lookup returns a value
- **THEN** the claim fails and no `checkAuthenticationPassword` request is handed to TDLibKit for that value

#### Scenario: an explicit call after the claim joins the automatic request

- **WHEN** TDLib waits for the 2FA password, the auto-fire has claimed the stored password and handed its request to TDLibKit, and a caller then invokes `sendPassword` with another value before TDLib answers
- **THEN** TDLibKit receives exactly one `checkAuthenticationPassword` request (the stored value's) and the explicit caller observes that request's outcome

##### Example: order of events for one state

| Events in order | Requests handed to TDLibKit for the state | Explicit caller observes |
| --- | --- | --- |
| auto claim and hand-off, then state change recorded | 1 (automatic) | (no explicit call) |
| state change recorded, then auto claim | 0 | (no explicit call) |
| auto claim and hand-off, then explicit call of the same method | 1 (automatic) | the automatic request's outcome |
| explicit call of the same method, then auto claim | 1 (explicit) | its own request's outcome |
