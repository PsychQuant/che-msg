import Foundation

/// Answers the five reading tools from TDLib's local cache without running
/// TDLib (PsychQuant/che-msg#58). Each call opens the cache read-only for its
/// own duration. The JSON uses `TDLibClient`'s field names; a field the reader
/// cannot determine is omitted rather than filled in.
public struct LocalTDLibReader {
    /// How recent the cache is for one chat a result covers.
    public struct ChatFreshness: Equatable {
        public enum Newest: Equatable {
            /// The cache holds no message for the chat.
            case noMessages
            /// Unix date of the newest cached message whose date could be decoded.
            case date(Int32)
            /// The cache holds messages, but none with a decodable date.
            case undated
        }

        public let chatId: Int64
        public let newest: Newest

        public init(chatId: Int64, newest: Newest) {
            self.chatId = chatId
            self.newest = newest
        }
    }

    public struct Result {
        public init(json: String, undecodableCount: Int, freshness: [ChatFreshness]) {
            self.json = json
            self.undecodableCount = undecodableCount
            self.freshness = freshness
        }

        /// The tool result, formatted as `TDLibClient` formats it.
        public let json: String
        /// Chats and messages the result covers (or a search scanned) whose
        /// data could not be decoded.
        public let undecodableCount: Int
        /// One entry per chat the result covers, in result order.
        public let freshness: [ChatFreshness]
    }

    /// The most messages `getChatHistory` returns with `maxMessages`, as in
    /// `TDLibClient.getChatHistory`.
    static let maxHistoryMessages = 10_000

    public let directory: String

    public init(directory: String) {
        self.directory = directory
    }

    // MARK: - Chats

    public func getChats(limit: Int = 50) throws -> Result {
        let cache = try TDLibCacheDatabase(directory: directory)
        let chats = Array(try cache.chats(mainListOnly: true).prefix(max(limit, 0)))
        return try chatResult(chats, in: cache, undecodableScanned: chats.filter { $0.type == .unknown }.count)
    }

    /// Chats whose title contains `query`, ignoring case, among every chat the
    /// cache knows (archived ones included). An empty query lists the main list.
    public func searchChats(query: String, limit: Int = 20) throws -> Result {
        let cache = try TDLibCacheDatabase(directory: directory)
        let candidates = try cache.chats(mainListOnly: query.isEmpty)
        let matches = query.isEmpty
            ? candidates
            : candidates.filter { $0.title?.range(of: query, options: .caseInsensitive) != nil }
        return try chatResult(Array(matches.prefix(max(limit, 0))), in: cache,
                              undecodableScanned: candidates.filter { $0.type == .unknown }.count)
    }

    private func chatResult(_ chats: [LocalChat], in cache: TDLibCacheDatabase, undecodableScanned: Int) throws -> Result {
        var undecodable = undecodableScanned
        var objects: [[String: Any]] = []
        var freshness: [ChatFreshness] = []
        for chat in chats {
            var object: [String: Any] = ["id": chat.id, "type": chat.type.rawValue]
            if let title = chat.title { object["title"] = title }
            if let last = try cache.newestMessage(chatId: chat.id) {
                object["last_message"] = last.dictionary
                if last.type == .unknown { undecodable += 1 }
            }
            objects.append(object)
            freshness.append(try cache.freshness(chatId: chat.id))
        }
        return Result(json: Self.json(objects), undecodableCount: undecodable, freshness: freshness)
    }

    // MARK: - Messages

    /// The three paths of `TDLibClient.getChatHistory`: one page of `limit`
    /// messages; one page filtered by date; or, with `maxMessages`, up to that
    /// many messages (at most 10,000) within the date range.
    public func getChatHistory(chatId: Int64, limit: Int = 50, fromMessageId: Int64 = 0, maxMessages: Int? = nil,
                               sinceDate: Date? = nil, untilDate: Date? = nil) throws -> Result {
        let cache = try TDLibCacheDatabase(directory: directory)
        let messages = try history(in: cache, chatId: chatId, limit: limit, fromMessageId: fromMessageId,
                                   maxMessages: maxMessages, sinceDate: sinceDate, untilDate: untilDate)
        return try messageResult(messages, chatId: chatId, in: cache,
                                 undecodable: messages.filter { $0.type == .unknown }.count)
    }

    /// Messages whose decoded text contains `query`, ignoring case, newest
    /// first. Messages that could not be decoded are counted, since they may
    /// contain the query.
    public func searchMessages(chatId: Int64, query: String, limit: Int = 50) throws -> Result {
        let cache = try TDLibCacheDatabase(directory: directory)
        let wanted = max(limit, 0)
        var found: [LocalMessage] = []
        var undecodable = 0
        if wanted > 0 {
            try cache.forEachMessage(chatId: chatId) { message in
                if message.type == .unknown { undecodable += 1 }
                if query.isEmpty || message.text?.range(of: query, options: .caseInsensitive) != nil {
                    found.append(message)
                }
                return found.count < wanted
            }
        }
        return try messageResult(found, chatId: chatId, in: cache, undecodable: undecodable)
    }

