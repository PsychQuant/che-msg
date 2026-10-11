import Foundation
import TDLibKit

/// Runs a TDLibKit call for the archive, turning TDLibKit's own errors into
/// `TDError.tdlibError` so the archiver can read `FLOOD_WAIT_<n>` and the server reports
/// TDLib's message. A 406 message must not be shown, so it is dropped.
internal func archiveTDLibCall<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as TDLibKit.Error {
        throw TDLibClient.TDError.tdlibError(code: error.code, message: error.code == 406 ? "" : error.message)
    }
}

/// Paging below a cursor (PsychQuant/che-msg#69).
internal enum ArchiveCursor {
    /// The messages of `page` older than `cursor`; all of them when `cursor` is 0 (newest).
    static func strictlyBelow(_ page: [[String: Any]], cursor: Int64) -> [[String: Any]] {
        guard cursor != 0 else { return page }
        return page.filter { (($0["id"] as? NSNumber)?.int64Value ?? .max) < cursor }
    }
}

/// What a TDLib chat id names, by TDLib's id ranges (td/telegram/DialogId.cpp).
internal enum ArchiveChatID: Equatable {
    case user(Int64)
    case basicGroup(Int64)
    case supergroup(Int64)
    /// Secret chats and ids TDLib does not use: nothing to create them from.
    case other

    private static let maxUserId: Int64 = (1 << 40) - 1
    private static let maxBasicGroupId: Int64 = 999_999_999_999
    private static let zeroChannelId: Int64 = -1_000_000_000_000
    private static let maxChannelId: Int64 = 1_000_000_000_000 - (1 << 31)

    // Compared without negating `chatId`: `-Int64.min` traps and would end the server process.
    init(_ chatId: Int64) {
        if (1...Self.maxUserId).contains(chatId) {
            self = .user(chatId)
        } else if (-Self.maxBasicGroupId ... -1).contains(chatId) {
            self = .basicGroup(-chatId)
        } else if (Self.zeroChannelId - Self.maxChannelId ... Self.zeroChannelId - 1).contains(chatId) {
            self = .supergroup(Self.zeroChannelId - chatId)
        } else {
            self = .other
        }
    }
}

/// TDLib as the archive's history source and media downloader (PsychQuant/che-msg#69).
extension TDLibClient: ArchiveHistorySource, ArchiveMediaDownloading {
    /// One page of `getChatHistory`, newest first, as message JSON objects.
    public func page(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [[String: Any]] {
        guard getAuthState() == .ready else { throw TDError.notAuthenticated }
        if fromMessageId == 0 { try await loadChatForArchive(chatId) }
        let result = try await archiveTDLibCall {
            try await client.getChatHistory(chatId: chatId, fromMessageId: fromMessageId, limit: limit,
                                            offset: 0, onlyLocal: false)
        }
        // TDLib excludes the cursor at offset 0 (OrderedMessages::get_history); filtering keeps
        // the protocol's "strictly below" true even if that ever changes.
        return ArchiveCursor.strictlyBelow(result.messages?.map { messageToDict($0) } ?? [], cursor: fromMessageId)
    }

    /// Downloads a file completely (`synchronous: true` returns only when it is done) and
    /// returns its path in TDLib's cache.
    public func download(fileId: Int) async throws -> String {
        guard getAuthState() == .ready else { throw TDError.notAuthenticated }
        let file = try await archiveTDLibCall {
            try await client.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: 1, synchronous: true)
        }
        guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else {
            throw TDError.tdlibError(code: 0, message: "download of file \(fileId) did not complete")
        }
        return file.local.path
    }

    public func message(chatId: Int64, messageId: Int64) async throws -> [String: Any] {
        guard getAuthState() == .ready else { throw TDError.notAuthenticated }
        try await loadChatForArchive(chatId)
        return messageToDict(try await archiveTDLibCall { try await client.getMessage(chatId: chatId, messageId: messageId) })
    }
}

extension TDLibClient {
    /// Makes `chatId` known to this TDLib before reading it. `getChat` answers for chats TDLib
    /// has seen (its chat database keeps them), but a fresh login has seen few, and reading an
    /// unseen chat fails with "Chat not found"; such a chat is created from its id.
    func loadChatForArchive(_ chatId: Int64) async throws {
        do {
            _ = try await archiveTDLibCall { try await client.getChat(chatId: chatId) }
        } catch TDError.tdlibError(code: 400, message: _) {
            switch ArchiveChatID(chatId) {
            case .user(let userId):
                _ = try await archiveTDLibCall { try await client.createPrivateChat(force: false, userId: userId) }
            case .basicGroup(let groupId):
                _ = try await archiveTDLibCall { try await client.createBasicGroupChat(basicGroupId: groupId, force: false) }
            case .supergroup(let supergroupId):
                _ = try await archiveTDLibCall { try await client.createSupergroupChat(force: false, supergroupId: supergroupId) }
            case .other:
                throw TDError.tdlibError(code: 400, message: "Chat not found")
            }
        }
    }
}

/// TDLib's local cache as the archive's history source while another process holds TDLib.
/// It also collects what the source note needs: undecodable records and cache freshness.
public final class LocalCacheHistorySource: ArchiveHistorySource {
    private let reader: LocalCacheReading
    public private(set) var undecodableCount = 0
    public private(set) var freshness: [LocalTDLibReader.ChatFreshness] = []

    public init(reader: LocalCacheReading) { self.reader = reader }

    /// The reader's cursor includes `fromMessageId` itself (`message_id <= from`), while the
    /// protocol pages strictly below it like TDLib; ask for one more and drop the cursor
    /// message, or the end of the history would look like a source that repeats.
    public func page(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [[String: Any]] {
        let result = try reader.getChatHistory(chatId: chatId, limit: fromMessageId == 0 ? limit : limit + 1,
                                               fromMessageId: fromMessageId, maxMessages: nil,
                                               sinceDate: nil, untilDate: nil)
        undecodableCount += result.undecodableCount
        if freshness.isEmpty { freshness = result.freshness }
        guard let messages = try JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return ArchiveCursor.strictlyBelow(messages, cursor: fromMessageId)
    }
}

extension ChatArchiver {
    /// An archiver reading from TDLib: sender names resolved, media downloaded, bookmark
    /// safety decided by `isSynced`.
    public static func tdlib(_ client: TDLibClient, isSynced: @escaping () -> Bool) -> ChatArchiver {
        ChatArchiver(source: client, sourceKind: .tdlib,
                     resolveNames: { messages in
                         await resolveSenderNames(in: messages, lookup: { try await client.getUser(userId: $0) })
                     },
                     isSynced: isSynced, media: client)
    }

    /// An archiver reading TDLib's local cache: no name lookup, no downloads, never bookmark-safe.
    public static func localCache(_ source: LocalCacheHistorySource) -> ChatArchiver {
        ChatArchiver(source: source, sourceKind: .localCache, isSynced: { false })
    }
}
