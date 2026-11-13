import Foundation

/// Decision returned by `decideAutoFire` for the auto-fire chain.
///
/// `TDLibClient`'s callback handler reads the current `authState` plus the
/// process environment, calls this pure function, and dispatches based on
/// the returned action. Extracting the routing decision keeps it unit-testable
/// (no `ProcessInfo` mocking, no `TDLibClient` instance setup).
internal enum AutoFireAction: Equatable, CustomStringConvertible {
    case fireSetParameters(apiId: Int, apiHash: String)
    case fireSendPhone(String)
    case fireSendPassword(String)
    case noOp

    /// Never shows a credential (#96).
    var description: String {
        switch self {
        case .fireSetParameters(let apiId, _): return "fireSetParameters(apiId: \(apiId), apiHash: <redacted>)"
        case .fireSendPhone: return "fireSendPhone(<redacted>)"
        case .fireSendPassword: return "fireSendPassword(<redacted>)"
        case .noOp: return "noOp"
        }
    }
}

/// Pure routing function for auto-fire decisions.
///
/// Spec contract:
/// - `WaitTdlibParameters` + both `TELEGRAM_API_ID` AND `TELEGRAM_API_HASH` → fire setParameters
/// - `WaitPhoneNumber` + `TELEGRAM_PHONE` → fire sendPhone
/// - `WaitCode` → MUST NEVER fire (SMS code is one-shot, caller-supplied only)
/// - `WaitPassword` + `TELEGRAM_2FA_PASSWORD` → fire sendPassword
/// - `Ready` / `Closed` / missing creds → noOp
///
/// `envAuthCode` is included as a parameter to make the "WaitCode never
/// auto-fires" test explicit — even when set, the function must return noOp.
internal func decideAutoFire(
    state: TDLibClient.AuthState,
    envApiId: Int?,
    envApiHash: String?,
    envPhone: String?,
    envPassword: String?,
    envAuthCode: String?
) -> AutoFireAction {
    switch state {
    case .waitingForParameters:
        guard let apiId = envApiId, let apiHash = envApiHash else { return .noOp }
        return .fireSetParameters(apiId: apiId, apiHash: apiHash)

    case .waitingForPhoneNumber:
        guard let phone = envPhone else { return .noOp }
        return .fireSendPhone(phone)

    case .waitingForCode:
        // Spec: SMS verification code is never auto-fired from environment.
        // The code MUST be supplied by an explicit caller invocation.
        return .noOp

    case .waitingForPassword:
        guard let password = envPassword else { return .noOp }
        return .fireSendPassword(password)

    case .ready, .closed:
        return .noOp
    }
}

/// Where the current state's Keychain lookup stands (PsychQuant/che-msg#49).
/// A status only: the value itself is never stored.
internal enum CredentialLookupStatus: Equatable, Sendable {
    /// The state needs no lookup: the environment has the value, or the state
    /// is not waiting for the phone number or the 2FA password.
    case notNeeded
    case pending
    /// A value was found and is being submitted.
    case found
    /// The lookup found nothing, failed or timed out.
    case absent
}

/// Whether TDLib's authorization has gone as far as it can without a caller:
/// it is ready or closed, an automatic step failed, or the current state needs
/// input that neither the environment nor the Keychain provides. A client
/// opened on demand waits for this before its first call (PsychQuant/che-msg#58).
/// While a Keychain lookup runs, or its value is being submitted, it is not
/// settled (#49), or the first call would answer before the value is sent.
internal func authorizationIsSettled(state: TDLibClient.AuthState, hasAutoFireError: Bool, envApiId: Int?,
                                     envApiHash: String?, envPhone: String?, envPassword: String?,
                                     keychainLookup: CredentialLookupStatus) -> Bool {
    if state == .ready || state == .closed || hasAutoFireError { return true }
    if keychainLookup == .pending || keychainLookup == .found { return false }
    return decideAutoFire(state: state, envApiId: envApiId, envApiHash: envApiHash, envPhone: envPhone,
                          envPassword: envPassword, envAuthCode: nil) == .noOp
}

/// What to do for the phone number or the 2FA password when TDLib asks for
/// it: send the environment's value, look the credential up in the Keychain,
/// or nothing (any other state, including the SMS code, which is never looked
/// up). Spec: "Auto-fire chain covers params, phone, and password steps".
internal enum CredentialPlan: Equatable, CustomStringConvertible {
    case fire(String)
    case lookUp(KeychainCredential)
    case nothing

    /// Never shows the value (#96).
    var description: String {
        switch self {
        case .fire: return "fire(<redacted>)"
        case .lookUp(let credential): return "lookUp(\(credential.rawValue))"
        case .nothing: return "nothing"
        }
    }
}

/// The authorization state that asks for a Keychain credential. A lookup's
/// outcome is recorded only for that state (#95).
internal func waitingState(for credential: KeychainCredential) -> TDLibClient.AuthState {
    switch credential {
    case .phone: return .waitingForPhoneNumber
    case .password: return .waitingForPassword
    }
}

