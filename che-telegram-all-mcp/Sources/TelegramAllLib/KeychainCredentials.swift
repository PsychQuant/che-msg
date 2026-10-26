import Foundation

/// The two credentials the binary may read from the Keychain while TDLib waits
/// for them (PsychQuant/che-msg#49). The SMS code and the API credentials are
/// deliberately not here, so they cannot be looked up at all.
public enum KeychainCredential: String, CaseIterable, Sendable {
    case phone = "TELEGRAM_PHONE"
    case password = "TELEGRAM_2FA_PASSWORD"
}

/// The result of one Keychain lookup. Only `found` carries a value; everything
/// else means "no value" to the caller. The description never shows the value.
public enum KeychainLookup: Equatable, Sendable, CustomStringConvertible {
    case found(String)
    case absent
    case timedOut
    case unavailable(exitStatus: Int32)

    public var value: String? {
        if case .found(let value) = self { return value }
        return nil
    }

    public var description: String {
        switch self {
        case .found: return "found(<redacted>)"
        case .absent: return "absent"
        case .timedOut: return "timedOut"
        case .unavailable(let status): return "unavailable(exitStatus: \(status))"
        }
    }
}

/// Where Keychain credentials come from. Injected into `TDLibClient` so the
/// auto-fire and `auth_run` paths can be tested without a Keychain.
public protocol KeychainCredentialSource: Sendable {
    func lookup(_ credential: KeychainCredential) async -> KeychainLookup
}

/// Reads a credential with `/usr/bin/security find-generic-password`, the same
/// tool and items the wrapper and the README use. Spec: "Keychain credential
/// lookup is bounded and keeps no copy" (telegram-auth-coordination).
///
/// - The arguments are constants: account `che-telegram-all-mcp`, the
///   credential's service name, `-g`, and the keychain path only when one is
///   given (tests use a scratch keychain file; production passes none).
/// - `-g`, not `-w`: `-w` prints a value with any non-ASCII or control byte as
///   bare hex, which cannot be told apart from an ASCII value that looks like
///   hex. `-g` writes the attributes to stdout and the value to stderr as
///   `password: "<value>"` or `password: 0x<HEX>  "<escaped>"` (measured on
///   macOS 27; PsychQuant/che-msg#49 verify round 1).
/// - The child's stdin is the null device, so it can never read the MCP
///   server's JSON-RPC input; its stdout (attributes only) is discarded.
/// - A child still running after `timeout` seconds is terminated and the
///   result is `timedOut`.
/// - The value is returned and nothing else keeps it: no property, no cache,
///   no log. Diagnostics name the credential and the reason, never the value.
public struct SecurityCLICredentialSource: KeychainCredentialSource {
    public static let account = "che-telegram-all-mcp"

