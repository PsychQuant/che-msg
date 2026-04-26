import XCTest
@testable import TelegramAllLib
@testable import CheTelegramAllMCPCore

/// E2E tests for Telegram personal account operations.
///
/// Prerequisites:
///   export TELEGRAM_API_ID=<your_api_id>
///   export TELEGRAM_API_HASH=<your_api_hash>
///
/// Auth flow (one-time, via CLI):
///   telegram-all auth-phone +886912345678
///   telegram-all auth-code 12345
///   telegram-all auth-status   # should print "Authenticated ✓"
///
/// Run:
///   swift test --filter E2ETests
///
/// IMPORTANT: TDLib's receive loop is process-global, so E2E tests
/// must be run separately from unit tests:
///   swift test --skip E2ETests   # unit tests
///   swift test --filter E2ETests # E2E tests
///
/// Skip in CI (no credentials):
///   swift test --skip E2ETests
final class TelegramE2ETests: XCTestCase {

    /// Shared client — TDLib only allows one receive thread,
    /// so all tests share a single TDLibClient instance.
    private static var sharedClient: TDLibClient?

    private var client: TDLibClient { Self.sharedClient! }

    // MARK: - Setup (once for entire suite)

    override class func setUp() {
        super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let idStr = env["TELEGRAM_API_ID"], let apiId = Int(idStr),
              let apiHash = env["TELEGRAM_API_HASH"] else { return }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let c = try await TDLibClient()
                // Workaround: TDLibClient init has a race condition where the first
                // authorizationStateWaitTdlibParameters update may be dropped.
                try await Task.sleep(nanoseconds: 500_000_000)
                if c.getAuthState() == .waitingForParameters {
                    try await c.setParameters(apiId: apiId, apiHash: apiHash)
                }
                // Wait for auth to reach ready (session must exist from prior login)
                for _ in 0..<150 {
                    if c.getAuthState() == .ready { break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                sharedClient = c
            } catch {
                print("E2E setUp failed: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TELEGRAM_API_ID"] != nil, env["TELEGRAM_API_HASH"] != nil else {
            throw XCTSkip("TELEGRAM_API_ID / TELEGRAM_API_HASH not set — skipping E2E tests")
        }
        guard let c = Self.sharedClient, c.getAuthState() == .ready else {
            throw XCTSkip("Auth not ready (state: \(Self.sharedClient?.getAuthState().rawValue ?? "nil")). Run auth flow first.")
        }
    }

    // MARK: - Auth

    func testAuthStatusIsReady() {
        let state: TDLibClient.AuthState = client.getAuthState()
        XCTAssertEqual(state, .ready)
    }

    // MARK: - Read: get_me

    func testGetMe() async throws {
        let json = try await client.getMe()
        let dict = try parseJSONObject(json)
        XCTAssertNotNil(dict["id"], "getMe should return user ID")
        XCTAssertNotNil(dict["first_name"], "getMe should return first_name")
    }

    // MARK: - Read: get_chats + get_chat

    func testGetChatsAndGetChat() async throws {
        let chatsJSON = try await client.getChats(limit: 5)
        let chats = try parseJSONArray(chatsJSON)
        XCTAssertFalse(chats.isEmpty, "Should have at least 1 chat")

        let firstChat = chats[0]
        let chatId = firstChat["id"] as! Int64
        XCTAssertNotNil(firstChat["title"])
        XCTAssertNotNil(firstChat["type"])

        let chatJSON = try await client.getChat(chatId: chatId)
        let chat = try parseJSONObject(chatJSON)
        XCTAssertEqual(chat["id"] as? Int64, chatId)
    }

    // MARK: - Read: get_chat_history

    func testGetChatHistory() async throws {
        let chatId = try await firstChatId()
        let historyJSON = try await client.getChatHistory(chatId: chatId, limit: 10)
        let messages = try parseJSONArray(historyJSON)
        XCTAssertNotNil(messages)
    }

    // MARK: - Read: search_messages

    func testSearchMessages() async throws {
        let chatId = try await firstChatId()
        let resultJSON = try await client.searchMessages(chatId: chatId, query: "a", limit: 5)
        let messages = try parseJSONArray(resultJSON)
        XCTAssertNotNil(messages)
    }

    // MARK: - Read: get_contacts

    func testGetContacts() async throws {
        let json = try await client.getContacts()
        let contacts = try parseJSONArray(json)
        XCTAssertNotNil(contacts)
    }

    // MARK: - Read: search_chats

    func testSearchChats() async throws {
        let json = try await client.searchChats(query: "a", limit: 5)
        let chats = try parseJSONArray(json)
        XCTAssertNotNil(chats)
    }

    // MARK: - Write: send_message (Saved Messages)

    func testSendMessageToSavedMessages() async throws {
        // Load chat list to populate TDLib's chat cache
        let chatsJSON = try await client.getChats(limit: 50)
        let chats = try parseJSONArray(chatsJSON)

        let meJSON = try await client.getMe()
        let me = try parseJSONObject(meJSON)
        let myId = me["id"] as! Int64

        // Find Saved Messages in the loaded chat list (chat_id == own user id)
        guard chats.contains(where: { ($0["id"] as? Int64) == myId }) else {
            throw XCTSkip("Saved Messages chat not in first 50 chats")
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let text = "[E2E Test] \(timestamp)"

        let resultJSON = try await client.sendMessage(chatId: myId, text: text)
        let result = try parseJSONObject(resultJSON)
        XCTAssertNotNil(result["id"], "sendMessage should return message ID")
        XCTAssertEqual(result["chat_id"] as? Int64, myId)
    }

    // MARK: - CLI: telegram-all --help

    func testCLIHelp() throws {
        let binary = productsDir().appendingPathComponent("telegram-all")
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw XCTSkip("telegram-all binary not found. Run `swift build` first.")
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--help"]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("telegram-all"))
        XCTAssertTrue(output.contains("chats"))
        XCTAssertTrue(output.contains("send"))
        XCTAssertTrue(output.contains("history"))
        XCTAssertTrue(output.contains("search"))
        XCTAssertTrue(output.contains("contacts"))
        XCTAssertTrue(output.contains("me"))
    }

    // MARK: - Helpers

    private func firstChatId() async throws -> Int64 {
        let json = try await client.getChats(limit: 1)
        let chats = try parseJSONArray(json)
        guard let first = chats.first, let id = first["id"] as? Int64 else {
            throw XCTSkip("No chats available")
        }
        return id
    }

    private func parseJSONArray(_ json: String) throws -> [[String: Any]] {
        let data = json.data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
    }

    private func parseJSONObject(_ json: String) throws -> [String: Any] {
        let data = json.data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func productsDir() -> URL {
        #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        #endif
        return Bundle.main.bundleURL
    }
}
