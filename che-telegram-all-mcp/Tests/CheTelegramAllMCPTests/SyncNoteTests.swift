import XCTest
import MCP
import TelegramAllLib
@testable import CheTelegramAllMCPCore

/// Covers "Answers from TDLib state when TDLib is not synced"
/// (telegram-tdlib-lifecycle; PsychQuant/che-msg#63, task 4.1).
final class SyncNoteTests: XCTestCase {
    /// Updating time equals the unsynced time while the state is Updating,
    /// as in the spec's example table; otherwise it is 0.
    private func snapshot(_ state: String?, _ seconds: Int) -> TDLibSyncState.Snapshot {
        .init(connectionState: state, isSynced: state == "connectionStateReady", unsyncedSeconds: seconds,
              updatingSeconds: state == "connectionStateUpdating" ? seconds : 0)
    }

    private let answer = CallTool.Result(content: [.text(text: "[]", annotations: nil, _meta: nil)], isError: false)

    private func texts(_ result: CallTool.Result) -> [String] {
        result.content.compactMap { if case .text(let text, _, _) = $0 { return text } else { return nil } }
    }

    // Example "sync note lines", row 1.
    func testSyncedTDLibAddsNoNote() {
        XCTAssertNil(syncNote(snapshot("connectionStateReady", 0)))
        XCTAssertEqual(texts(withSyncNote(answer, tool: "get_chats", authReady: true, snapshot: snapshot("connectionStateReady", 0))), ["[]"])
    }

    // Example rows 2 and 4.
    func testNotSyncedNoteNamesStateSecondsAndMissingMessages() throws {
        for (state, seconds) in [("connectionStateUpdating", 40), ("connectionStateWaitingForNetwork", 300)] {
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
        let texts = texts(withSyncNote(answer, tool: "get_chats", authReady: true, snapshot: snapshot("connectionStateUpdating", 40)))
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts.first, "[]")
        XCTAssertTrue(texts.last?.hasPrefix("sync: not-synced") == true)
    }

    func testFailedCallsCarryNoNote() {
        let failure = CallTool.Result(content: [.text(text: "Error: x", annotations: nil, _meta: nil)], isError: true)
        XCTAssertEqual(texts(withSyncNote(failure, tool: "get_chats", authReady: true, snapshot: snapshot("connectionStateUpdating", 40))), ["Error: x"])
    }

    func testNoNoteBeforeAuthorizationIsReady() {
        XCTAssertEqual(texts(withSyncNote(answer, tool: "get_chats", authReady: false, snapshot: snapshot("connectionStateUpdating", 40))), ["[]"])
    }

    func testNoteWithoutAnyReportedStateSaysSo() throws {
        let note = try XCTUnwrap(syncNote(snapshot(nil, 3)))
        XCTAssertTrue(note.contains("no connection state reported yet"), note)
    }

    // MARK: - Verify round 1 (task 8.2)

    // Scenario: Offline is not a stall.
    func testOfflineNoteSaysCheckTheNetworkAndNeverLogout() throws {
        for state in ["connectionStateWaitingForNetwork", "connectionStateConnectingToProxy"] {
            let note = try XCTUnwrap(syncNote(snapshot(state, 300)))
            XCTAssertTrue(note.contains("check the network"), note)
            XCTAssertFalse(note.contains("logout"), note)
        }
    }

    // Scenario: Long stall names the remedy and asks for the user.
    func testStallNoteAsksTheUserFirst() throws {
        let note = try XCTUnwrap(syncNote(snapshot("connectionStateUpdating", 125)))
        XCTAssertTrue(note.contains("ask the user"), note)
    }

    // Scenario: Non-read tools carry no note.
    func testOnlyReadToolsCarryTheNote() {
        let read = ["get_chats", "search_chats", "get_chat_history", "search_messages", "dump_chat_to_markdown",
                    "get_me", "get_user", "get_contacts", "get_chat", "get_chat_members"]
        for tool in read { XCTAssertTrue(shouldAttachSyncNote(tool: tool), tool) }
        for tool in ["auth_status", "auth_run", "logout", "send_message", "delete_messages", "create_group", "mark_as_read"] {
            XCTAssertFalse(shouldAttachSyncNote(tool: tool), tool)
        }
        XCTAssertEqual(texts(withSyncNote(answer, tool: "auth_status", authReady: true,
                                          snapshot: snapshot("connectionStateUpdating", 40))), ["[]"])
    }
}
