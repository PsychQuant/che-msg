import Foundation

/// The body of a message as both Markdown writers write it — `dump_chat_to_markdown` and the
/// archive's day files (PsychQuant/che-msg#82). Each writer brings its own label (`[voice]` in
/// the dump, `[voice_note](media/<id>/)` in the archive); the detail after it is defined here once.
enum MessageBody {
    /// A text message's text; otherwise `placeholder`, then a space and the inline detail when
    /// there is one, then a poll's option lines.
    static func render(_ message: [String: Any], placeholder: String) -> String {
        if (message["type"] as? String) == "text" { return (message["text"] as? String) ?? "" }
        let detail = detail(of: message)
        let head = detail.inline.map { "\(placeholder) \($0)" } ?? placeholder
        return ([head] + detail.lines).joined(separator: "\n")
    }

    /// What a non-text message carries, by type: a poll's question and one `- <option>` line per
    /// non-empty option; a sticker's emoji; a location's `<latitude>,<longitude>`; any other
    /// type's caption. A missing or empty value is none — as everything is for a message read
    /// from the local cache, which decodes none of these fields.
    static func detail(of message: [String: Any]) -> (inline: String?, lines: [String]) {
        let nonEmpty: (Any?) -> String? = { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch message["type"] as? String {
        case "poll":
            let options = (message["options"] as? [String] ?? []).filter { !$0.isEmpty }
            return (nonEmpty(message["question"]), options.map { "- " + oneLine($0) })
        case "sticker":
            return (nonEmpty(message["emoji"]), [])
        case "location":
            guard let latitude = coordinate(message["latitude"]), let longitude = coordinate(message["longitude"]) else {
                return (nil, [])
            }
            return ("\(plainDecimal(latitude)),\(plainDecimal(longitude))", [])
        default:
            return (nonEmpty(message["caption"]), [])
        }
    }

    /// `value` with the fewest digits that read back as the same `Double` (Swift's own
    /// description), in positional notation: `1e-05` becomes `0.00001`. Only the decimal point
    /// moves, so nothing is rounded.
    static func plainDecimal(_ value: Double) -> String {
        let text = "\(value)"
        guard let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }),
              let exponent = Int(text[text.index(after: e)...]) else { return text }
        var mantissa = text[..<e]
        let sign = mantissa.hasPrefix("-") ? "-" : ""
        if !sign.isEmpty { mantissa = mantissa.dropFirst() }
        let point = mantissa.firstIndex(of: ".").map { mantissa.distance(from: mantissa.startIndex, to: $0) }
            ?? mantissa.count
        let digits = mantissa.filter { $0 != "." }
        let position = point + exponent
        if position <= 0 { return sign + "0." + String(repeating: "0", count: -position) + digits }
        if position >= digits.count {
            return sign + digits + String(repeating: "0", count: position - digits.count) + ".0"
        }
        return sign + digits.prefix(position) + "." + digits.dropFirst(position)
    }

    /// A finite number, from JSON (`NSNumber`) or from `messageToDict` (`Double`).
    private static func coordinate(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// One option per line: a line break inside an option becomes a space, found by scalar so that
    /// a mark after it does not hide it.
    private static func oneLine(_ text: String) -> String {
        ScalarText.replacingLineBreaks(in: text, with: " ")
    }
}
