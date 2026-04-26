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
