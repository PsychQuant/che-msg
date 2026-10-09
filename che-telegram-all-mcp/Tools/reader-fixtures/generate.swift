// Generates the TDLib on-disk fixture used by the local reader tests
// (telegram-all-sqlite-reader, task 2.1; PsychQuant/che-msg#58).
//
// The fixture is a TDLib database directory that has NEVER logged in: TDLib
// creates the encrypted td.binlog (with its AES-CTR encryption event and the
// random sqlite_key) and the encrypted db.sqlite with its full schema as soon as
// it receives its parameters. No phone number is ever sent, so the directory
// holds no personal data and can be committed. (Telegram disabled test-DC test
// accounts — tdlib/td#3083 — so a logged-in fixture is not possible; message and
// user formats are tested with hand-built rows instead, see design.md
// "測試資料拆成三種來源".)
//
// TDLib runs with use_test_dc and the generator refuses to continue unless every
// TCP connection goes to one of TDLib's built-in test DC addresses. Before
// anything is written to the fixture directory, the decrypted binlog and every
// SQLite row are scanned for the API id and API hash; if either appears the run
// aborts.
//
// Usage: run through generate.sh, which builds this file against the
// TDLibFramework archive and reads the API credentials from the keychain.

import CommonCrypto
import Foundation

// MARK: - TDLib JSON interface (statically linked from TDLibFramework)

@_silgen_name("td_create_client_id") func td_create_client_id() -> Int32
@_silgen_name("td_send") func td_send(_ clientId: Int32, _ request: UnsafePointer<CChar>)
@_silgen_name("td_receive") func td_receive(_ timeout: Double) -> UnsafePointer<CChar>?
@_silgen_name("td_execute") func td_execute(_ request: UnsafePointer<CChar>) -> UnsafePointer<CChar>?

struct GeneratorError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

typealias JSON = [String: Any]

func encode(_ obj: JSON) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
}

/// Remote IPv4/IPv6 addresses of this process's established TCP connections.
func remoteAddresses() throws -> Set<String> {
    let lsof = Process()
    lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    lsof.arguments = ["-nP", "-a", "-iTCP", "-sTCP:ESTABLISHED", "-p", String(ProcessInfo.processInfo.processIdentifier)]
    let pipe = Pipe()
    lsof.standardOutput = pipe
    try lsof.run()
    lsof.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    var result = Set<String>()
    for field in out.split(whereSeparator: { $0 == " " || $0 == "\n" }) where field.contains("->") {
        let remote = field.split(separator: ">").last.map(String.init) ?? ""
        if let colon = remote.lastIndex(of: ":") { result.insert(String(remote[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) }
    }
    return result
}

/// One TDLib client that is given parameters and then closed, never logged in.
final class UnauthorizedClient {
    let id = td_create_client_id()
    let directory: String
    private(set) var state = "none"

    init(directory: String) {
        self.directory = directory
        _ = td_execute(encode(["@type": "setLogVerbosityLevel", "new_verbosity_level": 1]))
    }

    func waitUntil(timeout: Double, _ what: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw GeneratorError("timed out waiting for \(what)") }
            pump(1.0)
        }
    }

    func idle(_ seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { pump(0.2) }
    }

    private func pump(_ timeout: Double) {
        guard let raw = td_receive(timeout),
              let event = (try? JSONSerialization.jsonObject(with: Data(String(cString: raw).utf8))) as? JSON else { return }
        if event["@type"] as? String == "error" {
            FileHandle.standardError.write("  TDLib error: \(event["code"] ?? "") \(event["message"] ?? "")\n".data(using: .utf8)!)
        }
        guard event["@type"] as? String == "updateAuthorizationState",
              let authState = event["authorization_state"] as? JSON else { return }
        state = authState["@type"] as? String ?? ""
        print("  TDLib: \(state)")
    }

    func send(_ request: JSON) { td_send(id, encode(request)) }

    /// Gives TDLib its parameters and waits until it asks for a phone number —
    /// by then the binlog and the database exist. Never sends a number.
    func open(apiId: Int, apiHash: String) throws {
        send(["@type": "getOption", "name": "version"])
        try waitUntil(timeout: 60, "TDLib to ask for parameters") { state == "authorizationStateWaitTdlibParameters" }
        send([
            "@type": "setTdlibParameters",
            "use_test_dc": true,
            "database_directory": directory,
            "files_directory": directory + "/files",
            "database_encryption_key": "",
            "use_file_database": true,
            "use_chat_info_database": true,
            "use_message_database": true,
            "use_secret_chats": false,
            "api_id": apiId,
            "api_hash": apiHash,
            "system_language_code": "en",
            "device_model": "che-msg reader fixture",
            "system_version": "",
            "application_version": "1.0",
        ])
        try waitUntil(timeout: 120, "TDLib to open its database") { state == "authorizationStateWaitPhoneNumber" }

        // Every connection must go to a built-in test DC address
        // (ConnectionCreator::get_default_dc_options, TDLib 1.8.60).
        let testDCs: Set<String> = ["149.154.175.10", "149.154.167.40", "149.154.175.117"]
        var remotes = try remoteAddresses()
        for _ in 0..<15 where remotes.isEmpty {
            idle(1.0)
            remotes = try remoteAddresses()
        }
        print("  connected to \(remotes.sorted())")
        guard remotes.isSubset(of: testDCs) else { throw GeneratorError("connected outside the test environment") }
    }

    func close() throws {
        send(["@type": "close"])
        try waitUntil(timeout: 60, "TDLib to close") { state == "authorizationStateClosed" }
    }
}

