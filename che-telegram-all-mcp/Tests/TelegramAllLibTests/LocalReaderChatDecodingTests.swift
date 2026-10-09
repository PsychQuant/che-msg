import XCTest
@testable import TelegramAllLib

/// Covers the chat half of task 3.3 (telegram-local-reader; PsychQuant/che-msg#58):
/// names and titles decoded from hand-built `us`/`gr`/`ch`/`sc` records laid
/// out in the field order of TDLib 1.8.60 (`User::store`, `Chat::store`,
/// `Channel::store`, `SecretChat::store`, `DialogParticipantStatus::store`),
/// and the chat type implied by a dialog id (`DialogId::get_type`).
final class LocalReaderChatDecodingTests: XCTestCase {

    // MARK: - Users (UserManager::User::store)

    /// `has_last_name` is flag bit 8; flags2 exists from Version::AddUserFlags2 (48).
    private func userRecord(version: Int32 = 57, first: String, last: String?) -> [UInt8] {
        var w = TLWriter()
        w.int32(version)
        w.uint32(flags(0, 4) | (last == nil ? 0 : flags(8)))   // is_received, can_join_groups
        if version >= 48 { w.uint32(flags(1)) }
        w.string(first)
        if let last { w.string(last) }
        w.int64(0x1122_3344_5566_7788)                        // access_hash
        w.int32(1_760_000_000)                                 // was_online
        return w.bytes
    }

    func testUserWithFirstAndLastName() throws {
        XCTAssertEqual(try TDLibRecordDecoder.userTitle(userRecord(first: "Ada", last: "Lovelace")), "Ada Lovelace")
    }

    func testUserWithoutLastName() throws {
        XCTAssertEqual(try TDLibRecordDecoder.userTitle(userRecord(first: "Ada", last: nil)), "Ada")
    }

    func testUserWithOnlyLastName() throws {
        XCTAssertEqual(try TDLibRecordDecoder.userTitle(userRecord(first: "", last: "Lovelace")), "Lovelace")
    }

    func testUserWithNonASCIIName() throws {
        XCTAssertEqual(try TDLibRecordDecoder.userTitle(userRecord(first: "王", last: "小明")), "王 小明")
    }

    func testUserRecordBeforeFlags2HasNoSecondFlagWord() throws {
        XCTAssertEqual(try TDLibRecordDecoder.userTitle(userRecord(version: 47, first: "Grace", last: "Hopper")), "Grace Hopper")
    }

    func testUserNameLongerThan253BytesUsesTheLongStringForm() throws {
        let long = String(repeating: "名", count: 100)   // 300 UTF-8 bytes
        XCTAssertEqual(try TDLibRecordDecoder.userTitle(userRecord(first: long, last: "X")), long + " X")
    }

    func testTruncatedUserRecordIsUndecodable() {
        let record = userRecord(first: "Ada", last: "Lovelace")
        XCTAssertThrowsError(try TDLibRecordDecoder.userTitle(Array(record.prefix(14))))
    }

    func testUserNameThatIsNotUTF8IsUndecodable() {
        var w = TLWriter()
        w.int32(57); w.uint32(0); w.uint32(0)
        w.string([0xFF, 0xFE, 0x41])
        XCTAssertThrowsError(try TDLibRecordDecoder.userTitle(w.bytes))
    }

    func testRecordNewerThanTDLib1860IsUndecodable() {
        XCTAssertThrowsError(try TDLibRecordDecoder.userTitle(userRecord(version: 58, first: "Ada", last: nil)))
    }

    // MARK: - Basic groups (ChatManager::Chat::store)

    private func basicGroupRecord(title: String) -> [UInt8] {
        var w = TLWriter()
        w.int32(57)
        w.uint32(flags(6, 8, 9))     // is_active, use_new_rights, has_default_permissions_version
        w.string(title)
        w.int32(12)                  // participant_count
        w.int32(1_700_000_000)       // date
        w.int64(0)                   // migrated_to_channel_id
        w.int32(3)                   // version
        w.uint64(4 << 28)            // status
        return w.bytes
    }

    func testBasicGroupTitle() throws {
        XCTAssertEqual(try TDLibRecordDecoder.basicGroupTitle(basicGroupRecord(title: "週會小組")), "週會小組")
    }

    func testTruncatedBasicGroupRecordIsUndecodable() {
        XCTAssertThrowsError(try TDLibRecordDecoder.basicGroupTitle(Array(basicGroupRecord(title: "週會小組").prefix(9))))
    }

    // MARK: - Channels and supergroups (ChatManager::Channel::store)

    private enum Status {
        case plain                          // no until_date, no rank
        case rank(String)                   // HAS_RANK (bit 14)
        case until(Int32)                   // HAS_UNTIL_DATE (bit 31)
        case untilAndRank(Int32, String)
    }

