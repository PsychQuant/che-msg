import Foundation
import Testing
@testable import CheSlackMCPCore

/// `CheSlackMCP --version` (PsychQuant/che-msg#114). The release build runs
/// the built binary with `--version` before and after signing and expects the
/// one line `che-slack-mcp X`; the binary must answer before it starts the
/// server, so the check opens no Keychain item, no stdin and no connection.
@Suite("CheSlackMCP --version")
struct VersionFlagTests {
    @Test("the version line is the server name and its version")
    func versionLine() {
        #expect(CheSlackMCPServer.versionLine == "che-slack-mcp \(CheSlackMCPServer.version)")
        #expect(CheSlackMCPServer.versionLine.range(
            of: #"^che-slack-mcp [0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil)
    }

    @Test("--version as the first argument asks for the version")
    func versionFlag() {
        #expect(CheSlackMCPServer.asksForVersion(["CheSlackMCP", "--version"]))
    }

    /// Everything else starts the server, as every argument did before
    /// `--version` existed.
    @Test("any other argv starts the server", arguments: [
        [],
        ["CheSlackMCP"],
        ["CheSlackMCP", "-v"],
        ["CheSlackMCP", "--help"],
        ["CheSlackMCP", "--versions"],
        ["CheSlackMCP", "version"],
        ["CheSlackMCP", "config.json", "--version"],
    ])
    func otherArguments(_ argv: [String]) {
        #expect(!CheSlackMCPServer.asksForVersion(argv))
    }

    /// The built binary itself: stdin stays open, so a binary that started
    /// the server would wait on it until the deadline.
    @Test("the built CheSlackMCP prints the line and exits 0 without reading stdin")
    func builtBinary() async throws {
        let binary = try #require(Self.builtProduct("CheSlackMCP"),
                                  "no built CheSlackMCP next to the test bundle")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["--version"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let finished = !process.isRunning
        if !finished {
            process.terminate()
            process.waitUntilExit()
        }
        try stdin.fileHandleForWriting.close()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        #expect(finished, "still running after 10 s with stdin open: it started the server")
        #expect(process.terminationStatus == 0)
        #expect(out == CheSlackMCPServer.versionLine + "\n")
        #expect(err.isEmpty)
    }

    /// An executable product of this package, in the directory that holds this
    /// test bundle (`.build/<configuration>`).
    static func builtProduct(_ name: String) -> URL? {
        let bundle = Bundle(for: BundleMarker.self)
        guard bundle.bundlePath.hasSuffix(".xctest") else { return nil }
        let url = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent(name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}

/// Locates this test bundle; `Bundle.main` is the test runner.
private final class BundleMarker {}