// MARK: - Secret scan (decrypts the copied binlog and database, reusing TDLib's formats)

func crc32(_ data: ArraySlice<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for b in data {
        crc ^= UInt32(b)
        for _ in 0..<8 { crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1) }
    }
    return crc ^ 0xFFFF_FFFF
}

func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}

func tlString(_ b: [UInt8], _ pos: inout Int) -> [UInt8]? {
    guard pos < b.count else { return nil }
    var len = Int(b[pos])
    var header = 1
    if len == 254 {
        guard pos + 4 <= b.count else { return nil }
        len = Int(b[pos + 1]) | Int(b[pos + 2]) << 8 | Int(b[pos + 3]) << 16
        header = 4
    }
    guard pos + header + len <= b.count else { return nil }
    let s = Array(b[(pos + header)..<(pos + header + len)])
    pos += (header + len + 3) / 4 * 4
    return s
}

/// Returns the fully decrypted binlog stream and the sqlite_key it contains.
func decryptBinlog(_ path: String) throws -> (stream: [UInt8], sqliteKey: [UInt8]?) {
    var plain = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    var cursor = 0
    var sqliteKey: [UInt8]? = nil
    while cursor + 4 <= plain.count {
        let size = Int(u32(plain, cursor))
        guard size >= 32, size % 4 == 0, cursor + size <= plain.count,
              crc32(plain[cursor..<(cursor + size - 4)]) == u32(plain, cursor + size - 4) else { break }
        let type = Int32(bitPattern: u32(plain, cursor + 12))
        let data = Array(plain[(cursor + 28)..<(cursor + size - 4)])
        cursor += size
        if type == -3 {
            var p = 4
            guard let salt = tlString(data, &p), let iv = tlString(data, &p) else { throw GeneratorError("bad encryption event") }
            var key = [UInt8](repeating: 0, count: 32)
            let password = Array("cucumber".utf8)
            _ = password.withUnsafeBufferPointer { pw in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: Int8.self), pw.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 2, &key, 32)
            }
            var ref: CCCryptorRef?
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                    iv, key, 32, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &ref)
            let rest = Array(plain[cursor...])
            var out = [UInt8](repeating: 0, count: rest.count)
            var moved = 0
            CCCryptorUpdate(ref, rest, rest.count, &out, out.count, &moved)
            CCCryptorRelease(ref)
            plain = Array(plain[0..<cursor]) + out
        } else if type == 0x4327 {
            var p = 0
            if let k = tlString(data, &p), let v = tlString(data, &p), String(decoding: k, as: UTF8.self) == "sqlite_key" { sqliteKey = v }
        }
    }
    return (plain, sqliteKey)
}

