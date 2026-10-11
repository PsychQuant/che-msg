import Foundation
import TDLibKit

/// TDLib as the archive's history source and media downloader (PsychQuant/che-msg#69).
extension TDLibClient: ArchiveHistorySource, ArchiveMediaDownloading {
    /// One page of `getChatHistory`, newest first, as message JSON objects.
    public func page(chatId: Int64, fromMessageId: Int64, limit: Int) async throws -> [[String: Any]] {
        guard getAuthState() == .ready else { throw TDError.notAuthenticated }
        let result = try await client.getChatHistory(chatId: chatId, fromMessageId: fromMessageId, limit: limit,
                                                     offset: 0, onlyLocal: false)
        return result.messages?.map { messageToDict($0) } ?? []
    }

    /// Downloads a file completely (`synchronous: true` returns only when it is done) and
    /// returns its path in TDLib's cache.
    public func download(fileId: Int) async throws -> String {
        guard getAuthState() == .ready else { throw TDError.notAuthenticated }
        let file = try await client.downloadFile(fileId: fileId, limit: 0, offset: 0, priority: 1, synchronous: true)
        guard file.local.isDownloadingCompleted, !file.local.path.isEmpty else {
            throw TDError.tdlibError(code: 0, message: "download of file \(fileId) did not complete")
        }
        return file.local.path
    }

    public func message(chatId: Int64, messageId: Int64) async throws -> [String: Any] {
        guard getAuthState() == .ready else { throw TDError.notAuthenticated }
        return messageToDict(try await client.getMessage(chatId: chatId, messageId: messageId))
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
        guard fromMessageId != 0 else { return messages }
        return messages.filter { (($0["id"] as? NSNumber)?.int64Value ?? .max) < fromMessageId }
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
