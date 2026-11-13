import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-credentials — "Keychain write keeps values off argv", with a
/// stand-in for `/usr/bin/security` that records every call. No test here
/// runs the real tool; `ScratchKeychainTests` does that against a scratch
/// keychain file.
@Suite("Writing an item through security -i")
struct KeychainWriterTests {
    let scratch: ScratchDirectory

    init() throws { scratch = try ScratchDirectory() }

    static let service = "SLACK_TOKEN_T01"
    /// Synthetic, with every punctuation character the spec allows.
    static let value = "xoxc-TEST%2Fab_c.d-e+f/g="

    /// A stand-in that records each call's arguments, one per line, in
    /// `argv-<n>` and what `-i` read on stdin in `stdin-<n>`, then runs
    /// `interactive` for `-i` and `find` for anything else. The default
    /// `find` prints, the way `security -g` does, the value from the last
    /// `-w "..."` written.
    func recordingSecurity(interactive: String = "exit 0", find: String? = nil) throws -> URL {
        let echoWritten = #"v=$(sed -n 's/^add-generic-password .* -w "\([^"]*\)".*$/\1/p' "$dir"/stdin-*); "#
            + #"printf 'keychain: "/x"\n'; printf 'password: "%s"\n' "$v" >&2"#
        return try scratch.fakeSecurity("""
            dir='\(scratch.url.path)'
            n=$(ls "$dir" | grep -c '^argv-')
            printf '%s\\n' "$@" > "$dir/argv-$n"
            if [ "$1" = "-i" ]; then
              cat > "$dir/stdin-$n"
              \(interactive)
            else
              \(find ?? echoWritten)
            fi
            """)
    }

