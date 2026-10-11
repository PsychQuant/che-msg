import XCTest
@testable import TelegramAllLib

/// telegram-chat-archive media download and retry (PsychQuant/che-msg#69, task 6.3).
/// Synthetic files only.
final class ArchiveMediaTests: XCTestCase {
    /// Writes a small file per download into a scratch "TDLib cache" and returns its path.
    final class FakeDownloader: ArchiveMediaDownloading, @unchecked Sendable {
        let cache: URL
        var failing: Set<Int> = []
        var downloads: [Int] = []
        var messages: [Int64: [String: Any]] = [:]
        var ext = "jpg"
        init(cache: URL) { self.cache = cache }
        func download(fileId: Int) async throws -> String {
            downloads.append(fileId)
            if failing.contains(fileId) { throw NSError(domain: "fake", code: 1) }
            let path = cache.appendingPathComponent("file_\(fileId).\(ext)")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data("bytes-\(fileId)".utf8).write(to: path)
            return path.path
        }
        func message(chatId: Int64, messageId: Int64) async throws -> [String: Any] {
            guard let m = messages[messageId] else { throw NSError(domain: "fake", code: 2) }
            return m
        }
    }

    private func scratch() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    static func media(_ id: Int64, _ minutes: Int, type: String = "photo", fileId: Int, size: Int64 = 100,
                      name: String? = nil, caption: String? = nil) -> [String: Any] {
        var m = ChatArchiverTests.msg(id, minutes, type: type, caption: caption)
        var file: [String: Any] = ["id": fileId, "size": NSNumber(value: size)]
        if let name { file["name"] = name }
        m["file"] = file
        return m
    }

    // MARK: - File names

    func testFileNames() {
        XCTAssertEqual(ArchiveMedia.fileName(type: "photo", name: nil, downloadedPath: "/c/x.jpg"), "photo.jpg")
        XCTAssertEqual(ArchiveMedia.fileName(type: "document", name: "report.pdf", downloadedPath: "/c/x"), "report.pdf")
        XCTAssertEqual(ArchiveMedia.fileName(type: "document", name: "../../etc/passwd", downloadedPath: "/c/x"),
                       "etcpasswd")
        XCTAssertEqual(ArchiveMedia.fileName(type: "document", name: ".hidden", downloadedPath: "/c/x"), "hidden")
        XCTAssertEqual(ArchiveMedia.fileName(type: "voice_note", name: nil, downloadedPath: "/c/voice/file_7.oga"),
                       "voice_note.oga")
        XCTAssertEqual(ArchiveMedia.fileName(type: "sticker", name: "", downloadedPath: "/c/s/file_8.webp"), "sticker.webp")
        XCTAssertEqual(ArchiveMedia.fileName(type: "video_note", name: "///", downloadedPath: "/c/v/noext"), "video_note")
    }

    // MARK: - ensure

    // Scenario "Photo downloaded once".
    func testPhotoDownloadedOnce() async throws {
        let root = scratch(), chatDir = root.appendingPathComponent("777")
        let downloader = FakeDownloader(cache: root.appendingPathComponent("cache"))
        let first = await ArchiveMedia.ensure(Self.media(5_243_904, 1, fileId: 12), chatDir: chatDir,
                                              downloader: downloader, maxBytes: nil)
        let saved = chatDir.appendingPathComponent("media/5243904/photo.jpg")
        XCTAssertEqual(first, .downloaded(path: saved.path, size: 8))  // "bytes-12"
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
        let second = await ArchiveMedia.ensure(Self.media(5_243_904, 1, fileId: 12), chatDir: chatDir,
                                               downloader: downloader, maxBytes: nil)
        XCTAssertEqual(second, .alreadyPresent)
        XCTAssertEqual(downloader.downloads, [12])
    }

    // Scenario "File over the size cap".
    func testFileOverTheCapIsSkipped() async throws {
        let root = scratch()
        let downloader = FakeDownloader(cache: root.appendingPathComponent("cache"))
        let outcome = await ArchiveMedia.ensure(Self.media(7000, 1, type: "video", fileId: 70, size: 52_000_000),
                                                chatDir: root.appendingPathComponent("777"), downloader: downloader,
                                                maxBytes: 10_000_000)
        XCTAssertEqual(outcome, .skipped(size: 52_000_000))
        XCTAssertEqual(downloader.downloads, [])
    }

