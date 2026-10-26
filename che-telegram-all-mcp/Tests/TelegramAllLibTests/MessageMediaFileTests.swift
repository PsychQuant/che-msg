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

    // MARK: - Content fields (#82)

    private func poll(_ question: String, _ options: [String], type: PollType) -> MessageContent {
        .messagePoll(MessagePoll(poll: Poll(
            closeDate: 0, id: 1, isAnonymous: true, isClosed: false, openPeriod: 0,
            options: options.map { PollOption(isBeingChosen: false, isChosen: true,
                                              text: FormattedText(entities: [], text: $0),
                                              votePercentage: 50, voterCount: 3) },
            question: FormattedText(entities: [], text: question), recentVoterIds: [], totalVoterCount: 6, type: type)))
    }

    // Scenario "Poll options in the message JSON".
    func testPollCarriesItsQuestionAndOptionsInOrder() throws {
        let fields = messageContentFields(poll("Lunch?", ["Noodles", "Rice"], type: .pollTypeRegular(.init(allowMultipleAnswers: false))))
        XCTAssertEqual(fields["type"] as? String, "poll")
        XCTAssertEqual(fields["question"] as? String, "Lunch?")
        XCTAssertEqual(fields["options"] as? [String], ["Noodles", "Rice"])
        // Votes and a quiz's answer are not content to keep.
        XCTAssertEqual(Set(fields.keys), ["type", "question", "options"])
        let quiz = messageContentFields(poll("2+2?", ["3", "4"], type: .pollTypeQuiz(.init(
            correctOptionId: 1, explanation: FormattedText(entities: [], text: "")))))
        XCTAssertEqual(quiz["options"] as? [String], ["3", "4"])
        XCTAssertEqual(Set(quiz.keys), ["type", "question", "options"])
    }

    // Scenario "Location in the message JSON".
    func testLocationCarriesItsCoordinates() {
        let fields = messageContentFields(.messageLocation(MessageLocation(
            expiresIn: 0, heading: 0, livePeriod: 0,
            location: Location(horizontalAccuracy: 0, latitude: 25.0478, longitude: 121.5319), proximityAlertRadius: 0)))
        XCTAssertEqual(fields["type"] as? String, "location")
        XCTAssertEqual(fields["latitude"] as? Double, 25.0478)
        XCTAssertEqual(fields["longitude"] as? Double, 121.5319)
    }
}
