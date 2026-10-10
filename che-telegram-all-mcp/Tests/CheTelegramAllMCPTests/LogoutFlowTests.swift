import XCTest
import MCP
import TelegramAllLib
@testable import CheTelegramAllMCPCore

/// The server's `logout` flow (PsychQuant/che-msg#63, task 8.4): what is
/// released and reset after each outcome of the local reset.
final class LogoutFlowTests: XCTestCase {
    private final class FakeClient: TDLibClosable, @unchecked Sendable {
        var closeSucceeds = true
        func close(timeout: TimeInterval) async -> Bool { closeSucceeds }
    }

    private final class Calls: @unchecked Sendable { var discard = 0; var resetSync = 0 }

    private var parent: URL!
    private var database: URL!
    private let now = Date(timeIntervalSince1970: 1_791_601_445)

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString)")
        database = parent.appendingPathComponent("tdlib")
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        try Data("binlog".utf8).write(to: database.appendingPathComponent("td.binlog"))
        addTeardownBlock { [parent] in try? FileManager.default.removeItem(at: parent!) }
    }

    private func run(_ client: FakeClient, _ calls: Calls) async -> CallTool.Result {
        await performLocalReset(client: client, directory: database, now: now,
                                discard: { calls.discard += 1 }, resetSync: { calls.resetSync += 1 })
    }

    private func text(_ result: CallTool.Result) -> String {
        guard case .text(let text, _, _) = result.content.first else { return "" }
        return text
    }

    func testSuccessReleasesTDLibResetsSyncAndExplainsTheOldSession() async throws {
        let calls = Calls()
        let result = await run(FakeClient(), calls)
        XCTAssertEqual(result.isError, false)
        XCTAssertEqual(calls.discard, 1)
        XCTAssertEqual(calls.resetSync, 1)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(result).utf8)) as? [String: Any])
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual((payload["renamed_directory"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent },
                       "tdlib.invalidated-20261010-030405")
        let note = try XCTUnwrap(payload["note"] as? String)
        XCTAssertTrue(note.contains("device list"), note)
        XCTAssertTrue(note.contains("do not move"), note)
    }

    func testCloseFailureKeepsTDLibAndChangesNothing() async {
        let client = FakeClient(); client.closeSucceeds = false
        let calls = Calls()
        let result = await run(client, calls)
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(calls.discard, 0)
        XCTAssertEqual(calls.resetSync, 0)
        XCTAssertTrue(text(result).contains("nothing was changed"), text(result))
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
    }

    func testRenameFailureKeepsTDLibHeldSoTheOldDirectoryIsNotReopened() async throws {
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("tdlib.invalidated-20261010-030405"),
                                                withIntermediateDirectories: true)
        let calls = Calls()
        let result = await run(FakeClient(), calls)
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(calls.discard, 0, "TDLib stays held, so no client reopens the old directory")
        XCTAssertEqual(calls.resetSync, 0)
        XCTAssertTrue(text(result).contains("/mcp"), text(result))
    }
}
