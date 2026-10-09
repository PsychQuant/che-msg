import CTDLibSQLite
import XCTest
@testable import TelegramAllLib

/// Covers task 3.5 (telegram-local-reader; PsychQuant/che-msg#58): the five
/// reading tools answered from hand-built rows in a copy of the fixture cache,
/// "Reader answers five tools with the TDLib-mode JSON fields" and "Reader
/// never exposes the database key".
final class LocalReaderToolTests: XCTestCase {
    // Message ids are server ids shifted by 20 bits, as TDLib stores them.
    private let hello: Int64 = 5 << 20, helloThere: Int64 = 6 << 20, forwarded: Int64 = 7 << 20
    private let groupHello: Int64 = 1 << 20, groupBye: Int64 = 2 << 20

    /// Main list: 777 Bob Chen (order 300), basic group -42 Study Group (200),
    /// 888 Carol with no cached messages (100). Archived: channel Daily News.
    /// Chat 777 holds "hello" from 1001 (the spec example), "Hello there" from
    /// 777 a day later, and a day after that a forwarded message sent by the
    /// account owner (42), which the reader cannot decode.
    private func cacheDirectory() throws -> URL {
        let dir = try LocalReaderFixture.copy(for: self)
        let db = try LocalReaderFixture.openAsWriter(dir)
        defer { tdsqlite3_close(db) }
        LocalReaderFixture.putDialog(db, id: 777, order: 300, folder: 0)
        LocalReaderFixture.putDialog(db, id: -42, order: 200, folder: 0)
        LocalReaderFixture.putDialog(db, id: 888, order: 100, folder: 0)
        LocalReaderFixture.putDialog(db, id: -1_000_000_000_043, order: 50, folder: 1)
        LocalReaderFixture.putCommon(db, "us777", LocalReaderRecords.user("Bob", "Chen"))
        LocalReaderFixture.putCommon(db, "us888", LocalReaderRecords.user("Carol"))
        LocalReaderFixture.putCommon(db, "us1001", LocalReaderRecords.user("Ada", "Lovelace"))
        LocalReaderFixture.putCommon(db, "us42", LocalReaderRecords.user("Me"))
        LocalReaderFixture.putCommon(db, "gr42", LocalReaderRecords.basicGroup("Study Group"))
        LocalReaderFixture.putCommon(db, "ch43", LocalReaderRecords.channel("Daily News", megagroup: false))
        LocalReaderFixture.putMessage(db, chat: 777, id: hello, sender: 1001,
                                      data: LocalReaderRecords.message(id: hello, sender: 1001, date: 1_760_000_000, text: "hello"))
        LocalReaderFixture.putMessage(db, chat: 777, id: helloThere, sender: 777,
                                      data: LocalReaderRecords.message(id: helloThere, sender: 777, date: 1_760_086_400, text: "Hello there"))
        LocalReaderFixture.putMessage(db, chat: 777, id: forwarded, sender: 42,
                                      data: LocalReaderRecords.message(id: forwarded, sender: 42, date: 1_760_172_800, outgoing: true,
                                                                       text: "never read", forwarded: true))
        LocalReaderFixture.putMessage(db, chat: -42, id: groupHello, sender: 1001,
                                      data: LocalReaderRecords.message(id: groupHello, sender: 1001, date: 1_760_000_100, text: "hello there"))
        LocalReaderFixture.putMessage(db, chat: -42, id: groupBye, sender: 777,
                                      data: LocalReaderRecords.message(id: groupBye, sender: 777, date: 1_760_000_200, text: "bye"))
        return dir
    }

    private func reader() throws -> LocalTDLibReader {
        LocalTDLibReader(directory: try cacheDirectory().path)
    }

    /// The result's JSON re-serialised compactly with sorted keys.
    private func normalized(_ json: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }

    private func ids(_ json: String) throws -> [Int64] {
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        return array.compactMap { ($0["id"] as? NSNumber)?.int64Value }
    }

    private let specMessage = #"{"chat_id":777,"date":1760000000,"id":5242880,"is_outgoing":false,"sender":{"type":"user","user_id":1001},"text":"hello","type":"text"}"#
    private let helloThereMessage = #"{"chat_id":777,"date":1760086400,"id":6291456,"is_outgoing":false,"sender":{"type":"user","user_id":777},"text":"Hello there","type":"text"}"#
    private let forwardedMessage = #"{"chat_id":777,"date":1760172800,"id":7340032,"is_outgoing":true,"sender":{"type":"user","user_id":42},"type":"unknown"}"#

    // MARK: - get_chats

