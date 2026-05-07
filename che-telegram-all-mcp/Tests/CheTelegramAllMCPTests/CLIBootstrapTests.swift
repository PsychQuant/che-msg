import XCTest
@testable import CheTelegramAllMCPCore

/// Tests for `CLIBootstrap.parse` — argv handling that runs BEFORE TDLib init.
///
/// Why this exists: previous behavior (#29) had no fast-exit path for `--version`
/// or `--help`. Health checks and Claude Code's `/mcp` reconnect probe paid the
/// full ~10s cold-start cost (TDLib framework load + state init) for every spawn,
/// even though those callers only need the version string. This test pins down
/// the pure-function contract so the dispatcher in `main.swift` stays trivial.
final class CLIBootstrapTests: XCTestCase {

    // MARK: - --version / -v

    func testLongVersionFlagReturnsShowVersion() {
        XCTAssertEqual(CLIBootstrap.parse(["binary", "--version"]), .showVersion)
    }

    func testShortVersionFlagReturnsShowVersion() {
        XCTAssertEqual(CLIBootstrap.parse(["binary", "-v"]), .showVersion)
    }

    // MARK: - --help / -h

    func testLongHelpFlagReturnsShowHelp() {
        XCTAssertEqual(CLIBootstrap.parse(["binary", "--help"]), .showHelp)
    }

    func testShortHelpFlagReturnsShowHelp() {
        XCTAssertEqual(CLIBootstrap.parse(["binary", "-h"]), .showHelp)
    }

    // MARK: - Default: run server

    func testNoArgumentsReturnsRunServer() {
        XCTAssertEqual(CLIBootstrap.parse(["binary"]), .runServer)
    }

    func testUnknownFirstArgReturnsRunServer() {
        // Unknown args fall through to runServer; the MCP server itself is
        // stdio-driven and ignores argv beyond [0].
        XCTAssertEqual(CLIBootstrap.parse(["binary", "--unknown"]), .runServer)
    }

    func testEmptyArgsReturnsRunServer() {
        // Defensive: argv[0] missing shouldn't crash. Real OS always provides
        // it, but the parser must not assume.
        XCTAssertEqual(CLIBootstrap.parse([]), .runServer)
    }

    // MARK: - Help text content

    func testHelpTextContainsVersionConstant() {
        // Help text must self-document the version so users running --help
        // see the same number that --version would print.
        XCTAssertTrue(
            CLIBootstrap.helpText.contains(CLIBootstrap.version),
            "helpText must include version constant '\(CLIBootstrap.version)'"
        )
    }

    func testHelpTextMentionsStdioJsonRpc() {
        // Without this hint, a user running `--help` cannot tell that the
        // binary's primary mode is stdio JSON-RPC (not interactive CLI).
        // This was the diagnostic-finding rationale for adding --help (#29).
        XCTAssertTrue(
            CLIBootstrap.helpText.lowercased().contains("stdio")
                || CLIBootstrap.helpText.lowercased().contains("json-rpc")
                || CLIBootstrap.helpText.lowercased().contains("mcp"),
            "helpText must mention stdio JSON-RPC / MCP as the primary mode"
        )
    }

    func testHelpTextMentionsStartupLogEnvVar() {
        // Discoverability: env-gated startup log is the diagnostic hook for #29.
        // If `--help` doesn't surface the env var name, users won't know it exists.
        XCTAssertTrue(
            CLIBootstrap.helpText.contains("CHE_TELEGRAM_LOG_STARTUP"),
            "helpText must mention CHE_TELEGRAM_LOG_STARTUP env var for diagnostic discoverability"
        )
    }

    // MARK: - shouldLogStartup env predicate (#29 verify F4)

    /// `shouldLogStartup` is the production safety mechanism — a typo in its
    /// condition would either silently disable diagnostic logging or
    /// (worse) flood production stderr. These tests pin the strict `"1"`
    /// contract documented in the help text.

    func testShouldLogStartupTrueOnStrictOne() {
        XCTAssertTrue(shouldLogStartup(env: ["CHE_TELEGRAM_LOG_STARTUP": "1"]))
    }

    func testShouldLogStartupFalseWhenUnset() {
        XCTAssertFalse(shouldLogStartup(env: [:]))
    }

