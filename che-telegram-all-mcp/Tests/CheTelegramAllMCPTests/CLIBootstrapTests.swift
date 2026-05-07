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
}
