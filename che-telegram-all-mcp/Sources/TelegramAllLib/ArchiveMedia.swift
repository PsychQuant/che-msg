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
            // By scalar, not Character: "/" followed by a combining mark is one Character.
            var scalars = String.UnicodeScalarView(name.unicodeScalars.filter {
                $0 != "/" && $0 != "\\" && !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.newlines.contains($0)
            })
            while scalars.first == "." { scalars.removeFirst() }
            let cleaned = capped(String(scalars))
            if !cleaned.isEmpty { return cleaned }
        }
        let ext = URL(fileURLWithPath: downloadedPath).pathExtension
        return capped(ext.isEmpty ? type : "\(type).\(ext)")
    }

    /// `name` shortened to the 255 bytes a file name may have, keeping a short extension.
    static func capped(_ name: String, limit: Int = 255) -> String {
        guard name.utf8.count > limit else { return name }
        let ext = (name as NSString).pathExtension
        let keep = ext.isEmpty || ext.utf8.count > 16 ? "" : "." + ext
        var stem = String.UnicodeScalarView(name.unicodeScalars.dropLast(keep.unicodeScalars.count))
        while String(stem).utf8.count + keep.utf8.count > limit { stem.removeLast() }
        return String(stem) + keep
    }

    /// The message's file as `(id, size, name)`, or nil when it carries none.
    static func file(of message: [String: Any]) -> (id: Int, size: Int64, name: String?)? {
        guard let type = message["type"] as? String, ArchiveDayFile.fileTypes.contains(type),
              let file = message["file"] as? [String: Any],
              let id = (file["id"] as? NSNumber)?.intValue else { return nil }
        return (id, (file["size"] as? NSNumber)?.int64Value ?? 0, file["name"] as? String)
    }

    /// True when `directory` holds at least one regular, non-hidden file.
    static func holdsFile(_ directory: URL) -> Bool { existingFile(directory) != nil }

    /// The first regular, non-hidden file in `directory` by name, or nil. A symbolic link is
    /// not a downloaded file (`attributesOfItem` describes the link, not its target).
    static func existingFile(_ directory: URL) -> URL? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return nil }
        return names.sorted().lazy.map { directory.appendingPathComponent($0) }.first { url in
            !url.lastPathComponent.hasPrefix(".")
                && (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
        }
    }

    public enum DownloadError: Error, LocalizedError, Equatable {
        case noFile(messageId: Int64)
        case failed(messageId: Int64)

        public var errorDescription: String? {
            switch self {
            case .noFile(let id): return "message \(id) has no media file to download"
            case .failed(let id): return "downloading the media of message \(id) failed"
            }
        }
    }

    /// Downloads one message's media into `<outputDir>/<chatId>/media/<messageId>/` and returns
    /// `{"message_id","type","path","size"}` as JSON — never the message text or caption.
    public static func downloadOne(chatId: Int64, messageId: Int64, outputDir: URL,
                                   downloader: ArchiveMediaDownloading) async throws -> String {
        let message = try await downloader.message(chatId: chatId, messageId: messageId)
        guard let type = message["type"] as? String, file(of: message) != nil else {
            throw DownloadError.noFile(messageId: messageId)
        }
        let chatDir = outputDir.appendingPathComponent(String(chatId))
        let saved: URL
        switch await ensure(message, chatDir: chatDir, downloader: downloader, maxBytes: nil) {
        case .downloaded(let path, _):
            saved = URL(fileURLWithPath: path)
        case .alreadyPresent:
            guard let existing = existingFile(directory(chatDir: chatDir, messageId: messageId)) else {
                throw DownloadError.failed(messageId: messageId)
            }
            saved = existing
        case .failed, .skipped:
            throw DownloadError.failed(messageId: messageId)
        case .noFile:
            throw DownloadError.noFile(messageId: messageId)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: saved.path)[.size] as? NSNumber)?.int64Value ?? 0
        let object: [String: Any] = ["message_id": NSNumber(value: messageId), "type": type,
                                     "path": saved.path, "size": NSNumber(value: size)]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Makes sure the message's media directory holds its file.
    public static func ensure(_ message: [String: Any], chatDir: URL, downloader: ArchiveMediaDownloading,
                              maxBytes: Int64?) async -> Outcome {
        guard let file = file(of: message), let messageId = (message["id"] as? NSNumber)?.int64Value,
              let type = message["type"] as? String else { return .noFile }
        let directory = directory(chatDir: chatDir, messageId: messageId)
        if holdsFile(directory) { return .alreadyPresent }
        if let maxBytes, file.size > maxBytes { return .skipped(size: file.size) }
        let fm = FileManager.default
        // Copy through a temporary name so a half-copied file never looks complete.
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            let downloaded = try await downloader.download(fileId: file.id)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let target = directory.appendingPathComponent(fileName(type: type, name: file.name, downloadedPath: downloaded))
            try fm.copyItem(at: URL(fileURLWithPath: downloaded), to: temporary)
            // Archives hold other people's files: owner-only, whatever mode TDLib's cache had.
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            // A symbolic link where the file belongs is not a download (existingFile skips it);
            // remove the link itself, never what it points to.
            if (try? fm.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
                try fm.removeItem(at: target)
            }
            try fm.moveItem(at: temporary, to: target)
            let size = (try? fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            return .downloaded(path: target.path, size: size)
        } catch {
            try? fm.removeItem(at: temporary)
            return .failed
        }
    }
}
