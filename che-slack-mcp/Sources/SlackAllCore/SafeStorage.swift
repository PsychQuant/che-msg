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
/// - If the calling task is cancelled, the read stops waiting for stdout as
///   soon as the child has exited and returns what has arrived, as
///   `SecurityCLIKeychainReader` does (the two share `runBounded` and
///   `OutputCollector`; the copy this reader used to have waited out the
///   full output grace). Cancelling does not stop the child: that still
///   takes its exit or the timeout.
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

    /// The most stdout kept; a password is far shorter.
    static let outputLimit = 4096
    /// How long to wait for stdout to reach EOF after the child has exited
    /// (another process may have inherited it), and how long a terminated
    /// child gets before it is killed.
    static let outputGrace: TimeInterval = 1
    static let killGrace: TimeInterval = 1

    public func readPassword() async -> KeychainLookup {
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        let collector = OutputCollector(stdout.fileHandleForReading, limit: Self.outputLimit)

        let outcome = await runBounded(process, timeout: timeout, killGrace: Self.killGrace)
        let waitForOutput = outcome == .timedOut || outcome == .couldNotStart ? 0 : Self.outputGrace
        let (output, truncated) = await collector.finish(waitingUpTo: waitForOutput)

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
