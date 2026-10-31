import Foundation

/// One version of a key: its sequence number, and its value or nil for a
/// deletion. The description never shows the value (it may hold tokens).
struct LevelDBRecord: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let sequence: UInt64
    let value: [UInt8]?

    var description: String {
        "LevelDBRecord(sequence: \(sequence), \(value.map { "value: \($0.count) bytes" } ?? "deletion"))"
    }
    var debugDescription: String { description }
}

/// CRC-32C (Castagnoli), which LevelDB stores masked.
enum CRC32C {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1 }
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        ~bytes.reduce(UInt32.max) { crc, byte in table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
    }

    /// The CRC that LevelDB masked as `((crc >> 15) | (crc << 17)) + 0xa282ead8`.
    static func unmask(_ masked: UInt32) -> UInt32 {
        let rotated = masked &- 0xA282_EAD8
        return (rotated >> 17) | (rotated << 15)
    }
}

/// A LevelDB table file (`.ldb`, formerly `.sst`): data blocks found through
/// the index block named by the 48-byte footer. Every block is followed by a
/// compression byte (0 none, 1 Snappy) and the masked CRC-32C of the block
/// and that byte, which is checked.
enum LevelDBTable {
    static let magic: UInt64 = 0xDB47_7524_8B80_FB57
    static let footerSize = 48

    /// Every version, in file order, of each key for which `matching(userKey)`
    /// is true. Throws `DesktopFormatError` when the file is not a table this
    /// reader understands, or a block's checksum does not match.
    static func records(in file: [UInt8], matching: ([UInt8]) -> Bool) throws -> [LevelDBRecord] {
        guard file.count >= footerSize else { throw DesktopFormatError("is too short to be a LevelDB table") }
        var footer = ByteReader(file, position: file.count - footerSize)
        _ = try handle(&footer)   // metaindex: filters, not needed
        let index = try handle(&footer)
        var magicBytes = ByteReader(file, position: file.count - 8)
        guard try magicBytes.littleEndian(8) == magic else { throw DesktopFormatError("is not a LevelDB table (wrong magic)") }

        var found: [LevelDBRecord] = []
        for (_, value) in try entries(of: block(file, index)) {
            var reader = ByteReader(value)
            for (key, value) in try entries(of: block(file, try handle(&reader))) {
                guard key.count >= 8 else { throw DesktopFormatError("holds a LevelDB key without its sequence") }
                let userKey = Array(key.dropLast(8))
                guard matching(userKey) else { continue }
                var trailer = ByteReader(key, position: key.count - 8)
                let tag = try trailer.littleEndian(8)
                switch tag & 0xFF {
                case 1: found.append(LevelDBRecord(sequence: tag >> 8, value: value))
                case 0: found.append(LevelDBRecord(sequence: tag >> 8, value: nil))
                default: throw DesktopFormatError("holds a LevelDB key of an unknown type")
                }
            }
        }
        return found
    }

    /// A block handle: offset and size, as varints.
    private static func handle(_ reader: inout ByteReader) throws -> (offset: Int, size: Int) {
        (try reader.length(limit: Int.max), try reader.length(limit: Int.max))
    }

    /// The block at `handle`, checked and decompressed.
    private static func block(_ file: [UInt8], _ handle: (offset: Int, size: Int)) throws -> [UInt8] {
        let (offset, size) = handle
        guard offset <= file.count, size <= file.count - offset, file.count - offset - size >= 5 else {
            throw DesktopFormatError("names a LevelDB block outside the file")
        }
        let stored = file[offset..<offset + size]
        let type = file[offset + size]
        var crc = ByteReader(file, position: offset + size + 1)
        guard CRC32C.unmask(UInt32(try crc.littleEndian(4))) == CRC32C.checksum(stored + [type]) else {
            throw DesktopFormatError("holds a LevelDB block whose checksum does not match")
        }
        switch type {
        case 0: return Array(stored)
        case 1: return try Snappy.decompress(Array(stored))
        default: throw DesktopFormatError("holds a LevelDB block with an unknown compression")
        }
    }

    /// A block's key-value entries, prefix compression undone.
    private static func entries(of block: [UInt8]) throws -> [([UInt8], [UInt8])] {
        guard block.count >= 4 else { throw DesktopFormatError("holds a LevelDB block too short for its restarts") }
        var tail = ByteReader(block, position: block.count - 4)
        let restarts = try tail.littleEndian(4)
        guard restarts <= UInt64(block.count - 4) / 4 else {
            throw DesktopFormatError("holds a LevelDB block whose restart count does not fit")
        }
        let end = block.count - 4 - Int(restarts) * 4
        var reader = ByteReader(Array(block[..<end]))
        var key: [UInt8] = []
        var result: [([UInt8], [UInt8])] = []
        while !reader.atEnd {
            let shared = try reader.length()
            let unshared = try reader.length()
            let valueCount = try reader.length()
            guard shared <= key.count else { throw DesktopFormatError("holds a LevelDB entry that shares more than its key") }
            key = Array(key[..<shared]) + (try reader.bytes(unshared))
            result.append((key, try reader.bytes(valueCount)))
        }
        return result
    }
}

