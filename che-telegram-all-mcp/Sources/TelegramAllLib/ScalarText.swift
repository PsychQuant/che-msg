import Foundation

/// Text checks for the Markdown writers, by Unicode scalar (#72, #76). Swift's `hasPrefix`, `==`
/// and `String.range(of:options:)` compare `Character`s, and Foundation's default
/// `replacingOccurrences` compares composed sequences: a combining mark, ZWJ, variation selector or
/// CGJ after `<!--`, a time or a line break fuses with the character before it, so those checks miss
/// a `<!--`, a block header or a line break that every reader comparing code points sees.
enum ScalarText {
    /// True when `line` begins with exactly the scalars of `prefix`.
    static func starts(_ line: some StringProtocol, with prefix: String) -> Bool {
        line.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// True when `line` is exactly the scalars of `other`.
    static func equals(_ line: some StringProtocol, _ other: String) -> Bool {
        line.unicodeScalars.elementsEqual(other.unicodeScalars)
    }

    /// True when `line` begins like a block header: `**`, one or two ASCII digits, `:`, two ASCII digits.
    static func startsLikeHeader(_ line: some StringProtocol) -> Bool {
        let scalars = Array(line.unicodeScalars.prefix(7))
        let digit: (Unicode.Scalar) -> Bool = { ("0"..."9").contains($0) }
        guard scalars.count >= 6, scalars[0] == "*", scalars[1] == "*", digit(scalars[2]) else { return false }
        let colon = scalars[3] == ":" ? 3 : (digit(scalars[3]) ? 4 : -1)
        guard colon > 0, scalars.count >= colon + 3, scalars[colon] == ":" else { return false }
        return digit(scalars[colon + 1]) && digit(scalars[colon + 2])
    }

    /// `text` with every CR LF, lone CR and LF replaced by `replacement`.
    static func replacingLineBreaks(in text: String, with replacement: String) -> String {
        var out = String.UnicodeScalarView()
        var afterCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" && afterCR { afterCR = false; continue }   // the LF of a CR LF
            afterCR = scalar == "\r"
            if scalar == "\r" || scalar == "\n" { out.append(contentsOf: replacement.unicodeScalars) } else { out.append(scalar) }
        }
        return String(out)
    }

    /// `text` with every CR LF replaced by LF; a lone CR stays where it is.
    static func replacingCRLF(in text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n", out.last == "\r" { out.removeLast() }
            out.append(scalar)
        }
        return String(out)
    }

    /// `text` split at LF scalars, each line as a `String`.
    static func lines(_ text: some StringProtocol) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }
}
