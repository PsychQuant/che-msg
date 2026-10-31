import Foundation
import Testing
@testable import SlackWebLib

/// Deleting an item, for `slack-all auth remove` (spec: slack-credentials,
/// "Workspace removal"), with a stand-in for `/usr/bin/security` that
/// records each call. No test here runs the real tool;
/// `ScratchKeychainTests` does that against a scratch keychain file.
@Suite("Deleting an item through security")
struct KeychainDeleteTests {
    let scratch: ScratchDirectory

    init() throws { scratch = try ScratchDirectory() }

    /// A stand-in that records its arguments, one per line, in `argv-<n>` and
    /// what it read on stdin in `stdin-<n>`, then runs `delete` for
    /// `delete-generic-password` and `find` for the read-back (by default
    /// exit 44: the item is not found).
    func recordingSecurity(_ delete: String = "exit 0", find: String = "exit 44") throws -> URL {
        try scratch.fakeSecurity("""
            dir='\(scratch.url.path)'
            n=$(ls "$dir" | grep -c '^argv-')
            printf '%s\\n' "$@" > "$dir/argv-$n"
            cat > "$dir/stdin-$n"
            if [ "$1" = "delete-generic-password" ]; then
              \(delete)
            else
              \(find)
            fi
            """)
    }

    func recordedCalls() throws -> [[String]] {
        let names = try FileManager.default.contentsOfDirectory(atPath: scratch.url.path).filter { $0.hasPrefix("argv-") }
        return try (0..<names.count).map { n in
            try String(contentsOfFile: scratch.path("argv-\(n)"), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        }
    }

    static func error(_ body: () async throws -> Void) async -> SlackKeychainDeleteError? {
        do {
            try await body()
            return nil
        } catch let error as SlackKeychainDeleteError {
            return error
        } catch {
            Issue.record("unexpected error type: \(type(of: error))")
            return nil
        }
    }

    @Test("delete runs delete-generic-password with the account, the service and the keychain path, stdin empty, then reads the item back")
    func deleteArguments() async throws {
        let path = scratch.path("never-created.keychain-db")
        let writer = SecurityCLIKeychainWriter(executable: try recordingSecurity(), keychainPath: path)

        try await writer.delete(service: "SLACK_TOKEN_T01")

        #expect(try recordedCalls() == [
            ["delete-generic-password", "-a", "che-slack-mcp", "-s", "SLACK_TOKEN_T01", path],
            ["find-generic-password", "-a", "che-slack-mcp", "-s", "SLACK_TOKEN_T01", "-g", path],
        ])
        #expect(try String(contentsOfFile: scratch.path("stdin-0"), encoding: .utf8) == "")
    }

    @Test("an item that does not exist (security exits 44) is not an error")
    func absentIsNotAnError() async throws {
        let writer = SecurityCLIKeychainWriter(executable: try recordingSecurity("exit 44"), keychainPath: scratch.path("k"))

        let error = await Self.error { try await writer.delete(service: "SLACK_COOKIE_T01") }

        #expect(error == nil)
        #expect(try recordedCalls().count == 2)
    }

    @Test("a delete that fails throws failed, naming the service", arguments: [
        ("exit 1", "security exited with status 1"),
        ("exit 51", "security exited with status 51"),
    ])
    func failureIsReported(body: String, reason: String) async throws {
        let writer = SecurityCLIKeychainWriter(executable: try recordingSecurity(body), keychainPath: scratch.path("k"))

        let error = await Self.error { try await writer.delete(service: "SLACK_TOKEN_T01") }

        #expect(error == .failed(service: "SLACK_TOKEN_T01", reason: reason))
        #expect(error?.description.contains("SLACK_TOKEN_T01") == true)
    }

    /// A second keychain in the search list can hold the same item; deleting
    /// removes only the first, so a removal must not report success while a
    /// credential is still readable.
    @Test("an item still readable after the delete makes it fail, naming the service and not the value", arguments: [
        (#"printf 'password: "xoxc-still-here"\n' >&2"#, "the item still exists when read back"),
        ("exit 51", "reading the item back failed: exited with status 51"),
    ])
    func stillReadableFails(find: String, reason: String) async throws {
        let writer = SecurityCLIKeychainWriter(executable: try recordingSecurity(find: find), keychainPath: scratch.path("k"))

        let error = await Self.error { try await writer.delete(service: "SLACK_TOKEN_T01") }

        #expect(error == .failed(service: "SLACK_TOKEN_T01", reason: reason))
        #expect(error?.description.contains("xoxc-still-here") == false)
    }

    @Test("a service outside the layout is refused and nothing is started", arguments: [
        ("OTHER_ITEM", SlackKeychainWriteRefusal.unknownService),
        (#"SLACK_TOKEN_T01"x"#, .teamID),
        ("SLACK_COOKIE_", .teamID),
    ])
    func refusedServiceStartsNothing(service: String, reason: SlackKeychainWriteRefusal) async throws {
        let writer = SecurityCLIKeychainWriter(executable: try recordingSecurity(), keychainPath: scratch.path("k"))

        let error = await Self.error { try await writer.delete(service: service) }

        #expect(error == .refused(service: service, reason: reason))
        #expect(try recordedCalls().isEmpty)
    }

    @Test("a delete still running after the timeout is stopped and reported as timed out")
    func deleteTimesOut() async throws {
        let writer = SecurityCLIKeychainWriter(executable: try recordingSecurity("exec sleep 30"),
                                               keychainPath: scratch.path("k"), timeout: KeychainWriterTests.termination)

        let error = await Self.error { try await writer.delete(service: "SLACK_TOKEN_T01") }

        #expect(error == .timedOut(service: "SLACK_TOKEN_T01", after: KeychainWriterTests.termination))
    }

    @Test("a tool that cannot be started is reported as failed, naming the service")
    func cannotStart() async throws {
        let missing = scratch.path("no-such-security")
        let writer = SecurityCLIKeychainWriter(executable: URL(fileURLWithPath: missing), keychainPath: scratch.path("k"))

        let error = await Self.error { try await writer.delete(service: "SLACK_TOKEN_T01") }

        #expect(error == .failed(service: "SLACK_TOKEN_T01", reason: "could not start \(missing)"))
    }
}
