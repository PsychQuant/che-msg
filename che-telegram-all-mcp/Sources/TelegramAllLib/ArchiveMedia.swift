import Foundation

/// Downloads media for the archive (PsychQuant/che-msg#69). The TDLib implementation uses
/// `downloadFile(synchronous: true)`; tests use a fake.
public protocol ArchiveMediaDownloading {
    /// Downloads TDLib file `fileId` and returns the local path of the finished download.
    func download(fileId: Int) async throws -> String
    /// One message by id, as JSON message object (for retries).
    func message(chatId: Int64, messageId: Int64) async throws -> [String: Any]
}

/// Where archive media lives and how it is named (telegram-chat-archive,
/// "Media download into the archive").
public enum ArchiveMedia {
    public enum Outcome: Equatable {
        case alreadyPresent
        case downloaded(path: String, size: Int64)
        case skipped(size: Int64)
        case failed
        case noFile
    }

    /// `<chat directory>/media/<message_id>/`.
    public static func directory(chatDir: URL, messageId: Int64) -> URL {
        chatDir.appendingPathComponent("media").appendingPathComponent(String(messageId))
    }

    /// The saved file's name: `photo.jpg` for photos, the original name when there is one
    /// (path separators removed, leading dots stripped), else the type plus the extension of
    /// the downloaded file.
    public static func fileName(type: String, name: String?, downloadedPath: String) -> String {
        if type == "photo" { return "photo.jpg" }
        if let name {
            let cleaned = String(name.filter { $0 != "/" && $0 != "\\" && $0 != "\0" }.drop(while: { $0 == "." }))
            if !cleaned.isEmpty { return cleaned }
        }
        let ext = URL(fileURLWithPath: downloadedPath).pathExtension
        return ext.isEmpty ? type : "\(type).\(ext)"
    }

    /// The message's file as `(id, size, name)`, or nil when it carries none.
    static func file(of message: [String: Any]) -> (id: Int, size: Int64, name: String?)? {
        guard let type = message["type"] as? String, ArchiveDayFile.fileTypes.contains(type),
              let file = message["file"] as? [String: Any],
              let id = (file["id"] as? NSNumber)?.intValue else { return nil }
        return (id, (file["size"] as? NSNumber)?.int64Value ?? 0, file["name"] as? String)
    }

    /// True when `directory` holds at least one regular, non-hidden file.
    static func holdsFile(_ directory: URL) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
        return names.contains { name in
            var isDir: ObjCBool = false
            return !name.hasPrefix(".") && fm.fileExists(atPath: directory.appendingPathComponent(name).path,
                                                          isDirectory: &isDir) && !isDir.boolValue
        }
    }

    /// Makes sure the message's media directory holds its file.
    public static func ensure(_ message: [String: Any], chatDir: URL, downloader: ArchiveMediaDownloading,
                              maxBytes: Int64?) async -> Outcome {
        guard let file = file(of: message), let messageId = (message["id"] as? NSNumber)?.int64Value,
              let type = message["type"] as? String else { return .noFile }
        let directory = directory(chatDir: chatDir, messageId: messageId)
        if holdsFile(directory) { return .alreadyPresent }
        if let maxBytes, file.size > maxBytes { return .skipped(size: file.size) }
        do {
            let downloaded = try await downloader.download(fileId: file.id)
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(fileName(type: type, name: file.name, downloadedPath: downloaded))
            // Copy through a temporary name so a half-copied file never looks complete.
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            try fm.copyItem(at: URL(fileURLWithPath: downloaded), to: temporary)
            try fm.moveItem(at: temporary, to: target)
            let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            return .downloaded(path: target.path, size: size)
        } catch {
            return .failed
        }
    }
}