    public let executable: URL
    public let keychainPath: String?
    public let timeout: TimeInterval
    private let diagnostics: @Sendable (String) -> Void

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/security"), keychainPath: String? = nil,
                timeout: TimeInterval = 10,
                diagnostics: @escaping @Sendable (String) -> Void = SecurityCLICredentialSource.writeToStandardError) {
        self.executable = executable
        self.keychainPath = keychainPath
        self.timeout = timeout
        self.diagnostics = diagnostics
    }

    public static let writeToStandardError: @Sendable (String) -> Void = { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    func arguments(for credential: KeychainCredential) -> [String] {
        var args = ["find-generic-password", "-a", Self.account, "-s", credential.rawValue, "-g"]
        if let keychainPath { args.append(keychainPath) }
        return args
    }

    /// How long to wait for the child's stdout to reach EOF after the child
    /// has exited (another process may have inherited it), and how long a
    /// terminated child gets before it is killed.
    static let outputGrace: TimeInterval = 1
    static let killGrace: TimeInterval = 1

    public func lookup(_ credential: KeychainCredential) async -> KeychainLookup {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: credential)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        let output = OutputCollector(stderr.fileHandleForReading)

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<ChildOutcome, Never>) in
            let once = ResumeOnce(continuation)
            process.terminationHandler = { finished in
                once.resume(.exited(finished.terminationStatus))
            }
            do {
                try process.run()
            } catch {
                once.resume(.couldNotStart)
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                // Resume first: once terminated, the exit handler would report
                // the signal's exit status instead of the timeout.
                once.resume(.timedOut)
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        // Never wait on the pipe without a bound: a process that inherited the
        // child's stderr can keep it open after the child has gone. Nothing to
        // wait for when the child timed out or never started.
        let waitForOutput = outcome == .timedOut || outcome == .couldNotStart ? 0 : Self.outputGrace
        let (data, truncated) = await output.finish(waitingUpTo: waitForOutput)

        switch outcome {
        case .timedOut:
            diagnostics("che-telegram-all-mcp: Keychain lookup for \(credential.rawValue) did not finish within \(Self.format(timeout)) s; treated as not stored")
            return .timedOut
        case .couldNotStart:
            diagnostics("che-telegram-all-mcp: Keychain lookup for \(credential.rawValue) could not start \(executable.path); treated as not stored")
            return .unavailable(exitStatus: -1)
        case .exited(44):
            return .absent
        case .exited(0):
            if truncated {
                diagnostics("che-telegram-all-mcp: Keychain lookup for \(credential.rawValue) printed more than \(OutputCollector.limit) bytes; treated as not stored")
                return .unavailable(exitStatus: 0)
            }
            switch Self.parsePasswordLine(data) {
            case .value(let value):
                return value.isEmpty ? .absent : .found(value)
            case .unreadable(let reason):
                diagnostics("che-telegram-all-mcp: Keychain lookup for \(credential.rawValue) \(reason); treated as not stored")
                return .unavailable(exitStatus: 0)
            }
        case .exited(let status):
            diagnostics("che-telegram-all-mcp: Keychain lookup for \(credential.rawValue) failed with exit status \(status); treated as not stored")
            return .unavailable(exitStatus: status)
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
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix("password:") }) else {
            return .unreadable("printed no password line")
        }
        let rest = line.dropFirst("password:".count).drop(while: { $0 == " " })
        if rest.isEmpty { return .value("") }
        if rest.hasPrefix("0x") {
            let digits = rest.dropFirst(2)
            let hex = digits.prefix { $0.isHexDigit }
            // The hex is followed by nothing or by `  "<escaped>"`; anything else is not this form.
            let afterHex = digits.dropFirst(hex.count)
            guard hex.count % 2 == 0, !hex.isEmpty, afterHex.isEmpty || afterHex.first == " " else {
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
            guard let value = String(bytes: bytes, encoding: .utf8) else {
                return .unreadable("holds a value that is not UTF-8")
            }
            return .value(value)
        }
        if rest.count >= 2, rest.hasPrefix("\""), rest.hasSuffix("\"") {
            return .value(String(rest.dropFirst().dropLast()))
        }
        return .unreadable("printed a password line in an unknown form")
    }

    private static func format(_ seconds: TimeInterval) -> String {
        seconds == seconds.rounded() ? String(Int(seconds)) : String(seconds)
    }
}

private enum ChildOutcome: Equatable, Sendable {
    case exited(Int32)
    case timedOut
    case couldNotStart
}

/// Collects a child's output in the background, up to `limit` bytes, so the
/// child never blocks on a full pipe and the caller never blocks on EOF.
final class OutputCollector: @unchecked Sendable {
    static let limit = 64 * 1024
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var reachedEnd = false
    private var truncated = false

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] readable in
            let chunk = readable.availableData
            guard let self else { return }
            self.lock.withLock {
                if chunk.isEmpty {
                    self.reachedEnd = true
                } else {
                    let room = Self.limit - self.data.count
                    if chunk.count > room { self.truncated = true }
                    if room > 0 { self.data.append(chunk.prefix(room)) }
                }
            }
            if chunk.isEmpty { readable.readabilityHandler = nil }
        }
    }

    /// Waits up to `seconds` for EOF, then stops reading and returns what
    /// arrived, and whether more than `limit` bytes were written.
    func finish(waitingUpTo seconds: TimeInterval) async -> (Data, Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !lock.withLock({ reachedEnd }), Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        handle.readabilityHandler = nil
        try? handle.close()
        return lock.withLock { (data, truncated) }
    }
}

/// Resumes a continuation once, whichever of exit and timeout comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ChildOutcome, Never>?

    init(_ continuation: CheckedContinuation<ChildOutcome, Never>) { self.continuation = continuation }

    func resume(_ outcome: ChildOutcome) {
        let pending: CheckedContinuation<ChildOutcome, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: outcome)
    }
}
