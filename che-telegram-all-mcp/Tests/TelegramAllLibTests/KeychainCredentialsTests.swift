import Darwin
import XCTest
@testable import TelegramAllLib

/// Covers "Keychain credential lookup is bounded and keeps no copy"
/// (telegram-auth-coordination; PsychQuant/che-msg#49). A small shell script
/// in a scratch directory plays `/usr/bin/security`, so no test reads a real
/// Keychain.
final class KeychainCredentialsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("keychain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { [dir] in try? FileManager.default.removeItem(at: dir!) }
    }

    /// Writes an executable script that stands in for `security`.
    private func fakeSecurity(_ body: String) throws -> URL {
        let url = dir.appendingPathComponent("security-\(UUID().uuidString)")
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o755)
        return url
    }

    /// Runs a lookup and returns its result and every diagnostic line it wrote.
    private func lookup(_ body: String, _ credential: KeychainCredential = .phone,
                        timeout: TimeInterval = 5) async throws -> (KeychainLookup, [String]) {
        let messages = Messages()
        let source = SecurityCLICredentialSource(executable: try fakeSecurity(body), timeout: timeout,
                                                 diagnostics: { messages.append($0) })
        let result = await source.lookup(credential)
        return (result, messages.all)
    }

    // MARK: - Outcomes of a lookup (spec example table)

    func testValueWithTrailingNewlineIsFound() async throws {
        let (result, messages) = try await lookup("printf 'secret\\n'")
        XCTAssertEqual(result, .found("secret"))
        XCTAssertEqual(messages, [])
    }

    func testOnlyOneTrailingNewlineIsRemoved() async throws {
        let (result, _) = try await lookup("printf 'a\\nb\\n'")
        XCTAssertEqual(result, .found("a\nb"))
    }

    func testEmptyValueIsAbsent() async throws {
        let (result, messages) = try await lookup("exit 0")
        XCTAssertEqual(result, .absent)
        XCTAssertEqual(messages, [])
    }

    func testItemNotFoundIsAbsentWithoutADiagnostic() async throws {
        let (result, messages) = try await lookup("echo 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.' >&2; exit 44")
        XCTAssertEqual(result, .absent)
        XCTAssertEqual(messages, [])
    }

    func testOtherFailureIsUnavailableWithOneDiagnostic() async throws {
        let (result, messages) = try await lookup("exit 51", .password)
        XCTAssertEqual(result, .unavailable(exitStatus: 51))
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("TELEGRAM_2FA_PASSWORD"), messages[0])
        XCTAssertTrue(messages[0].contains("51"), messages[0])
    }

    func testLookupThatDoesNotFinishIsTerminated() async throws {
        let pidFile = dir.appendingPathComponent("pid").path
        let started = Date()
        let (result, messages) = try await lookup("echo $$ > '\(pidFile)'; exec sleep 30", .password, timeout: 0.5)
        XCTAssertEqual(result, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the lookup must give up at its time limit")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("TELEGRAM_2FA_PASSWORD"), messages[0])
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<50 where !gone {
            gone = kill(pid, 0) != 0
            if !gone { usleep(20_000) }
        }
        XCTAssertTrue(gone, "the child must be terminated, not left running")
    }

    /// A process that inherits the child's stdout and keeps it open must not
    /// hold the lookup past its limit.
    func testOutputHeldOpenByAnotherProcessDoesNotBlockTheLookup() async throws {
        let pidFile = dir.appendingPathComponent("holder").path
        let started = Date()
        let (result, _) = try await lookup("sleep 30 & echo $! > '\(pidFile)'; printf 'x'; exit 0", timeout: 0.5)
        let holder = Int32((try? String(contentsOfFile: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        if holder > 0 { kill(holder, SIGKILL) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "the lookup must not wait for the stdout to close")
        XCTAssertEqual(result, .found("x"))
    }

    /// A child that ignores SIGTERM is killed after a short grace period.
    func testChildIgnoringTerminateIsKilled() async throws {
        let pidFile = dir.appendingPathComponent("pid").path
        let started = Date()
        let (result, _) = try await lookup("trap '' TERM; echo $$ > '\(pidFile)'; while :; do sleep 0.05; done", timeout: 0.5)
        XCTAssertEqual(result, .timedOut)
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<100 where !gone {
            gone = kill(pid, 0) != 0
            if !gone { usleep(20_000) }
        }
        if !gone { kill(pid, SIGKILL) }
        XCTAssertTrue(gone, "a child that ignores SIGTERM must still be stopped")
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: - What the child is given

    func testChildGetsConstantArgumentsOnly() async throws {
        let argsFile = dir.appendingPathComponent("args").path
        _ = try await lookup("printf '%s\\n' \"$@\" > '\(argsFile)'; printf 'x'", .password)
        let args = try String(contentsOfFile: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(args, ["find-generic-password", "-a", "che-telegram-all-mcp", "-s", "TELEGRAM_2FA_PASSWORD", "-w"])
    }

    func testKeychainPathIsPassedLast() async throws {
        let argsFile = dir.appendingPathComponent("args").path
        let source = SecurityCLICredentialSource(
            executable: try fakeSecurity("printf '%s\\n' \"$@\" > '\(argsFile)'; printf 'x'"),
            keychainPath: "/tmp/scratch.keychain-db", diagnostics: { _ in })
        _ = await source.lookup(.phone)
        let args = try String(contentsOfFile: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(args.last, "/tmp/scratch.keychain-db")
        XCTAssertEqual(Array(args.dropLast()), ["find-generic-password", "-a", "che-telegram-all-mcp", "-s", "TELEGRAM_PHONE", "-w"])
    }

    /// The child must never read the MCP server's standard input (the JSON-RPC
    /// stream). The test's own stdin is replaced by a pipe holding "leaked" for
    /// the duration, so an inherited stdin would be visible.
    func testChildStdinIsTheNullDevice() async throws {
        let (result, _) = try await withRedirected(fd: 0, feeding: "leaked\n") {
            try await self.lookup("if read -r line; then printf '%s' \"$line\"; else printf 'eof'; fi")
        }
        XCTAssertEqual(result, .found("eof"))
    }

    /// The child's error output is discarded, not copied to the server's stderr.
    func testChildStderrIsNotForwarded() async throws {
        let captured = try await captureOutput(fd: 2) {
            _ = try await self.lookup("echo 'child-stderr-marker' >&2; printf 'x'")
        }
        XCTAssertFalse(captured.contains("child-stderr-marker"), captured)
    }

    // MARK: - No copy of the value

    func testDescriptionOfAFoundValueDoesNotContainIt() {
        let lookup = KeychainLookup.found("+886912345678")
        XCTAssertFalse(String(describing: lookup).contains("+886912345678"))
        XCTAssertFalse("\(lookup)".contains("886912345678"))
        XCTAssertEqual(lookup.value, "+886912345678")
        XCTAssertNil(KeychainLookup.absent.value)
        XCTAssertNil(KeychainLookup.timedOut.value)
        XCTAssertNil(KeychainLookup.unavailable(exitStatus: 1).value)
    }

    func testOnlyPhoneAndPasswordCanBeLookedUp() {
        XCTAssertEqual(KeychainCredential.allCases.map(\.rawValue), ["TELEGRAM_PHONE", "TELEGRAM_2FA_PASSWORD"])
    }

    func testProductionDefaultsAreTheSystemSecurityToolAndTenSeconds() {
        let source = SecurityCLICredentialSource()
        XCTAssertEqual(source.executable.path, "/usr/bin/security")
        XCTAssertNil(source.keychainPath)
        XCTAssertEqual(source.timeout, 10)
    }

    // MARK: - A real Keychain file

    /// End to end with the real `/usr/bin/security`, against a scratch keychain
    /// file passed by path. The user's search list is never changed: this test
    /// only creates, reads and deletes its own file, and checks the list is the
    /// same before and after.
    func testReadsASyntheticItemFromAScratchKeychainFile() async throws {
        let security = URL(fileURLWithPath: "/usr/bin/security")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: security.path), "no /usr/bin/security")
        let searchListBefore = try run(security, ["list-keychains", "-d", "user"])
        let keychain = dir.appendingPathComponent("scratch.keychain-db").path
        let password = "scratch-\(UUID().uuidString)"
        _ = try run(security, ["create-keychain", "-p", password, keychain])
        addTeardownBlock { [self] in _ = try? self.run(security, ["delete-keychain", keychain]) }
        _ = try run(security, ["unlock-keychain", "-p", password, keychain])
        _ = try run(security, ["add-generic-password", "-a", SecurityCLICredentialSource.account,
                               "-s", KeychainCredential.phone.rawValue, "-w", "+10000000000", keychain])

        let source = SecurityCLICredentialSource(keychainPath: keychain, diagnostics: { _ in })
        let phone = await source.lookup(.phone)
        let password2FA = await source.lookup(.password)

        XCTAssertEqual(phone, .found("+10000000000"))
        XCTAssertEqual(password2FA, .absent)
        XCTAssertEqual(try run(security, ["list-keychains", "-d", "user"]), searchListBefore,
                       "the test must not change the user's keychain search list")
    }

    /// Runs a tool to completion and returns its stdout; throws on a non-zero exit.
    @discardableResult
    private func run(_ tool: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "security", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(arguments.first ?? "") exited \(process.terminationStatus)"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Helpers

    /// Replaces `fd` with the read end of a pipe holding `input` while `body` runs.
    private func withRedirected<T>(fd: Int32, feeding input: String, _ body: () async throws -> T) async throws -> T {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(input.utf8))
        try pipe.fileHandleForWriting.close()
        let saved = dup(fd)
        dup2(pipe.fileHandleForReading.fileDescriptor, fd)
        defer { dup2(saved, fd); close(saved) }
        return try await body()
    }

    /// Captures what is written to `fd` while `body` runs.
    private func captureOutput(fd: Int32, _ body: () async throws -> Void) async throws -> String {
        let file = dir.appendingPathComponent("captured-\(fd)").path
        let out = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        let saved = dup(fd)
        dup2(out, fd)
        close(out)
        do { try await body() } catch { dup2(saved, fd); close(saved); throw error }
        dup2(saved, fd)
        close(saved)
        return (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
    }
}

/// Collects diagnostic lines from any thread.
private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
