import Foundation

/// Why a write was refused before anything ran. Each reason is a fixed
/// phrase and never quotes the value.
public enum SlackKeychainWriteRefusal: String, Equatable, Sendable {
    case unknownService = "the service is not SLACK_WORKSPACES, SLACK_TOKEN_<team id> or SLACK_COOKIE_<team id>"
    case teamID = "the team id is not 1 to 32 characters from A-Z and 0-9"
    case emptyValue = "the value is empty"
    case valueCharacters = "the value contains a character outside A-Z a-z 0-9 - _ . % + / ="
    case keychainPath = "the keychain path is empty or contains a quote, a backslash or a control character"
    case lineTooLong = "the security -i command line would be longer than 4094 bytes"
}

/// Why a Keychain item was not written, or may not have been. Every case
/// names the item's service; no case holds the value, and every reason is a
/// fixed phrase, never text the child printed.
public enum SlackKeychainWriteError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// Refused before any process started: nothing was written.
    case refused(service: String, reason: SlackKeychainWriteRefusal)
    /// `security -i` could not run, failed, printed something, or the item
    /// did not read back as written. The item may or may not have changed.
    case failed(service: String, reason: String)
    /// `security -i` was still running after `after` seconds and was
    /// stopped. The item may or may not have changed.
    case timedOut(service: String, after: TimeInterval)

    public var service: String {
        switch self {
        case .refused(let service, _), .failed(let service, _), .timedOut(let service, _): return service
        }
    }

    public var description: String {
        let item = "Keychain item \(service)"
        switch self {
        case .refused(_, let reason):
            return "Refused to write \(item): \(reason.rawValue); nothing was written."
        case .failed(_, let reason):
            return "Writing \(item) may have failed: \(reason)."
        case .timedOut(_, let seconds):
            return "Writing \(item) did not finish within \(formatSeconds(seconds)) s; it may or may not have been written."
        }
    }

    public var errorDescription: String? { description }
}

/// Writes Keychain items by service name under the account `che-slack-mcp`.
/// The CLI takes one of these so its tests can inject a fake.
public protocol KeychainItemWriter: Sendable {
    /// Throws `SlackKeychainWriteError.refused` when `write` would refuse
    /// this item, without starting anything. Lets a caller check several
    /// items before writing any of them.
    func check(service: String, value: String) throws
    /// Creates or replaces the item; returns only once it holds `value`.
    func write(service: String, value: String) async throws
    /// Deletes the item. An item that does not exist is not an error: the
    /// call returns once the item is gone either way. Throws
    /// `SlackKeychainDeleteError` naming the service otherwise.
    func delete(service: String) async throws
}

extension KeychainItemWriter {
    /// The spec's checks on the service and value.
    public func check(service: String, value: String) throws {
        try KeychainWritePolicy.check(service: service, value: value)
    }
}

/// The checks every write makes before anything runs (spec:
/// slack-credentials, "Keychain write keeps values off argv"). They work on
/// UTF-8 bytes, so a non-ASCII character can never pass as an allowed one.
enum KeychainWritePolicy {
    static let tokenPrefix = SlackKeychain.tokenService(teamID: "")
    static let cookiePrefix = SlackKeychain.cookieService(teamID: "")

    /// Throws `.refused` naming `service` unless the service is one of the
    /// layout's (with a team id of 1 to 32 bytes from `A-Z 0-9`) and the
    /// value is 1 or more bytes from `A-Z a-z 0-9 - _ . % + / =`. The
    /// service is checked first.
    static func check(service: String, value: String) throws {
        if let reason = serviceRefusal(service) {
            throw SlackKeychainWriteError.refused(service: service, reason: reason)
        }
        guard !value.isEmpty else { throw SlackKeychainWriteError.refused(service: service, reason: .emptyValue) }
        guard value.utf8.allSatisfy(isValueByte) else {
            throw SlackKeychainWriteError.refused(service: service, reason: .valueCharacters)
        }
    }

    /// Why `service` is not one of the layout's, or nil when it is.
    static func serviceRefusal(_ service: String) -> SlackKeychainWriteRefusal? {
        if service == SlackKeychain.workspacesService { return nil }
        guard let prefix = [tokenPrefix, cookiePrefix].first(where: { service.hasPrefix($0) }) else {
            return .unknownService
        }
        let teamID = service.utf8.dropFirst(prefix.utf8.count)
        guard (1...32).contains(teamID.count), teamID.allSatisfy(isTeamIDByte) else { return .teamID }
        return nil
    }

    private static func isTeamIDByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static let punctuation = Set("-_.%+/=".utf8)

