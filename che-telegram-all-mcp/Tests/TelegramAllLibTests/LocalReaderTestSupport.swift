import CTDLibSQLite
import XCTest
@testable import TelegramAllLib

/// Writes TDLib's TL serialization (td/utils/tl_storers.h): little-endian
/// integers and length-prefixed strings padded to 4 bytes. Used to hand-build
/// records in the field order of the TDLib 1.8.60 sources.
struct TLWriter {
    private(set) var bytes: [UInt8] = []

    mutating func int32(_ value: Int32) { uint32(UInt32(bitPattern: value)) }

    mutating func uint32(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }

    mutating func int64(_ value: Int64) {
        let raw = UInt64(bitPattern: value)
        uint32(UInt32(truncatingIfNeeded: raw))
        uint32(UInt32(truncatingIfNeeded: raw >> 32))
    }

    mutating func uint64(_ value: UInt64) { int64(Int64(bitPattern: value)) }

    mutating func string(_ value: String) { string(Array(value.utf8)) }

    mutating func string(_ value: [UInt8]) {
        let header: Int
        if value.count < 254 {
            bytes.append(UInt8(value.count))
            header = 1
        } else {
            bytes += [254, UInt8(value.count & 0xFF), UInt8((value.count >> 8) & 0xFF), UInt8((value.count >> 16) & 0xFF)]
            header = 4
        }
        bytes += value
        bytes += [UInt8](repeating: 0, count: (4 - (header + value.count) % 4) % 4)
    }
}

/// Flag word with the given bits set (BEGIN_STORE_FLAGS numbers bits from 0).
func flags(_ bits: Int...) -> UInt32 { bits.reduce(0) { $0 | 1 << UInt32($1) } }

func flags64(_ bits: Int...) -> UInt64 { bits.reduce(0) { $0 | 1 << UInt64($1) } }

/// Private copies of the never-logged-in TDLib 1.8.60 fixture
/// (Fixtures/tdlib-1.8.60-test-dc), and a read-write connection that plays
/// the TDLib instance holding the database.
enum LocalReaderFixture {
    static var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/tdlib-1.8.60-test-dc")
    }

    /// Copies td.binlog and db.sqlite into a new temporary directory that the
    /// test case removes when it finishes. With `authorized`, the copy's binlog
    /// gets the `auth` = `ok` entry TDLib writes on login; the fixture itself
    /// was never logged in.
    static func copy(for test: XCTestCase, named name: String = "tdlib-\(UUID().uuidString)",
                     authorized: Bool = true) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in ["td.binlog", "db.sqlite"] {
            try FileManager.default.copyItem(at: directory.appendingPathComponent(file), to: dir.appendingPathComponent(file))
        }
        test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        if authorized {
            try appendBinlogEvents([.keyValue("auth", "ok")], to: dir.appendingPathComponent("td.binlog").path)
        }
        return dir
    }

    /// A binlog event to append; `id` nil means one past the largest id.
    struct BinlogEvent {
        var id: UInt64?
        var type: Int32
        var flags: Int32
        var data: [UInt8]

        /// A `BinlogKeyValue` set, or with `id` a rewrite of that entry.
        static func keyValue(_ key: String, _ value: String, rewriting id: UInt64? = nil) -> BinlogEvent {
            var w = TLWriter()
            w.string(key)
            w.string(value)
            return BinlogEvent(id: id, type: TDLibBinlogReader.binlogPMCEventType, flags: id == nil ? 0 : 1, data: w.bytes)
        }

        /// A `BinlogKeyValue` erase: an `Empty` event rewriting entry `id`.
        static func erase(_ id: UInt64) -> BinlogEvent {
            BinlogEvent(id: id, type: -2, flags: 1, data: [])
        }
    }

    /// Appends `events` to the encrypted binlog at `path` in TDLib's event
    /// format (size, id, type, flags, extra, data, CRC32), continuing its
    /// AES-CTR stream. Returns the ids used.
    @discardableResult
    static func appendBinlogEvents(_ events: [BinlogEvent], to path: String) throws -> [UInt64] {
        let file = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        var cursor = 0
        var encryption: (key: [UInt8], iv: [UInt8], start: Int)?
        while encryption == nil, let event = TDLibBinlogReader.nextEvent(in: file, at: cursor) {
            cursor += event.size
            if event.type == TDLibBinlogReader.encryptionEventType {
                let cipher = try TDLibBinlogReader.encryptionKey(from: event.data)
                encryption = (cipher.key, cipher.iv, cursor)
            }
        }
        let cipher = try XCTUnwrap(encryption, "the fixture binlog has no encryption event")
        var plain = Array(file[0..<cipher.start])
            + (try TDLibBinlogReader.aesCTR(Array(file[cipher.start...]), key: cipher.key, iv: cipher.iv))
        var lastId: UInt64 = 0
        cursor = 0
        while let event = TDLibBinlogReader.nextEvent(in: plain, at: cursor) {
            lastId = max(lastId, event.id)
            cursor += event.size
        }
        plain = Array(plain[0..<cursor])
        var ids: [UInt64] = []
        for event in events {
            let id = event.id ?? lastId + 1
            lastId = max(lastId, id)
            ids.append(id)
            var w = TLWriter()
            w.uint32(UInt32(28 + event.data.count + 4))
            w.uint64(id)
            w.int32(event.type)
            w.int32(event.flags)
            w.uint64(0)
            var bytes = w.bytes + event.data
            let crc = TDLibBinlogReader.crc32(bytes[...])
            bytes += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
            plain += bytes
        }
        let encrypted = Array(plain[0..<cipher.start])
            + (try TDLibBinlogReader.aesCTR(Array(plain[cipher.start...]), key: cipher.key, iv: cipher.iv))
        try Data(encrypted).write(to: URL(fileURLWithPath: path))
        return ids
    }

    /// Opens the database read-write with its key, the way TDLib does.
    static func openAsWriter(_ dir: URL) throws -> OpaquePointer? {
        let key = try TDLibBinlogReader.sqliteKey(fromBinlogAt: dir.appendingPathComponent("td.binlog").path)
        var db: OpaquePointer?
        XCTAssertEqual(tdsqlite3_open_v2(dir.appendingPathComponent("db.sqlite").path, &db, 0x2, nil), TDSQLITE_OK)
        let hex = key.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(tdsqlite3_exec(db, "PRAGMA key = \"x'\(hex)'\"", nil, nil, nil), TDSQLITE_OK)
        return db
    }

    /// Runs `sql` on the writer connection and fails the test if it errors.
    static func exec(_ db: OpaquePointer?, _ sql: String, file: StaticString = #filePath, line: UInt = #line) {
        let rc = tdsqlite3_exec(db, sql, nil, nil, nil)
        XCTAssertEqual(rc, TDSQLITE_OK, String(cString: tdsqlite3_errmsg(db)), file: file, line: line)
    }

    /// `x'…'` literal for `bytes`.
    static func blob(_ bytes: [UInt8]) -> String {
        "x'" + bytes.map { String(format: "%02x", $0) }.joined() + "'"
    }

    /// Stores `value` under `key` in the `common` table the way TDLib's
    /// SqliteKeyValue does: both columns are BLOBs.
    static func putCommon(_ db: OpaquePointer?, _ key: String, _ value: [UInt8], line: UInt = #line) {
        exec(db, "INSERT INTO common (k, v) VALUES (\(blob(Array(key.utf8))), \(blob(value)))", line: line)
    }

    static func putDialog(_ db: OpaquePointer?, id: Int64, order: Int64, folder: Int32, line: UInt = #line) {
        exec(db, "INSERT INTO dialogs (dialog_id, dialog_order, data, folder_id) VALUES (\(id), \(order), x'00', \(folder))", line: line)
    }
}

