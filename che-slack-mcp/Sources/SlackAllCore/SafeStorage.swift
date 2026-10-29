import Foundation
import SlackWebLib

/// Reads the password of the Keychain item `Slack Safe Storage`, which the
/// Slack desktop app encrypts its cookies with. The executable provides the
/// `security` one; tests provide a fake, so no test reads the real item.
public protocol SlackSafeStorageReader: Sendable {
    /// How long a read may run before it is stopped.
    var timeout: TimeInterval { get }
    /// The password, or why there is none. `KeychainLookup`'s description
    /// never shows the value.
    func readPassword() async -> KeychainLookup
}

/// Reads `Slack Safe Storage` with `/usr/bin/security find-generic-password
/// -s "Slack Safe Storage" -w`.
///
/// - The arguments are constants; the password is never on any argv.
/// - The child's stdin is the null device and its stderr is discarded; its
///   stdout (the password and a newline) goes to a pipe, is read up to 4 KiB,
///   and is never printed or logged.
/// - macOS asks the user whether `security` may use the item, and the user
///   may take a while to find the dialog and type the login password, so the
///   default timeout is a generous 180 s (chosen, not measured). A child
///   still running then is terminated (killed a second later) and the result
///   is `timedOut`.
/// - `-w`, unlike `-g`, prints a value with non-ASCII bytes as bare hex; the
///   Safe Storage password Chromium generates is base64 text, so `-w` is
///   read as text as is.
public struct SecuritySafeStorageReader: SlackSafeStorageReader {
    public static let service = "Slack Safe Storage"
    public static let defaultTimeout: TimeInterval = 180

    public let executable: URL
    public let timeout: TimeInterval

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/security"), timeout: TimeInterval = Self.defaultTimeout) {
        self.executable = executable
        self.timeout = timeout
    }

    static let arguments = ["find-generic-password", "-s", service, "-w"]

    public func readPassword() async -> KeychainLookup {
        let (outcome, output, truncated) = await BoundedChild.run(executable, Self.arguments, timeout: timeout,
                                                                  outputLimit: 4096)
        switch outcome {
        case .timedOut:
            return .timedOut(after: timeout)
        case .couldNotStart:
            return .unavailable(reason: "could not start \(executable.path)")
        case .exited(44):
            return .absent
        case .exited(0):
            guard !truncated, var text = String(data: output, encoding: .utf8) else {
                return .unavailable(reason: "\(executable.lastPathComponent) printed something that is not a password")
            }
            if text.hasSuffix("\n") { text.removeLast() }
            guard !text.contains(where: { $0.isNewline }) else {
                return .unavailable(reason: "\(executable.lastPathComponent) printed something that is not a password")
            }
            return text.isEmpty ? .absent : .found(text)
        case .exited(let status):
            return .unavailable(reason: "\(executable.lastPathComponent) exited with status \(status)")
        }
    }
}

/// Runs a child with stdin on the null device, stderr discarded and stdout
/// collected up to a limit, and stops it at a timeout.
enum BoundedChild {
    enum Outcome: Equatable, Sendable {
        case exited(Int32)
        case timedOut
        case couldNotStart
    }

    static let killGrace: TimeInterval = 1
    static let outputGrace: TimeInterval = 1

    /// How the child ended, its stdout (at most `outputLimit` bytes), and
    /// whether it wrote more than that.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval,
                    outputLimit: Int) async -> (Outcome, Data, Bool) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let collector = Collector(pipe.fileHandleForReading, limit: outputLimit)

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = Once(continuation)
            process.terminationHandler = { once.resume(.exited($0.terminationStatus)) }
            do {
                try process.run()
            } catch {
                once.resume(.couldNotStart)
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                once.resume(.timedOut)
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        let wait = outcome == .timedOut || outcome == .couldNotStart ? 0 : outputGrace
        let (data, truncated) = await collector.finish(waitingUpTo: wait)
        return (outcome, data, truncated)
    }

    /// Reads a pipe in the background so the child never blocks on it.
    private final class Collector: @unchecked Sendable {
        private let handle: FileHandle
        private let limit: Int
        private let lock = NSLock()
        private var data = Data()
        private var ended = false
        private var truncated = false

        init(_ handle: FileHandle, limit: Int) {
            self.handle = handle
            self.limit = limit
            handle.readabilityHandler = { [weak self] readable in
                let chunk = readable.availableData
                guard let self else { return }
                self.lock.withLock {
                    if chunk.isEmpty {
                        self.ended = true
                    } else {
                        let room = self.limit - self.data.count
                        if chunk.count > room { self.truncated = true }
                        if room > 0 { self.data.append(chunk.prefix(room)) }
                    }
                }
                if chunk.isEmpty { readable.readabilityHandler = nil }
            }
        }

        func finish(waitingUpTo seconds: TimeInterval) async -> (Data, Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !lock.withLock({ ended }), Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            handle.readabilityHandler = nil
            try? handle.close()
            return lock.withLock { (data, truncated) }
        }
    }

    /// Resumes a continuation once, whichever of exit and timeout is first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?

        init(_ continuation: CheckedContinuation<Outcome, Never>) { self.continuation = continuation }

        func resume(_ outcome: Outcome) {
            let pending: CheckedContinuation<Outcome, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: outcome)
        }
    }
}
