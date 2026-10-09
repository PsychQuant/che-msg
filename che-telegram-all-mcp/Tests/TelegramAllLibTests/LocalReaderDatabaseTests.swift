import CTDLibSQLite
import XCTest
@testable import TelegramAllLib

/// Covers spec requirements "Reader never writes TDLib files" and "Reader
/// accepts only verified TDLib versions" (telegram-local-reader;
/// PsychQuant/che-msg#58, task 3.2).
final class LocalReaderDatabaseTests: XCTestCase {
    private func copyOfFixture(named name: String = "tdlib-\(UUID().uuidString)") throws -> URL {
        try LocalReaderFixture.copy(for: self, named: name)
    }

    /// Name -> (size, modification time) of every file in `dir`.
    private func snapshot(_ dir: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            let size = attributes[.size] as? Int ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            result[name] = "\(size)@\(modified)"
        }
        return result
    }

    private func openAsWriter(_ dir: URL) throws -> OpaquePointer? {
        try LocalReaderFixture.openAsWriter(dir)
    }

    func testOpensTheFixtureAndReadsItsUserVersion() throws {
        let database = try TDLibCacheDatabase(directory: try copyOfFixture().path)
        XCTAssertEqual(database.userVersion, 14)
    }

    /// The real database lives under "Application Support"; the URI the reader
    /// builds must survive spaces and URI metacharacters in the path.
    func testOpensADirectoryWhoseNameNeedsEscaping() throws {
        let dir = try copyOfFixture(named: "Application Support #?% \(UUID().uuidString)")
        XCTAssertEqual(try TDLibCacheDatabase(directory: dir.path).userVersion, 14)
    }

    func testLinkedTDLibIsTheVerifiedVersion() {
        let linked = TDLibCacheDatabase.linkedTDLibVersion()
        XCTAssertEqual(linked.version, "1.8.60")
        XCTAssertTrue(linked.commit.hasPrefix("cb863c16"), "linked TDLib commit \(linked.commit)")
    }

    // Scenario: Directory unchanged after reading (no TDLib instance holds the database)
    func testReadingADirectoryWithoutAWriterChangesNoFile() throws {
        let dir = try copyOfFixture()
        let before = try snapshot(dir)
        _ = try LocalTDLibReader(directory: dir.path).getChatHistory(chatId: 777)
        XCTAssertEqual(try snapshot(dir), before)
    }

    // Scenario: Directory unchanged after reading — except db.sqlite-shm, while a
    // TDLib instance holds the database and has written to its WAL.
    func testReadingWhileAWriterHoldsTheDatabaseChangesOnlyTheShmFile() throws {
        let dir = try copyOfFixture()
        let writer = try openAsWriter(dir)
        defer { tdsqlite3_close(writer) }
        XCTAssertEqual(tdsqlite3_exec(writer, "INSERT INTO common (k, v) VALUES ('test-writer', x'00')", nil, nil, nil), TDSQLITE_OK)
        var before = try snapshot(dir)
        XCTAssertNotNil(before["db.sqlite-wal"], "the writer should have created a WAL")
        do {
            let database = try TDLibCacheDatabase(directory: dir.path)
            XCTAssertEqual(try database.scalarInt("SELECT count(*) FROM common WHERE k = 'test-writer'"), 1,
                           "the reader must see the writer's committed data")
        }
        var after = try snapshot(dir)
        before.removeValue(forKey: "db.sqlite-shm")
        after.removeValue(forKey: "db.sqlite-shm")
        XCTAssertEqual(after, before)
    }

    // Scenario: Unknown SQLite user_version
    func testUnknownSQLiteUserVersionIsRejected() throws {
        let dir = try copyOfFixture()
        let writer = try openAsWriter(dir)
        XCTAssertEqual(tdsqlite3_exec(writer, "PRAGMA user_version = 13", nil, nil, nil), TDSQLITE_OK)
        tdsqlite3_close(writer)
        XCTAssertThrowsError(try TDLibCacheDatabase(directory: dir.path)) {
            XCTAssertEqual(($0 as? LocalReaderError)?.reason, "unsupported_tdlib_version")
        }
    }

    func testUnknownLinkedTDLibVersionIsRejected() throws {
        let dir = try copyOfFixture()
        XCTAssertThrowsError(try TDLibCacheDatabase(directory: dir.path, linkedVersion: (version: "1.8.61", commit: "0123abcd"))) {
            XCTAssertEqual(($0 as? LocalReaderError)?.reason, "unsupported_tdlib_version")
        }
    }

    /// A directory TDLib never logged in (or logged out of) has no `auth` =
    /// `ok` entry in its binlog.
    func testDirectoryThatIsNotLoggedInIsReported() throws {
        let dir = try LocalReaderFixture.copy(for: self, authorized: false)
        XCTAssertThrowsError(try TDLibCacheDatabase(directory: dir.path)) {
            XCTAssertEqual(($0 as? LocalReaderError)?.reason, "not_authenticated")
        }
        try LocalReaderFixture.appendBinlogEvents([.keyValue("auth", "logout")], to: dir.appendingPathComponent("td.binlog").path)
        XCTAssertThrowsError(try TDLibCacheDatabase(directory: dir.path)) {
            XCTAssertEqual(($0 as? LocalReaderError)?.reason, "not_authenticated")
        }
    }

    func testMissingDatabaseIsReportedAsUnreadable() throws {
        let dir = try copyOfFixture()
        try FileManager.default.removeItem(at: dir.appendingPathComponent("db.sqlite"))
        XCTAssertThrowsError(try TDLibCacheDatabase(directory: dir.path)) {
            XCTAssertEqual(($0 as? LocalReaderError)?.reason, "database_unreadable")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("db.sqlite").path),
                       "the reader must not create a database")
    }
}
