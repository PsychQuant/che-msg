import XCTest
import TelegramAllLib
@testable import CheTelegramAllMCPCore

final class CheTelegramAllMCPTests: XCTestCase {

    // MARK: - Tool Definition Tests

    func testToolCount() {
        let tools = CheTelegramAllMCPServer.defineTools()
        XCTAssertEqual(tools.count, 28)
    }

    func testAllExpectedToolsExist() {
        let tools = CheTelegramAllMCPServer.defineTools()
        let names = Set(tools.map(\.name))

        let expected: Set<String> = [
            // Auth
            "auth_set_parameters", "auth_send_phone", "auth_send_code",
            "auth_send_password", "auth_status", "auth_run", "logout",
            // User
            "get_me", "get_user", "get_contacts",
            // Chats
            "get_chats", "get_chat", "search_chats",
            // Messages
            "get_chat_history", "send_message", "edit_message",
            "delete_messages", "forward_messages", "search_messages",
            // Group
            "get_chat_members", "pin_message", "unpin_message",
            "set_chat_title", "set_chat_description",
            "create_group", "add_chat_member",
            // Read state
            "mark_as_read",
            // History export
            "dump_chat_to_markdown",
        ]

        XCTAssertEqual(names, expected, "Tool set mismatch")
    }

    func testToolsHaveDescriptions() {
        let tools = CheTelegramAllMCPServer.defineTools()
        for tool in tools {
            XCTAssertFalse(
                (tool.description ?? "").isEmpty,
                "\(tool.name) missing description"
            )
        }
    }

    func testToolsHaveInputSchema() {
        let tools = CheTelegramAllMCPServer.defineTools()
        for tool in tools {
            XCTAssertNotNil(tool.inputSchema, "\(tool.name) missing inputSchema")
        }
    }

    // MARK: - Server Init

    func testServerInitSucceeds() async throws {
        let server = try await CheTelegramAllMCPServer()
        XCTAssertNotNil(server)
    }

    /// Scenario "Server starts without holding TDLib" (telegram-tdlib-lifecycle;
    /// PsychQuant/che-msg#58): after startup no TDLib client exists and the
    /// TDLib lock is free.
    func testServerStartsWithoutOpeningOrLockingTDLib() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let server = try await CheTelegramAllMCPServer(lock: TDLibProcessLock(cacheDirectory: cache, pid: getpid()),
                                                       idleTimeout: 600)
        let isOpen = await server.isTDLibOpen
        XCTAssertFalse(isOpen)
        let fd = open(cache.appendingPathComponent("che-telegram-all-mcp.tdlib.lock").path, O_RDWR | O_CREAT, 0o600)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "the server must not hold the TDLib lock at startup")
    }
}
