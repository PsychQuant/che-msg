import Foundation

/// The result of reading one Keychain item. Only `found` carries a value.
/// The description never shows it, and `unavailable`'s reason is written by
/// the reader from fixed phrases, never from the item's content.
public enum KeychainLookup: Equatable, Sendable, CustomStringConvertible {
    case found(String)
    /// The item does not exist, or holds an empty value.
    case absent
    /// The lookup was still running after `after` seconds and was stopped.
    case timedOut(after: TimeInterval)
    /// The tool failed or printed something that is not a value.
    case unavailable(reason: String)

    public var value: String? {
        if case .found(let value) = self { return value }
        return nil
    }

    public var description: String {
        switch self {
        case .found: return "found(\(SlackCredential.redacted))"
        case .absent: return "absent"
        case .timedOut(let seconds): return "timedOut(after: \(formatSeconds(seconds)) s)"
        case .unavailable(let reason): return "unavailable(\(reason))"
        }
    }
}

/// Reads Keychain items by service name under the account `che-slack-mcp`.
/// The MCP server and the CLI take one of these so their tests can inject a
/// fake instead of a Keychain.
public protocol KeychainItemReader: Sendable {
    func read(service: String) async -> KeychainLookup
}

/// Reads an item with `/usr/bin/security find-generic-password -g` (spec:
/// slack-credentials, "Credential lookup is bounded"), the same tool that
/// writes the items, so reading never meets an ACL that trusts another binary.
///
/// - The arguments are constants: account `che-slack-mcp`, the service, `-g`,
///   and the keychain path only when one is given (tests pass a scratch
///   keychain file; production passes none and uses the user's search list).
/// - `-g`, not `-w`: `-w` prints a value with any non-ASCII or control byte as
///   bare hex, which cannot be told apart from an ASCII value that looks like
///   hex. `-g` writes the attributes to stdout and the value to stderr as
///   `password: "<value>"` or `password: 0x<HEX>  "<escaped>"`.
/// - The child's stdin is the null device, so it can never read the MCP
///   server's JSON-RPC input; its stdout (attributes only) is discarded.
/// - A child still running after `timeout` seconds is terminated (killed
///   after a further second) and the result is `timedOut`.
/// - The value is returned and nothing else keeps it: no property, no cache.
public struct SecurityCLIKeychainReader: KeychainItemReader {
    public let executable: URL
    public let keychainPath: String?
    public let timeout: TimeInterval

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/security"), keychainPath: String? = nil,
                timeout: TimeInterval = 10) {
        self.executable = executable
        self.keychainPath = keychainPath
        self.timeout = timeout
    }

    func arguments(for service: String) -> [String] {
        var args = ["find-generic-password", "-a", SlackKeychain.account, "-s", service, "-g"]
        if let keychainPath { args.append(keychainPath) }
        return args
    }

    /// How long to wait for the child's stderr to reach EOF after the child
    /// has exited (another process may have inherited it), and how long a
    /// terminated child gets before it is killed.
    static let outputGrace: TimeInterval = 1
    static let killGrace: TimeInterval = 1

    public func read(service: String) async -> KeychainLookup {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: service)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let output = OutputCollector(stderr.fileHandleForReading)

        let outcome = await runBounded(process, timeout: timeout, killGrace: Self.killGrace)
        // Never wait on the pipe without a bound: a process that inherited the
        // child's stderr can keep it open after the child has gone.
        let waitForOutput = outcome == .timedOut || outcome == .couldNotStart ? 0 : Self.outputGrace
        let (data, truncated) = await output.finish(waitingUpTo: waitForOutput)

        switch outcome {
        case .timedOut:
            return .timedOut(after: timeout)
        case .couldNotStart:
            return .unavailable(reason: "could not start \(executable.path)")
        case .exited(44):
            return .absent
        case .exited(0):
            if truncated { return .unavailable(reason: "printed more than \(OutputCollector.limit) bytes") }
            switch Self.parsePasswordLine(data) {
            case .value(let value): return value.isEmpty ? .absent : .found(value)
            case .unreadable(let reason): return .unavailable(reason: reason)
            }
        case .exited(let status):
            return .unavailable(reason: "exited with status \(status)")
        }
    }

    enum PasswordLine: Equatable {
        case value(String)
        case unreadable(String)   // why, never the value
    }

    /// The value on the `password:` line of `security -g`'s stderr: the text
    /// between the quotes, or the hex after `0x` decoded as UTF-8.
    static func parsePasswordLine(_ stderr: Data) -> PasswordLine {
        let text = String(decoding: stderr, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let index = lines.firstIndex(where: { $0.hasPrefix("password:") }) else {
            return .unreadable("printed no password line")
        }
        // `security` ends the line with a newline; without one the output may
        // have been cut short.
        guard index < lines.count - 1 else { return .unreadable("printed a password line without its end") }
        let rest = lines[index].dropFirst("password:".count).drop(while: { $0 == " " })
        if rest.isEmpty { return .value("") }
        if rest.hasPrefix("0x") { return decodeHex(rest.dropFirst(2)) }
        if rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") {
            return .value(String(rest.dropFirst().dropLast()))
        }
        return .unreadable("printed a password line in an unknown form")
    }

    /// `digits` is what follows `0x`: hex digits, then nothing or
    /// `  "<escaped>"`. Anything else is not this form.
    private static func decodeHex(_ digits: Substring) -> PasswordLine {
        let hex = digits.prefix { $0.isHexDigit }
        let afterHex = digits.dropFirst(hex.count)
        guard !hex.isEmpty, hex.count % 2 == 0, afterHex.isEmpty || afterHex.first == " " else {
            return .unreadable("printed a malformed hex value")
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return .unreadable("printed a malformed hex value")
            }
            bytes.append(byte)
            index = next
        }
        // Validate first, then decode with String(decoding:), which keeps a
        // leading U+FEFF that String(bytes:encoding:) would drop.
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            return .unreadable("holds a value that is not UTF-8")
        }
        return .value(String(decoding: bytes, as: UTF8.self))
    }
}

/// `10` for whole seconds, `0.5` otherwise.
func formatSeconds(_ seconds: TimeInterval) -> String {
    seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
}
