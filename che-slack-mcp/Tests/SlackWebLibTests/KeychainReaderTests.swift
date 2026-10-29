import Darwin
import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-credentials — Requirement "Credential lookup is bounded".
/// A bash script in a scratch directory plays `/usr/bin/security`, so no test
/// here reads a Keychain. Like the real tool with `-g`, the fake prints the
/// attributes on stdout and the password line on stderr.
@Suite("Credential lookup is bounded")
struct KeychainReaderTests {
    let scratch: ScratchDirectory

    init() throws { scratch = try ScratchDirectory() }

    func read(_ body: String, service: String = "SLACK_TOKEN_T01", timeout: TimeInterval = 5) async throws -> KeychainLookup {
        let reader = SecurityCLIKeychainReader(executable: try scratch.fakeSecurity(body), timeout: timeout)
        return await reader.read(service: service)
    }

    // MARK: - What the child is given

    @Test("the child gets find-generic-password, account che-slack-mcp, the service and -g, nothing else")
    func constantArguments() async throws {
        let argsFile = scratch.path("args")
        _ = try await read("printf '%s\\n' \"$@\" > '\(argsFile)'; printf 'password: \"x\"\\n' >&2", service: "SLACK_COOKIE_T01")

        let args = try String(contentsOfFile: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args == ["find-generic-password", "-a", "che-slack-mcp", "-s", "SLACK_COOKIE_T01", "-g"])
    }