    private static func isValueByte(_ byte: UInt8) -> Bool {
        isTeamIDByte(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || punctuation.contains(byte)
    }
}

/// Writes an item with `/usr/bin/security -i` (spec: slack-credentials,
/// "Keychain write keeps values off argv"). The child's only argument is
/// `-i`; the `add-generic-password` line holding the value goes in on its
/// standard input, so the value is in no process's argument list. Reading
/// uses the same tool, so the item's ACL already trusts the reader.
///
/// How `security -i` behaves, observed on 2026-10-29 (macOS 27.2) with a
/// scratch keychain file and malformed lines that cannot prompt:
/// - A command that succeeds prints nothing.
/// - A command that fails prints its usage or an error, then
///   `<command>: returned <status>`, on stderr, and the session reads on.
/// - The exit status is that of the last line only: a failing line followed
///   by a good one exits 0, and empty input exits 0 with no output.
/// - Lines are read 4095 bytes at a time. The rest of a longer line runs as
///   a command of its own (which would lose the keychain path); a 4095-byte
///   line leaves its newline behind as an empty line that resets the status
///   to 0.
/// - `-w` as the last word makes `add-generic-password` prompt for the
///   password on stderr and still exit 0.
///
/// So each child gets exactly one line of at most 4094 bytes, and a write
/// succeeds only when the child exits 0, prints nothing, and reading the
/// item back with `find-generic-password -g` (as the reader does, through
/// the same keychain path or search list) gives the value written.
/// Otherwise it throws `refused` before anything starts, or `failed` /
/// `timedOut` afterwards, when the item may or may not have changed.
///
/// An empty value is refused: whether `security -i` keeps `""` as an empty
/// word was not tested, and a bare `-w` prompts. The keychain path is for
/// tests; production passes none and writes to the default keychain.
public struct SecurityCLIKeychainWriter: KeychainItemWriter {
    public let executable: URL
    public let keychainPath: String?
    public let timeout: TimeInterval

    public init(executable: URL = URL(fileURLWithPath: "/usr/bin/security"), keychainPath: String? = nil,
                timeout: TimeInterval = 10) {
        self.executable = executable
        self.keychainPath = keychainPath
        self.timeout = timeout
    }

    /// The longest line `security -i` reads as one command: it reads 4095
    /// bytes at a time, and the newline has to fit in the same read.
    static let maxLineBytes = 4094

    /// The line sent on stdin. Only safe for a service, value and path that
    /// passed `check`: none of them can then contain `"`, `\` or a newline.
    func commandLine(service: String, value: String) -> String {
        var line = "add-generic-password -U -a \(SlackKeychain.account) -s \(service) -w \"\(value)\""
        if let keychainPath { line += " \"\(keychainPath)\"" }
        return line
    }

    /// The policy's checks, then the keychain path (tests only) and the
    /// length of the line.
    public func check(service: String, value: String) throws {
        try KeychainWritePolicy.check(service: service, value: value)
        if let keychainPath {
            let unsafe = keychainPath.unicodeScalars.contains {
                $0 == "\"" || $0 == "\\" || $0.properties.generalCategory == .control
            }
            guard !keychainPath.isEmpty, !unsafe else {
                throw SlackKeychainWriteError.refused(service: service, reason: .keychainPath)
            }
        }
        guard commandLine(service: service, value: value).utf8.count <= Self.maxLineBytes else {
            throw SlackKeychainWriteError.refused(service: service, reason: .lineTooLong)
        }
    }

    /// As the reader: how long to wait for output to reach EOF after the
    /// child exits, and how long a terminated child gets before it is killed.
    static let outputGrace: TimeInterval = 1
    static let killGrace: TimeInterval = 1

    public func write(service: String, value: String) async throws {
        try check(service: service, value: value)
        let line = Data((commandLine(service: service, value: value) + "\n").utf8)
        let input = Pipe()
        // At most 4095 bytes, far below a pipe's buffer, so this cannot
        // block; and this process still holds the read end, so it cannot
        // raise SIGPIPE even when the child never starts. Closing the write
        // end gives the child end-of-input right after the line.
        do {
            try input.fileHandleForWriting.write(contentsOf: line)
            try input.fileHandleForWriting.close()
        } catch {
            throw SlackKeychainWriteError.failed(service: service, reason: "could not pass the command to security -i")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-i"]
        process.standardInput = input
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output = OutputCollector(stdout.fileHandleForReading)
        let errors = OutputCollector(stderr.fileHandleForReading)

        let outcome = await runBounded(process, timeout: timeout, killGrace: Self.killGrace)
        let waitForOutput = outcome == .timedOut || outcome == .couldNotStart ? 0 : Self.outputGrace
        let printed = await output.finish(waitingUpTo: waitForOutput).data.count
            + errors.finish(waitingUpTo: waitForOutput).data.count

        switch outcome {
        case .timedOut:
            throw SlackKeychainWriteError.timedOut(service: service, after: timeout)
        case .couldNotStart:
            throw SlackKeychainWriteError.failed(service: service, reason: "could not start \(executable.path)")
        case .exited(let status) where status != 0:
            throw SlackKeychainWriteError.failed(service: service, reason: "security -i exited with status \(status)")
        case .exited:
            break
        }
        // Whatever it printed is not quoted: a prompt or usage text says
        // nothing the reason needs, and a fixed phrase cannot leak.
        guard printed == 0 else { throw SlackKeychainWriteError.failed(service: service, reason: "security -i printed output") }
        try await confirm(service: service, value: value)
    }

    /// Reads the item back the way `SecurityCLIKeychainReader` does and
    /// throws `failed` unless it holds `value`.
    private func confirm(service: String, value: String) async throws {
        let reader = SecurityCLIKeychainReader(executable: executable, keychainPath: keychainPath, timeout: timeout)
        let reason: String
        switch await reader.read(service: service) {
        case .found(let stored) where stored == value:
            return
        case .found:
            reason = "reading the item back gave a different value"
        case .absent:
            reason = "the item was not found when read back"
        case .timedOut(let seconds):
            reason = "reading the item back did not finish within \(formatSeconds(seconds)) s"
        case .unavailable(let why):
            reason = "reading the item back failed: \(why)"
        }
        throw SlackKeychainWriteError.failed(service: service, reason: reason)
    }
}
