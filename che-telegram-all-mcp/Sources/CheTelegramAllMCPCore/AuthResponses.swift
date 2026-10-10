import Foundation
import MCP
import TelegramAllLib

// MARK: - auth_status response

/// Builds an MCP `CallTool.Result` for the `auth_status` tool.
///
/// Per spec requirement "`auth_status` response includes structured next-step hint"
/// (design Decision 5), the response includes:
///   - `state`: matching `TDLibClient.AuthState` raw value
///   - `next_step`: null when ready/closed, otherwise `{tool, required_args, hint}`
///   - `last_error`: null when no auto-fire failure, otherwise structured payload
///   - `connection_state`, `unsynced_seconds`, `sync_stalled`: whether TDLib is
///     synced with Telegram (#63). A session Telegram has invalidated stays
///     `ready` and never syncs; once stalled, `next_step` points to `logout`.
///
/// All three fields are deterministic given (state, lastError) — no env var
/// inspection. The caller is told what arguments to provide; auto-fire (if env
/// vars present) handles the same advancement concurrently via coalescing.
internal func authStatusResult(
    state: TDLibClient.AuthState,
    lastError: TDLibClient.TDError?,
    sync: TDLibSyncState.Snapshot = .init(connectionState: nil, isSynced: false, unsyncedSeconds: 0)
) -> CallTool.Result {
    // Only time spent updating makes a session stalled; offline never does.
    let stalled = state == .ready && sync.isStalled()
    let nextStep = stalled ? stalledNextStep(updatingSeconds: sync.updatingSeconds) : authStatusNextStep(state: state)
    let payload: [String: Any] = [
        "state": state.rawValue,
        "next_step": nextStep ?? NSNull(),
        "last_error": authStatusLastError(lastError) ?? NSNull(),
        "connection_state": sync.connectionState ?? NSNull(),
        "unsynced_seconds": sync.unsyncedSeconds,
        "sync_stalled": stalled,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        ?? Data(#"{"state":"unknown","next_step":null,"last_error":null,"connection_state":null,"unsynced_seconds":0,"sync_stalled":false}"#.utf8)
    let json = String(data: data, encoding: .utf8) ?? ""
    return CallTool.Result(
        content: [.text(text: json, annotations: nil, _meta: nil)],
        isError: false
    )
}

/// `next_step` when TDLib is authorized but has been updating without
/// finishing for the stall threshold (#63). `logout` resets the local session
/// and a new login needs a code, so the hint asks for the user first.
private func stalledNextStep(updatingSeconds: Int) -> [String: Any] {
    [
        "tool": "logout",
        "required_args": [String](),
        "hint": "TDLib has been updating for \(updatingSeconds) s without finishing although it is logged in. "
            + "A session invalidated by Telegram (for example, the same session used in two places at once) is the likely cause. "
            + "First ask the user: logout resets the local session (its data is moved aside, not deleted) and logging in "
            + "again needs a code sent to the account. With their agreement, call logout, then log in again with auth_run.",
    ]
}

private func authStatusNextStep(state: TDLibClient.AuthState) -> [String: Any]? {
    switch state {
    case .ready, .closed:
        return nil
    case .waitingForParameters:
        return [
            "tool": "auth_run",
            "required_args": ["api_id", "api_hash"],
            "hint": "Provide Telegram API credentials. Get them from https://my.telegram.org/apps.",
        ]
    case .waitingForPhoneNumber:
        return [
            "tool": "auth_run",
            "required_args": ["phone"],
            "hint": "Provide your Telegram phone number in international format (e.g., +886912345678).",
        ]
    case .waitingForCode:
        return [
            "tool": "auth_run",
            "required_args": ["code"],
            "hint": "Enter the verification code Telegram sent to your registered device.",
        ]
    case .waitingForPassword:
        return [
            "tool": "auth_run",
            "required_args": ["password"],
            "hint": "Enter your two-factor authentication password.",
        ]
    }
}

private func authStatusLastError(_ error: TDLibClient.TDError?) -> [String: Any]? {
    guard let error else { return nil }
    switch error {
    case .tdlibError(let code, let message):
        return [
            "type": "tdlib_error",
            "code": code,
            "message": message,
        ]
    case .notAuthenticated, .missingCredentials:
        // Spec scope is "Auto-fire failure surfacing" — only TDLib-origin errors
        // populate lastAutoFireError. Other TDError cases shouldn't reach this
        // serializer, but if they do, return a coherent shape.
        return [
            "type": "client_error",
            "message": error.errorDescription ?? "client error",
        ]
    }
}

// MARK: - auth_run state-machine routing

/// Decision returned by `decideAuthRunAction`, used by Server's `auth_run`
/// handler to dispatch to the correct TDLibClient method.
internal enum AuthRunAction: Equatable {
    case callSetParameters(apiId: Int, apiHash: String)
    case callSendPhone(String)
    case callSendCode(String)
    case callSendPassword(String)
    case noOpReady
    case errorClosed
    case needsArgs([String])
}

/// Pure routing function for the `auth_run` MCP tool.
///
/// - Caller-supplied args take precedence over env vars (caller knows
///   what they want; env vars are convenience defaults).
/// - For `waitingForCode`, env vars MUST NOT be honored — the SMS code
///   is one-shot delivery. Caller arg is required.
internal func decideAuthRunAction(
    state: TDLibClient.AuthState,
    phone: String?,
    code: String?,
    password: String?,
    envApiId: Int?,
    envApiHash: String?,
    envPhone: String?,
    envPassword: String?
) -> AuthRunAction {
    switch state {
    case .waitingForParameters:
        if let id = envApiId, let hash = envApiHash {
            return .callSetParameters(apiId: id, apiHash: hash)
        }
        return .needsArgs(["api_id", "api_hash"])

    case .waitingForPhoneNumber:
        if let arg = phone { return .callSendPhone(arg) }
        if let env = envPhone { return .callSendPhone(env) }
        return .needsArgs(["phone"])

    case .waitingForCode:
        if let arg = code { return .callSendCode(arg) }
        return .needsArgs(["code"])

    case .waitingForPassword:
        if let arg = password { return .callSendPassword(arg) }
        if let env = envPassword { return .callSendPassword(env) }
        return .needsArgs(["password"])

    case .ready:
        return .noOpReady

    case .closed:
        return .errorClosed
    }
}
