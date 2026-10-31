import Foundation
import SlackWebLib

/// Slack message markup to markdown (spec: slack-chat-archive, "Slack
/// markup conversion").
///
/// Slack writes a literal `<`, `>` or `&` in message text as `&lt;`, `&gt;`
/// or `&amp;`, so every `<…>` in the text is markup. Each one becomes:
/// - `<@U123>` → `@` and the user's name, else `@U123`; `<@U123|label>`
///   with an unknown user → `@label` (spec silent: the label Slack sent);
/// - `<#C123|general>` → `#general`; `<#C123>` → `#C123` (spec silent);
/// - `<!here>`, `<!channel>`, `<!everyone>` → `@here` and so on; any other
///   `<!…|label>` → its label (spec silent);
/// - `<https://x|label>` → `[label](https://x)`; `<https://x>` → `https://x`.
///
/// The entities `&amp;`, `&lt;` and `&gt;` are then decoded, once, in the
/// plain text, the labels and the links. A `<` with no closing `>` is kept
/// as text.
enum SlackMarkup {
    /// The archive body of a message: its converted text, then one line
    /// `[file: <name>](<permalink>)` per attached file. Nothing is
    /// downloaded (design: 第一版不下載檔案). Spec silent, chosen: a file
    /// without a permalink is `[file: <name>]`; a file without a name uses
    /// its title, then its id, then `file`.
    static func body(text: String?, files: [SlackFile], userName: (String) -> String?) -> String {
        var lines: [String] = []
        if let text, !text.isEmpty { lines.append(markdown(text, userName: userName)) }
        lines += files.map(fileLine)
        return lines.joined(separator: "\n")
    }

    static func fileLine(_ file: SlackFile) -> String {
        let name = [file.name, file.title, file.id].compactMap { $0 }.first { !$0.isEmpty } ?? "file"
        guard let link = file.permalink, !link.isEmpty else { return "[file: \(name)]" }
        return "[file: \(name)](\(link))"
    }

    /// `text` with its markup converted.
    static func markdown(_ text: String, userName: (String) -> String?) -> String {
        var out = ""
        for piece in pieces(text) {
            switch piece {
            case .text(let plain): out += decodeEntities(plain)
            case .markup(let inner): out += convert(inner, userName: userName)
            }
        }
        return out
    }

    /// The user ids mentioned with `<@…>`, in order of first mention, each once.
    static func mentionedUsers(_ text: String) -> [String] {
        var seen: Set<String> = []
        var users: [String] = []
        for case .markup(let inner) in pieces(text) where inner.hasPrefix("@") {
            let user = target(inner.dropFirst())
            if !user.isEmpty, seen.insert(user).inserted { users.append(user) }
        }
        return users
    }

    private enum Piece {
        case text(Substring)
        case markup(Substring)
    }

    /// `text` split into plain runs and the insides of `<…>`.
    private static func pieces(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "<") {
            guard let close = rest[open...].firstIndex(of: ">") else { break }
            if open > rest.startIndex { pieces.append(.text(rest[..<open])) }
            pieces.append(.markup(rest[rest.index(after: open)..<close]))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { pieces.append(.text(rest)) }
        return pieces
    }

    private static func convert(_ inner: Substring, userName: (String) -> String?) -> String {
        let label = self.label(inner).map(decodeEntities)
        switch inner.first {
        case "@":
            let user = target(inner.dropFirst())
            return "@" + (userName(user) ?? label ?? user)
        case "#":
            return "#" + (label ?? target(inner.dropFirst()))
        case "!":
            if let label { return label }
            return "@" + (target(inner.dropFirst()).split(separator: "^").first.map(String.init) ?? "")
        default:
            let link = decodeEntities(inner.prefix { $0 != "|" })
            guard let label else { return link }
            return "[\(label)](\(link))"
        }
    }

    /// The part before `|`.
    private static func target(_ inner: Substring) -> String { String(inner.prefix { $0 != "|" }) }

    /// The part after the first `|`, when there is one.
    private static func label(_ inner: Substring) -> Substring? {
        inner.firstIndex(of: "|").map { inner[inner.index(after: $0)...] }
    }

    /// `&amp;`, `&lt;` and `&gt;` decoded in one pass, so `&amp;lt;` is `&lt;`.
    static func decodeEntities<S: StringProtocol>(_ text: S) -> String {
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let tail = rest[amp...]
            if let (entity, decoded) = [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">")].first(where: { tail.hasPrefix($0.0) }) {
                out += decoded
                rest = tail.dropFirst(entity.count)
            } else {
                out += "&"
                rest = tail.dropFirst()
            }
        }
        return out + rest
    }
}
