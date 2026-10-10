import XCTest
@testable import TelegramAllLib

/// Covers "First use waits a bounded time for TDLib to sync"
/// (telegram-tdlib-lifecycle; PsychQuant/che-msg#63, task 3.1).
final class TDLibSyncWaitTests: XCTestCase {
    final class Clock: @unchecked Sendable { var now: TimeInterval = 0 }

    /// Runs the wait with a clock that sleeping advances, and a condition
    /// that turns true at `readyAt` (never when nil).
    private func runWait(readyAt: TimeInterval?, timeout: TimeInterval = 10) async -> (ready: Bool, elapsed: TimeInterval) {
        let clock = Clock()
        let ready = await TDLibClient.wait(
            timeout: timeout,
            now: { clock.now },
            sleep: { clock.now += $0 },
            until: { readyAt.map { clock.now >= $0 } ?? false })
        return (ready, clock.now)
    }

    // Scenario: Sync completes within the bound.
    func testReturnsWhenTDLibBecomesReady() async {
        let result = await runWait(readyAt: 2)
        XCTAssertTrue(result.ready)
        XCTAssertGreaterThanOrEqual(result.elapsed, 2)
        XCTAssertLessThan(result.elapsed, 2.5)
    }

    // Scenario: Sync does not complete within the bound.
    func testGivesUpAtTheBound() async {
        let result = await runWait(readyAt: nil)
        XCTAssertFalse(result.ready)
        XCTAssertGreaterThanOrEqual(result.elapsed, 10)
        XCTAssertLessThan(result.elapsed, 10.5)
    }

    func testAlreadyReadyDoesNotWait() async {
        let result = await runWait(readyAt: 0)
        XCTAssertTrue(result.ready)
        XCTAssertEqual(result.elapsed, 0)
    }

    // "When authorization is not ready, the server SHALL NOT wait."
    func testWaitsOnlyWhenAuthorizationIsReady() {
        XCTAssertTrue(TDLibClient.shouldWaitForSync(authState: .ready))
        for state: TDLibClient.AuthState in [.waitingForParameters, .waitingForPhoneNumber, .waitingForCode, .waitingForPassword, .closed] {
            XCTAssertFalse(TDLibClient.shouldWaitForSync(authState: state), "\(state)")
        }
    }
}
