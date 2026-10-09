import Foundation

/// Decodes the chat and user records TDLib 1.8.60 keeps in the `common` table
/// under `us<id>`, `gr<id>`, `ch<id>` and `sc<id>`.
///
/// Each record is TDLib's log event serialization: an int32 version (the
/// `Version` enum value current when the record was written), then the fields
/// of the object's `store()`. Only the fields up to the name are read. A record
/// that ends early, carries a version newer than TDLib 1.8.60, or has a name
/// that is not UTF-8 throws `Undecodable`.
enum TDLibRecordDecoder {
    struct Undecodable: Error {}

    /// `Version::Next - 1` in TDLib 1.8.60.
    static let newestVersion: Int32 = 57
    static let support64BitIds: Int32 = 33
    static let makeParticipantFlags64Bit: Int32 = 46
    static let addUserFlags2: Int32 = 48

    /// The user's name as TDLib titles their private chat
    /// (`UserManager::get_user_title`).
    static func userTitle(_ record: [UInt8]) throws -> String {
        let name = try userName(record)
        if name.last.isEmpty { return name.first }
        if name.first.isEmpty { return name.last }
        return name.first + " " + name.last
    }

    /// `UserManager::User::store`: flags (`has_last_name` is bit 8), a second
    /// flag word from `AddUserFlags2`, `first_name`, `last_name`.
    static func userName(_ record: [UInt8]) throws -> (first: String, last: String) {
        var reader = TLReader(record)
        let version = try readVersion(&reader)
        let flags = try reader.uint32()
        if version >= addUserFlags2 { _ = try reader.uint32() }
        let first = try utf8(reader.string())
        let last = try isSet(flags, 8) ? utf8(reader.string()) : ""
        return (first, last)
    }

    /// `ChatManager::Chat::store`: flags, then `title`.
    static func basicGroupTitle(_ record: [UInt8]) throws -> String {
        var reader = TLReader(record)
        _ = try readVersion(&reader)
        _ = try reader.uint32()
        return try utf8(reader.string())
    }

    /// `ChatManager::Channel::store`: flags (`is_megagroup` bit 7,
    /// `use_new_rights` bit 12, `has_flags2` bit 29), the second flag word, the
    /// user's participant status when `use_new_rights`, `access_hash`, `title`.
    static func channel(_ record: [UInt8]) throws -> (title: String, isMegagroup: Bool) {
        var reader = TLReader(record)
        let version = try readVersion(&reader)
        let flags = try reader.uint32()
        if isSet(flags, 29) { _ = try reader.uint32() }
        if isSet(flags, 12) { try skipParticipantStatus(&reader, version: version) }
        _ = try reader.int64()
        return (try utf8(reader.string()), isSet(flags, 7))
    }

    /// `UserManager::SecretChat::store`: flags, `access_hash`, `user_id`
    /// (`UserId` is an int32 before `Support64BitIds`).
    static func secretChatUserId(_ record: [UInt8]) throws -> Int64 {
        var reader = TLReader(record)
        let version = try readVersion(&reader)
        _ = try reader.uint32()
        _ = try reader.int64()
        return try version >= support64BitIds ? reader.int64() : Int64(reader.int32())
    }

    /// `DialogParticipantStatus::store`: flags (64-bit from
    /// `MakeParticipantFlags64Bit`), `until_date` if `HAS_UNTIL_DATE` (bit 31),
    /// `rank` if `HAS_RANK` (bit 14).
    private static func skipParticipantStatus(_ reader: inout TLReader, version: Int32) throws {
        let flags = try version >= makeParticipantFlags64Bit
            ? UInt64(bitPattern: reader.int64())
            : UInt64(reader.uint32())
        if flags & (1 << 31) != 0 { _ = try reader.int32() }
        if flags & (1 << 14) != 0 { _ = try reader.string() }
    }

    private static func readVersion(_ reader: inout TLReader) throws -> Int32 {
        let version = try reader.int32()
        guard (1...newestVersion).contains(version) else { throw Undecodable() }
        return version
    }

    private static func utf8(_ bytes: [UInt8]) throws -> String {
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw Undecodable() }
        return text
    }

    private static func isSet(_ flags: UInt32, _ bit: UInt32) -> Bool { flags & (1 << bit) != 0 }
}
