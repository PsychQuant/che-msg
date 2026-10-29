import Foundation
import MCP

/// Reads one tool call's arguments and checks each against its allowed form
/// and range before the Keychain is read or Slack is called (spec:
/// slack-mcp-tools, "Conversation read tools": an argument outside its
/// allowed form or range is an error naming the argument, without calling
/// Slack).
///
/// Rules shared by every argument:
/// - absent and JSON `null` both mean omitted;
/// - a value of the wrong JSON type is refused, never converted: a string
///   is not read as a number, a number not as a timestamp, `true` not as 1;
/// - a refusal names the argument and says what is allowed, and never
///   repeats the value given;
/// - arguments the tool does not define are ignored.
struct ToolArguments: Sendable {
    let values: [String: Value]

    init(_ values: [String: Value]) { self.values = values }

    /// An integer within `bounds.range`, or `bounds.defaultValue` when
    /// omitted. A JSON number with a fractional part of zero (`50.0`) is the
    /// integer it equals; any other fraction, a string or a boolean is
    /// refused.
    func integer(_ name: String, _ bounds: IntegerBounds) throws(ToolFailure) -> Int {
        let range = bounds.range
        let refusal = ToolFailure("\(name) must be an integer from \(range.lowerBound) to \(range.upperBound).")
        let number: Int
        switch values[name] {
        case nil, .null?:
            return bounds.defaultValue
        case let .int(value)?:
            number = value
        case let .double(value)? where value.rounded() == value && abs(value) < 1e15:
            number = Int(value)
        default:
            throw refusal
        }
        guard range.contains(number) else { throw refusal }
        return number
    }

    /// A required Slack id (`C0123ABCD`, `U0123ABCD`): a string of 1 to 64
    /// ASCII letters and digits. A name such as `#general` or `@alice` is
    /// refused rather than sent to Slack.
    func id(_ name: String, _ meaning: String) throws(ToolFailure) -> String {
        guard case let .string(value)? = values[name], Self.isSlackID(value) else {
            throw ToolFailure("\(name) is required and must be \(meaning): a Slack id made of letters and digits; "
                              + "a name such as #general or @alice is not accepted.")
        }
        return value
    }

    /// 1 to 64 ASCII letters and digits, the form of every Slack id.
    static func isSlackID(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count) && value.utf8.allSatisfy(isASCIIAlphanumeric)
    }

    /// A required Slack timestamp string.
    func timestamp(_ name: String) throws(ToolFailure) -> String {
        guard let value = try optionalTimestamp(name) else { throw Self.timestampRefusal(name, required: true) }
        return value
    }

    /// A Slack timestamp string (`1730000000.000100` or `1730000000`): ASCII
    /// digits, optionally a point and more digits, at most 32 characters. A
    /// JSON number is refused because it cannot hold a message's `ts`
    /// exactly (`1730000000.000100` would become `1730000000.0001`).
    func optionalTimestamp(_ name: String) throws(ToolFailure) -> String? {
        switch values[name] {
        case nil, .null?:
            return nil
        case let .string(value)? where Self.isTimestamp(value):
            return value
        default:
            throw Self.timestampRefusal(name, required: false)
        }
    }

    private static func timestampRefusal(_ name: String, required: Bool) -> ToolFailure {
        ToolFailure("\(name) \(required ? "is required and " : "")must be a Slack timestamp written as a string, "
                    + "such as \"1730000000.000100\".")
    }

    static func isTimestamp(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return value.utf8.count <= 32 && (1...2).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.utf8.allSatisfy(isASCIIDigit) }
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        isASCIIDigit(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    /// A required string that is not empty or only whitespace, returned
    /// exactly as given (not trimmed).
    func nonBlankString(_ name: String, _ meaning: String) throws(ToolFailure) -> String {
        guard case let .string(value)? = values[name],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ToolFailure("\(name) is required and must be a non-empty string: \(meaning).")
        }
        return value
    }

    /// `nonBlankString`, also refused when longer than `limit` UTF-16 code
    /// units. UTF-16 units are never fewer than Unicode scalars or
    /// user-perceived characters, so a text within `limit` here is within it
    /// whichever of those a service counts; an emoji outside the Basic
    /// Multilingual Plane counts as 2.
    func nonBlankString(_ name: String, _ meaning: String, maxUTF16Length limit: Int) throws(ToolFailure) -> String {
        let value = try nonBlankString(name, meaning)
        let length = value.utf16.count
        guard length <= limit else {
            throw ToolFailure("\(name) must be at most \(limit) characters, counted as UTF-16 code units (an emoji "
                              + "may count as 2); this one has \(length).")
        }
        return value
    }
}

/// An integer argument's allowed range and its value when omitted; the
/// same value feeds the check and the `tools/list` schema.
struct IntegerBounds: Sendable {
    let range: ClosedRange<Int>
    let defaultValue: Int
}
