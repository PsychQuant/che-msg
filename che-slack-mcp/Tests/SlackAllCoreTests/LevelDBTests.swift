import Foundation
import Testing
@testable import SlackAllCore

/// LevelDB tables and logs written by `LevelDBFixture` (an independent
/// writer), read back by the reader under test.
@Suite("LevelDB")
struct LevelDBTests {
    typealias F = LevelDBFixture
    static let wanted = Array("_https://app.slack.com\u{0}\u{1}localConfig_v2".utf8)
    static let other = Array("_https://app.slack.com\u{0}\u{1}otherKey".utf8)
    static func isWanted(_ key: [UInt8]) -> Bool { key == wanted }
    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: CRC-32C

    @Test("CRC-32C of 123456789 is the published check value E3069283, in the fixture and in the reader")
    func crcCheckValue() {
        #expect(F.crc32c(Self.bytes("123456789")) == 0xE306_9283)
        #expect(CRC32C.checksum(Self.bytes("123456789")) == 0xE306_9283)
    }

    @Test("unmask undoes LevelDB's mask")
    func unmask() {
        for value: UInt32 in [0, 1, 0xE306_9283, 0xFFFF_FFFF] {
            #expect(CRC32C.unmask(F.masked(value)) == value)
        }
    }

    // MARK: Tables

    static func sampleTable(compressed: Bool) -> [UInt8] {
        F.table([
            (F.internalKey(other, sequence: 3), bytes("unrelated")),
            (F.internalKey(wanted, sequence: 9), bytes("newer")),
            (F.internalKey(wanted, sequence: 5), bytes("older")),
            (F.internalKey(Array("_https://app.slack.com\u{0}\u{1}zz".utf8), sequence: 4), bytes("last")),
        ], perBlock: 2, compressed: compressed)
    }

