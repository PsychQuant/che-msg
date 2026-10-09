import CommonCrypto
import Foundation

/// Reads the SQLite key from TDLib's encrypted binlog (`td.binlog`).
///
/// Format (TDLib 1.8.60, `tddb/td/db/binlog/`):
/// - The file is a sequence of events: `size:uint32 id:uint64 type:int32
///   flags:int32 extra:uint64 data crc32:uint32`, all little-endian, where `size`
///   covers the whole event and the CRC32 covers everything before it.
/// - An event of type -3 (`AesCtrEncryption`) carries `flags:uint32`, the salt,
///   the IV and an HMAC of the key, each salt/IV/hash a TL string. Every byte
///   after that event is AES-256-CTR encrypted, with the key derived by
///   PBKDF2-SHA256 from TDLib's default database key `cucumber` (2 iterations,
///   because `cucumber` is a raw key) and the event's salt.
/// - Binlog PMC events (type `0x4327`) hold a TL-string key and a TL-string
///   value; the entry `sqlite_key` is the 32-byte SQLCipher raw key.
///
/// Only events whose size and CRC are valid are used; reading stops at the
/// first event that is incomplete or damaged, which is how TDLib itself treats
/// a binlog whose tail is still being written.
public enum TDLibBinlogReader {
    static let defaultDatabaseKey = Array("cucumber".utf8)
    static let keyHashMessage = Array("cucumbers everywhere".utf8)
    static let emptyEventType: Int32 = -2
    static let encryptionEventType: Int32 = -3
    static let binlogPMCEventType: Int32 = 0x4327
    static let rewriteFlag: Int32 = 1
    static let headerSize = 28
    static let minimumEventSize = 32
    static let maximumEventSize = 1 << 24

    /// Returns the 32-byte SQLite key stored in the binlog at `path`. The file is
    /// only read.
    public static func sqliteKey(fromBinlogAt path: String) throws -> Data {
        try sqliteKey(in: keyValues(fromBinlogAt: path))
    }

    static func sqliteKey(fromBinlog file: [UInt8]) throws -> Data {
        try sqliteKey(in: keyValues(fromBinlog: file))
    }

    static func sqliteKey(in values: [String: [UInt8]]) throws -> Data {
        guard let key = values["sqlite_key"], key.count == 32 else { throw LocalReaderError.keyNotFound }
        return Data(key)
    }

    /// The binlog key-value store (`BinlogKeyValue`) of the binlog at `path`.
    static func keyValues(fromBinlogAt path: String) throws -> [String: [UInt8]] {
        let bytes: [UInt8]
        do {
            bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw LocalReaderError.binlogUnreadable((error as NSError).localizedDescription)
        }
        return try keyValues(fromBinlog: bytes)
    }

    /// Replays the key-value events as TDLib does: each key lives in one event
    /// id, a `Rewrite` event replaces the event with its id, and an `Empty`
    /// rewrite erases it.
    static func keyValues(fromBinlog file: [UInt8]) throws -> [String: [UInt8]] {
        var stream = file
        var cursor = 0
        var entries: [UInt64: (key: [UInt8], value: [UInt8])] = [:]
        while let event = nextEvent(in: stream, at: cursor) {
            cursor += event.size
            switch event.type {
            case encryptionEventType:
                let cipherKey = try encryptionKey(from: event.data)
                let decrypted = try aesCTR(Array(stream[cursor...]), key: cipherKey.key, iv: cipherKey.iv)
                stream = Array(stream[0..<cursor]) + decrypted
            case binlogPMCEventType:
                var reader = TLReader(event.data)
                if let key = try? reader.string(), let value = try? reader.string() {
                    entries[event.id] = (key, value)
                }
            case emptyEventType where event.flags & rewriteFlag != 0:
                entries[event.id] = nil
            default:
                break
            }
        }
        var values: [String: [UInt8]] = [:]
        for id in entries.keys.sorted() {   // a later event wins a shared key
            let entry = entries[id]!
            values[String(decoding: entry.key, as: UTF8.self)] = entry.value
        }
        return values
    }

    /// Whether TDLib is logged in: `AuthManager` sets `auth` to `ok` on login
    /// and to `logout` or `destroy` when the session ends.
    static func isLoggedIn(_ values: [String: [UInt8]]) -> Bool {
        values["auth"] == Array("ok".utf8)
    }