    @Test("a keychain path, when given, is passed as the last argument")
    func keychainPathIsLast() async throws {
        let argsFile = scratch.path("args")
        let reader = SecurityCLIKeychainReader(
            executable: try scratch.fakeSecurity("printf '%s\\n' \"$@\" > '\(argsFile)'; printf 'password: \"x\"\\n' >&2"),
            keychainPath: "/tmp/scratch.keychain-db")
        _ = await reader.read(service: "SLACK_WORKSPACES")

        let args = try String(contentsOfFile: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(args == ["find-generic-password", "-a", "che-slack-mcp", "-s", "SLACK_WORKSPACES", "-g", "/tmp/scratch.keychain-db"])
    }

    /// The MCP server's stdin carries JSON-RPC: the child must never read it.
    /// While the lookup runs, this process's fd 0 is a pipe holding "leaked",
    /// so an inherited stdin would show. (Nothing in the test runner reads
    /// stdin, so swapping fd 0 does not disturb tests running alongside.)
    @Test("the child's stdin is the null device")
    func childStdinIsTheNullDevice() async throws {
        let fake = "if read -r line; then v=$line; else v=eof; fi; printf 'password: \"%s\"\\n' \"$v\" >&2"

        let result = try await withRedirectedStdin(feeding: "leaked\n") { try await read(fake) }

        #expect(result == .found("eof"))
    }

    /// The MCP server's stdout carries JSON-RPC: the child must never write
    /// to it. The fake compares its own fd 1 with `/dev/null` instead of this
    /// process swapping its fd 1, which the test runner writes its console to.
    /// (When the runner's own stdout is `/dev/null` this cannot catch an
    /// inherited stdout, but it never fails correct code.)
    @Test("the child's stdout is the null device")
    func childStdoutIsTheNullDevice() async throws {
        let fake = """
        exec 9>&1
        if [ "$(stat -L -f '%HT %Hr,%Lr' /dev/fd/9)" = "$(stat -f '%HT %Hr,%Lr' /dev/null)" ]; then o=null; else o=other; fi
        printf 'password: "%s"\\n' "$o" >&2
        """

        #expect(try await read(fake) == .found("null"))
    }

    // MARK: - Outcomes

    @Test("exit status 44 (item not found) is absent")
    func notFoundIsAbsent() async throws {
        let result = try await read("echo 'security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.' >&2; exit 44")
        #expect(result == .absent)
    }

    @Test("a stored value is found")
    func storedValueIsFound() async throws {
        #expect(try await read(dashG(#"password: "xoxc-fake-1""#)) == .found("xoxc-fake-1"))
    }

    @Test("a stored empty value is absent")
    func emptyValueIsAbsent() async throws {
        #expect(try await read(dashG("password: ")) == .absent)
    }

    @Test("any other exit status is unavailable and names the status")
    func otherExitIsUnavailable() async throws {
        let result = try await read("exit 51")
        guard case .unavailable(let reason) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(reason.contains("51"))
    }

    @Test("a tool that cannot be started is unavailable at once")
    func missingToolIsUnavailable() async throws {
        let reader = SecurityCLIKeychainReader(executable: scratch.url.appendingPathComponent("missing"))
        let started = Date()

        let result = await reader.read(service: "SLACK_TOKEN_T01")

        guard case .unavailable = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    @Test("a password line that cannot be read is unavailable, and the reason does not show the value")
    func unreadableLineIsUnavailable() async throws {
        let result = try await read(dashG("password: xoxc-not-quoted"))
        guard case .unavailable(let reason) = result else {
            Issue.record("expected unavailable, got \(result)")
            return
        }
        #expect(!reason.contains("xoxc-not-quoted"))
    }

    // MARK: - Bounded in time

    /// Long enough for bash to start and write its pid on a loaded machine: a
    /// 0.5 s limit failed once when the full suite ran under load, before the
    /// fake had written its pid.
    static let termination: TimeInterval = 2

    @Test("a lookup still running at its time limit is terminated and reported as timed out")
    func slowLookupTimesOut() async throws {
        let pidFile = scratch.path("pid")
        let started = Date()

        let script = try scratch.fakeSecurity("echo $$ > '\(pidFile)'; exec sleep 30")
        let result = await SecurityCLIKeychainReader(executable: script, timeout: Self.termination)
            .read(service: "SLACK_TOKEN_T01")

        #expect(result == .timedOut(after: Self.termination))
        #expect(Date().timeIntervalSince(started) < Self.termination + 3)
        #expect(try processIsGone(pidFile: pidFile, script: script))
    }

    @Test("a child that ignores SIGTERM is killed after a short grace")
    func childIgnoringTerminateIsKilled() async throws {
        let pidFile = scratch.path("pid")

        let script = try scratch.fakeSecurity("trap '' TERM; echo $$ > '\(pidFile)'; while :; do sleep 0.05; done")
        let result = await SecurityCLIKeychainReader(executable: script, timeout: Self.termination)
            .read(service: "SLACK_TOKEN_T01")

        #expect(result == .timedOut(after: Self.termination))
        #expect(try processIsGone(pidFile: pidFile, script: script, within: 3))
    }

    /// A process that inherits the child's stderr and keeps it open must not
    /// hold the lookup until that process exits.
    @Test("output held open by another process does not block the lookup")
    func heldOpenOutputDoesNotBlock() async throws {
        let holderFile = scratch.path("holder")
        let started = Date()

        let result = try await read("sleep 30 & echo $! > '\(holderFile)'; printf 'password: \"x\"\\n' >&2; exit 0")

        if let holder = Int32((try? String(contentsOfFile: holderFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") { kill(holder, SIGKILL) }
        #expect(result == .found("x"))
        #expect(Date().timeIntervalSince(started) < 10)
    }

    // MARK: - Bounded in size

    /// `security -g` writes `password: "` (11 bytes), the value, `"` and a newline.
    func passwordOfLength(_ bytes: Int) -> String {
        "{ printf 'password: \"'; head -c \(bytes) /dev/zero | tr '\\0' a; printf '\"\\n'; } >&2"
    }

    @Test("output exactly at the limit is read; one byte more is unavailable")
    func outputLimit() async throws {
        let limit = OutputCollector.limit

        let atLimit = try await read(passwordOfLength(limit - 13))
        let overLimit = try await read(passwordOfLength(limit - 12))

        #expect(atLimit.value?.count == limit - 13)
        guard case .unavailable(let reason) = overLimit else {
            Issue.record("a truncated value must not be used, got \(overLimit)")
            return
        }
        #expect(reason.contains("more than"))
    }

    // MARK: - No copy of the value

    @Test("every lookup runs the tool again: nothing is cached")
    func everyLookupRunsTheTool() async throws {
        let counter = scratch.path("count")
        let reader = SecurityCLIKeychainReader(executable: try scratch.fakeSecurity(
            "echo x >> '\(counter)'; n=$(wc -l < '\(counter)' | tr -d ' '); printf 'password: \"value-%s\"\\n' \"$n\" >&2"))

        let first = await reader.read(service: "SLACK_TOKEN_T01")
        let second = await reader.read(service: "SLACK_TOKEN_T01")

        #expect(first == .found("value-1"))
        #expect(second == .found("value-2"))
    }

    @Test("a found lookup describes itself without the value")
    func foundDescriptionIsRedacted() {
        let lookup = KeychainLookup.found("xoxc-1111-secret")

        #expect(!String(describing: lookup).contains("xoxc-1111-secret"))
        #expect(!String(reflecting: lookup).contains("xoxc-1111-secret"))
        #expect(String(describing: lookup).contains("<redacted>"))
        #expect(lookup.value == "xoxc-1111-secret")
    }

    @Test("only found carries a value", arguments: [KeychainLookup.absent, .timedOut(after: 10), .unavailable(reason: "exited with status 51")])
    func onlyFoundHasAValue(lookup: KeychainLookup) {
        #expect(lookup.value == nil)
    }

    @Test("production reads /usr/bin/security with the user's search list and a 10 second limit")
    func productionDefaults() {
        let reader = SecurityCLIKeychainReader()

        #expect(reader.executable.path == "/usr/bin/security")
        #expect(reader.keychainPath == nil)
        #expect(reader.timeout == 10)
    }

    // MARK: - Helpers

    /// Replaces fd 0 with a pipe holding `input` while `body` runs.
    func withRedirectedStdin<T>(feeding input: String, _ body: () async throws -> T) async throws -> T {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(input.utf8))
        try pipe.fileHandleForWriting.close()
        let saved = dup(0)
        dup2(pipe.fileHandleForReading.fileDescriptor, 0)
        defer { dup2(saved, 0); close(saved) }
        return try await body()
    }
}
