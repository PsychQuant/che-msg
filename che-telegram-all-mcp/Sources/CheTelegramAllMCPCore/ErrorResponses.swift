import Foundation
import MCP

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
/// - Returns: An MCP tool-call result with `isError: true` and a JSON-encoded
///   text content block carrying the structured error fields.
internal func tdlibErrorResult(code: Int, message: String) -> CallTool.Result {
    let payload: [String: Any] = [
        "type": "tdlib_error",
        "code": code,
        "message": message,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
        ?? Data(#"{"type":"tdlib_error","code":0,"message":""}"#.utf8)
    let json = String(data: data, encoding: .utf8) ?? ""
    return CallTool.Result(
        content: [.text(text: json, annotations: nil, _meta: nil)],
        isError: true
    )
}
