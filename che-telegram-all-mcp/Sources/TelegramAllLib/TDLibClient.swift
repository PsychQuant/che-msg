import Foundation
import TDLibKit
import TDLibFramework

// MARK: - File-scope helpers (testable seams)

/// Configures the `JSONDecoder` used to decode TDLib `Update` broadcast payloads.
///
/// CRITICAL invariant — `keyDecodingStrategy` MUST be `.convertFromSnakeCase`. TDLib
/// emits snake_case keys (`authorization_state`, `chat_id`, etc.), Swift Codable
/// types use camelCase. Without this strategy every `Update` decode silently fails
/// inside `TDLibClient`'s callback `do/catch`, freezing `authState` at
/// `.waitingForParameters`. This was the v0.2.0 critical bug.
///
/// Exposed at file scope so `JSONDecoderRegressionTests` can verify the contract
/// without instantiating `TDLibClient` (TDLib's receive loop is process-global).
internal func makeUpdateDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}

/// Maps a `Swift.Error` thrown by a TDLib auth call into either a structured
/// `TDLibClient.TDError.tdlibError(code:message:)` or a silent return (code 406).
///
/// Per the TDLib protocol contract documented in
/// `Sources/TDLibKit/Generated/Models/Error.swift`:
/// > "If the error code is 406, the error message must not be processed in any
/// >  way and must not be displayed to the user."
///
/// Exposed at file scope so `TDLibAuthErrorTests` can verify the mapping
/// without instantiating `TDLibClient`.
///
/// - Parameter error: The error caught from a TDLibKit auth call.
/// - Throws: `TDLibClient.TDError.tdlibError(code:message:)` for any TDLibKit
///   error other than code 406; rethrows non-TDLibKit errors unchanged.
internal func mapTDLibError(_ error: Swift.Error) throws {
    guard let td = error as? TDLibKit.Error else {
        throw error
    }
    guard td.code != 406 else {
        // Silent-ignore per TDLib protocol. Caller treats this as success.
        return
    }
    throw TDLibClient.TDError.tdlibError(code: td.code, message: td.message)
}

/// Manages a TDLib client session with authentication state tracking.
public final class TDLibClient {
    private let manager: TDLibClientManager
    private let client: TDLibKit.TDLibClient
    private let dbPath: String

    public private(set) var authState: AuthState = .waitingForParameters

    /// Cached API credentials (from env or tool call).
    private var cachedApiId: Int?
    private var cachedApiHash: String?

    /// Weak reference holder to break the init capture cycle.
    private class Weak {
        weak var value: TDLibClient?
    }

    public enum AuthState: String, Sendable {
        case waitingForParameters
        case waitingForPhoneNumber
        case waitingForCode
        case waitingForPassword
        case ready
        case closed
    }

