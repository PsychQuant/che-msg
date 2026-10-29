import Foundation
import SQLite3
import Testing
@testable import SlackAllCore

/// Reading the encrypted `d` cookie from a synthetic `Cookies` database,
/// built here with the SQLite C API in the shape Chromium uses (a `meta`
/// table of key/value text, a `cookies` table with `host_key`, `name`,
/// `value`, `encrypted_value` and `creation_utc`).
@Suite("Cookies database")
struct CookieDatabaseTests {
    struct Row {
        var host = ".slack.com"
        var name = "d"
        var encrypted: [UInt8]
        var created: Int64 = 100
    }

    /// A database file with the given meta version (nil: no version row,
    /// a String: stored as text, an Int: stored as an integer) and rows.
    static func database(version: Any?, rows: [Row]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cookies-test-\(UUID().uuidString)")
        try writeDatabase(to: url, version: version, rows: rows)
        return url
    }

    /// Writes such a database at `url`.
    static func writeDatabase(to url: URL, version: Any?, rows: [Row]) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw DesktopFormatError("fixture open") }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw DesktopFormatError("fixture: \(sql)") }
        }
        try exec("CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR)")
        try exec("CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL, "
            + "name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL)")
        switch version {
        case let text as String: try exec("INSERT INTO meta VALUES('version', '\(text)')")
        case let number as Int: try exec("INSERT INTO meta VALUES('version', \(number))")
        default: break
        }
        try exec("INSERT INTO meta VALUES('last_compatible_version', '24')")
        for row in rows {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT INTO cookies VALUES(?, ?, '', ?, '', ?, '/')", -1, &statement, nil) == SQLITE_OK else {
                throw DesktopFormatError("fixture prepare")
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_int64(statement, 1, row.created)
            sqlite3_bind_text(statement, 2, row.host, -1, transient)
            sqlite3_bind_text(statement, 3, row.name, -1, transient)
            _ = row.encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw DesktopFormatError("fixture insert") }
        }
    }

    static let value = Array("v10".utf8) + [0x01, 0x02, 0x03]

    @Test("the d cookie of .slack.com and the meta version are read; other hosts and names are not", arguments: ["24", 24] as [Any])
    func reads(version: Any) throws {
        let url = try Self.database(version: version, rows: [
            Row(host: ".other.com", encrypted: [9]),
            Row(name: "d-s", encrypted: [8]),
            Row(encrypted: Self.value),
            Row(host: "app.slack.com", encrypted: [7]),
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)

        let cookie = try ChromiumCookieDatabase.encryptedCookie(at: url, hostKey: ".slack.com", name: "d")

        #expect(cookie == EncryptedCookie(metaVersion: 24, encryptedValue: Self.value))
        #expect(try Data(contentsOf: url) == before)
        #expect(!cookie.description.contains("1, 2, 3"))
    }

    @Test("of two d cookies for .slack.com, the one created last is read")
    func newest() throws {
        let url = try Self.database(version: "24", rows: [
            Row(encrypted: [1], created: 300), Row(encrypted: Self.value, created: 900), Row(encrypted: [2], created: 500),
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try ChromiumCookieDatabase.encryptedCookie(at: url, hostKey: ".slack.com", name: "d").encryptedValue == Self.value)
    }

    @Test("no d cookie, an empty encrypted value, or no meta version throws a fixed phrase", arguments: 0..<4)
    func missing(index: Int) throws {
        let cases: [(Any?, [Row])] = [
            ("24", [Row(host: ".other.com", encrypted: Self.value)]),
            ("24", []),
            ("24", [Row(encrypted: [])]),
            (nil, [Row(encrypted: Self.value)]),
        ]
        let url = try Self.database(version: cases[index].0, rows: cases[index].1)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: DesktopFormatError.self) {
            try ChromiumCookieDatabase.encryptedCookie(at: url, hostKey: ".slack.com", name: "d")
        }
    }

    @Test("a file that is not SQLite, an empty file, or no file throws", arguments: ["not sqlite at all, just text", "", nil] as [String?])
    func notADatabase(contents: String?) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cookies-test-\(UUID().uuidString)")
        if let contents { try Data(contents.utf8).write(to: url) }
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: DesktopFormatError.self) {
            try ChromiumCookieDatabase.encryptedCookie(at: url, hostKey: ".slack.com", name: "d")
        }
    }

    @Test("a database without a cookies table throws")
    func noCookiesTable() throws {
        let url = try Self.database(version: "24", rows: [])
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        sqlite3_open(url.path, &db)
        sqlite3_exec(db, "DROP TABLE cookies", nil, nil, nil)
        sqlite3_close(db)

        #expect(throws: DesktopFormatError.self) {
            try ChromiumCookieDatabase.encryptedCookie(at: url, hostKey: ".slack.com", name: "d")
        }
    }
}
