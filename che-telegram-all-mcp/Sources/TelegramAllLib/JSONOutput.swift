import Foundation

/// The JSON serializer shared by `TDLibClient.toJSON` and
/// `LocalTDLibReader.json`, so the two cannot drift apart. Compact with
/// sorted keys: no line breaks, indentation or spaces around colons, which
/// only cost tokens (PsychQuant/che-msg#101). Not every tool result goes
/// through it: auth, logout, error payloads and the archive and dump
/// summaries serialize on their own.
enum JSONOutput {
    static func string(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