    struct Event {
        let size: Int
        let id: UInt64
        let type: Int32
        let flags: Int32
        let data: [UInt8]
    }

    /// The complete, CRC-valid event starting at `offset`, or nil.
    static func nextEvent(in bytes: [UInt8], at offset: Int) -> Event? {
        guard offset >= 0, bytes.count - offset >= 4 else { return nil }
        let size = Int(littleEndianUInt32(bytes, offset))
        guard size >= minimumEventSize, size <= maximumEventSize, size % 4 == 0,
              size <= bytes.count - offset else { return nil }
        let crcOffset = offset + size - 4
        guard crc32(bytes[offset..<crcOffset]) == littleEndianUInt32(bytes, crcOffset) else { return nil }
        let id = UInt64(littleEndianUInt32(bytes, offset + 4)) | UInt64(littleEndianUInt32(bytes, offset + 8)) << 32
        let type = Int32(bitPattern: littleEndianUInt32(bytes, offset + 12))
        let flags = Int32(bitPattern: littleEndianUInt32(bytes, offset + 16))
        return Event(size: size, id: id, type: type, flags: flags, data: Array(bytes[(offset + headerSize)..<crcOffset]))
    }

    /// Derives the AES-CTR key from an encryption event and checks it against the
    /// event's key hash.
    static func encryptionKey(from data: [UInt8]) throws -> (key: [UInt8], iv: [UInt8]) {
        var reader = TLReader(data)
        guard (try? reader.uint32()) != nil,
              let salt = try? reader.string(), let iv = try? reader.string(), let hash = try? reader.string(),
              iv.count == 16 else {
            throw LocalReaderError.wrongBinlogKey
        }
        let key = try pbkdf2SHA256(password: defaultDatabaseKey, salt: salt, rounds: 2)
        guard hmacSHA256(key: key, message: keyHashMessage) == hash else { throw LocalReaderError.wrongBinlogKey }
        return (key, iv)
    }

    static func littleEndianUInt32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func pbkdf2SHA256(password: [UInt8], salt: [UInt8], rounds: UInt32) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBufferPointer { pw in
            pw.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pw.count) { pwPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwPtr, pw.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &out, out.count)
            }
        }
        guard status == kCCSuccess else { throw LocalReaderError.wrongBinlogKey }
        return out
    }

    static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, message, message.count, &out)
        return out
    }

    /// AES-256-CTR with a 128-bit big-endian counter starting at `iv`, as OpenSSL's
    /// EVP_aes_256_ctr that TDLib uses.
    static func aesCTR(_ input: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var cryptor: CCCryptorRef?
        guard CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                      CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
                                      CCModeOptions(kCCModeOptionCTR_BE), &cryptor) == kCCSuccess else {
            throw LocalReaderError.wrongBinlogKey
        }
        defer { CCCryptorRelease(cryptor) }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        guard CCCryptorUpdate(cryptor, input, input.count, &output, output.count, &moved) == kCCSuccess,
              moved == input.count else {
            throw LocalReaderError.wrongBinlogKey
        }
        return output
    }
}

/// Reads TDLib's TL serialization: little-endian integers and length-prefixed,
/// 4-byte-padded strings.
struct TLReader {
    struct OutOfData: Error {}

    private let bytes: [UInt8]
    private(set) var position = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - position }

    mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw OutOfData() }
        defer { position += 4 }
        return UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
            | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
    }

    mutating func int32() throws -> Int32 { Int32(bitPattern: try uint32()) }

    mutating func int64() throws -> Int64 {
        let low = UInt64(try uint32())
        let high = UInt64(try uint32())
        return Int64(bitPattern: low | high << 32)
    }

    mutating func double() throws -> Double { Double(bitPattern: UInt64(bitPattern: try int64())) }

    mutating func string() throws -> [UInt8] {
        guard remaining >= 1 else { throw OutOfData() }
        var length = Int(bytes[position])
        var header = 1
        if length == 254 {
            guard remaining >= 4 else { throw OutOfData() }
            length = Int(bytes[position + 1]) | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3]) << 16
            header = 4
        } else if length == 255 {
            throw OutOfData()
        }
        guard remaining >= header + length else { throw OutOfData() }
        let value = Array(bytes[(position + header)..<(position + header + length)])
        let padded = (header + length + 3) / 4 * 4
        position += min(padded, remaining)
        return value
    }
}