    /// Writes the chat to `outputPath` in the `telegram-history-export` format,
    /// using the same rendering as `MarkdownExporter`, and returns its summary.
    public func dumpChatToMarkdown(chatId: Int64, outputPath: String, maxMessages: Int = 5000, sinceDate: Date? = nil,
                                   untilDate: Date? = nil, selfLabel: String = "我") async throws -> Result {
        try validateOutputPath(outputPath)
        let cache = try TDLibCacheDatabase(directory: directory)
        let chat = try cache.chat(id: chatId)
        let messages = try history(in: cache, chatId: chatId, limit: 100, fromMessageId: 0,
                                   maxMessages: maxMessages, sinceDate: sinceDate, untilDate: untilDate)
        let dictionaries = messages.map(\.dictionary)
        var users: [Int64: String] = [:]
        for case .user(let userId) in messages.compactMap(\.sender) where users[userId] == nil {
            if let name = try cache.userName(id: userId) {
                users[userId] = Self.json(["first_name": name.first, "last_name": name.last])
            }
        }
        let senderNames = await resolveSenderNames(in: dictionaries) { userId in
            guard let user = users[userId] else { throw LocalReaderError.databaseUnreadable("no record for user \(userId)") }
            return user
        }
        let markdown = formatMarkdown(messages: dictionaries, senderNames: senderNames, selfLabel: selfLabel,
                                      chatTitle: chat.title ?? "Chat \(chatId)", chatId: chatId,
                                      sinceDate: sinceDate, untilDate: untilDate, exportedAt: Date())
        try markdown.write(toFile: outputPath, atomically: true, encoding: .utf8)
        let summary = buildSummaryJSON(path: outputPath, messages: dictionaries, senderNames: senderNames,
                                       sinceDate: sinceDate, untilDate: untilDate, isSecretChat: chat.type == .secret)
        let undecodable = messages.filter { $0.type == .unknown }.count + (chat.type == .unknown ? 1 : 0)
        return Result(json: summary, undecodableCount: undecodable, freshness: [try cache.freshness(chatId: chatId)])
    }

    private func history(in cache: TDLibCacheDatabase, chatId: Int64, limit: Int, fromMessageId: Int64,
                         maxMessages: Int?, sinceDate: Date?, untilDate: Date?) throws -> [LocalMessage] {
        let upTo = fromMessageId == 0 ? Int64.max : fromMessageId
        guard let maxMessages else {
            var page: [LocalMessage] = []
            let pageSize = max(limit, 0)
            if pageSize > 0 {
                try cache.forEachMessage(chatId: chatId, maxMessageId: upTo) { page.append($0); return page.count < pageSize }
            }
            return page.filter { Self.isWithin($0, since: sinceDate, until: untilDate) }
        }
        let cap = min(max(maxMessages, 0), Self.maxHistoryMessages)
        if maxMessages > Self.maxHistoryMessages {
            fputs("warning: LocalTDLibReader.getChatHistory capped maxMessages \(maxMessages) -> \(cap) (#6)\n", stderr)
        }
        var accumulated: [LocalMessage] = []
        if cap > 0 {
            try cache.forEachMessage(chatId: chatId, maxMessageId: upTo) { message in
                if let date = message.date, let sinceDate, Self.date(date) < sinceDate { return false }
                if Self.isWithin(message, since: sinceDate, until: untilDate) { accumulated.append(message) }
                return accumulated.count < cap
            }
        }
        return accumulated
    }

    private func messageResult(_ messages: [LocalMessage], chatId: Int64, in cache: TDLibCacheDatabase,
                               undecodable: Int) throws -> Result {
        Result(json: Self.json(messages.map(\.dictionary)), undecodableCount: undecodable,
               freshness: [try cache.freshness(chatId: chatId)])
    }

    /// `filterMessagesByDate`: both bounds inclusive, a message without a date kept.
    private static func isWithin(_ message: LocalMessage, since: Date?, until: Date?) -> Bool {
        guard let unix = message.date else { return true }
        let date = date(unix)
        if let since, date < since { return false }
        if let until, date > until { return false }
        return true
    }

    private static func date(_ unix: Int32) -> Date { Date(timeIntervalSince1970: TimeInterval(unix)) }

    /// `TDLibClient.toJSON`: pretty-printed with sorted keys.
    static func json(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// The five reading tools answered from TDLib's local cache; the server talks
/// to the reader through this so tests can substitute one.
public protocol LocalCacheReading {
    func getChats(limit: Int) throws -> LocalTDLibReader.Result
    func searchChats(query: String, limit: Int) throws -> LocalTDLibReader.Result
    func getChatHistory(chatId: Int64, limit: Int, fromMessageId: Int64, maxMessages: Int?,
                        sinceDate: Date?, untilDate: Date?) throws -> LocalTDLibReader.Result
    func searchMessages(chatId: Int64, query: String, limit: Int) throws -> LocalTDLibReader.Result
    func dumpChatToMarkdown(chatId: Int64, outputPath: String, maxMessages: Int, sinceDate: Date?,
                            untilDate: Date?, selfLabel: String) async throws -> LocalTDLibReader.Result
}

extension LocalTDLibReader: LocalCacheReading {}
