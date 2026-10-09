import Darwin
import MCP
import XCTest
import TelegramAllLib
@testable import CheTelegramAllMCPCore

/// Covers "Tool routing while TDLib is held by another process"
/// (telegram-tdlib-lifecycle) and "Reader marks its results as coming from the
/// local cache" (telegram-local-reader); PsychQuant/che-msg#58, task 4.3.
///
/// Another process is played by a second open file description holding the
/// flock in a private cache directory, with PID 4242 recorded as its owner.
final class ToolRoutingTests: XCTestCase {
    private final class FakeReader: LocalCacheReading {
        var calls: [String] = []
        var error: Error?
        var result = LocalTDLibReader.Result(
            json: #"[{"id":777}]"#, undecodableCount: 1,
            freshness: [.init(chatId: 777, newest: .date(1_777_507_200)), .init(chatId: 888, newest: .noMessages)])

        private func answer(_ call: String) throws -> LocalTDLibReader.Result {
            calls.append(call)
            if let error { throw error }
            return result
        }

        func getChats(limit: Int) throws -> LocalTDLibReader.Result { try answer("get_chats") }
        func searchChats(query: String, limit: Int) throws -> LocalTDLibReader.Result { try answer("search_chats") }
        func getChatHistory(chatId: Int64, limit: Int, fromMessageId: Int64, maxMessages: Int?,
                            sinceDate: Date?, untilDate: Date?) throws -> LocalTDLibReader.Result { try answer("get_chat_history") }
        func searchMessages(chatId: Int64, query: String, limit: Int) throws -> LocalTDLibReader.Result { try answer("search_messages") }
        func dumpChatToMarkdown(chatId: Int64, outputPath: String, maxMessages: Int, sinceDate: Date?,
                                untilDate: Date?, selfLabel: String) async throws -> LocalTDLibReader.Result {
            try answer("dump_chat_to_markdown")
        }
    }

    private static let readerTools = ["get_chats", "search_chats", "get_chat_history", "search_messages", "dump_chat_to_markdown"]
    private static let unsupportedTools = ["get_me", "get_user", "get_contacts", "get_chat", "get_chat_members"]

    private var cache: URL!
    private let reader = FakeReader()

    override func setUpWithError() throws {
        cache = FileManager.default.temporaryDirectory.appendingPathComponent("routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock { [cache] in try? FileManager.default.removeItem(at: cache!) }
    }

    /// Holds the TDLib flock as another process would, recording `pid` as owner.
    private func holdTDLib(asPid pid: Int32?) throws {
        let fd = open(cache.appendingPathComponent("che-telegram-all-mcp.tdlib.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        addTeardownBlock { close(fd) }
        if let pid {
            try "\(pid)\n".write(to: cache.appendingPathComponent("che-telegram-all-mcp.tdlib.owner"), atomically: true, encoding: .utf8)
        }
    }

    private func makeServer() async throws -> CheTelegramAllMCPServer {
        try await CheTelegramAllMCPServer(lock: TDLibProcessLock(cacheDirectory: cache, pid: getpid()),
                                          idleTimeout: 600, reader: reader)
    }

    /// Arguments that pass each tool's argument checks.
    private func arguments(for tool: String) -> [String: Value] {
        switch tool {
        case "search_chats": return ["query": .string("a")]
        case "get_chat_history", "get_chat", "get_chat_members": return ["chat_id": .int(777)]
        case "search_messages": return ["chat_id": .int(777), "query": .string("a")]
        case "dump_chat_to_markdown":
            return ["chat_id": .int(777), "output_path": .string(cache.appendingPathComponent("chat.md").path)]
        case "get_user": return ["user_id": .int(1001)]
        default: return [:]
        }
    }

    private func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { if case .text(let text, _, _) = $0 { return text } else { return nil } }
    }

    private func json(_ result: CallTool.Result) throws -> [String: Any] {
        let items = texts(result)
        XCTAssertEqual(items.count, 1)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data((items.first ?? "").utf8)) as? [String: Any])
    }

    // MARK: - Routing table

    /// Scenario "Supported read tool while TDLib is held elsewhere".
    func testReaderToolsAreAnsweredFromTheLocalCache() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        for tool in Self.readerTools {
            let result = await server.handleToolCall(name: tool, arguments: arguments(for: tool))
            XCTAssertEqual(result.isError, false, tool)
            let items = texts(result)
            XCTAssertEqual(items.count, 2, tool)
            XCTAssertEqual(items.first, #"[{"id":777}]"#, tool)
            XCTAssertTrue(items.last?.contains("source: local-cache") == true, tool)
            XCTAssertTrue(items.last?.contains("4242") == true, tool)
        }
        XCTAssertEqual(reader.calls, Self.readerTools)
        let isOpen = await server.isTDLibOpen
        XCTAssertFalse(isOpen, "no TDLib client may be created while another process holds TDLib")
    }