    func testFailureAndNoFile() async throws {
        let root = scratch()
        let downloader = FakeDownloader(cache: root.appendingPathComponent("cache"))
        downloader.failing = [71]
        let failed = await ArchiveMedia.ensure(Self.media(7100, 1, fileId: 71), chatDir: root.appendingPathComponent("777"),
                                               downloader: downloader, maxBytes: nil)
        XCTAssertEqual(failed, .failed)
        let text = await ArchiveMedia.ensure(ChatArchiverTests.msg(7200, 1), chatDir: root.appendingPathComponent("777"),
                                             downloader: downloader, maxBytes: nil)
        XCTAssertEqual(text, .noFile)
    }

    // MARK: - Archiver integration

    private func archiver(_ messages: [[String: Any]], downloader: FakeDownloader?, kind: ChatArchiver.Source = .tdlib)
        -> ChatArchiver {
        ChatArchiver(source: ChatArchiverTests.FakeSource(messages), sourceKind: kind, isSynced: { true },
                     pageSize: 10, media: downloader)
    }

    func testArchiveDownloadsMediaAndReportsCounts() async throws {
        let root = scratch(), out = root.appendingPathComponent("out")
        let downloader = FakeDownloader(cache: root.appendingPathComponent("cache"))
        downloader.failing = [71]
        let result = try await archiver([
            Self.media(7200, 4, type: "video", fileId: 72, size: 52_000_000),
            Self.media(7100, 3, fileId: 71),
            Self.media(7000, 2, type: "document", fileId: 70, name: "a.pdf", caption: "secret caption"),
            ChatArchiverTests.msg(6900, 1),
        ], downloader: downloader).archive(.init(chatId: 777, outputDir: out, utcOffset: "+08:00",
                                                 maxMediaBytes: 10_000_000))
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("777/media/7000/a.pdf").path))
        XCTAssertEqual(result.mediaDownloaded, 1)
        XCTAssertEqual(result.mediaSkipped, [ChatArchiver.SkippedMedia(messageId: 7200, size: 52_000_000)])
        XCTAssertEqual(result.mediaFailedIds, [7100])
        XCTAssertTrue(result.bookmarkSafe, "media failures do not affect the bookmark")
        let json = result.manifestJSON()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["media_downloaded"] as? Int, 1)
        XCTAssertEqual(object["media_failed_ids"] as? [Int], [7100])
        XCTAssertEqual(object["media_pending_local_cache"] as? Int, 0)
        let skipped = try XCTUnwrap(object["media_skipped"] as? [[String: Any]])
        XCTAssertEqual(skipped.first?["message_id"] as? Int, 7200)
        XCTAssertEqual(skipped.first?["size"] as? Int, 52_000_000)
        XCTAssertNil(object["media_retried_ids"])
        for secret in ["a.pdf", "secret caption"] { XCTAssertFalse(json.contains(secret), secret) }
    }

    func testRetryByMessageId() async throws {
        let root = scratch(), out = root.appendingPathComponent("out")
        let downloader = FakeDownloader(cache: root.appendingPathComponent("cache"))
        downloader.messages = [7100: Self.media(7100, 3, fileId: 71), 7300: Self.media(7300, 5, fileId: 73)]
        downloader.failing = [73]
        let result = try await archiver([], downloader: downloader).archive(
            .init(chatId: 777, outputDir: out, afterMessageId: 9000, utcOffset: "+08:00", retryMediaMessageIds: [7100, 7300]))
        XCTAssertEqual(result.mediaRetriedIds, [7100])
        XCTAssertEqual(result.mediaFailedIds, [7300])
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("777/media/7100/photo.jpg").path))
        XCTAssertEqual(result.newMessages, 0, "retries write no day files")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.manifestJSON().utf8)) as? [String: Any])
        XCTAssertEqual(object["media_retried_ids"] as? [Int], [7100])
    }

    func testLocalCacheCountsPendingMediaAndKeepsRetryIds() async throws {
        let root = scratch(), out = root.appendingPathComponent("out")
        let result = try await archiver([Self.media(7100, 3, fileId: 71), ChatArchiverTests.msg(6900, 1)],
                                        downloader: nil, kind: .localCache)
            .archive(.init(chatId: 777, outputDir: out, utcOffset: "+08:00", retryMediaMessageIds: [5000]))
        XCTAssertEqual(result.mediaPendingLocalCache, 1)
        XCTAssertEqual(result.mediaDownloaded, 0)
        XCTAssertEqual(result.mediaFailedIds, [5000])
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("777/media").path))
    }
}
