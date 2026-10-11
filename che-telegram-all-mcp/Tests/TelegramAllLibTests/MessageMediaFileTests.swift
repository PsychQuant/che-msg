import XCTest
import TDLibKit
@testable import TelegramAllLib

/// The `file` field of message JSON (PsychQuant/che-msg#69, task 6.2). Synthetic values only.
final class MessageMediaFileTests: XCTestCase {
    private func file(_ id: Int, size: Int64, expected: Int64 = 0) -> File {
        File(expectedSize: expected, id: id,
             local: LocalFile(canBeDeleted: false, canBeDownloaded: true, downloadOffset: 0, downloadedPrefixSize: 0,
                              downloadedSize: 0, isDownloadingActive: false, isDownloadingCompleted: false, path: ""),
             remote: RemoteFile(id: "r\(id)", isUploadingActive: false, isUploadingCompleted: true,
                                uniqueId: "u\(id)", uploadedSize: size),
             size: size)
    }
    private let noCaption = FormattedText(entities: [], text: "")

    func testPhotoUsesItsLargestSize() throws {
        let photo = Photo(hasStickers: false, minithumbnail: nil, sizes: [
            PhotoSize(height: 90, photo: file(11, size: 1_000), progressiveSizes: [], type: "s", width: 90),
            PhotoSize(height: 960, photo: file(12, size: 90_000), progressiveSizes: [], type: "y", width: 1280),
            PhotoSize(height: 320, photo: file(13, size: 9_000), progressiveSizes: [], type: "m", width: 320),
        ])
        let info = try XCTUnwrap(mediaFileInfo(.messagePhoto(MessagePhoto(
            caption: noCaption, hasSpoiler: false, isSecret: false, photo: photo, showCaptionAboveMedia: false))))
        XCTAssertEqual(info["id"] as? Int, 12)
        XCTAssertEqual(info["size"] as? Int64, 90_000)
        XCTAssertNil(info["name"])
    }

    func testDocumentKeepsItsFileName() throws {
        let doc = Document(document: file(21, size: 5_000), fileName: "report.pdf", mimeType: "application/pdf",
                           minithumbnail: nil, thumbnail: nil)
        let info = try XCTUnwrap(mediaFileInfo(.messageDocument(MessageDocument(caption: noCaption, document: doc))))
        XCTAssertEqual(info["id"] as? Int, 21)
        XCTAssertEqual(info["size"] as? Int64, 5_000)
        XCTAssertEqual(info["name"] as? String, "report.pdf")
    }

    func testUnknownSizeFallsBackToTheExpectedSize() throws {
        let voice = VoiceNote(duration: 3, mimeType: "audio/ogg", speechRecognitionResult: nil,
                              voice: file(31, size: 0, expected: 777), waveform: Data())
        let info = try XCTUnwrap(mediaFileInfo(.messageVoiceNote(MessageVoiceNote(
            caption: noCaption, isListened: false, voiceNote: voice))))
        XCTAssertEqual(info["id"] as? Int, 31)
        XCTAssertEqual(info["size"] as? Int64, 777)
    }

    func testTextHasNoFile() {
        XCTAssertNil(mediaFileInfo(.messageText(MessageText(linkPreview: nil, linkPreviewOptions: nil,
                                                             text: FormattedText(entities: [], text: "hi")))))
    }
}
