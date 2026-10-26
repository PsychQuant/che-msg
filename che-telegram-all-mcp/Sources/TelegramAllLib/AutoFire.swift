import Foundation

/// Decision returned by `decideAutoFire` for the auto-fire chain.
///
/// `TDLibClient`'s callback handler reads the current `authState` plus the
/// process environment, calls this pure function, and dispatches based on
/// the returned action. Extracting the routing decision keeps it unit-testable
/// (no `ProcessInfo` mocking, no `TDLibClient` instance setup).
internal enum AutoFireAction: Equatable {
    case fireSetParameters(apiId: Int, apiHash: String)
    case fireSendPhone(String)
    case fireSendPassword(String)
    case noOp
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
internal enum CredentialPlan: Equatable {
    case fire(String)
    case lookUp(KeychainCredential)
    case nothing
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

    /// Records a state change; `lookingUp` when a lookup starts for the new
    /// state. Returns the generation that lookup must finish with.
    func stateChanged(lookingUp: Bool) -> UInt64 {
        lock.withLock {
            generation &+= 1
            status = lookingUp ? .pending : .notNeeded
            return generation
        }
    }

    /// Records a lookup's outcome. Returns false, changing nothing, when the
    /// state has changed since the lookup started.
    func finish(_ lookupGeneration: UInt64, found: Bool) -> Bool {
        lock.withLock {
            guard lookupGeneration == generation else { return false }
            status = found ? .found : .absent
            return true
        }
    }

    var current: CredentialLookupStatus { lock.withLock { status } }
}