    /// Each recorded call's arguments, in call order.
    func recordedCalls() throws -> [[String]] {
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).filter { $0.hasPrefix("argv-") }
        return try (0..<names.count).map { n in
            try String(contentsOfFile: scratch.path("argv-\(n)"), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    static func error(_ body: () async throws -> Void) async -> SlackKeychainWriteError? {
        do {
            try await body()
            return nil
        } catch let error as SlackKeychainWriteError {
            return error
        } catch {
            Issue.record("unexpected error type: \(type(of: error))")
            return nil
        }
    }

    // MARK: - The value stays off argv

    @Test("security is started with only -i; the value goes in on stdin and is read back; no argv holds it")
    func valueOnlyOnStdin() async throws {
        let path = scratch.path("never-created.keychain-db")
        let writer = SecurityCLIKeychainWriter(executable: try recordingSecurity(), keychainPath: path)

        try await writer.write(service: Self.service, value: Self.value)

        let calls = try recordedCalls()
        #expect(calls == [
            ["-i"],
            ["find-generic-password", "-a", "che-slack-mcp", "-s", "SLACK_TOKEN_T01", "-g", path],
        ])
        #expect(calls.allSatisfy { call in call.allSatisfy { !$0.contains(Self.value) } })
        let stdin = try String(contentsOfFile: scratch.path("stdin-0"), encoding: .utf8)
        #expect(stdin == #"add-generic-password -U -a che-slack-mcp -s SLACK_TOKEN_T01 -w "xoxc-TEST%2Fab_c.d-e+f/g=" ""#
                + path + "\"\n")
    }

    /// The spec scenarios "Team id with a quote is refused" and "Value with a
    /// quote is refused", at the writer: nothing is started.
    @Test("a refused write starts no process", arguments: [
        (#"SLACK_TOKEN_T01"x"#, "xoxc-1", SlackKeychainWriteRefusal.teamID),
        ("SLACK_COOKIE_T01", #"xoxd-a"b"#, .valueCharacters),
        ("SLACK_COOKIE_T01", "", .emptyValue),
    ])
    func refusedWriteStartsNothing(service: String, value: String, reason: SlackKeychainWriteRefusal) async throws {
        let writer = SecurityCLIKeychainWriter(executable: try recordingSecurity(), keychainPath: scratch.path("k.keychain-db"))

        let error = await Self.error { try await writer.write(service: service, value: value) }

        #expect(error == .refused(service: service, reason: reason))
        #expect(try recordedCalls().isEmpty)
    }

    // MARK: - A write that may have failed is never a success

    /// Each case: what the stand-in does for `-i` and for the read-back, and
    /// the reason expected. The first case is what `security -i` printed for
    /// a malformed `add-generic-password` line (2026-10-29); the third is
    /// what it printed for `-w` with no value, where it prompted on stderr
    /// and still exited 0.
    static let failures: [(String, String?, String)] = [
        ("printf 'Usage: add-generic-password [-h] [-a account]\\n' >&2; printf 'add-generic-password: returned 2\\n' >&2; exit 2",
         nil, "security -i exited with status 2"),
        ("exit 1", nil, "security -i exited with status 1"),
        ("printf 'password data for new item: retype password for new item: ' >&2", nil, "security -i printed output"),
        ("echo done", nil, "security -i printed output"),
        ("exit 0", #"printf 'password: "xoxc-other"\n' >&2"#, "reading the item back gave a different value"),
        ("exit 0", "exit 44", "the item was not found when read back"),
        ("exit 0", "exit 51", "reading the item back failed: exited with status 51"),
    ]

    @Test("a failed or unconfirmed write throws failed, naming the service and never the value", arguments: failures)
    func failureIsReported(interactive: String, find: String?, reason: String) async throws {
        let security = try recordingSecurity(interactive: interactive, find: find)
        let writer = SecurityCLIKeychainWriter(executable: security, keychainPath: scratch.path("k.keychain-db"))

        let error = try #require(await Self.error { try await writer.write(service: Self.service, value: Self.value) })

        #expect(error == .failed(service: Self.service, reason: reason))
        #expect(!error.description.contains(Self.value))
    }

    /// Long enough for a new stand-in script to start and finish its `-i`
    /// part on a loaded machine (`KeychainReaderTests.termination` records a
    /// 0.5 s limit failing that way).
    static let termination: TimeInterval = 2

    @Test("a read-back that does not finish makes the write fail, naming the service")
    func readBackTimesOut() async throws {
        let security = try recordingSecurity(find: "exec sleep 30")
        let writer = SecurityCLIKeychainWriter(executable: security, keychainPath: scratch.path("k.keychain-db"),
                                               timeout: Self.termination)

        let error = await Self.error { try await writer.write(service: Self.service, value: Self.value) }

        #expect(error == .failed(service: Self.service, reason: "reading the item back did not finish within 2 s"))
    }

    @Test("security -i still running after the timeout is stopped and reported as timed out")
    func writeTimesOut() async throws {
        let pidFile = scratch.path("pid")
        let security = try recordingSecurity(interactive: "echo $$ > '\(pidFile)'; exec sleep 30")
        let writer = SecurityCLIKeychainWriter(executable: security, keychainPath: scratch.path("k.keychain-db"),
                                               timeout: Self.termination)
        let started = Date()

        let error = await Self.error { try await writer.write(service: Self.service, value: Self.value) }

        #expect(error == .timedOut(service: Self.service, after: Self.termination))
        #expect(Date().timeIntervalSince(started) < Self.termination + 3)
        #expect(try processIsGone(pidFile: pidFile, script: security, within: 3))
    }

    @Test("a tool that cannot be started is reported as failed, naming the service")
    func cannotStart() async throws {
        let missing = scratch.path("no-such-security")
        let writer = SecurityCLIKeychainWriter(executable: URL(fileURLWithPath: missing), keychainPath: scratch.path("k.keychain-db"))

        let error = await Self.error { try await writer.write(service: Self.service, value: Self.value) }

        #expect(error == .failed(service: Self.service, reason: "could not start \(missing)"))
    }

    @Test("production writes through security -i with a 10 second limit and no keychain path")
    func productionWriter() {
        let writer = SecurityCLIKeychainWriter()

        #expect(writer.executable.path == "/usr/bin/security")
        #expect(writer.keychainPath == nil)
        #expect(writer.timeout == 10)
    }
}
