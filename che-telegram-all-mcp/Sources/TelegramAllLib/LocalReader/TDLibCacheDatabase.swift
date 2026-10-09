import CTDLibSQLite
import Foundation
import TDLibFramework

/// Read-only access to TDLib's encrypted SQLite cache (`db.sqlite`).
///
/// The database is opened with `SQLITE_OPEN_READONLY` and `PRAGMA query_only`,
/// through the SQLCipher build bundled in TDLibFramework, so this connection
/// cannot write `db.sqlite` or `db.sqlite-wal`. SQLite may still update
/// `db.sqlite-shm`, the shared-memory index that concurrent readers use; that
/// file is the one exception the spec allows.
///
/// Reading proceeds only for the TDLib build and SQLite schema the reader was
/// verified against; anything else is `unsupportedTDLibVersion`.
public final class TDLibCacheDatabase {
    static let verifiedTDLibVersion = "1.8.60"
    static let verifiedTDLibCommitPrefix = "cb863c16"
    static let verifiedUserVersion: Int64 = 14

    public let userVersion: Int
    private let db: OpaquePointer

    /// The version and commit of the TDLib linked into this binary.
    public static func linkedTDLibVersion() -> (version: String, commit: String) {
        (stringOption("version"), stringOption("commit_hash"))
    }

