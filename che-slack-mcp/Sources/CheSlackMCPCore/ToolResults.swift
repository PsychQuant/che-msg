import Foundation
import MCP

/// A tool call that stops before doing its work, with the message the
/// caller sees. The message is written by this module from fixed phrases,
/// workspace names, team ids, domains and Keychain service names; it never
/// holds a token or a cookie.
struct ToolFailure: Error, Equatable, Sendable {
    let message: String

    init(_ message: String) { self.message = message }

    /// The failure as a tool result with `isError: true`.
    var result: CallTool.Result { ToolResult.error(message) }
}

/// How every tool answers. Success is one text item holding JSON with
/// sorted keys; failure is one text item `Error: <message>` with
/// `isError: true` (the same shapes as che-telegram-all-mcp).
enum ToolResult {
    static func error(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: "Error: \(message)", annotations: nil, _meta: nil)], isError: true)
    }

    static func json<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return error("could not encode the result as JSON")
        }
        return CallTool.Result(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                               isError: false)
    }
}
