import Foundation

/// Writes synthetic LevelDB files from the format description (leveldb's
/// doc/table_format.md and doc/log_format.md). It shares no code with the
/// reader under test: its CRC-32C is the bitwise form, checked against the
/// published check value, and its Snappy output is literals only.
enum LevelDBFixture {
    enum Op {
        case put(key: [UInt8], value: [UInt8])
        case delete(key: [UInt8])
    }

    // MARK: Primitives

    /// Bitwise CRC-32C (reflected polynomial 0x82F63B78).
    static func crc32c(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1 }
        }
        return ~crc
    }

    static func masked(_ crc: UInt32) -> UInt32 { ((crc >> 15) | (crc << 17)) &+ 0xA282_EAD8 }

    static func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
        return out
    }

    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }
    static func le64(_ value: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) } }

    /// `userKey` plus the 8-byte trailer `sequence << 8 | type`.
    static func internalKey(_ userKey: [UInt8], sequence: UInt64, deletion: Bool = false) -> [UInt8] {
        userKey + le64(sequence << 8 | (deletion ? 0 : 1))
    }

    /// A Snappy stream made of literals of at most 1000 bytes each.
    static func snappyLiterals(_ bytes: [UInt8]) -> [UInt8] {
        var out = varint(UInt64(bytes.count))
        var start = 0
        while start < bytes.count {
            let chunk = Array(bytes[start..<min(start + 1000, bytes.count)])
            let n = chunk.count - 1
            if n < 60 {
                out.append(UInt8(n << 2))
            } else if n < 256 {
                out += [0xF0, UInt8(n)]
            } else {
                out += [0xF4, UInt8(n & 0xFF), UInt8(n >> 8)]
            }
            out += chunk
            start += chunk.count
        }
        return out
    }

    // MARK: Tables

    /// A block holding `entries` with prefix compression and a restart
    /// point every `restartInterval` entries.
    static func block(_ entries: [([UInt8], [UInt8])], restartInterval: Int = 2) -> [UInt8] {
        var out: [UInt8] = []
        var restarts: [UInt32] = []
        var previous: [UInt8] = []
        for (index, (key, value)) in entries.enumerated() {
            var shared = 0
            if index % restartInterval == 0 {
                restarts.append(UInt32(out.count))
            } else {
                while shared < min(previous.count, key.count), previous[shared] == key[shared] { shared += 1 }
            }
            out += varint(UInt64(shared)) + varint(UInt64(key.count - shared)) + varint(UInt64(value.count))
            out += key[shared...] + value
            previous = key
        }
        if restarts.isEmpty { restarts = [0] }
        return out + restarts.flatMap(le32) + le32(UInt32(restarts.count))
    }

    /// A table whose data blocks hold `perBlock` entries each. Every block,
    /// the index included, is Snappy-compressed when `compressed`.
    static func table(_ entries: [([UInt8], [UInt8])], perBlock: Int = 2, compressed: Bool = true) -> [UInt8] {
        var file: [UInt8] = []
        func append(_ contents: [UInt8]) -> [UInt8] {
            let stored = compressed ? snappyLiterals(contents) : contents
            let type: UInt8 = compressed ? 1 : 0
            let handle = varint(UInt64(file.count)) + varint(UInt64(stored.count))
            file += stored + [type] + le32(masked(crc32c(stored + [type])))
            return handle
        }
        var indexEntries: [([UInt8], [UInt8])] = []
        var start = 0
        while start < entries.count {
            let chunk = Array(entries[start..<min(start + perBlock, entries.count)])
            indexEntries.append((chunk.last!.0, append(block(chunk))))
            start += chunk.count
        }
        let metaindex = append(block([]))
        let index = append(block(indexEntries, restartInterval: 1))
        var footer = metaindex + index
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        return file + footer + le64(0xDB47_7524_8B80_FB57)
    }

    // MARK: Logs

    static let logBlockSize = 32768

    static func writeBatch(sequence: UInt64, _ ops: [Op]) -> [UInt8] {
        var out = le64(sequence) + le32(UInt32(ops.count))
        for op in ops {
            switch op {
            case let .put(key, value):
                out += [1] + varint(UInt64(key.count)) + key + varint(UInt64(value.count)) + value
            case let .delete(key):
                out += [0] + varint(UInt64(key.count)) + key
            }
        }
        return out
    }

    /// A log holding `records`, fragmented across 32 KiB blocks, with a
    /// block's last 1 to 6 bytes zero-filled when no header fits there.
    static func log(_ records: [[UInt8]]) -> [UInt8] {
        var file: [UInt8] = []
        for record in records {
            var rest = record[...]
            var first = true
            repeat {
                let left = logBlockSize - file.count % logBlockSize
                if left < 7 {
                    file += [UInt8](repeating: 0, count: left)
                    continue
                }
                let fragment = rest.prefix(left - 7)
                rest = rest.dropFirst(fragment.count)
                let type: UInt8 = first ? (rest.isEmpty ? 1 : 2) : (rest.isEmpty ? 4 : 3)
                let payload = Array(fragment)
                file += le32(masked(crc32c([type] + payload)))
                file += [UInt8(payload.count & 0xFF), UInt8(payload.count >> 8), type] + payload
                first = false
            } while !rest.isEmpty
        }
        return file
    }
}
