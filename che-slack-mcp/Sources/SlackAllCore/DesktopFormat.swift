import Foundation

/// Data from the Slack desktop app that is not in the shape the desktop
/// import expects. The reason is a fixed phrase (and at most a file name);
/// it never quotes the data, which may hold a token or a cookie.
struct DesktopFormatError: Error, Equatable, Sendable, CustomStringConvertible {
    let reason: String

    init(_ reason: String) { self.reason = reason }

    var description: String { reason }
}

/// Bounds-checked reading of a byte array: every read that would run past
/// the end throws instead of trapping.
struct ByteReader {
    private let bytes: [UInt8]
    private(set) var position: Int

    init(_ bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    var atEnd: Bool { position >= bytes.count }
    var remaining: Int { max(0, bytes.count - position) }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw DesktopFormatError("ends in the middle of a value") }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= remaining else { throw DesktopFormatError("ends in the middle of a value") }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }

    /// An unsigned little-endian integer of `count` (at most 8) bytes.
    mutating func littleEndian(_ count: Int) throws -> UInt64 {
        precondition(count >= 0 && count <= 8)
        return try bytes(count).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    /// A base-128 varint of at most `maxBytes` bytes (5 for 32-bit, 10 for
    /// 64-bit values).
    mutating func varint(maxBytes: Int = 10) throws -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<maxBytes {
            let next = try byte()
            let shift = UInt64(7 * index)
            let bits = UInt64(next & 0x7f)
            guard shift < 64, (bits << shift) >> shift == bits else { throw DesktopFormatError("holds an oversized varint") }
            result |= bits << shift
            if next < 0x80 { return result }
        }
        throw DesktopFormatError("holds an oversized varint")
    }

    /// A varint that must fit in `Int` and be at most `limit`.
    mutating func length(limit: Int = Int(Int32.max)) throws -> Int {
        let value = try varint()
        guard value <= UInt64(limit) else { throw DesktopFormatError("holds a length out of range") }
        return Int(value)
    }
}

/// Snappy decompression (the raw block format LevelDB uses, no framing).
enum Snappy {
    /// The most a block may claim to decompress to.
    static let maxLength = 64 << 20

    /// The decompressed bytes. Throws `DesktopFormatError` when the stream
    /// is cut short, a copy reaches before the start of the output, or the
    /// output would differ in length from what the stream declares.
    static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        var reader = ByteReader(input)
        let declared = try reader.varint(maxBytes: 5)
        guard declared <= UInt64(maxLength) else { throw DesktopFormatError("is a Snappy block that claims an oversized length") }
        let length = Int(declared)
        var output: [UInt8] = []
        output.reserveCapacity(min(length, input.count * 32))
        while !reader.atEnd {
            let tag = try reader.byte()
            let (count, offset): (Int, Int)
            switch tag & 3 {
            case 0:
                var literal = UInt64(tag >> 2)
                if literal >= 60 { literal = try reader.littleEndian(Int(literal) - 59) }
                guard literal < UInt64(length) else { throw Self.tooLong }
                let bytes = try reader.bytes(Int(literal) + 1)
                guard bytes.count <= length - output.count else { throw Self.tooLong }
                output.append(contentsOf: bytes)
                continue
            case 1:
                count = Int((tag >> 2) & 7) + 4
                offset = Int(tag >> 5) << 8 | Int(try reader.byte())
            case 2:
                count = Int(tag >> 2) + 1
                offset = Int(try reader.littleEndian(2))
            default:
                count = Int(tag >> 2) + 1
                offset = Int(try reader.littleEndian(4))
            }
            guard offset > 0, offset <= output.count else {
                throw DesktopFormatError("is a Snappy block with a copy from outside its output")
            }
            guard count <= length - output.count else { throw Self.tooLong }
            let start = output.count - offset
            for index in 0..<count { output.append(output[start + index]) }
        }
        guard output.count == length else { throw DesktopFormatError("is a Snappy block shorter than it declares") }
        return output
    }

    private static let tooLong = DesktopFormatError("is a Snappy block longer than it declares")
}