    @Test("a table yields every version of the matching key, from every data block", arguments: [false, true])
    func tableRecords(compressed: Bool) throws {
        let records = try LevelDBTable.records(in: Self.sampleTable(compressed: compressed), matching: Self.isWanted)
        #expect(records == [LevelDBRecord(sequence: 9, value: Self.bytes("newer")),
                            LevelDBRecord(sequence: 5, value: Self.bytes("older"))])
    }

    @Test("a deletion in a table is a record without a value")
    func tableDeletion() throws {
        let table = F.table([(F.internalKey(Self.wanted, sequence: 7, deletion: true), [])])
        #expect(try LevelDBTable.records(in: table, matching: Self.isWanted) == [LevelDBRecord(sequence: 7, value: nil)])
    }

    /// Each case breaks the sample table in one way.
    static let brokenTables: [(String, ([UInt8]) -> [UInt8])] = [
        ("shorter than a footer", { Array($0.suffix(47)) }),
        ("wrong magic", { var t = $0; t[t.count - 1] ^= 0xFF; return t }),
        ("block checksum mismatch", { var t = $0; t[3] ^= 0x01; return t }),
        ("index handle past the end", { t in
            var footer = F.varint(0) + F.varint(1) + F.varint(UInt64(t.count)) + F.varint(10)
            footer += [UInt8](repeating: 0, count: 40 - footer.count)
            return Array(t.dropLast(48)) + footer + Array(t.suffix(8))
        }),
        ("unknown compression type", { t in
            // The first block: stored bytes, then type, then CRC. Recompute the
            // CRC so only the type is wrong.
            var r = Array(t)
            let stored = Array(sampleStoredFirstBlock)
            r[stored.count] = 2
            let crc = F.le32(F.masked(F.crc32c(stored + [2])))
            r.replaceSubrange(stored.count + 1..<stored.count + 5, with: crc)
            return r
        }),
    ]

    /// The first data block of the compressed sample table as stored.
    static var sampleStoredFirstBlock: [UInt8] {
        F.snappyLiterals(F.block([(F.internalKey(other, sequence: 3), bytes("unrelated")),
                                  (F.internalKey(wanted, sequence: 9), bytes("newer"))]))
    }

    @Test("a broken table throws a format error", arguments: brokenTables.indices)
    func brokenTable(index: Int) {
        let broken = Self.brokenTables[index].1(Self.sampleTable(compressed: true))
        #expect(throws: DesktopFormatError.self) { try LevelDBTable.records(in: broken, matching: Self.isWanted) }
    }

    @Test("a block whose restart count does not fit throws")
    func restartCountTooLarge() {
        var block = F.block([(F.internalKey(Self.wanted, sequence: 1), [1])])
        block.replaceSubrange(block.count - 4..<block.count, with: F.le32(1000))
        let stored = block
        var file = stored + [0] + F.le32(F.masked(F.crc32c(stored + [0])))
        let metaStart = file.count
        let meta = F.block([])
        file += meta + [0] + F.le32(F.masked(F.crc32c(meta + [0])))
        let indexStart = file.count
        let index = F.block([(F.internalKey(Self.wanted, sequence: 1), F.varint(0) + F.varint(UInt64(stored.count)))], restartInterval: 1)
        file += index + [0] + F.le32(F.masked(F.crc32c(index + [0])))
        var footer = F.varint(UInt64(metaStart)) + F.varint(UInt64(meta.count)) + F.varint(UInt64(indexStart)) + F.varint(UInt64(index.count))
        footer += [UInt8](repeating: 0, count: 40 - footer.count)
        file += footer + F.le64(0xDB47_7524_8B80_FB57)

        #expect(throws: DesktopFormatError.self) { try LevelDBTable.records(in: file, matching: Self.isWanted) }
    }

    @Test("every single-byte change to a table either reads or throws, never traps", arguments: [false, true])
    func mutatedTable(compressed: Bool) {
        let table = Self.sampleTable(compressed: compressed)
        for position in table.indices {
            for value: UInt8 in [0x00, 0x01, 0x7F, 0x80, 0xFF] {
                var copy = table
                copy[position] = value
                _ = try? LevelDBTable.records(in: copy, matching: Self.isWanted)
            }
        }
    }

    // MARK: Logs

    @Test("a log yields each put and deletion of the key, numbered from the batch's sequence")
    func logRecords() {
        let log = F.log([
            F.writeBatch(sequence: 20, [.put(key: Self.other, value: [1]), .put(key: Self.wanted, value: Self.bytes("first"))]),
            F.writeBatch(sequence: 30, [.delete(key: Self.wanted), .put(key: Self.wanted, value: Self.bytes("second"))]),
        ])
        #expect(LevelDBLog.records(in: log, matching: Self.isWanted) == [
            LevelDBRecord(sequence: 21, value: Self.bytes("first")),
            LevelDBRecord(sequence: 30, value: nil),
            LevelDBRecord(sequence: 31, value: Self.bytes("second")),
        ])
    }

    @Test("a record split across 32 KiB blocks (first, middle, last fragments) is reassembled")
    func logFragments() {
        let big = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 % 251) }
        let log = F.log([
            F.writeBatch(sequence: 1, [.put(key: Self.other, value: [UInt8](repeating: 7, count: 32_740))]),
            F.writeBatch(sequence: 2, [.put(key: Self.wanted, value: big)]),
        ])
        #expect(log.count > 3 * F.logBlockSize)
        #expect(LevelDBLog.records(in: log, matching: Self.isWanted) == [LevelDBRecord(sequence: 2, value: big)])
    }

    /// A first record that leaves fewer than 7 bytes in the block, so the
    /// next header starts in the next block.
    @Test("a block trailer too short for a header is skipped")
    func logTrailer() {
        // Header 7 + batch (sequence and count 12, tag 1, key length 1, key,
        // value length 3, value) fills the block to 32765, leaving 3 bytes.
        let valueCount = F.logBlockSize - 3 - 7 - 12 - 1 - 1 - Self.other.count - 3
        let log = F.log([
            F.writeBatch(sequence: 1, [.put(key: Self.other, value: [UInt8](repeating: 1, count: valueCount))]),
            F.writeBatch(sequence: 2, [.put(key: Self.wanted, value: Self.bytes("after"))]),
        ])
        #expect(log.count > F.logBlockSize)
        #expect(LevelDBLog.records(in: log, matching: Self.isWanted) == [LevelDBRecord(sequence: 2, value: Self.bytes("after"))])
    }

    @Test("a log cut short or damaged keeps the records before the damage")
    func logTornTail() {
        let first = F.writeBatch(sequence: 5, [.put(key: Self.wanted, value: Self.bytes("kept"))])
        let second = F.writeBatch(sequence: 6, [.put(key: Self.wanted, value: Self.bytes("lost"))])
        let log = F.log([first, second])
        let kept = [LevelDBRecord(sequence: 5, value: Self.bytes("kept"))]

        #expect(LevelDBLog.records(in: Array(log.dropLast(3)), matching: Self.isWanted) == kept)
        var badCRC = log
        badCRC[7 + first.count] ^= 0xFF
        #expect(LevelDBLog.records(in: badCRC, matching: Self.isWanted) == kept)
        var badPayload = log
        badPayload[log.count - 1] ^= 0xFF
        #expect(LevelDBLog.records(in: badPayload, matching: Self.isWanted) == kept)
    }

    @Test("a batch whose count does not match its entries is ignored")
    func logBadBatch() {
        var batch = F.writeBatch(sequence: 5, [.put(key: Self.wanted, value: Self.bytes("x"))])
        batch.replaceSubrange(8..<12, with: F.le32(2))
        #expect(LevelDBLog.records(in: F.log([batch]), matching: Self.isWanted).isEmpty)
    }

    @Test("every single-byte change to a log reads what it can, never traps")
    func mutatedLog() {
        let log = F.log([
            F.writeBatch(sequence: 5, [.put(key: Self.wanted, value: Self.bytes("kept"))]),
            F.writeBatch(sequence: 6, [.delete(key: Self.other)]),
        ])
        for position in log.indices {
            for value: UInt8 in [0x00, 0x01, 0x02, 0x03, 0x04, 0x7F, 0x80, 0xFF] {
                var copy = log
                copy[position] = value
                _ = LevelDBLog.records(in: copy, matching: Self.isWanted)
            }
        }
    }

    // MARK: A folder

    func folder(_ files: [String: [UInt8]]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leveldb-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        for (name, contents) in files { try Data(contents).write(to: url.appendingPathComponent(name)) }
        return url
    }

    @Test("the newest version across tables and logs wins")
    func newestAcrossFiles() throws {
        let table = F.table([(F.internalKey(Self.wanted, sequence: 9), Self.bytes("table"))])
        let olderTable = F.table([(F.internalKey(Self.wanted, sequence: 2), Self.bytes("old"))])
        let newerLog = F.log([F.writeBatch(sequence: 12, [.put(key: Self.wanted, value: Self.bytes("log"))])])
        let olderLog = F.log([F.writeBatch(sequence: 4, [.put(key: Self.wanted, value: Self.bytes("old log"))])])

        let logWins = try folder(["000005.ldb": table, "000001.sst": olderTable, "000007.log": newerLog,
                                  "LOG": Self.bytes("info"), "CURRENT": Self.bytes("MANIFEST-000001\n")])
        defer { try? FileManager.default.removeItem(at: logWins) }
        #expect(try LevelDBFolder.newest(in: logWins, matching: Self.isWanted) == LevelDBRecord(sequence: 12, value: Self.bytes("log")))

        let tableWins = try folder(["000005.ldb": table, "000003.log": olderLog])
        defer { try? FileManager.default.removeItem(at: tableWins) }
        #expect(try LevelDBFolder.newest(in: tableWins, matching: Self.isWanted) == LevelDBRecord(sequence: 9, value: Self.bytes("table")))
    }

    @Test("when the newest version is a deletion, the result is that deletion")
    func newestIsDeletion() throws {
        let table = F.table([(F.internalKey(Self.wanted, sequence: 9), Self.bytes("table"))])
        let log = F.log([F.writeBatch(sequence: 12, [.delete(key: Self.wanted)])])
        let url = try folder(["000005.ldb": table, "000007.log": log])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try LevelDBFolder.newest(in: url, matching: Self.isWanted) == LevelDBRecord(sequence: 12, value: nil))
    }

    @Test("a folder without the key gives nil")
    func newestMissing() throws {
        let url = try folder(["000005.ldb": F.table([(F.internalKey(Self.other, sequence: 9), [1])])])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try LevelDBFolder.newest(in: url, matching: Self.isWanted) == nil)
    }

    @Test("a damaged table stops the read with an error naming the file")
    func damagedTableNamesFile() throws {
        var table = F.table([(F.internalKey(Self.wanted, sequence: 9), Self.bytes("table"))])
        table[2] ^= 0x01
        let url = try folder(["000005.ldb": table])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect {
            try LevelDBFolder.newest(in: url, matching: Self.isWanted)
        } throws: { error in
            (error as? DesktopFormatError)?.reason.contains("000005.ldb") == true
        }
    }
}
