import Foundation
import Testing
import SlackWebLib
@testable import SlackAllCore

/// The production Safe Storage reader, pointed at fake executables (shell
/// scripts in a temporary folder). No test runs `/usr/bin/security`.
@Suite("Slack Safe Storage reader")
final class SafeStorageReaderTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("safe-storage-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    }

    deinit { try? FileManager.default.removeItem(at: folder) }

    /// A script whose body is `body`, made executable.
    func script(_ body: String) throws -> URL {
        let url = folder.appendingPathComponent("fake-security-\(UUID().uuidString)")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @Test("the password is what security -w prints, without its newline, and the arguments name only the service")
    func found() async throws {
        let args = folder.appendingPathComponent("args")
        let fake = try script("printf '%s\\n' \"$@\" > '\(args.path)'\nprintf 'fake-safe-storage-pw\\n'")

        let lookup = await SecuritySafeStorageReader(executable: fake, timeout: 10).readPassword()

        #expect(lookup == .found("fake-safe-storage-pw"))
        #expect(try String(contentsOf: args, encoding: .utf8) == "find-generic-password\n-s\nSlack Safe Storage\n-w\n")
        #expect(!lookup.description.contains("fake-safe-storage-pw"))
    }

    @Test("the child's standard input is at its end, so it can never read the CLI's input")
    func stdinIsNull() async throws {
        let fake = try script("if read -r line; then exit 3; fi\nprintf 'pw\\n'")

        #expect(await SecuritySafeStorageReader(executable: fake, timeout: 10).readPassword() == .found("pw"))
    }

    @Test("exit status 44 (item not found) is absent; an empty password is absent")
    func absent() async throws {
        #expect(await SecuritySafeStorageReader(executable: try script("exit 44"), timeout: 10).readPassword() == .absent)
        #expect(await SecuritySafeStorageReader(executable: try script("printf '\\n'"), timeout: 10).readPassword() == .absent)
    }

    @Test("another exit status is unavailable, naming the status and not the output")
    func otherStatus() async throws {
        let lookup = await SecuritySafeStorageReader(executable: try script("printf 'secret-ish\\n'; exit 51"), timeout: 10).readPassword()

        guard case .unavailable(let reason) = lookup else {
            Issue.record("expected unavailable, got \(lookup)")
            return
        }
        #expect(reason.contains("51"))
        #expect(!reason.contains("secret-ish"))
    }

    @Test("output of more than one line is unavailable, without quoting it")
    func notAPassword() async throws {
        let lookup = await SecuritySafeStorageReader(executable: try script("printf 'one\\ntwo\\n'"), timeout: 10).readPassword()

        guard case .unavailable(let reason) = lookup else {
            Issue.record("expected unavailable, got \(lookup)")
            return
        }
        #expect(!reason.contains("one") && !reason.contains("two"))
    }

    @Test("a child still running at the timeout is stopped and reported timed out")
    func timeout() async throws {
        let fake = try script("sleep 30")
        let start = Date()

        let lookup = await SecuritySafeStorageReader(executable: fake, timeout: 0.5).readPassword()

        #expect(lookup == .timedOut(after: 0.5))
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test("an executable that cannot be started is unavailable")
    func cannotStart() async {
        let missing = folder.appendingPathComponent("no-such-tool")

        let lookup = await SecuritySafeStorageReader(executable: missing, timeout: 10).readPassword()

        guard case .unavailable = lookup else {
            Issue.record("expected unavailable, got \(lookup)")
            return
        }
    }

    @Test("the production reader runs /usr/bin/security with a timeout of 180 s")
    func defaults() {
        let reader = SecuritySafeStorageReader()
        #expect(reader.executable.path == "/usr/bin/security")
        #expect(reader.timeout == 180)
    }
}
