import XCTest
import MCP
import TelegramAllLib
@testable import CheTelegramAllMCPCore

/// Covers "Answers from TDLib state when TDLib is not synced"
/// (telegram-tdlib-lifecycle; PsychQuant/che-msg#63, task 4.1).
final class SyncNoteTests: XCTestCase {
    private func snapshot(_ state: String?, _ seconds: Int) -> TDLibSyncState.Snapshot {
        .init(connectionState: state, isSynced: state == "connectionStateReady", unsyncedSeconds: seconds)
    }

    private let answer = CallTool.Result(content: [.text(text: "[]", annotations: nil, _meta: nil)], isError: false)

    private func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { if case .text(let text, _, _) = $0 { return text } else { return nil } }
    }

    // Example "sync note lines", row 1.
    func testSyncedTDLibAddsNoNote() {
        XCTAssertNil(syncNote(snapshot("connectionStateReady", 0)))
        XCTAssertEqual(texts(withSyncNote(answer, authReady: true, snapshot: snapshot("connectionStateReady", 0))), ["[]"])
    }

    // Example rows 2 and 4.
    func testNotSyncedNoteNamesStateSecondsAndMissingMessages() throws {
        for (state, seconds) in [("connectionStateUpdating", 40), ("connectionStateWaitingForNetwork", 15)] {
            let note = try XCTUnwrap(syncNote(snapshot(state, seconds)))
            XCTAssertTrue(note.hasPrefix("sync: not-synced\n"), note)
            XCTAssertTrue(note.contains(state), note)
            XCTAssertTrue(note.contains("\(seconds) s"), note)
            XCTAssertTrue(note.contains("newer than what TDLib last received can be absent"), note)
            XCTAssertFalse(note.contains("logout"), note)
        }
    }

    // Example row 3 / scenario "Long stall names the remedy".
    func testLongStallNamesTheLikelyCauseAndRemedy() throws {
        let note = try XCTUnwrap(syncNote(snapshot("connectionStateUpdating", 125)))
        XCTAssertTrue(note.contains("125 s"), note)
        XCTAssertTrue(note.contains("invalidated by Telegram"), note)
        let logout = try XCTUnwrap(note.range(of: "logout"))
        let authRun = try XCTUnwrap(note.range(of: "auth_run"))
        XCTAssertLessThan(logout.lowerBound, authRun.lowerBound, "logout comes before auth_run")
    }

    func testStallWordingStartsExactlyAtTheThreshold() throws {
        XCTAssertFalse(try XCTUnwrap(syncNote(snapshot("connectionStateUpdating", 119))).contains("logout"))
        XCTAssertTrue(try XCTUnwrap(syncNote(snapshot("connectionStateUpdating", 120))).contains("logout"))
    }

    // Scenario "Read while TDLib is updating": the note is the second item.
    func testNoteIsTheSecondTextItem() {
        let texts = texts(withSyncNote(answer, authReady: true, snapshot: snapshot("connectionStateUpdating", 40)))
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts.first, "[]")
        XCTAssertTrue(texts.last?.hasPrefix("sync: not-synced") == true)
    }

    func testFailedCallsCarryNoNote() {
        let failure = CallTool.Result(content: [.text(text: "Error: x", annotations: nil, _meta: nil)], isError: true)
        XCTAssertEqual(texts(withSyncNote(failure, authReady: true, snapshot: snapshot("connectionStateUpdating", 40))), ["Error: x"])
    }

    func testNoNoteBeforeAuthorizationIsReady() {
        XCTAssertEqual(texts(withSyncNote(answer, authReady: false, snapshot: snapshot("connectionStateUpdating", 40))), ["[]"])
    }

    func testNoteWithoutAnyReportedStateSaysSo() throws {
        let note = try XCTUnwrap(syncNote(snapshot(nil, 3)))
        XCTAssertTrue(note.contains("no connection state reported yet"), note)
    }
}