@_silgen_name("tdsqlite3_open_v2") func sqlOpen(_ p: UnsafePointer<CChar>, _ db: UnsafeMutablePointer<OpaquePointer?>, _ f: Int32, _ v: UnsafePointer<CChar>?) -> Int32
@_silgen_name("tdsqlite3_exec") func sqlExec(_ db: OpaquePointer?, _ s: UnsafePointer<CChar>, _ cb: OpaquePointer?, _ a: OpaquePointer?, _ e: OpaquePointer?) -> Int32
@_silgen_name("tdsqlite3_prepare_v2") func sqlPrepare(_ db: OpaquePointer?, _ s: UnsafePointer<CChar>, _ n: Int32, _ st: UnsafeMutablePointer<OpaquePointer?>, _ t: OpaquePointer?) -> Int32
@_silgen_name("tdsqlite3_step") func sqlStep(_ st: OpaquePointer?) -> Int32
@_silgen_name("tdsqlite3_column_count") func sqlColumnCount(_ st: OpaquePointer?) -> Int32
@_silgen_name("tdsqlite3_column_blob") func sqlColumnBlob(_ st: OpaquePointer?, _ i: Int32) -> UnsafeRawPointer?
@_silgen_name("tdsqlite3_column_bytes") func sqlColumnBytes(_ st: OpaquePointer?, _ i: Int32) -> Int32
@_silgen_name("tdsqlite3_column_text") func sqlColumnText(_ st: OpaquePointer?, _ i: Int32) -> UnsafePointer<UInt8>?
@_silgen_name("tdsqlite3_finalize") func sqlFinalize(_ st: OpaquePointer?) -> Int32
@_silgen_name("tdsqlite3_close") func sqlClose(_ db: OpaquePointer?) -> Int32

func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    let first = needle[0]
    var i = 0
    while i <= haystack.count - needle.count {
        if haystack[i] == first && Array(haystack[i..<(i + needle.count)]) == needle { return true }
        i += 1
    }
    return false
}

/// Throws when the API id or hash, or a machine-identifying string, appears
/// anywhere in the decrypted binlog or database.
func assertNoCredentials(directory: String, apiId: Int, apiHash: String) throws {
    var needles: [(String, [UInt8])] = [("api_hash", Array(apiHash.utf8)), ("api_id", Array(String(apiId).utf8))]
    // Machine-identifying strings: none of them may end up in a committed fixture.
    for (name, value) in [("home directory", NSHomeDirectory()), ("work directory", directory),
                          ("host name", ProcessInfo.processInfo.hostName)] where value.count >= 6 {
        needles.append((name, Array(value.utf8)))
    }
    let (stream, key) = try decryptBinlog(directory + "/td.binlog")
    for (name, needle) in needles where contains(stream, needle) {
        throw GeneratorError("\(name) found in the decrypted binlog — fixture not written")
    }
    guard let sqliteKey = key else { throw GeneratorError("no sqlite_key in the generated binlog") }
    var db: OpaquePointer?
    guard sqlOpen(directory + "/db.sqlite", &db, 1, nil) == 0 else { throw GeneratorError("cannot open generated db.sqlite") }
    defer { _ = sqlClose(db) }
    let hex = sqliteKey.map { String(format: "%02x", $0) }.joined()
    _ = sqlExec(db, "PRAGMA key = \"x'\(hex)'\"", nil, nil, nil)
    var tables: [String] = []
    var st: OpaquePointer?
    guard sqlPrepare(db, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &st, nil) == 0 else { throw GeneratorError("cannot read the generated database") }
    while sqlStep(st) == 100 { if let t = sqlColumnText(st, 0) { tables.append(String(cString: t)) } }
    _ = sqlFinalize(st)
    for table in tables {
        guard sqlPrepare(db, "SELECT * FROM \"\(table)\"", -1, &st, nil) == 0 else { continue }
        while sqlStep(st) == 100 {
            for c in 0..<sqlColumnCount(st) {
                let n = Int(sqlColumnBytes(st, c))
                guard n > 0, let p = sqlColumnBlob(st, c) else { continue }
                let bytes = Array(UnsafeRawBufferPointer(start: p, count: n))
                for (name, needle) in needles where contains(bytes, needle) {
                    _ = sqlFinalize(st)
                    throw GeneratorError("\(name) found in table \(table) — fixture not written")
                }
            }
        }
        _ = sqlFinalize(st)
    }
}