    /// Scenario "Unsupported read tool while TDLib is held elsewhere".
    func testUnsupportedReadToolsReportLocalReaderUnsupported() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        for tool in Self.unsupportedTools {
            let result = await server.handleToolCall(name: tool, arguments: arguments(for: tool))
            XCTAssertEqual(result.isError, true, tool)
            let payload = try json(result)
            XCTAssertEqual(payload["type"] as? String, "local_reader_unsupported", tool)
            XCTAssertEqual(payload["tool"] as? String, tool)
            XCTAssertNotNil(payload["message"] as? String, tool)
        }
        XCTAssertTrue(reader.calls.isEmpty)
    }

    /// Scenario "Write tool while TDLib is held elsewhere", for every tool the
    /// table does not send to the reader or mark unsupported.
    func testEveryOtherToolReportsTDLibInUse() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        let others = CheTelegramAllMCPServer.defineTools().map(\.name)
            .filter { !Self.readerTools.contains($0) && !Self.unsupportedTools.contains($0) }
        XCTAssertEqual(others.count, 18)
        for tool in others {
            let result = await server.handleToolCall(name: tool, arguments: arguments(for: tool))
            XCTAssertEqual(result.isError, true, tool)
            let payload = try json(result)
            XCTAssertEqual(payload["type"] as? String, "tdlib_in_use", tool)
            XCTAssertEqual((payload["lock_holder_pid"] as? NSNumber)?.int32Value, 4242, tool)
            XCTAssertNotNil(payload["message"] as? String, tool)
        }
        let isOpen = await server.isTDLibOpen
        XCTAssertFalse(isOpen)
    }

    func testUnknownHolderIsReportedAsNull() async throws {
        try holdTDLib(asPid: nil)
        let server = try await makeServer()
        let payload = try json(await server.handleToolCall(name: "send_message", arguments: [:]))
        XCTAssertEqual(payload["type"] as? String, "tdlib_in_use")
        XCTAssertTrue(payload["lock_holder_pid"] is NSNull)
    }

    // MARK: - Reader failures and arguments

    func testReaderThatCannotReadTheCacheReportsLocalReaderUnavailable() async throws {
        try holdTDLib(asPid: 4242)
        let cases: [(LocalReaderError, String)] = [
            (.unsupportedTDLibVersion("db.sqlite user_version 13"), "unsupported_tdlib_version"),
            (.keyNotFound, "key_not_found"),
            (.databaseUnreadable("disk I/O error"), "database_unreadable"),
            (.notAuthenticated, "not_authenticated"),
        ]
        let server = try await makeServer()
        for (error, reason) in cases {
            reader.error = error
            let result = await server.handleToolCall(name: "get_chat_history", arguments: arguments(for: "get_chat_history"))
            XCTAssertEqual(result.isError, true, reason)
            let payload = try json(result)
            XCTAssertEqual(payload["type"] as? String, "local_reader_unavailable", reason)
            XCTAssertEqual(payload["reason"] as? String, reason)
            XCTAssertNotNil(payload["message"] as? String, reason)
        }
    }

    func testReaderToolArgumentsAreCheckedAsInTDLibMode() async throws {
        try holdTDLib(asPid: 4242)
        let server = try await makeServer()
        let result = await server.handleToolCall(name: "get_chat_history", arguments: [:])
        XCTAssertEqual(result.isError, true)
        XCTAssertTrue(reader.calls.isEmpty)
    }

    // MARK: - Source note

    /// Example "freshness lines".
    func testSourceNoteStatesTheHolderSkippedRecordsAndFreshness() {
        let note = localCacheNote(holderPid: 4242, result: reader.result, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(note.contains("source: local-cache"), note)
        XCTAssertTrue(note.contains("4242"), note)
        XCTAssertTrue(note.contains("undecodable records: 1"), note)
        XCTAssertTrue(note.contains("chat 777: newest cached message 2026-04-30"), note)
        XCTAssertTrue(note.contains("chat 888: no cached messages"), note)
        XCTAssertTrue(note.contains("newer messages can exist on Telegram"), note)
    }
}
