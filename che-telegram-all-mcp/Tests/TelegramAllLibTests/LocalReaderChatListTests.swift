import CTDLibSQLite
import XCTest
@testable import TelegramAllLib

/// Covers the chat listing half of task 3.3 and the chat part of "Undecodable
/// records are reported, not guessed" (telegram-local-reader;
/// PsychQuant/che-msg#58): chats come from the `dialogs` table in
/// `dialog_order` order, names from the `us`/`gr`/`ch`/`sc` records in
/// `common`, and a chat whose record cannot be decoded is listed as `unknown`
/// without a title.
final class LocalReaderChatListTests: XCTestCase {
    private func user(_ first: String, _ last: String?) -> [UInt8] {
        var w = TLWriter()
        w.int32(57); w.uint32(last == nil ? 0 : flags(8)); w.uint32(0)
        w.string(first)
        if let last { w.string(last) }
        return w.bytes
    }

    private func channel(_ title: String, megagroup: Bool) -> [UInt8] {
        var w = TLWriter()
        w.int32(57); w.uint32(megagroup ? flags(7, 12, 29) : flags(12, 29)); w.uint32(0)
        w.uint64(UInt64(4) << 28)
        w.int64(99)
        w.string(title)
        return w.bytes
    }

    private func secretChat(userId: Int64) -> [UInt8] {
        var w = TLWriter()
        w.int32(57); w.uint32(0); w.int64(5); w.int64(userId)
        return w.bytes
    }

    /// A cache with a main list of five chats, one archived chat and one chat in
    /// no list. Main list by dialog_order: 1001 (300), supergroup 42 (250),
    /// truncated basic group 5 (200), secret chat 7 with user 1001 (150),
    /// user 1003 whose record is missing (50).
    private func cacheWithChats() throws -> TDLibCacheDatabase {
        let dir = try LocalReaderFixture.copy(for: self)
        let db = try LocalReaderFixture.openAsWriter(dir)
        defer { tdsqlite3_close(db) }
        LocalReaderFixture.putDialog(db, id: 1001, order: 300, folder: 0)
        LocalReaderFixture.putDialog(db, id: -1_000_000_000_042, order: 250, folder: 0)
        LocalReaderFixture.putDialog(db, id: -5, order: 200, folder: 0)
        LocalReaderFixture.putDialog(db, id: -2_000_000_000_007, order: 150, folder: 0)
        LocalReaderFixture.putDialog(db, id: -1_000_000_000_043, order: 100, folder: 1)
        LocalReaderFixture.putDialog(db, id: 1003, order: 50, folder: 0)
        LocalReaderFixture.putDialog(db, id: 1002, order: 0, folder: 0)
        LocalReaderFixture.putCommon(db, "us1001", user("Ada", "Lovelace"))
        LocalReaderFixture.putCommon(db, "us1002", user("Grace", nil))
        LocalReaderFixture.putCommon(db, "ch42", channel("Lab Chat", megagroup: true))
        LocalReaderFixture.putCommon(db, "ch43", channel("Daily News", megagroup: false))
        LocalReaderFixture.putCommon(db, "gr5", [57, 0, 0, 0, 0, 0])   // cut after the version
        LocalReaderFixture.putCommon(db, "sc-7", secretChat(userId: 1001))
        // Full-info records share the prefixes; they must never be read as chats.
        LocalReaderFixture.putCommon(db, "grf5", [1, 2, 3])
        LocalReaderFixture.putCommon(db, "chf42", [1, 2, 3])
        LocalReaderFixture.putCommon(db, "usf1001", [1, 2, 3])
        return try TDLibCacheDatabase(directory: dir.path)
    }

    func testMainListInDialogOrderWithUndecodableChatsAsUnknown() throws {
        let chats = try cacheWithChats().chats(mainListOnly: true)
        XCTAssertEqual(chats, [
            LocalChat(id: 1001, title: "Ada Lovelace", type: .privateChat),
            LocalChat(id: -1_000_000_000_042, title: "Lab Chat", type: .supergroup),
            LocalChat(id: -5, title: nil, type: .unknown),
            LocalChat(id: -2_000_000_000_007, title: "Ada Lovelace", type: .secret),
            LocalChat(id: 1003, title: nil, type: .unknown),
        ])
        XCTAssertEqual(chats.filter { $0.type == .unknown }.count, 2)
    }

    func testAllKnownChatsIncludeArchivedAndUnlisted() throws {
        let chats = try cacheWithChats().chats(mainListOnly: false)
        XCTAssertEqual(chats.map(\.id), [1001, -1_000_000_000_042, -5, -2_000_000_000_007, -1_000_000_000_043, 1003, 1002])
        guard chats.count == 7 else { return }
        XCTAssertEqual(chats[4], LocalChat(id: -1_000_000_000_043, title: "Daily News", type: .channel))
        XCTAssertEqual(chats[6], LocalChat(id: 1002, title: "Grace", type: .privateChat))
    }

    func testSingleChatLookupAndUserTitle() throws {
        let cache = try cacheWithChats()
        XCTAssertEqual(try cache.chat(id: -1_000_000_000_043), LocalChat(id: -1_000_000_000_043, title: "Daily News", type: .channel))
        XCTAssertEqual(try cache.userTitle(id: 1001), "Ada Lovelace")
        XCTAssertNil(try cache.userTitle(id: 4242))
    }
}