    /// `version` and `commit_hash` are TDLib's synchronous options: `td_execute`
    /// answers them without a client.
    private static func stringOption(_ name: String) -> String {
        guard let raw = td_execute(#"{"@type":"getOption","name":"\#(name)"}"#),
              let object = try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8)) as? [String: Any],
              object["@type"] as? String == "optionValueString",
              let value = object["value"] as? String else { return "" }
        return value
    }

    /// Opens the cache in `directory` (the folder holding `td.binlog` and
    /// `db.sqlite`). Error messages never include key material.
    public init(directory: String,
                linkedVersion: (version: String, commit: String) = TDLibCacheDatabase.linkedTDLibVersion()) throws {
        guard linkedVersion.version == Self.verifiedTDLibVersion,
              linkedVersion.commit.hasPrefix(Self.verifiedTDLibCommitPrefix) else {
            throw LocalReaderError.unsupportedTDLibVersion(
                "linked TDLib \(linkedVersion.version) (\(linkedVersion.commit.prefix(8))); "
                + "the reader is verified for \(Self.verifiedTDLibVersion) (\(Self.verifiedTDLibCommitPrefix))")
        }
        let folder = URL(fileURLWithPath: directory)
        let values = try TDLibBinlogReader.keyValues(fromBinlogAt: folder.appendingPathComponent("td.binlog").path)
        let key = try TDLibBinlogReader.sqliteKey(in: values)
        guard TDLibBinlogReader.isLoggedIn(values) else { throw LocalReaderError.notAuthenticated }
        let db = try Self.openReadOnly(folder.appendingPathComponent("db.sqlite").path, key: key)
        do {
            let version = try Self.scalarInt("PRAGMA user_version", in: db)
            guard version == Self.verifiedUserVersion else {
                throw LocalReaderError.unsupportedTDLibVersion(
                    "db.sqlite user_version \(version); the reader is verified for \(Self.verifiedUserVersion)")
            }
            self.userVersion = Int(version)
        } catch {
            tdsqlite3_close(db)
            throw error
        }
        self.db = db
    }

    deinit {
        tdsqlite3_close(db)
    }

    func scalarInt(_ sql: String) throws -> Int64 {
        try Self.scalarInt(sql, in: db)
    }

    enum Parameter {
        case int(Int64)
        case blob([UInt8])
    }

    /// One result row; valid only inside the `forEachRow` callback.
    struct Row {
        fileprivate let statement: OpaquePointer

        func int64(_ column: Int32) -> Int64 { tdsqlite3_column_int64(statement, column) }

        func isNull(_ column: Int32) -> Bool { tdsqlite3_column_type(statement, column) == TDSQLITE_NULL }

        func blob(_ column: Int32) -> [UInt8] {
            let count = Int(tdsqlite3_column_bytes(statement, column))
            guard count > 0, let base = tdsqlite3_column_blob(statement, column) else { return [] }
            return Array(UnsafeRawBufferPointer(start: base, count: count))
        }
    }

    /// Runs `sql` with `parameters` bound to `?1`, `?2`, … and calls `body`
    /// for each row.
    func forEachRow(_ sql: String, _ parameters: [Parameter] = [], _ body: (Row) throws -> Void) throws {
        try forEachRow(sql, parameters, until: { try body($0); return true })
    }

    /// Like `forEachRow`, but stops as soon as `body` returns false.
    func forEachRow(_ sql: String, _ parameters: [Parameter] = [], until body: (Row) throws -> Bool) throws {
        var prepared: OpaquePointer?
        guard tdsqlite3_prepare_v2(db, sql, -1, &prepared, nil) == TDSQLITE_OK, let statement = prepared else {
            throw LocalReaderError.databaseUnreadable(String(cString: tdsqlite3_errmsg(db)))
        }
        defer { tdsqlite3_finalize(statement) }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let rc: Int32
            switch parameter {
            case .int(let value):
                rc = tdsqlite3_bind_int64(statement, index, value)
            case .blob(let bytes):
                rc = bytes.withUnsafeBytes { ctdlib_bind_blob_copy(statement, index, $0.baseAddress, Int32($0.count)) }
            }
            guard rc == TDSQLITE_OK else {
                throw LocalReaderError.databaseUnreadable(String(cString: tdsqlite3_errmsg(db)))
            }
        }
        while true {
            let rc = tdsqlite3_step(statement)
            if rc == TDSQLITE_DONE { return }
            guard rc == TDSQLITE_ROW else {
                throw LocalReaderError.databaseUnreadable(String(cString: tdsqlite3_errmsg(db)))
            }
            if try !body(Row(statement: statement)) { return }
        }
    }

    /// A read-only connection to a WAL database creates `db.sqlite-wal` and
    /// `db.sqlite-shm` when they are missing, and cannot remove them afterwards.
    /// They are missing when no TDLib instance holds the database; the main file
    /// then holds everything, so it is opened as immutable (no locks, no -wal,
    /// no -shm). With a holder present the -wal file exists and is read normally,
    /// which is how the reader sees messages not yet checkpointed into the main
    /// file. A holder that starts mid-read writes to a new -wal; the main file
    /// changes only at a checkpoint, a window the short read accepts.
    private static func openReadOnly(_ path: String, key: Data) throws -> OpaquePointer {
        var uri = URLComponents()
        uri.scheme = "file"
        uri.path = path
        uri.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        if !FileManager.default.fileExists(atPath: path + "-wal") {
            uri.queryItems?.append(URLQueryItem(name: "immutable", value: "1"))
        }
        guard FileManager.default.fileExists(atPath: path), let uriString = uri.string else {
            throw LocalReaderError.databaseUnreadable("db.sqlite not found")
        }
        var handle: OpaquePointer?
        let rc = tdsqlite3_open_v2(uriString, &handle, TDSQLITE_OPEN_READONLY | TDSQLITE_OPEN_URI, nil)
        guard rc == TDSQLITE_OK, let db = handle else {
            let reason = handle.map { String(cString: tdsqlite3_errmsg($0)) } ?? "SQLite code \(rc)"
            tdsqlite3_close(handle)
            throw LocalReaderError.databaseUnreadable("cannot open db.sqlite: \(reason)")
        }
        let hex = key.map { String(format: "%02x", $0) }.joined()
        guard tdsqlite3_exec(db, "PRAGMA key = \"x'\(hex)'\"", nil, nil, nil) == TDSQLITE_OK,
              tdsqlite3_exec(db, "PRAGMA query_only = 1", nil, nil, nil) == TDSQLITE_OK else {
            tdsqlite3_close(db)
            throw LocalReaderError.databaseUnreadable("cannot configure the db.sqlite connection")
        }
        return db
    }

    private static func scalarInt(_ sql: String, in db: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard tdsqlite3_prepare_v2(db, sql, -1, &statement, nil) == TDSQLITE_OK else {
            throw LocalReaderError.databaseUnreadable(String(cString: tdsqlite3_errmsg(db)))
        }
        defer { tdsqlite3_finalize(statement) }
        guard tdsqlite3_step(statement) == TDSQLITE_ROW else {
            throw LocalReaderError.databaseUnreadable(String(cString: tdsqlite3_errmsg(db)))
        }
        return tdsqlite3_column_int64(statement, 0)
    }
}