    func testShouldLogStartupFalseOnZero() {
        XCTAssertFalse(shouldLogStartup(env: ["CHE_TELEGRAM_LOG_STARTUP": "0"]))
    }

    func testShouldLogStartupFalseOnTrueWord() {
        // Strict `"1"` — does NOT accept `"true"`, `"yes"`, `"on"`. This is
        // intentional (matches help text + avoids ambiguous truthy strings).
        XCTAssertFalse(shouldLogStartup(env: ["CHE_TELEGRAM_LOG_STARTUP": "true"]))
    }

    func testShouldLogStartupFalseOnEmpty() {
        XCTAssertFalse(shouldLogStartup(env: ["CHE_TELEGRAM_LOG_STARTUP": ""]))
    }

    func testShouldLogStartupFalseOnUppercase() {
        XCTAssertFalse(shouldLogStartup(env: ["CHE_TELEGRAM_LOG_STARTUP": "TRUE"]))
    }

    // MARK: - Subprocess integration tests (#29 verify F1)

    /// Spawn the built binary with a flag and assert exit code + stdout.
    /// Skipped if the debug binary is not built — keeps CI environments
    /// without a build artifact happy.
    ///
    /// Why these complement the parser unit tests: the parser tests pin
    /// down the pure decision contract (parse arr → CLIAction). The
    /// dispatcher in `main.swift` translates that into print/exit/run.
    /// A typo there (e.g. swapping `print(version)` and `print(help)`,
    /// or `exit(0)` → `exit(1)`) is silently shipped without these.
    /// These tests are 100ms each, deterministic (no TDLib path), and
    /// were called out as a P1 gap by both pr-test-analyzer and Codex
    /// in the verify round.
    private func runBinary(_ args: [String]) throws -> (exitCode: Int32, stdout: String, stderr: String)? {
        // Locate the built binary relative to the test bundle. SwiftPM puts
        // executables and test bundles in the same .build/<arch>/<config>/
        // directory, so we resolve from the .xctest bundle URL up to the
        // build dir. `Bundle(for:)` returns the .xctest bundle reliably
        // under both `swift test` and Xcode test runners — `ProcessInfo
        // .arguments[0]` is the test runner (e.g., xctest helper), not the
        // bundle, so it can't be used here.
        let testBundleURL = Bundle(for: type(of: self)).bundleURL.resolvingSymlinksInPath()
        // testBundleURL example: .../.build/arm64-apple-macosx/debug/CheTelegramAllMCPPackageTests.xctest
        let buildDir = testBundleURL.deletingLastPathComponent()
        let candidate = buildDir.appendingPathComponent("CheTelegramAllMCP")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            return nil  // Binary not built — caller should skip
        }

        let process = Process()
        process.executableURL = candidate
        process.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = Pipe()  // closed stdin so server flow exits if accidentally entered

        try process.run()
        process.waitUntilExit()

        let stdout = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, stdout, stderr)
    }

    func testBinaryVersionFlagExits0WithVersionStdout() throws {
        guard let result = try runBinary(["--version"]) else {
            throw XCTSkip("CheTelegramAllMCP binary not built — skip subprocess test")
        }
        XCTAssertEqual(result.exitCode, 0, "exit 0 expected")
        XCTAssertTrue(
            result.stdout.contains(CLIBootstrap.version),
            "stdout must contain version constant; got: \(result.stdout)"
        )
        XCTAssertFalse(
            result.stderr.contains("[startup]"),
            "stderr must NOT contain [startup] lines (TDLib init must NOT have been entered); got: \(result.stderr)"
        )
    }

    func testBinaryShortVersionFlagExits0() throws {
        guard let result = try runBinary(["-v"]) else {
            throw XCTSkip("CheTelegramAllMCP binary not built — skip subprocess test")
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains(CLIBootstrap.version))
    }

    func testBinaryHelpFlagExits0WithStdioMention() throws {
        guard let result = try runBinary(["--help"]) else {
            throw XCTSkip("CheTelegramAllMCP binary not built — skip subprocess test")
        }
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(
            result.stdout.lowercased().contains("stdio") || result.stdout.lowercased().contains("json-rpc"),
            "stdout must surface stdio/json-rpc mode; got: \(result.stdout)"
        )
    }
}
