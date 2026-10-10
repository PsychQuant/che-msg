import XCTest
@testable import TelegramAllLib

/// Covers "Logout resets a session that no longer syncs"
/// (telegram-tdlib-lifecycle; PsychQuant/che-msg#63, task 6.1).
final class LogoutResetTests: XCTestCase {
    private final class FakeClient: TDLibLoggingOut, @unchecked Sendable {
        var logOutCompletes = true
        var closeSucceeds = true
        var calls: [String] = []
        func logOut(timeout: TimeInterval) async -> Bool { calls.append("logOut(\(Int(timeout)))"); return logOutCompletes }
        func close(timeout: TimeInterval) async -> Bool { calls.append("close"); return closeSucceeds }
    }

    private var parent: URL!
    private var database: URL!
    /// 2026-10-10 03:04:05 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_601_445)

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("reset-\(UUID().uuidString)")
        database = parent.appendingPathComponent("tdlib")
        try FileManager.default.createDirectory(at: database.appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data("binlog".utf8).write(to: database.appendingPathComponent("td.binlog"))
        try Data("sqlite".utf8).write(to: database.appendingPathComponent("db.sqlite"))
        addTeardownBlock { [parent] in try? FileManager.default.removeItem(at: parent!) }
    }

    private func contents(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let url = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            out[name] = isDir.boolValue ? Data() : try Data(contentsOf: url)
        }
        return out
    }

    func testRenamedNameIsUTCTimestamped() {
        XCTAssertEqual(TDLibSessionReset.renamedName(at: now), "tdlib.invalidated-20261010-030405")
    }

    // Scenario: TDLib completes the logout.
    func testCompletedLogoutRenamesNothing() async throws {
        let client = FakeClient()
        let before = try contents(database)
        let renamed = try await TDLibSessionReset.reset(client: client, directory: database, timeout: 30, now: now)
        XCTAssertNil(renamed)
        XCTAssertEqual(client.calls, ["logOut(30)"])
        XCTAssertEqual(try contents(database), before)
    }

    // Scenario: TDLib does not complete the logout.
    func testIncompleteLogoutClosesTDLibAndRenamesTheDirectory() async throws {
        let client = FakeClient(); client.logOutCompletes = false
        let before = try contents(database)
        let renamed = try await TDLibSessionReset.reset(client: client, directory: database, timeout: 30, now: now)
        XCTAssertEqual(client.calls, ["logOut(30)", "close"])
        XCTAssertEqual(renamed?.lastPathComponent, "tdlib.invalidated-20261010-030405")
        XCTAssertEqual(renamed?.deletingLastPathComponent().standardizedFileURL, parent.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path), "the next login starts from a new directory")
        XCTAssertEqual(try contents(try XCTUnwrap(renamed)), before, "nothing is deleted")
    }

    func testDirectoryIsLeftAloneWhenTDLibCannotBeClosed() async throws {
        let client = FakeClient(); client.logOutCompletes = false; client.closeSucceeds = false
        let before = try contents(database)
        do {
            _ = try await TDLibSessionReset.reset(client: client, directory: database, timeout: 30, now: now)
            XCTFail("expected couldNotClose")
        } catch let error as TDLibSessionReset.ResetError {
            XCTAssertEqual(error, .couldNotClose)
        }
        XCTAssertEqual(try contents(database), before)
    }

    func testExistingTargetIsNotOverwritten() async throws {
        let target = parent.appendingPathComponent("tdlib.invalidated-20261010-030405")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("earlier".utf8).write(to: target.appendingPathComponent("marker"))
        let client = FakeClient(); client.logOutCompletes = false
        let before = try contents(database)
        do {
            _ = try await TDLibSessionReset.reset(client: client, directory: database, timeout: 30, now: now)
            XCTFail("expected renameFailed")
        } catch let error as TDLibSessionReset.ResetError {
            guard case .renameFailed = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try contents(database), before)
        XCTAssertEqual(try contents(target), ["marker": Data("earlier".utf8)])
    }
}