    public enum TDError: LocalizedError {
        case notAuthenticated
        case missingCredentials(String)
        case tdlibError(code: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .notAuthenticated: return "Not authenticated. Use auth_set_parameters, auth_send_phone, and auth_send_code first."
            case .missingCredentials(let msg): return "Missing: \(msg)"
            case .tdlibError(let code, let message): return "TDLib error \(code): \(message)"
            }
        }
    }

    public init(logVerbosity: Int = 0) async throws {
        // Silence TDLib's stdout spam BEFORE creating any client.
        // td_execute is synchronous, thread-safe, and doesn't need a client.
        let logRequest = #"{"@type":"setLogVerbosityLevel","new_verbosity_level":\#(logVerbosity)}"#
        _ = td_execute(logRequest)

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dbPath = appSupport.appendingPathComponent("che-telegram-all-mcp/tdlib").path
        try FileManager.default.createDirectory(atPath: dbPath, withIntermediateDirectories: true)

        let decoder = makeUpdateDecoder()
        let weakRef = Weak()
        manager = TDLibClientManager()
        client = manager.createClient { data, _ in
            guard let strongSelf = weakRef.value else { return }
            do {
                let update = try decoder.decode(Update.self, from: data)
                strongSelf.handleUpdate(update)
            } catch {
                // Ignore decode errors for unknown updates
            }
        }
        weakRef.value = self
    }

    deinit {
        manager.closeClients()
    }

    // MARK: - Update Handler

    private func handleUpdate(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let state):
            handleAuthStateUpdate(state.authorizationState)
        default:
            break
        }
    }

    private func handleAuthStateUpdate(_ state: AuthorizationState) {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            authState = .waitingForParameters
            autoSetParametersIfAvailable()
        case .authorizationStateWaitPhoneNumber:
            authState = .waitingForPhoneNumber
        case .authorizationStateWaitCode:
            authState = .waitingForCode
        case .authorizationStateWaitPassword:
            authState = .waitingForPassword
            autoSendPasswordIfAvailable()
        case .authorizationStateReady:
            authState = .ready
        case .authorizationStateClosed:
            authState = .closed
        default:
            break
        }
    }

    /// Auto-set TDLib parameters from environment variables if available.
    private func autoSetParametersIfAvailable() {
        let env = ProcessInfo.processInfo.environment
        guard let idStr = env["TELEGRAM_API_ID"], let apiId = Int(idStr),
              let apiHash = env["TELEGRAM_API_HASH"] else { return }
        cachedApiId = apiId
        cachedApiHash = apiHash
        Task { [weak self] in
            try? await self?.setParameters(apiId: apiId, apiHash: apiHash)
        }
    }

    /// Auto-send 2FA password from environment variable if available.
    private func autoSendPasswordIfAvailable() {
        guard let password = ProcessInfo.processInfo.environment["TELEGRAM_2FA_PASSWORD"] else { return }
        Task { [weak self] in
            try? await self?.sendPassword(password)
        }
    }

    // MARK: - Authentication

    public func setParameters(apiId: Int, apiHash: String) async throws {
        do {
            _ = try await client.setTdlibParameters(
                apiHash: apiHash,
                apiId: apiId,
                applicationVersion: "0.1.0",
                databaseDirectory: dbPath,
                databaseEncryptionKey: Data(),
                deviceModel: "macOS",
                filesDirectory: dbPath + "/files",
                systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
                systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: true,
                useSecretChats: false,
                useTestDc: false
            )
        } catch {
            try mapTDLibError(error)
        }
    }

    public func sendPhoneNumber(_ phoneNumber: String) async throws {
        do {
            _ = try await client.setAuthenticationPhoneNumber(phoneNumber: phoneNumber, settings: nil)
        } catch {
            try mapTDLibError(error)
        }
    }

    public func sendAuthCode(_ code: String) async throws {
        do {
            _ = try await client.checkAuthenticationCode(code: code)
        } catch {
            try mapTDLibError(error)
        }
    }

    public func sendPassword(_ password: String) async throws {
        do {
            _ = try await client.checkAuthenticationPassword(password: password)
        } catch {
            try mapTDLibError(error)
        }
    }

    public func getAuthState() -> String {
        return authState.rawValue
    }

    // MARK: - Chat Operations

    public func getChats(limit: Int = 50) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let result = try await client.getChats(chatList: nil, limit: limit)
        var chats: [[String: Any]] = []
        for chatId in result.chatIds {
            let chat = try await client.getChat(chatId: chatId)
            chats.append(chatToDict(chat))
        }
        return toJSON(chats)
    }

    public func getChat(chatId: Int64) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let chat = try await client.getChat(chatId: chatId)
        return toJSON(chatToDict(chat))
    }

    public func getChatHistory(
        chatId: Int64,
        limit: Int = 50,
        fromMessageId: Int64 = 0,
        maxMessages: Int? = nil,
        sinceDate: Foundation.Date? = nil,
        untilDate: Foundation.Date? = nil
    ) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }

        // Backward-compatible single-page path: when no bulk/filter params are given,
        // behave exactly as the prior implementation (one TDLib call, raw batch, no filtering).
        if maxMessages == nil && sinceDate == nil && untilDate == nil {
            let result = try await client.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: limit,
                offset: 0,
                onlyLocal: false
            )
            let messages = result.messages?.map { messageToDict($0) } ?? []
            return toJSON(messages)
        }

        // Single-page + date-filter path: one TDLib call, client-side date filter applied.
        if maxMessages == nil {
            let result = try await client.getChatHistory(
                chatId: chatId,
                fromMessageId: fromMessageId,
                limit: limit,
                offset: 0,
                onlyLocal: false
            )
            let rawBatch = result.messages?.map { messageToDict($0) } ?? []
            let filtered = filterMessagesByDate(rawBatch, since: sinceDate, until: untilDate)
            return toJSON(filtered)
        }

        // Bulk pagination path: iterate TDLib calls until termination condition met.
        // Hard cap: 10_000 messages. Prevents runaway pagination from accidentally or
        // maliciously large `max_messages` values (each page = one TDLib roundtrip).
        // Rationale: 10k covers near-all realistic use cases; larger exports should use
        // `dump_chat_to_markdown` with explicit date bounds instead of unbounded pagination.
        let requested = maxMessages!
        let cap = min(requested, 10_000)
        if requested > 10_000 {
            fputs(
                "warning: TDLibClient.getChatHistory capped maxMessages \(requested) → \(cap) (#6)\n",
                stderr
            )
        }
        let pageSize = min(max(limit, 1), 100)
        var accumulated: [[String: Any]] = []
        var nextFromId: Int64 = fromMessageId

        while accumulated.count < cap {
            let result = try await client.getChatHistory(
                chatId: chatId,
                fromMessageId: nextFromId,
                limit: pageSize,
                offset: 0,
                onlyLocal: false
            )
            let batch = result.messages?.map { messageToDict($0) } ?? []

            let step = accumulatePaginationBatch(
                current: accumulated,
                newBatch: batch,
                sinceDate: sinceDate,
                untilDate: untilDate,
                maxMessages: cap
            )
            accumulated = step.accumulated
            if !step.shouldContinue { break }
            guard let next = step.nextFromMessageId else { break }
            nextFromId = next
        }

        return toJSON(accumulated)
    }

    public func searchChats(query: String, limit: Int = 20) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let result = try await client.searchChats(limit: limit, query: query)
        var chats: [[String: Any]] = []
        for chatId in result.chatIds {
            let chat = try await client.getChat(chatId: chatId)
            chats.append(chatToDict(chat))
        }
        return toJSON(chats)
    }

    // MARK: - Message Operations

    public func sendMessage(chatId: Int64, text: String, replyToMessageId: Int64? = nil) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let content = InputMessageContent.inputMessageText(
            InputMessageText(
                clearDraft: true,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: text)
            )
        )
        var replyTo: InputMessageReplyTo? = nil
        if let replyId = replyToMessageId {
            replyTo = .inputMessageReplyToMessage(
                InputMessageReplyToMessage(checklistTaskId: 0, messageId: replyId, quote: nil)
            )
        }
        let result = try await client.sendMessage(
            chatId: chatId,
            inputMessageContent: content,
            options: nil,
            replyMarkup: nil,
            replyTo: replyTo,
            topicId: nil
        )
        return toJSON(messageToDict(result))
    }

    public func editMessage(chatId: Int64, messageId: Int64, text: String) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let content = InputMessageContent.inputMessageText(
            InputMessageText(
                clearDraft: true,
                linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: text)
            )
        )
        let result = try await client.editMessageText(
            chatId: chatId,
            inputMessageContent: content,
            messageId: messageId,
            replyMarkup: nil
        )
        return toJSON(messageToDict(result))
    }

    public func deleteMessages(chatId: Int64, messageIds: [Int64], revoke: Bool = true) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        _ = try await client.deleteMessages(chatId: chatId, messageIds: messageIds, revoke: revoke)
        return "{\"ok\": true}"
    }

    public func forwardMessages(chatId: Int64, fromChatId: Int64, messageIds: [Int64]) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let result = try await client.forwardMessages(
            chatId: chatId,
            fromChatId: fromChatId,
            messageIds: messageIds,
            options: nil,
            removeCaption: false,
            sendCopy: false,
            topicId: nil
        )
        let messages = result.messages?.map { messageToDict($0) } ?? []
        return toJSON(messages)
    }

    public func searchMessages(chatId: Int64, query: String, limit: Int = 50) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let result = try await client.searchChatMessages(
            chatId: chatId,
            filter: nil,
            fromMessageId: 0,
            limit: limit,
            offset: 0,
            query: query,
            senderId: nil,
            topicId: nil
        )
        let messages = result.messages.map { messageToDict($0) }
        return toJSON(messages)
    }

    // MARK: - Contact / User Operations

    public func getMe() async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let me = try await client.getMe()
        return toJSON(userToDict(me))
    }

    public func getUser(userId: Int64) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let user = try await client.getUser(userId: userId)
        return toJSON(userToDict(user))
    }

    public func getContacts() async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let result = try await client.getContacts()
        var users: [[String: Any]] = []
        for userId in result.userIds {
            let user = try await client.getUser(userId: userId)
            users.append(userToDict(user))
        }
        return toJSON(users)
    }

    // MARK: - Group Management

    public func getChatMembers(chatId: Int64, limit: Int = 200) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let chat = try await client.getChat(chatId: chatId)
        switch chat.type {
        case .chatTypeSupergroup(let sg):
            let result = try await client.getSupergroupMembers(
                filter: nil,
                limit: limit,
                offset: 0,
                supergroupId: sg.supergroupId
            )
            let members = result.members.map { memberToDict($0) }
            return toJSON(members)
        case .chatTypeBasicGroup(let bg):
            let info = try await client.getBasicGroupFullInfo(basicGroupId: bg.basicGroupId)
            let members = info.members.map { memberToDict($0) }
            return toJSON(members)
        default:
            return "[]"
        }
    }

    public func pinMessage(chatId: Int64, messageId: Int64, disableNotification: Bool = false) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        _ = try await client.pinChatMessage(
            chatId: chatId,
            disableNotification: disableNotification,
            messageId: messageId,
            onlyForSelf: false
        )
        return "{\"ok\": true}"
    }

    public func unpinMessage(chatId: Int64, messageId: Int64) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        _ = try await client.unpinChatMessage(chatId: chatId, messageId: messageId)
        return "{\"ok\": true}"
    }

    public func setChatTitle(chatId: Int64, title: String) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        _ = try await client.setChatTitle(chatId: chatId, title: title)
        return "{\"ok\": true}"
    }

    public func setChatDescription(chatId: Int64, description: String) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        _ = try await client.setChatDescription(chatId: chatId, description: description)
        return "{\"ok\": true}"
    }

    // MARK: - Group Creation

    public func createGroup(title: String, userIds: [Int64]) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        let created = try await client.createNewBasicGroupChat(
            messageAutoDeleteTime: 0,
            title: title,
            userIds: userIds
        )
        let chat = try await client.getChat(chatId: created.chatId)
        return toJSON(chatToDict(chat))
    }

    public func addChatMember(chatId: Int64, userId: Int64) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        _ = try await client.addChatMember(chatId: chatId, forwardLimit: 0, userId: userId)
        return "{\"ok\": true}"
    }

    // MARK: - Read State

    public func markAsRead(chatId: Int64, messageIds: [Int64]) async throws -> String {
        guard authState == .ready else { throw TDError.notAuthenticated }
        _ = try await client.viewMessages(
            chatId: chatId,
            forceRead: true,
            messageIds: messageIds,
            source: nil
        )
        return "{\"ok\": true}"
    }

    // MARK: - Logout

    public func logout() async throws -> String {
        _ = try await client.logOut()
        return "{\"ok\": true}"
    }

    // MARK: - Serialization Helpers

    private func chatToDict(_ chat: Chat) -> [String: Any] {
        var dict: [String: Any] = [
            "id": chat.id,
            "title": chat.title,
            "unread_count": chat.unreadCount,
        ]
        switch chat.type {
        case .chatTypePrivate: dict["type"] = "private"
        case .chatTypeBasicGroup: dict["type"] = "basic_group"
        case .chatTypeSupergroup(let sg):
            dict["type"] = sg.isChannel ? "channel" : "supergroup"
        case .chatTypeSecret: dict["type"] = "secret"
        }
        if let lastMsg = chat.lastMessage {
            dict["last_message"] = messageToDict(lastMsg)
        }
        return dict
    }

    private func messageToDict(_ msg: Message) -> [String: Any] {
        var dict: [String: Any] = [
            "id": msg.id,
            "chat_id": msg.chatId,
            "date": msg.date,
            "sender": senderToDict(msg.senderId),
            "is_outgoing": msg.isOutgoing,
        ]
        switch msg.content {
        case .messageText(let text):
            dict["type"] = "text"
            dict["text"] = text.text.text
        case .messagePhoto(let photo):
            dict["type"] = "photo"
            dict["caption"] = photo.caption.text
        case .messageVideo(let video):
            dict["type"] = "video"
            dict["caption"] = video.caption.text
        case .messageDocument(let doc):
            dict["type"] = "document"
            dict["file_name"] = doc.document.fileName
            dict["caption"] = doc.caption.text
        case .messageSticker(let sticker):
            dict["type"] = "sticker"
            dict["emoji"] = sticker.sticker.emoji
        case .messageVoiceNote:
            dict["type"] = "voice_note"
        case .messageVideoNote:
            dict["type"] = "video_note"
        case .messageAnimation:
            dict["type"] = "animation"
        case .messageLocation(let loc):
            dict["type"] = "location"
            dict["latitude"] = loc.location.latitude
            dict["longitude"] = loc.location.longitude
        case .messagePoll(let poll):
            dict["type"] = "poll"
            dict["question"] = poll.poll.question.text
        default:
            dict["type"] = "other"
        }
        return dict
    }

    private func senderToDict(_ sender: MessageSender) -> [String: Any] {
        switch sender {
        case .messageSenderUser(let user):
            return ["type": "user", "user_id": user.userId]
        case .messageSenderChat(let chat):
            return ["type": "chat", "chat_id": chat.chatId]
        }
    }

    private func userToDict(_ user: User) -> [String: Any] {
        [
            "id": user.id,
            "first_name": user.firstName,
            "last_name": user.lastName,
            "username": user.usernames?.activeUsernames.first ?? "",
            "phone_number": user.phoneNumber,
            "is_contact": user.isContact,
        ]
    }

    private func memberToDict(_ member: ChatMember) -> [String: Any] {
        var dict: [String: Any] = [
            "member_id": senderToDict(member.memberId),
            "joined_date": member.joinedChatDate,
        ]
        switch member.status {
        case .chatMemberStatusCreator: dict["status"] = "creator"
        case .chatMemberStatusAdministrator: dict["status"] = "administrator"
        case .chatMemberStatusMember: dict["status"] = "member"
        case .chatMemberStatusRestricted: dict["status"] = "restricted"
        case .chatMemberStatusBanned: dict["status"] = "banned"
        case .chatMemberStatusLeft: dict["status"] = "left"
        }
        return dict
    }

    private func toJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