    func testGetChatsListsTheMainListWithLastMessages() throws {
        let result = try reader().getChats(limit: 10)
        XCTAssertEqual(try normalized(result.json), "["
            + #"{"id":777,"last_message":"# + forwardedMessage + #","title":"Bob Chen","type":"private"},"#
            + #"{"id":-42,"last_message":{"chat_id":-42,"date":1760000200,"id":2097152,"is_outgoing":false,"sender":{"type":"user","user_id":777},"text":"bye","type":"text"},"title":"Study Group","type":"basic_group"},"#
            + #"{"id":888,"title":"Carol","type":"private"}"#
            + "]")
        XCTAssertEqual(result.undecodableCount, 1)
        XCTAssertEqual(result.freshness, [
            .init(chatId: 777, newest: .date(1_760_172_800)),
            .init(chatId: -42, newest: .date(1_760_000_200)),
            .init(chatId: 888, newest: .noMessages),
        ])
    }

    /// Scenario "Unread count omitted".
    func testGetChatsOmitsUnreadCount() throws {
        XCTAssertFalse(try reader().getChats().json.contains("unread_count"))
    }

    func testGetChatsHonoursTheLimit() throws {
        XCTAssertEqual(try ids(reader().getChats(limit: 1).json), [777])
    }

    // MARK: - search_chats

    func testSearchChatsMatchesTitlesCaseInsensitivelyIncludingArchived() throws {
        let reader = try reader()
        XCTAssertEqual(try ids(reader.searchChats(query: "CHEN").json), [777])
        XCTAssertEqual(try ids(reader.searchChats(query: "study").json), [-42])
        XCTAssertEqual(try ids(reader.searchChats(query: "news").json), [-1_000_000_000_043])
        XCTAssertEqual(try ids(reader.searchChats(query: "nothing like this").json), [])
    }

    // MARK: - get_chat_history

    /// Scenario "Chat history from the local cache" with its example.
    func testChatHistoryNewestFirstWithTheSpecExample() throws {
        let result = try reader().getChatHistory(chatId: 777)
        XCTAssertEqual(try normalized(result.json), "[" + [forwardedMessage, helloThereMessage, specMessage].joined(separator: ",") + "]")
        XCTAssertEqual(result.undecodableCount, 1)
        XCTAssertEqual(result.freshness, [.init(chatId: 777, newest: .date(1_760_172_800))])
    }

    func testChatHistoryLimitAndInclusiveFromMessageId() throws {
        let reader = try reader()
        XCTAssertEqual(try ids(reader.getChatHistory(chatId: 777, limit: 2).json), [forwarded, helloThere])
        XCTAssertEqual(try ids(reader.getChatHistory(chatId: 777, fromMessageId: helloThere).json), [helloThere, hello])
    }

    func testChatHistoryDateFiltersOnOnePage() throws {
        let reader = try reader()
        let since = Date(timeIntervalSince1970: 1_760_050_000), until = Date(timeIntervalSince1970: 1_760_100_000)
        XCTAssertEqual(try ids(reader.getChatHistory(chatId: 777, sinceDate: since).json), [forwarded, helloThere])
        XCTAssertEqual(try ids(reader.getChatHistory(chatId: 777, untilDate: until).json), [helloThere, hello])
        XCTAssertEqual(try ids(reader.getChatHistory(chatId: 777, sinceDate: since, untilDate: until).json), [helloThere])
    }

    func testChatHistoryBulkModeStopsAtMaxMessagesAndSince() throws {
        let reader = try reader()
        XCTAssertEqual(try ids(reader.getChatHistory(chatId: 777, maxMessages: 2).json), [forwarded, helloThere])
        let since = Date(timeIntervalSince1970: 1_760_050_000)
        XCTAssertEqual(try ids(reader.getChatHistory(chatId: 777, maxMessages: 100, sinceDate: since).json), [forwarded, helloThere])
    }

    /// Freshness example: a chat without cached messages.
    func testChatHistoryForAChatWithoutMessages() throws {
        let result = try reader().getChatHistory(chatId: 888)
        XCTAssertEqual(try normalized(result.json), "[]")
        XCTAssertEqual(result.freshness, [.init(chatId: 888, newest: .noMessages)])
    }

    // MARK: - search_messages

    /// Scenario "Search matches decoded text".
    func testSearchMatchesDecodedTextCaseInsensitively() throws {
        let result = try reader().searchMessages(chatId: -42, query: "HELLO")
        XCTAssertEqual(try ids(result.json), [groupHello])
        XCTAssertEqual(result.undecodableCount, 0)
    }

    /// An undecodable message could hold the query, so it is counted.
    func testSearchCountsUndecodableMessagesItCouldNotSearch() throws {
        let result = try reader().searchMessages(chatId: 777, query: "hello")
        XCTAssertEqual(try ids(result.json), [helloThere, hello])
        XCTAssertEqual(result.undecodableCount, 1)
    }

    func testSearchHonoursTheLimit() throws {
        XCTAssertEqual(try ids(reader().searchMessages(chatId: 777, query: "hello", limit: 1).json), [helloThere])
    }

    // MARK: - dump_chat_to_markdown