internal func credentialPlan(state: TDLibClient.AuthState, envPhone: String?, envPassword: String?) -> CredentialPlan {
    switch decideAutoFire(state: state, envApiId: nil, envApiHash: nil, envPhone: envPhone,
                          envPassword: envPassword, envAuthCode: nil) {
    case .fireSendPhone(let value), .fireSendPassword(let value):
        return .fire(value)
    case .fireSetParameters, .noOp:
        break
    }
    switch state {
    case .waitingForPhoneNumber: return .lookUp(.phone)
    case .waitingForPassword: return .lookUp(.password)
    case .waitingForParameters, .waitingForCode, .ready, .closed: return .nothing
    }
}

/// The Keychain lookup status for the current authorization state, behind a
/// lock. Every state change starts a new generation, so a lookup that
/// finishes after the state moved on changes nothing and is not submitted.
internal final class CredentialLookupTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var status: CredentialLookupStatus = .notNeeded
    /// Why the current state's last lookup produced no value (#95); kept apart
    /// from `status`, which `authorizationIsSettled` reads.
    private var miss: KeychainMiss?
    /// Whether a value has been sent for the current state, automatically or
    /// explicitly (#96).
    private var submitted = false

    /// Records a state change; `lookingUp` when a lookup starts for the new
    /// state. Returns the generation that lookup must finish with.
    func stateChanged(lookingUp: Bool) -> UInt64 {
        lock.withLock {
            generation &+= 1
            status = lookingUp ? .pending : .notNeeded
            miss = nil
            submitted = false
            return generation
        }
    }

    /// Records a lookup's outcome: `miss` is nil when it found a value.
    /// Returns false, changing nothing, when the state has changed since the
    /// lookup started.
    func finish(_ lookupGeneration: UInt64, miss: KeychainMiss?) -> Bool {
        lock.withLock {
            guard lookupGeneration == generation else { return false }
            status = miss == nil ? .found : .absent
            self.miss = miss
            return true
        }
    }

    /// The current state's generation, for a lookup made outside the
    /// auto-fire (`auth_run`'s) to `note` its outcome against.
    var generationNow: UInt64 { lock.withLock { generation } }

    /// Records the outcome of a lookup made outside the auto-fire, for the
    /// state it started in. The settle status is unchanged: that lookup's
    /// caller sends what it finds itself.
    func note(_ lookupGeneration: UInt64, miss: KeychainMiss?) {
        lock.withLock {
            if lookupGeneration == generation { self.miss = miss }
        }
    }

    /// Why the current state's last lookup produced no value; nil when none
    /// did or none ran.
    var lastMiss: KeychainMiss? { lock.withLock { miss } }

    /// Claims the one automatic submission a state gets (#96): true only while
    /// the state is still the one `lookupGeneration` began with and no value
    /// has been sent for it yet, by the auto-fire or by an explicit call.
    func claimSubmission(_ lookupGeneration: UInt64) -> Bool {
        lock.withLock {
            guard lookupGeneration == generation, !submitted else { return false }
            submitted = true
            return true
        }
    }

    /// Records that a value was sent explicitly for the current state, so the
    /// auto-fire sends none for it (#96).
    func explicitSubmission() {
        lock.withLock { submitted = true }
    }

    /// Whether no state change has happened since `lookupGeneration` began.
    func isCurrent(_ lookupGeneration: UInt64) -> Bool {
        lock.withLock { lookupGeneration == generation }
    }

    /// Whether a value for the current state is being looked up, or was found
    /// and not yet reported as failed: something is on its way to TDLib.
    var isInFlight: Bool {
        lock.withLock { status == .pending || status == .found }
    }

    /// A found value could not be submitted: nothing is on its way any more,
    /// so the state counts as settled.
    func submissionFailed(_ lookupGeneration: UInt64) {
        lock.withLock {
            if lookupGeneration == generation, status == .found { status = .absent }
        }
    }

    var current: CredentialLookupStatus { lock.withLock { status } }
}

/// Runs the credential part of an auto-fire plan, outside TDLib's callback
/// thread (PsychQuant/che-msg#49): sends the environment's value, or looks the
/// credential up and sends what it finds. `submit` claims the state's one
/// automatic value and sends it (#96): it returns false, sending nothing, when
/// the state has moved on or a value was already sent for it, by the auto-fire
/// or explicitly. `AuthCoordinator` takes the claim under the lock that also
/// guards the authorization state. A failed submission is passed to
/// `recordFailure` (for `auth_status`) before the state counts as settled, so
/// an answer given once it has settled carries the error; a failure for a
/// state that has moved on is not recorded. `AuthCoordinator` passes its
/// Keychain source, its claim-and-send and its auto-fire error record.
internal func runCredentialPlan(_ plan: CredentialPlan, generation: UInt64, tracker: CredentialLookupTracker,
                                lookup: @Sendable (KeychainCredential) async -> KeychainLookup,
                                submit: @Sendable (String) async throws -> Bool,
                                recordFailure: @Sendable (Error) -> Void) async {
    switch plan {
    case .nothing:
        return
    case .fire(let value):
        do { _ = try await submit(value) } catch { recordFailure(error) }
    case .lookUp(let credential):
        let result = await lookup(credential)
        guard tracker.finish(generation, miss: KeychainMiss(result)), let value = result.value else { return }
        do {
            if try await submit(value) { return }
            // A value went out for this state while the lookup ran: nothing
            // from the Keychain is on its way.
        } catch {
            if tracker.isCurrent(generation) { recordFailure(error) }
        }
        tracker.submissionFailed(generation)
    }
}