/// Hand-built `common` and `messages` records in TDLib 1.8.60 field order.
enum LocalReaderRecords {
    /// `User::store` with a version-57 layout.
    static func user(_ first: String, _ last: String? = nil) -> [UInt8] {
        var w = TLWriter()
        w.int32(57); w.uint32(last == nil ? 0 : flags(8)); w.uint32(0)
        w.string(first)
        if let last { w.string(last) }
        return w.bytes
    }

    /// `Chat::store`: flags, title.
    static func basicGroup(_ title: String) -> [UInt8] {
        var w = TLWriter()
        w.int32(57); w.uint32(flags(8)); w.string(title)
        return w.bytes
    }

    /// `Channel::store`: flags, flags2, status, access_hash, title.
    static func channel(_ title: String, megagroup: Bool) -> [UInt8] {
        var w = TLWriter()
        w.int32(57); w.uint32(megagroup ? flags(7, 12, 29) : flags(12, 29)); w.uint32(0)
        w.uint64(UInt64(4) << 28); w.int64(99); w.string(title)
        return w.bytes
    }

    /// `Message::store` for a text message; with `forwarded`, a message whose
    /// forward info (flags3 bit 12) the reader does not decode.
    static func message(id: Int64, sender: Int64, date: Int32, outgoing: Bool = false,
                        text: String, forwarded: Bool = false) -> [UInt8] {
        var w = TLWriter()
        w.int32(57)
        w.uint32(flags(10) | (outgoing ? flags(1) : 0) | (forwarded ? flags(29) : 0))
        if forwarded { w.uint32(flags(29)); w.uint32(flags(12)) }
        w.int64(id); w.int64(sender); w.int32(date)
        if forwarded { w.int64(0x0BAD_F00D) }
        w.int32(0); w.uint32(0); w.string(text); w.int32(0)
        return w.bytes
    }
}

extension LocalReaderFixture {
    static func putMessage(_ db: OpaquePointer?, chat: Int64, id: Int64, sender: Int64, data: [UInt8], line: UInt = #line) {
        exec(db, "INSERT INTO messages (dialog_id, message_id, sender_user_id, data) VALUES (\(chat), \(id), \(sender), \(blob(data)))", line: line)
    }
}
