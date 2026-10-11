import XCTest
import TDLibKit
@testable import TelegramAllLib

/// TDLibKit errors on the archive path (PsychQuant/che-msg#69). The end-to-end run showed
/// them reaching the server as "TDLibKit.Error error 1", and a FLOOD_WAIT in that form is
/// not recognised by the archiver.
final class ArchiveTDLibErrorTests: XCTestCase {
    func testFloodWaitFromTDLibKitIsRecognised() async {
        do {
            _ = try await archiveTDLibCall { () async throws -> Int in throw TDLibKit.Error(code: 429, message: "FLOOD_WAIT_30") }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(ChatArchiver.floodWaitSeconds(error), 30)
            guard case TelegramAllLib.TDLibClient.TDError.tdlibError(code: let code, message: let message) = error else {
                return XCTFail("not mapped: \(error)")
            }
            XCTAssertEqual(code, 429)
            XCTAssertEqual(message, "FLOOD_WAIT_30")
        }
    }

    func testOtherTDLibKitErrorsKeepTheirMessageExcept406() async {
        for (code, message, expected) in [(400, "Chat not found", "Chat not found"), (406, "internal", "")] {
            do {
                _ = try await archiveTDLibCall { () async throws -> Int in throw TDLibKit.Error(code: code, message: message) }
                XCTFail("expected an error")
            } catch TelegramAllLib.TDLibClient.TDError.tdlibError(code: let gotCode, message: let gotMessage) {
                XCTAssertEqual(gotCode, code)
                XCTAssertEqual(gotMessage, expected)
            } catch {
                XCTFail("not mapped: \(error)")
            }
        }
    }

    func testOtherErrorsPassThrough() async {
        do {
            _ = try await archiveTDLibCall { () async throws -> Int in throw CocoaError(.fileNoSuchFile) }
            XCTFail("expected an error")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileNoSuchFile)
        } catch {
            XCTFail("changed: \(error)")
        }
    }

    /// A chat TDLib has not seen yet is created from its id (the end-to-end run got
    /// "Chat not found" for Saved Messages in a freshly opened TDLib).
    func testChatIdRanges() {
        XCTAssertEqual(ArchiveChatID(123_456_789), .user(123_456_789))
        XCTAssertEqual(ArchiveChatID(1_099_511_627_775), .user(1_099_511_627_775))
        XCTAssertEqual(ArchiveChatID(1_099_511_627_776), .other)
        XCTAssertEqual(ArchiveChatID(-123_456_789), .basicGroup(123_456_789))
        XCTAssertEqual(ArchiveChatID(-999_999_999_999), .basicGroup(999_999_999_999))
        XCTAssertEqual(ArchiveChatID(-1_000_000_000_000), .other)
        XCTAssertEqual(ArchiveChatID(-1_001_234_567_890), .supergroup(1_234_567_890))
        XCTAssertEqual(ArchiveChatID(-1_997_852_516_352), .supergroup(997_852_516_352))
        XCTAssertEqual(ArchiveChatID(-1_997_852_516_353), .other)   // secret chats start here
        XCTAssertEqual(ArchiveChatID(-2_000_000_000_001), .other)
        XCTAssertEqual(ArchiveChatID(0), .other)
    }
}