    /// flags1: is_megagroup bit 7, use_new_rights bit 12, has_participant_count
    /// bit 13, has_flags2 bit 29. The participant status is stored with 64-bit
    /// flags from Version::MakeParticipantFlags64Bit (46), 32-bit before.
    private func channelRecord(version: Int32 = 57, megagroup: Bool, newRights: Bool = true,
                               hasFlags2: Bool = true, status: Status = .plain, title: String) -> [UInt8] {
        var w = TLWriter()
        w.int32(version)
        var f1 = flags(13)
        if megagroup { f1 |= flags(7) }
        if newRights { f1 |= flags(12) }
        if hasFlags2 { f1 |= flags(29) }
        w.uint32(f1)
        if hasFlags2 { w.uint32(flags(0, 12)) }        // is_forum, show_message_sender
        if newRights {
            var statusFlags = UInt64(2) << 28 | flags64(0, 3)   // administrator type, some rights
            switch status {
            case .plain: break
            case .rank: statusFlags |= flags64(14)
            case .until: statusFlags |= flags64(31)
            case .untilAndRank: statusFlags |= flags64(14, 31)
            }
            if version >= 46 { w.uint64(statusFlags) } else { w.uint32(UInt32(truncatingIfNeeded: statusFlags)) }
            switch status {
            case .plain: break
            case .rank(let rank): w.string(rank)
            case .until(let date): w.int32(date)
            case .untilAndRank(let date, let rank): w.int32(date); w.string(rank)
            }
        }
        w.int64(-0x0102_0304_0506_0708)   // access_hash
        w.string(title)
        w.int32(1_700_000_000)            // date
        w.int32(250)                      // participant_count
        return w.bytes
    }

    func testSupergroupTitleAndKind() throws {
        let channel = try TDLibRecordDecoder.channel(channelRecord(megagroup: true, title: "Lab Chat"))
        XCTAssertEqual(channel.title, "Lab Chat")
        XCTAssertTrue(channel.isMegagroup)
    }

    func testBroadcastChannelWhoseMemberStatusHasARank() throws {
        let channel = try TDLibRecordDecoder.channel(channelRecord(megagroup: false, status: .rank("Editor"), title: "Daily News"))
        XCTAssertEqual(channel.title, "Daily News")
        XCTAssertFalse(channel.isMegagroup)
    }

    func testChannelWhoseMemberStatusHasAnUntilDate() throws {
        let record = channelRecord(megagroup: true, status: .until(1_800_000_000), title: "Muted Room")
        XCTAssertEqual(try TDLibRecordDecoder.channel(record).title, "Muted Room")
    }

    func testChannelWhoseMemberStatusHasUntilDateAndRank() throws {
        let record = channelRecord(megagroup: true, status: .untilAndRank(1_800_000_000, "Mod"), title: "Busy Room")
        XCTAssertEqual(try TDLibRecordDecoder.channel(record).title, "Busy Room")
    }

    func testChannelRecordBeforeVersion46HasA32BitStatus() throws {
        let record = channelRecord(version: 45, megagroup: true, status: .rank("Owner"), title: "Old Group")
        XCTAssertEqual(try TDLibRecordDecoder.channel(record).title, "Old Group")
    }

    func testChannelWithoutNewRightsOrFlags2() throws {
        let record = channelRecord(megagroup: false, newRights: false, hasFlags2: false, title: "Legacy Channel")
        XCTAssertEqual(try TDLibRecordDecoder.channel(record).title, "Legacy Channel")
    }

    func testChannelRecordCutInsideTheStatusIsUndecodable() {
        let record = channelRecord(megagroup: true, status: .rank("Editor"), title: "Daily News")
        XCTAssertThrowsError(try TDLibRecordDecoder.channel(Array(record.prefix(20))))
    }

    // MARK: - Secret chats (UserManager::SecretChat::store)

    private func secretChatRecord(version: Int32 = 57, userId: Int64) -> [UInt8] {
        var w = TLWriter()
        w.int32(version)
        w.uint32(flags(0))                 // is_outbound
        w.int64(0x0A0B_0C0D_0E0F_1011)     // access_hash
        if version >= 33 { w.int64(userId) } else { w.int32(Int32(userId)) }
        w.int32(2)                         // state
        w.int32(0)                         // ttl
        w.int32(1_700_000_000)             // date
        w.string([UInt8](repeating: 7, count: 20))   // key_hash
        return w.bytes
    }

    func testSecretChatUserId() throws {
        XCTAssertEqual(try TDLibRecordDecoder.secretChatUserId(secretChatRecord(userId: 1001)), 1001)
    }

    func testSecretChatUserIdBefore64BitIds() throws {
        XCTAssertEqual(try TDLibRecordDecoder.secretChatUserId(secretChatRecord(version: 32, userId: 1001)), 1001)
    }

    // MARK: - Dialog id ranges (DialogId::get_type)

    func testDialogIdRanges() {
        let cases: [(Int64, DialogKind)] = [
            (1, .user(1)),
            ((1 << 40) - 1, .user((1 << 40) - 1)),
            (1 << 40, .none),
            (0, .none),
            (-1, .basicGroup(1)),
            (-999_999_999_999, .basicGroup(999_999_999_999)),
            (-1_000_000_000_000, .none),
            (-1_000_000_000_001, .channel(1)),
            (-1_997_852_516_352, .channel(997_852_516_352)),
            (-1_997_852_516_353, .secretChat(2_147_483_647)),
            (-2_000_000_000_007, .secretChat(-7)),
            (-2_000_000_000_000, .none),
            (-2_002_147_483_648, .secretChat(-2_147_483_648)),
            (-2_002_147_483_649, .channel(1_002_147_483_649)),
            (-4_000_000_000_000, .channel(3_000_000_000_000)),
            (-4_000_000_000_001, .none),
        ]
        for (id, expected) in cases {
            XCTAssertEqual(DialogKind(dialogId: id), expected, "dialog id \(id)")
        }
    }
}
