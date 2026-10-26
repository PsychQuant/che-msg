import Foundation
import MCP
import TelegramAllLib

/// Builds an MCP `CallTool.Result` for a structured TDLib auth error.
///
/// Per spec requirement "MCP response error serialization" (design Decision 3),
/// the response payload includes the discrete `code` and `message` fields so AI
/// agents can distinguish flood-wait from invalid-code from internal-error
/// without parsing free-text. Caller-detectable via `isError == true` and a
/// JSON content block of shape `{"type":"tdlib_error","code":<int>,"message":<string>}`.
///
/// - Parameters:
///   - code: TDLib numeric error code (e.g., 420 for FLOOD_WAIT, 400 for invalid args).
///   - message: TDLib error message (e.g., "FLOOD_WAIT_30").
///   - hint: What the caller can do next, added as a `hint` field when given (#71).
/// - Returns: An MCP tool-call result with `isError: true` and a JSON-encoded
///   text content block carrying the structured error fields.
internal func tdlibErrorResult(code: Int, message: String, hint: String? = nil) -> CallTool.Result {
    var payload: [String: Any] = [
        "type": "tdlib_error",
        "code": code,
        "message": message,
    ]
    if let hint { payload["hint"] = hint }
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        ?? Data(#"{"type":"tdlib_error","code":0,"message":""}"#.utf8)
    let json = String(data: data, encoding: .utf8) ?? ""
    return CallTool.Result(
        content: [.text(text: json, annotations: nil, _meta: nil)],
        isError: true
    )
}

/// The result any tool returns for a TDLib error (PsychQuant/che-msg#71): `tdlibError` with
/// its code and message, and `unknownChat` the same way plus its `hint`. Nil for every
/// other error, which keeps its plain-text result (`errorResultFromParse`).
internal func tdlibErrorResult(for error: Error) -> CallTool.Result? {
    guard let error = error as? TDLibClient.TDError else { return nil }
    switch error {
    case .tdlibError(let code, let message):
        return tdlibErrorResult(code: code, message: message)
    case .unknownChat(_, let code, let message):
        return tdlibErrorResult(code: code, message: message, hint: error.hint)
    case .notAuthenticated, .missingCredentials, .sessionClosed:
        return nil
    }
}
