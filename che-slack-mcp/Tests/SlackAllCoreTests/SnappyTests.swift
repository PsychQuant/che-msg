import Foundation
import Testing
@testable import SlackAllCore

/// The Snappy block format. Each well-formed stream below is written by hand
/// from the format description (tag low two bits: 0 literal, 1/2/3 copy with
/// a 1/2/4-byte offset), except `reference`, which python-snappy 0.7.3
/// (cramjam) produced; none comes from the decoder under test.
@Suite("Snappy")
struct SnappyTests {
    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    static let wellFormed: [(name: String, stream: [UInt8], decoded: [UInt8])] = [
        ("one literal", [0x05, 0x10] + bytes("hello"), bytes("hello")),
        ("copy with a 1-byte offset", [0x09, 0x08] + bytes("abc") + [0x09, 0x03], bytes("abcabcabc")),
        ("copy with a 2-byte offset", [0x09, 0x08] + bytes("abc") + [0x16, 0x03, 0x00], bytes("abcabcabc")),
        ("copy with a 4-byte offset", [0x09, 0x08] + bytes("abc") + [0x17, 0x03, 0x00, 0x00, 0x00], bytes("abcabcabc")),
        ("overlapping copy repeats the last byte", [0x07, 0x00] + bytes("a") + [0x09, 0x01], bytes("aaaaaaa")),
        ("literal length in 1 extra byte", [0x46, 0xF0, 0x45] + bytes(String(repeating: "0123456789", count: 7)),
         bytes(String(repeating: "0123456789", count: 7))),
        ("literal length in 2 extra bytes", [0xAC, 0x02, 0xF4, 0x2B, 0x01] + bytes(String(repeating: "abc", count: 100)),
         bytes(String(repeating: "abc", count: 100))),
        ("empty", [0x00], []),
    ]

    @Test("hand-written streams decode to their known text", arguments: wellFormed.indices)
    func handWritten(index: Int) throws {
        let (_, stream, decoded) = Self.wellFormed[index]
        #expect(try Snappy.decompress(stream) == decoded)
    }

    /// `snappy.compress(text)` from python-snappy 0.7.3; it uses literals and
    /// copies with 1- and 2-byte offsets, including overlapping runs.
    static let reference = hex("e401347b227465616d73223a7b2254303101070c6964223a050c582c22646f6d61696e223a22616c706861227d2c22"
        + "5430321d2400322e24002462657461227d7d7d2078fe01008a010038206c6f63616c436f6e6669675f7632760f00")
    static let referenceText = #"{"teams":{"T01":{"id":"T01","domain":"alpha"},"T02":{"id":"T02","domain":"beta"}}} "#
        + String(repeating: "x", count: 100) + " localConfig_v2 localConfig_v2 localConfig_v2"

    @Test("a stream python-snappy compressed decodes to the original text")
    func pythonSnappy() throws {
        #expect(try Snappy.decompress(Self.reference) == Self.bytes(Self.referenceText))
    }

    static let malformed: [(name: String, stream: [UInt8])] = [
        ("no length", []),
        ("unterminated length", [0x80, 0x80]),
        ("length above the limit", [0xFF, 0xFF, 0xFF, 0xFF, 0x0F]),
        ("shorter than its length", [0x05, 0x08] + bytes("abc")),
        ("literal past the end", [0x05, 0x10] + bytes("ab")),
        ("literal length past the end", [0x05, 0xF4, 0x01]),
        ("huge literal length", [0x05, 0xFC, 0xFF, 0xFF, 0xFF, 0xFF]),
        ("copy with offset 0", [0x05, 0x00] + bytes("a") + [0x01, 0x00]),
        ("copy before the start", [0x05, 0x00] + bytes("a") + [0x01, 0x05]),
        ("copy past its length", [0x02, 0x00] + bytes("a") + [0x01, 0x01]),
        ("literal past its length", [0x01, 0x04] + bytes("ab")),
        ("copy offset cut short", [0x05, 0x00] + bytes("a") + [0x16, 0x01]),
        ("4-byte copy offset cut short", [0x05, 0x00] + bytes("a") + [0x17, 0x01, 0x00]),
    ]

    @Test("a malformed stream throws instead of trapping", arguments: malformed.indices)
    func malformedThrows(index: Int) {
        #expect(throws: DesktopFormatError.self) { try Snappy.decompress(Self.malformed[index].stream) }
    }

    @Test("every single-byte change to the reference stream decodes or throws, never traps")
    func mutatedReference() {
        for position in Self.reference.indices {
            for value: UInt8 in [0x00, 0x01, 0x02, 0x03, 0x7F, 0x80, 0xFC, 0xFF] {
                var stream = Self.reference
                stream[position] = value
                _ = try? Snappy.decompress(stream)
            }
        }
    }

    @Test("random byte strings decode or throw, never trap")
    func randomInput() {
        var random = SplitMix64(seed: 0x5EED)
        for _ in 0..<5000 {
            let count = Int(random.next() % 48)
            let stream = (0..<count).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            _ = try? Snappy.decompress(stream)
        }
    }
}

/// A seeded generator, so a failure can be replayed.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Bytes from a hex string written in a test.
func hex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        bytes.append(UInt8(text[index..<next], radix: 16)!)
        index = next
    }
    return bytes
}
