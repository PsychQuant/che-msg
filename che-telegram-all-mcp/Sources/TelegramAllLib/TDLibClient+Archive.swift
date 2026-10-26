import Foundation
import TDLibKit

/// Paging below a cursor (PsychQuant/che-msg#69).
internal enum ArchiveCursor {
    /// The messages of `page` older than `cursor`; all of them when `cursor` is 0 (newest).
    static func strictlyBelow(_ page: [[String: Any]], cursor: Int64) -> [[String: Any]] {
        guard cursor != 0 else { return page }
        return page.filter { (($0["id"] as? NSNumber)?.int64Value ?? .max) < cursor }
    }
}

/// TDLib as the archive's history source and media downloader (PsychQuant/che-msg#69).
extension TDLibClient: ArchiveHistorySource, ArchiveMediaDownloading {
    /// One page of `getChatHistory`, newest first, as message JSON objects. The chat is made
    /// known on every page, whatever the cursor (#71): `getChat` answers locally once TDLib
    /// knows the chat, and a caller may start below a message rather than at the newest.
    public func page(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [[String: Any]] {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        let result = try await tdlibCall { try await openClient.getChatHistory(
            chatId: chatId, fromMessageId: fromMessageId, limit: limit, offset: 0, onlyLocal: false) }
        // TDLib excludes the cursor at offset 0 (OrderedMessages::get_history); filtering keeps
        // the protocol's "strictly below" true even if that ever changes.
        return ArchiveCursor.strictlyBelow(result.messages?.map { messageToDict($0) } ?? [], cursor: fromMessageId)
    }

    /// Downloads a file completely (`synchronous: true` returns only when it is done) and
    /// returns its path in TDLib's cache.
    public func download(fileId: Int) async throws -> String {
        try requireOpen(authorized: true)
        let file = try await tdlibCall { try await openClient.downloadFile(
            fileId: fileId, limit: 0, offset: 0, priority: 1, synchronous: true) }
        guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else {
            throw TDError.tdlibError(code: 0, message: "download of file \(fileId) did not complete")
        }
        return file.local.path
    }

    public func message(chatId: Int64, messageId: Int64) async throws -> [String: Any] {
        try requireOpen(authorized: true)
        try await knownChat(chatId)
        return messageToDict(try await tdlibCall { try await openClient.getMessage(chatId: chatId, messageId: messageId) })
    }
}

/// TDLib's local cache as the archive's history source while another process holds TDLib.
/// It also collects what the source note needs: undecodable records and cache freshness.
public final class LocalCacheHistorySource: ArchiveHistorySource {
    private let reader: LocalCacheReading
    public private(set) var undecodableCount = 0
    public private(set) var freshness: [LocalTDLibReader.ChatFreshness] = []

    public init(reader: LocalCacheReading) { self.reader = reader }

    /// The reader pages strictly below `fromMessageId`, like TDLib (#73). The filter below
    /// only drops the cursor row if a source ever returns it; it does not make up for a
    /// reader that includes the cursor (a page holding only the cursor would come back empty).
    public func page(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [[String: Any]] {
        let result = try reader.getChatHistory(chatId: chatId, limit: limit,
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