    func testDumpWritesTheHistoryExportFormat() async throws {
        let reader = try reader()
        let output = try LocalReaderFixture.copy(for: self).appendingPathComponent("chat.md")
        let result = try await reader.dumpChatToMarkdown(chatId: 777, outputPath: output.path)
        let summary = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
        XCTAssertEqual(summary["message_count"] as? Int, 3)
        let senders = (summary["senders"] as? [[String: Any]] ?? []).compactMap { $0["display_name"] as? String }.sorted()
        XCTAssertEqual(senders, ["Ada Lovelace", "Bob Chen", "Me"])

        let markdown = try String(contentsOf: output, encoding: .utf8)
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        time.timeZone = .current
        func at(_ unix: TimeInterval) -> String { time.string(from: Date(timeIntervalSince1970: unix)) }
        XCTAssertTrue(markdown.hasPrefix("# 對話：Bob Chen (chat_id=777)\n"), markdown)
        XCTAssertTrue(markdown.contains("**\(at(1_760_000_000)) Ada Lovelace**：\nhello\n"), markdown)
        XCTAssertTrue(markdown.contains("**\(at(1_760_086_400)) Bob Chen**：\nHello there\n"), markdown)
        XCTAssertTrue(markdown.contains("**\(at(1_760_172_800)) 我**：\n[other]\n"), markdown)
        XCTAssertEqual(result.undecodableCount, 1)
    }

    // MARK: - Key exposure

    /// Scenario "Key absent from outputs": every result, error message, the
    /// exported file and stderr are free of both keys in raw, hex and base64 form.
    func testNoOutputContainsTheDatabaseKey() async throws {
        let dir = try cacheDirectory()
        let key = try TDLibBinlogReader.sqliteKey(fromBinlogAt: dir.appendingPathComponent("td.binlog").path)
        let binlogKey = try binlogEncryptionKey(dir)
        let reader = LocalTDLibReader(directory: dir.path)
        let output = dir.deletingLastPathComponent().appendingPathComponent("dump-\(UUID().uuidString).md")
        addTeardownBlock { try? FileManager.default.removeItem(at: output) }

        var outputs: [String] = []
        let stderrText = try captureStandardError {
            outputs.append(try reader.getChats().json)
            outputs.append(try reader.searchChats(query: "e").json)
            outputs.append(try reader.getChatHistory(chatId: 777, maxMessages: 20_000).json)
            outputs.append(try reader.searchMessages(chatId: 777, query: "hello").json)
            for broken in [LocalTDLibReader(directory: "/nonexistent"), LocalTDLibReader(directory: try self.tamperedDirectory())] {
                do { _ = try broken.getChats() } catch { outputs += [String(describing: error), error.localizedDescription] }
            }
        }
        outputs.append(try await reader.dumpChatToMarkdown(chatId: 777, outputPath: output.path).json)
        outputs.append(try String(contentsOf: output, encoding: .utf8))
        outputs.append(stderrText)
        // The 20,000-message request writes a cap warning, which proves stderr was captured.
        XCTAssertTrue(stderrText.contains("capped maxMessages"), "stderr was not captured")

        // Both keys: the SQLite key and the binlog's AES-CTR key.
        for secret in [key, binlogKey] {
            let hex = secret.map { String(format: "%02x", $0) }.joined()
            let forms = [hex, hex.uppercased(), secret.base64EncodedString()]
            for text in outputs {
                for form in forms { XCTAssertFalse(text.contains(form), "a key appears in an output") }
                XCTAssertNil(Data(text.utf8).range(of: secret), "raw key bytes appear in an output")
            }
        }
        XCTAssertGreaterThan(outputs.count, 8)
    }

    /// The binlog's AES-CTR key, derived from its encryption event.
    private func binlogEncryptionKey(_ dir: URL) throws -> Data {
        let file = [UInt8](try Data(contentsOf: dir.appendingPathComponent("td.binlog")))
        var cursor = 0
        while let event = TDLibBinlogReader.nextEvent(in: file, at: cursor) {
            if event.type == TDLibBinlogReader.encryptionEventType {
                return Data(try TDLibBinlogReader.encryptionKey(from: event.data).key)
            }
            cursor += event.size
        }
        throw XCTSkip("fixture binlog has no encryption event")
    }

    private func tamperedDirectory() throws -> String {
        let dir = try LocalReaderFixture.copy(for: self)
        let db = try LocalReaderFixture.openAsWriter(dir)
        LocalReaderFixture.exec(db, "PRAGMA user_version = 13")
        tdsqlite3_close(db)
        return dir.path
    }

    /// Runs `body` with file descriptor 2 redirected to a temporary file and
    /// returns what was written to it.
    private func captureStandardError(_ body: () throws -> Void) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        fflush(stderr)
        let saved = dup(2)
        dup2(handle.fileDescriptor, 2)
        defer {
            fflush(stderr)
            dup2(saved, 2)
            close(saved)
            try? handle.close()
        }
        try body()
        fflush(stderr)
        return try String(contentsOf: file, encoding: .utf8)
    }
}
