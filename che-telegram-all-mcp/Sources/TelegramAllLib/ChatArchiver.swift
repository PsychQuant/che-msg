import Foundation

/// Where the archiver reads messages from: TDLib, or the local cache while another
/// process holds TDLib (telegram-chat-archive).
public protocol ArchiveHistorySource {
    /// One page of messages, newest first, starting below `fromMessageId` (0 = newest),
    /// as JSON message objects (`id`, `date`, `sender`, `is_outgoing`, `type`, `text`/`caption`).
    func page(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [[String: Any]]
}

/// Writes a chat's messages into per-day Markdown files (PsychQuant/che-msg#69).
public struct ChatArchiver {
    public enum Source: String, Sendable { case tdlib, localCache = "local-cache" }

    public struct Request {
        public var chatId: Int64
        public var outputDir: URL
        public var afterMessageId: Int64?
        /// Start of `since_date` at the effective offset; ignored when `afterMessageId` is set.
        public var since: Date?
        public var utcOffset: String
        public var selfLabel: String
        public var maxMediaBytes: Int64?
        public var retryMediaMessageIds: [Int64]?

        public init(chatId: Int64, outputDir: URL, afterMessageId: Int64? = nil, since: Date? = nil,
                    utcOffset: String, selfLabel: String = "我", maxMediaBytes: Int64? = nil,
                    retryMediaMessageIds: [Int64]? = nil) {
            self.chatId = chatId
            self.outputDir = outputDir
            self.afterMessageId = afterMessageId
            self.since = since
            self.utcOffset = utcOffset
            self.selfLabel = selfLabel
            self.maxMediaBytes = maxMediaBytes
            self.retryMediaMessageIds = retryMediaMessageIds
        }
    }

    public struct SkippedMedia: Equatable {
        public var messageId: Int64
        public var size: Int64
        public init(messageId: Int64, size: Int64) { self.messageId = messageId; self.size = size }
    }

    public struct Result: Equatable {
        public var mediaDownloaded = 0
        public var mediaSkipped: [SkippedMedia] = []
        public var mediaFailedIds: [Int64] = []
        public var mediaPendingLocalCache = 0
        public var mediaRetriedIds: [Int64]?
        public var files: [String] = []
        public var newMessages = 0
        public var mediaMessages = 0
        public var newestMessageId: Int64?
        public var source: Source = .tdlib
        public var complete = false
        public var bookmarkSafe = false
        public var stoppedReason: String?
        public var retryAfterSeconds: Int?
        public var bookmarkUnsafeReason: String?

        /// The manifest returned to the caller: counts, ids and flags, never content.
        public func manifestJSON() -> String {
            var object: [String: Any] = [
                "files": files,
                "new_messages": newMessages,
                "media_messages": mediaMessages,
                "newest_message_id": newestMessageId.map { NSNumber(value: $0) } ?? NSNull(),
                "source": source.rawValue,
                "complete": complete,
                "bookmark_safe": bookmarkSafe,
            ]
            object["media_downloaded"] = mediaDownloaded
            object["media_skipped"] = mediaSkipped.map { ["message_id": NSNumber(value: $0.messageId),
                                                          "size": NSNumber(value: $0.size)] }
            object["media_failed_ids"] = mediaFailedIds.map { NSNumber(value: $0) }
            object["media_pending_local_cache"] = mediaPendingLocalCache
            if let mediaRetriedIds { object["media_retried_ids"] = mediaRetriedIds.map { NSNumber(value: $0) } }
            if let stoppedReason { object["stopped_reason"] = stoppedReason }
            if let retryAfterSeconds { object["retry_after_seconds"] = retryAfterSeconds }
            if let bookmarkUnsafeReason { object["bookmark_unsafe_reason"] = bookmarkUnsafeReason }
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return String(decoding: data, as: UTF8.self)
        }
    }

    public let source: ArchiveHistorySource
    public let sourceKind: Source
    /// Display names for user ids (TDLib path); nil leaves senders as `User <id>`.
    public let resolveNames: (([[String: Any]]) async -> [Int64: String])?
    /// True when TDLib reports `connectionStateReady`; asked once, at the end.
    public let isSynced: () -> Bool
    public let pageSize: Int
    /// Waits the given number of seconds (injected so tests do not sleep).
    public let sleep: (Int) async -> Void
    /// Downloads media on the TDLib path; nil on the local-cache path.
    public let media: ArchiveMediaDownloading?