/// Table names and PRAGMA user_version of a database, opened with its binlog key.
func describeDatabase(directory: String) throws -> JSON {
    let (_, key) = try decryptBinlog(directory + "/td.binlog")
    guard let sqliteKey = key else { throw GeneratorError("no sqlite_key in the generated binlog") }
    var db: OpaquePointer?
    guard sqlOpen(directory + "/db.sqlite", &db, 1, nil) == 0 else { throw GeneratorError("cannot open generated db.sqlite") }
    defer { _ = sqlClose(db) }
    let hex = sqliteKey.map { String(format: "%02x", $0) }.joined()
    _ = sqlExec(db, "PRAGMA key = \"x'\(hex)'\"", nil, nil, nil)
    func strings(_ sql: String) -> [String] {
        var st: OpaquePointer?
        var out: [String] = []
        guard sqlPrepare(db, sql, -1, &st, nil) == 0 else { return out }
        while sqlStep(st) == 100 { if let t = sqlColumnText(st, 0) { out.append(String(cString: t)) } }
        _ = sqlFinalize(st)
        return out
    }
    let tables = strings("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    let version = Int(strings("PRAGMA user_version").first ?? "") ?? -1
    guard !tables.isEmpty else { throw GeneratorError("generated database has no tables") }
    return ["tdlib_version": "1.8.60", "sqlite_user_version": version, "tables": tables, "logged_in": false]
}

// MARK: - Main

func run() throws {
    let env = ProcessInfo.processInfo.environment
    guard let apiId = env["TELEGRAM_API_ID"].flatMap(Int.init), let apiHash = env["TELEGRAM_API_HASH"], !apiHash.isEmpty else {
        throw GeneratorError("TELEGRAM_API_ID / TELEGRAM_API_HASH not set")
    }
    let args = CommandLine.arguments
    guard args.count == 3 else { throw GeneratorError("usage: gen <work-dir> <fixture-dir>") }
    let work = args[1], fixture = args[2]
    let fm = FileManager.default
    try fm.createDirectory(atPath: work, withIntermediateDirectories: true)

    let client = UnauthorizedClient(directory: work)
    try client.open(apiId: apiId, apiHash: apiHash)
    try client.close()
    // With use_test_dc TDLib names its files td_test.binlog / db_test.sqlite
    // (TdDb::get_binlog_path / get_sqlite_path). The reader reads the production
    // names, so the fixture uses those.
    for leftover in ["db_test.sqlite-wal", "db_test.sqlite-shm"] where fm.fileExists(atPath: work + "/" + leftover) {
        throw GeneratorError("\(leftover) still present after close — database was not checkpointed")
    }
    try fm.moveItem(atPath: work + "/td_test.binlog", toPath: work + "/td.binlog")
    try fm.moveItem(atPath: work + "/db_test.sqlite", toPath: work + "/db.sqlite")
    try assertNoCredentials(directory: work, apiId: apiId, apiHash: apiHash)
    print("credential scan: API id, API hash, home and work directory paths and host name absent from binlog and database")
    let expected = try describeDatabase(directory: work)

    try fm.createDirectory(atPath: fixture, withIntermediateDirectories: true)
    for name in ["td.binlog", "db.sqlite"] {
        let dst = fixture + "/" + name
        if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
        try fm.copyItem(atPath: work + "/" + name, toPath: dst)
    }
    let binlog = [UInt8](try Data(contentsOf: URL(fileURLWithPath: work + "/td.binlog")))
    // Truncated variant: the last event loses its final 7 bytes.
    try Data(binlog[0..<(binlog.count - 7)]).write(to: URL(fileURLWithPath: fixture + "/td.binlog.truncated"))
    // No-key variant: only the first (encryption) event survives.
    try Data(binlog[0..<Int(u32(binlog, 0))]).write(to: URL(fileURLWithPath: fixture + "/td.binlog.no-sqlite-key"))
    let json = try JSONSerialization.data(withJSONObject: expected, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: fixture + "/expected.json"))
    print("fixture written: \((expected["tables"] as? [String])?.count ?? 0) tables, user_version \(expected["sqlite_user_version"] ?? "?")")
}

do {
    try run()
} catch {
    FileHandle.standardError.write("generate: \(error)\n".data(using: .utf8)!)
    exit(1)
}
