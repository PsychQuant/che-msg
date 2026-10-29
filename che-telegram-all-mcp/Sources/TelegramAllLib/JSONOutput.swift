import Foundation

/// The one place telegram-all turns a tool result into a JSON string, shared by
/// `TDLibClient.toJSON` and `LocalTDLibReader.json` so the two cannot drift
/// apart. Compact with sorted keys: no line breaks, indentation or spaces
/// around colons, which only cost tokens (PsychQuant/che-msg#101).
enum JSONOutput {
    static func string(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