/// A LevelDB write-ahead log (`.log`): 32 KiB blocks of records (masked
/// CRC-32C, 2-byte length, type FULL 1 / FIRST 2 / MIDDLE 3 / LAST 4), each
/// whole record a write batch (8-byte sequence, 4-byte count, then puts and
/// deletions).
enum LevelDBLog {
    static let blockSize = 32768
    static let headerSize = 7

    /// Every put and deletion of a key for which `matching(userKey)` is
    /// true, in log order. Reading stops at the first record that is cut
    /// short, fails its checksum, or is out of order, keeping what came
    /// before: a log's tail can be half-written when Slack is running, and
    /// LevelDB itself drops such a tail.
    static func records(in file: [UInt8], matching: ([UInt8]) -> Bool) -> [LevelDBRecord] {
        var found: [LevelDBRecord] = []
        var position = 0
        var pending: [UInt8]?
        while position < file.count {
            let blockEnd = min((position / blockSize + 1) * blockSize, file.count)
            guard blockEnd - position >= headerSize else {
                position = blockEnd
                continue
            }
            let length = Int(file[position + 4]) | Int(file[position + 5]) << 8
            let type = file[position + 6]
            if type == 0 && length == 0 {   // preallocated, zero-filled space
                position = blockEnd
                continue
            }
            let start = position + headerSize
            guard length <= blockEnd - start else { break }
            let payload = file[start..<start + length]
            let stored = UInt32(file[position]) | UInt32(file[position + 1]) << 8
                | UInt32(file[position + 2]) << 16 | UInt32(file[position + 3]) << 24
            guard CRC32C.unmask(stored) == CRC32C.checksum([type] + payload) else { break }
            position = start + length

            let whole: [UInt8]
            switch (type, pending) {
            case (1, nil): whole = Array(payload)
            case (2, nil): pending = Array(payload); continue
            case (3, .some(let soFar)): pending = soFar + payload; continue
            case (4, .some(let soFar)): whole = soFar + payload; pending = nil
            default: return found
            }
            guard let batch = try? batchRecords(whole, matching: matching) else { break }
            found += batch
        }
        return found
    }

    /// The matching puts and deletions of one write batch. Throws when the
    /// batch is malformed or its count does not match its entries.
    private static func batchRecords(_ batch: [UInt8], matching: ([UInt8]) -> Bool) throws -> [LevelDBRecord] {
        var reader = ByteReader(batch)
        let sequence = try reader.littleEndian(8)
        let count = try reader.littleEndian(4)
        var found: [LevelDBRecord] = []
        var index: UInt64 = 0
        while !reader.atEnd {
            guard index < count else { throw DesktopFormatError("holds a write batch longer than its count") }
            let tag = try reader.byte()
            let key = try reader.bytes(reader.length())
            let value: [UInt8]?
            switch tag {
            case 1: value = try reader.bytes(reader.length())
            case 0: value = nil
            default: throw DesktopFormatError("holds a write batch entry of an unknown type")
            }
            if matching(key) { found.append(LevelDBRecord(sequence: sequence &+ index, value: value)) }
            index += 1
        }
        guard index == count else { throw DesktopFormatError("holds a write batch shorter than its count") }
        return found
    }
}

/// A LevelDB folder: its tables and logs together.
enum LevelDBFolder {
    /// The version with the highest sequence number, across every table
    /// (`.ldb`, `.sst`) and log (`.log`) in `directory`, of a key for which
    /// `matching(userKey)` is true; nil when no file holds one. Other files
    /// (`CURRENT`, `LOCK`, `LOG`, `MANIFEST-*`) are not read.
    ///
    /// - Throws: `DesktopFormatError` naming the file when a table cannot be
    ///   read or is damaged, or when the folder cannot be listed.
    static func newest(in directory: URL, matching: ([UInt8]) -> Bool) throws -> LevelDBRecord? {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            throw DesktopFormatError("cannot be listed")
        }
        var newest: LevelDBRecord?
        for name in names {
            let isTable = name.hasSuffix(".ldb") || name.hasSuffix(".sst")
            guard isTable || name.hasSuffix(".log") else { continue }
            let contents: [UInt8]
            do {
                contents = Array(try Data(contentsOf: directory.appendingPathComponent(name)))
            } catch {
                throw DesktopFormatError("\(name) cannot be read")
            }
            let records: [LevelDBRecord]
            if isTable {
                do {
                    records = try LevelDBTable.records(in: contents, matching: matching)
                } catch let error as DesktopFormatError {
                    throw DesktopFormatError("\(name) \(error.reason)")
                }
            } else {
                records = LevelDBLog.records(in: contents, matching: matching)
            }
            for record in records where record.sequence > (newest?.sequence ?? 0) || newest == nil {
                newest = record
            }
        }
        return newest
    }
}
