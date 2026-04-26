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
///
/// All three fields are deterministic given (state, lastError) — no env var
/// inspection. The caller is told what arguments to provide; auto-fire (if env
/// vars present) handles the same advancement concurrently via coalescing.
internal func authStatusResult(
    state: TDLibClient.AuthState,
    lastError: TDLibClient.TDError?
) -> CallTool.Result {
    let payload: [String: Any] = [
        "state": state.rawValue,
        "next_step": authStatusNextStep(state: state) ?? NSNull(),
        "last_error": authStatusLastError(lastError) ?? NSNull(),
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        ?? Data(#"{"state":"unknown","next_step":null,"last_error":null}"#.utf8)
    let json = String(data: data, encoding: .utf8) ?? ""
    return CallTool.Result(
        content: [.text(text: json, annotations: nil, _meta: nil)],
        isError: false
    )
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
