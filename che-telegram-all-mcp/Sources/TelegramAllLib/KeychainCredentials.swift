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
///   credential's service name, `-w`, and the keychain path only when one is
///   given (tests use a scratch keychain file; production passes none).
/// - The child's stdin is the null device, so it can never read the MCP
///   server's JSON-RPC input; its stderr is discarded.
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
        var args = ["find-generic-password", "-a", Self.account, "-s", credential.rawValue, "-w"]
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
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let output = OutputCollector(stdout.fileHandleForReading)

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
                process.terminate()
                once.resume(.timedOut)
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.killGrace) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        // Never wait on the pipe without a bound: a process that inherited the
        // child's stdout can keep it open after the child has gone.
        let data = await output.finish(waitingUpTo: outcome == .timedOut ? 0 : Self.outputGrace)

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
            var value = String(decoding: data, as: UTF8.self)
            if value.hasSuffix("\n") { value.removeLast() }
            return value.isEmpty ? .absent : .found(value)
        case .exited(let status):
            diagnostics("che-telegram-all-mcp: Keychain lookup for \(credential.rawValue) failed with exit status \(status); treated as not stored")
            return .unavailable(exitStatus: status)
        }
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

/// Collects a child's stdout in the background, up to `limit` bytes, so the
/// child never blocks on a full pipe and the caller never blocks on EOF.
private final class OutputCollector: @unchecked Sendable {
    private static let limit = 64 * 1024
    private let handle: FileHandle
    private let lock = NSLock()
    private var data = Data()
    private var reachedEnd = false

    init(_ handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] readable in
            let chunk = readable.availableData
            guard let self else { return }
            self.lock.withLock {
                if chunk.isEmpty {
                    self.reachedEnd = true
                } else if self.data.count < Self.limit {
                    self.data.append(chunk.prefix(Self.limit - self.data.count))
                }
            }
            if chunk.isEmpty { readable.readabilityHandler = nil }
        }
    }

    /// Waits up to `seconds` for EOF, then stops reading and returns what arrived.
    func finish(waitingUpTo seconds: TimeInterval) async -> Data {
        let deadline = Date().addingTimeInterval(seconds)
        while !lock.withLock({ reachedEnd }), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        handle.readabilityHandler = nil
        try? handle.close()
        return lock.withLock { data }
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
