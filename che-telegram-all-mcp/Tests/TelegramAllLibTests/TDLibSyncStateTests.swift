import XCTest
import TDLibKit
@testable import TelegramAllLib

/// Covers "Server tracks whether TDLib is synced with Telegram"
/// (telegram-tdlib-lifecycle; PsychQuant/che-msg#63, task 2.1).
final class TDLibSyncStateTests: XCTestCase {
    /// A clock the test moves by hand.
    final class Clock: @unchecked Sendable {
        var now: TimeInterval = 0
    }

    private var clock: Clock!
    private var state: TDLibSyncState!

    override func setUp() {
        clock = Clock()
        let clock = self.clock!
        state = TDLibSyncState(clock: { clock.now })
    }

    private let ready = "connectionStateReady"
    private let updating = "connectionStateUpdating"

    // Example "unsynced duration over time", row by row.
    func testUnsyncedDurationFollowsTheSpecExample() {
        clock.now = 0; state.tdlibOpened(); state.record("connectionStateConnecting")
        XCTAssertEqual(state.snapshot.unsyncedSeconds, 0)
        clock.now = 5; state.record(updating)
        XCTAssertEqual(state.snapshot.unsyncedSeconds, 5)
        clock.now = 85; state.tdlibClosed()
        XCTAssertEqual(state.snapshot.unsyncedSeconds, 85)
        clock.now = 600; state.tdlibOpened(); state.record(updating)
        XCTAssertEqual(state.snapshot.unsyncedSeconds, 85)
        clock.now = 650
        XCTAssertEqual(state.snapshot.unsyncedSeconds, 135)
        clock.now = 660; state.record(ready)
        XCTAssertEqual(state.snapshot.unsyncedSeconds, 0)
        XCTAssertTrue(state.snapshot.isSynced)
    }

    // Scenario: Ready resets the unsynced duration.
    func testReadyResetsTheUnsyncedDuration() {
        state.tdlibOpened(); state.record(updating)
        clock.now = 30; state.record(ready)
        XCTAssertEqual(state.snapshot, .init(connectionState: ready, isSynced: true, unsyncedSeconds: 0))
    }

    // Scenario: Unsynced time accumulates across an idle close.
    func testUnsyncedTimeAccumulatesAcrossAnIdleClose() {
        state.tdlibOpened(); state.record(updating)
        clock.now = 80; state.tdlibClosed()
        clock.now = 1_000; state.tdlibOpened(); state.record(updating)
        clock.now = 1_050
        XCTAssertEqual(state.snapshot.unsyncedSeconds, 130)
    }

    func testTimeBeforeTheFirstConnectionStateCounts() {
        state.tdlibOpened()
        clock.now = 7
        XCTAssertEqual(state.snapshot, .init(connectionState: nil, isSynced: false, unsyncedSeconds: 7))
    }

    func testLosingTheConnectionAfterReadyStartsCountingAgain() {
        state.tdlibOpened(); state.record(ready)
        clock.now = 100; state.record("connectionStateWaitingForNetwork")
        clock.now = 115
        XCTAssertEqual(state.snapshot.unsyncedSeconds, 15)
        XCTAssertFalse(state.snapshot.isSynced)
    }

    func testClosedTDLibIsNotSyncedAndReportsNoConnectionState() {
        state.tdlibOpened(); state.record(ready)
        clock.now = 50; state.tdlibClosed()
        XCTAssertEqual(state.snapshot, .init(connectionState: nil, isSynced: false, unsyncedSeconds: 0))
    }

    func testStallThreshold() {
        state.tdlibOpened(); state.record(updating)
        clock.now = 119
        XCTAssertFalse(state.isStalled())
        clock.now = 120
        XCTAssertTrue(state.isStalled())
        XCTAssertFalse(state.isStalled(threshold: 121))
    }

    // MARK: - TDLib updates drive the state (task 2.2)

    private func apply(_ update: Update) { TDLibClient.applySyncUpdate(update, to: state) }
    private func connection(_ s: ConnectionState) -> Update { .updateConnectionState(UpdateConnectionState(state: s)) }

    func testConnectionUpdatesAreRecordedByCaseName() {
        state.tdlibOpened()
        apply(connection(.connectionStateConnecting))
        clock.now = 3; apply(connection(.connectionStateUpdating))
        XCTAssertEqual(state.snapshot, .init(connectionState: "connectionStateUpdating", isSynced: false, unsyncedSeconds: 3))
        clock.now = 4; apply(connection(.connectionStateReady))
        XCTAssertEqual(state.snapshot, .init(connectionState: "connectionStateReady", isSynced: true, unsyncedSeconds: 0))
        apply(connection(.connectionStateWaitingForNetwork))
        XCTAssertEqual(state.snapshot.connectionState, "connectionStateWaitingForNetwork")
        apply(connection(.connectionStateConnectingToProxy))
        XCTAssertEqual(state.snapshot.connectionState, "connectionStateConnectingToProxy")
    }

    func testAuthorizationClosedMeansTDLibClosed() {
        state.tdlibOpened(); apply(connection(.connectionStateUpdating))
        clock.now = 20
        apply(.updateAuthorizationState(UpdateAuthorizationState(authorizationState: .authorizationStateClosed)))
        clock.now = 500
        XCTAssertEqual(state.snapshot, .init(connectionState: nil, isSynced: false, unsyncedSeconds: 20))
    }

    func testOtherUpdatesLeaveTheStateAlone() {
        state.tdlibOpened(); apply(connection(.connectionStateReady))
        apply(.updateAuthorizationState(UpdateAuthorizationState(authorizationState: .authorizationStateReady)))
        XCTAssertTrue(state.snapshot.isSynced)
    }

    // A logout starts a new session: its unsynced time starts at 0 (task 6.1).
    func testResetStartsTheUnsyncedTimeAgain() {
        state.tdlibOpened(); state.record("connectionStateUpdating")
        clock.now = 300; state.reset()
        XCTAssertEqual(state.snapshot.unsyncedSeconds, 0)
        clock.now = 310
        XCTAssertEqual(state.snapshot.unsyncedSeconds, 10, "still open and not synced: counting restarts from the reset")
        state.tdlibClosed(); state.reset()
        clock.now = 400
        XCTAssertEqual(state.snapshot.unsyncedSeconds, 0)
    }
}