    public init(source: ArchiveHistorySource, sourceKind: Source,
                resolveNames: (([[String: Any]]) async -> [Int64: String])? = nil,
                isSynced: @escaping () -> Bool, pageSize: Int = 100,
                sleep: @escaping (Int) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0) * 1_000_000_000) },
                media: ArchiveMediaDownloading? = nil) {
        self.source = source
        self.sourceKind = sourceKind
        self.resolveNames = resolveNames
        self.isSynced = isSynced
        self.pageSize = pageSize
        self.sleep = sleep
        self.media = media
    }

    public func archive(_ request: Request) async throws -> Result {
        var result = Result()
        result.source = sourceKind
        let offset = ArchiveDayFile.offsetSeconds(request.utcOffset) ?? 0
        let chatDir = request.outputDir.appendingPathComponent(String(request.chatId))
        var files: Set<String> = []
        var seen: Set<Int64> = []
        var fromMessageId: Int64 = 0

        // Paging stops at an empty page (the beginning of the history), at the first message
        // at or below the bound, or when a page brings nothing new (a source that repeats).
        var reachedBound = false
        while true {
            guard let page = try await fetchPage(request.chatId, fromMessageId, into: &result) else { break }
            if page.isEmpty { reachedBound = true; break }
            var inBound: [[String: Any]] = []
            var fresh = 0
            for message in page {
                guard let id = Self.id(of: message), seen.insert(id).inserted else { continue }
                fresh += 1
                if isBelowBound(message, id: id, request) { reachedBound = true } else { inBound.append(message) }
            }
            if !inBound.isEmpty {
                try await write(inBound, request, chatDir: chatDir, offset: offset, into: &result, files: &files)
            }
            guard !reachedBound, fresh > 0, let lowest = page.compactMap(Self.id(of:)).min() else { break }
            fromMessageId = lowest
        }
        try await retryMedia(request, chatDir: chatDir, into: &result)
        result.files = files.sorted()
        result.complete = reachedBound && result.stoppedReason == nil
        if !reachedBound && result.stoppedReason == nil { result.stoppedReason = "no-progress" }
        if !reachedBound {
            result.bookmarkUnsafeReason = "incomplete"
        } else if sourceKind == .localCache {
            result.bookmarkUnsafeReason = "local-cache"
        } else if !isSynced() {
            result.bookmarkUnsafeReason = "not-synced"
        }
        result.bookmarkSafe = result.bookmarkUnsafeReason == nil
        return result
    }

    /// The longest `FLOOD_WAIT` the archiver sleeps through before retrying once.
    public static let maxFloodWaitSeconds = 60

    /// One page, sleeping through a short `FLOOD_WAIT` once. Returns nil (with the stop
    /// recorded in `result`) when the wait is long or repeats; other errors are thrown.
    private func fetchPage(_ chatId: Int64, _ fromMessageId: Int64,
                           into result: inout Result) async throws -> [[String: Any]]? {
        var retried = false
        while true {
            do {
                return try await source.page(chatId: chatId, fromMessageId: fromMessageId, limit: pageSize)
            } catch {
                guard let seconds = Self.floodWaitSeconds(error) else { throw error }
                if !retried && seconds <= Self.maxFloodWaitSeconds {
                    retried = true
                    await sleep(seconds)
                    continue
                }
                result.stoppedReason = "flood_wait"
                result.retryAfterSeconds = seconds
                return nil
            }
        }
    }

    /// `n` from a TDLib `FLOOD_WAIT_<n>` error, or nil for any other error.
    static func floodWaitSeconds(_ error: Error) -> Int? {
        guard case TDLibClient.TDError.tdlibError(_, let message) = error,
              let range = message.range(of: "FLOOD_WAIT_") else { return nil }
        return Int(message[range.upperBound...].prefix { $0.isNumber })
    }

    private func isBelowBound(_ message: [String: Any], id: Int64, _ request: Request) -> Bool {
        if let after = request.afterMessageId { return id <= after }
        if let since = request.since, let date = messageDate(message) { return date < since }
        return false
    }

    private func write(_ messages: [[String: Any]], _ request: Request, chatDir: URL, offset: Int,
                       into result: inout Result, files: inout Set<String>) async throws {
        let names = await resolveNames?(messages) ?? [:]
        var byDay: [String: [ArchiveMessage]] = [:]
        var media: [Int64: Bool] = [:]
        for message in messages {
            guard let id = Self.id(of: message), let date = messageDate(message) else { continue }
            let type = (message["type"] as? String) ?? "other"
            let body = ArchiveDayFile.body(type: type, text: message["text"] as? String,
                                           caption: message["caption"] as? String, messageId: id)
            let archived = ArchiveMessage(id: id, date: date, sender: senderLabel(message, names, request.selfLabel),
                                          body: body)
            byDay[ArchiveDayFile.dayKey(for: date, offsetSeconds: offset), default: []].append(archived)
            media[id] = type != "text"
            result.newestMessageId = max(result.newestMessageId ?? id, id)
        }
        await ensureMedia(messages, chatDir: chatDir, maxBytes: request.maxMediaBytes, into: &result)
        for (day, dayMessages) in byDay {
            let added = try ArchiveDayFile.write(directory: chatDir, chatId: request.chatId, day: day,
                                                 utcOffset: request.utcOffset, messages: dayMessages)
            result.newMessages += added.count
            result.mediaMessages += added.filter { media[$0] == true }.count
            files.insert("\(request.chatId)/\(day).md")
        }
    }

    /// Downloads (TDLib path) or counts as pending (local cache) the media of `messages`.
    private func ensureMedia(_ messages: [[String: Any]], chatDir: URL, maxBytes: Int64?,
                             into result: inout Result) async {
        for message in messages where ArchiveMedia.file(of: message) != nil {
            guard let media else {
                if let id = Self.id(of: message),
                   !ArchiveMedia.holdsFile(ArchiveMedia.directory(chatDir: chatDir, messageId: id)) {
                    result.mediaPendingLocalCache += 1
                }
                continue
            }
            switch await ArchiveMedia.ensure(message, chatDir: chatDir, downloader: media, maxBytes: maxBytes) {
            case .downloaded: result.mediaDownloaded += 1
            case .skipped(let size): result.mediaSkipped.append(.init(messageId: Self.id(of: message) ?? 0, size: size))
            case .failed: if let id = Self.id(of: message) { result.mediaFailedIds.append(id) }
            case .alreadyPresent, .noFile: break
            }
        }
    }

    /// Retries the media of `retryMediaMessageIds` by fetching each message by id.
    private func retryMedia(_ request: Request, chatDir: URL, into result: inout Result) async throws {
        guard let ids = request.retryMediaMessageIds, !ids.isEmpty else { return }
        guard let media else { result.mediaFailedIds.append(contentsOf: ids); return }
        var retried: [Int64] = []
        for id in ids {
            guard let message = try? await media.message(chatId: request.chatId, messageId: id) else {
                result.mediaFailedIds.append(id); continue
            }
            switch await ArchiveMedia.ensure(message, chatDir: chatDir, downloader: media, maxBytes: request.maxMediaBytes) {
            case .downloaded:
                result.mediaDownloaded += 1
                retried.append(id)
            case .alreadyPresent:
                retried.append(id)
            case .skipped(let size):
                result.mediaSkipped.append(.init(messageId: id, size: size))
            case .failed, .noFile:
                result.mediaFailedIds.append(id)
            }
        }
        result.mediaRetriedIds = retried
    }

    private func senderLabel(_ message: [String: Any], _ names: [Int64: String], _ selfLabel: String) -> String {
        if (message["is_outgoing"] as? Bool) == true { return selfLabel }
        guard let sender = message["sender"] as? [String: Any] else { return "Unknown" }
        if let uid = userIdFromSender(sender) { return names[uid] ?? "User \(uid)" }
        if let chat = sender["chat_id"] as? NSNumber { return "Chat \(chat.int64Value)" }
        return "Unknown"
    }

    static func id(of message: [String: Any]) -> Int64? {
        (message["id"] as? NSNumber)?.int64Value
    }
}
