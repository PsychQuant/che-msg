import XCTest
@testable import TelegramAllLib

/// The Keychain lookup status that `authorizationIsSettled` reads
/// (PsychQuant/che-msg#49). It holds a status, never a value, and a lookup
/// started for one authorization state cannot change the status of the next.
final class CredentialLookupTrackerTests: XCTestCase {
    func testStartsAsNotNeeded() {
        XCTAssertEqual(CredentialLookupTracker().current, .notNeeded)
    }

    func testAStartedLookupIsPendingUntilItFinishes() {
        let tracker = CredentialLookupTracker()
        let generation = tracker.stateChanged(lookingUp: true)
        XCTAssertEqual(tracker.current, .pending)
        XCTAssertTrue(tracker.finish(generation, miss: nil))
        XCTAssertEqual(tracker.current, .found)
    }

    func testALookupThatFindsNothingIsAbsent() {
        let tracker = CredentialLookupTracker()
        let generation = tracker.stateChanged(lookingUp: true)
        XCTAssertTrue(tracker.finish(generation, miss: .notStored))
        XCTAssertEqual(tracker.current, .absent)
    }

    func testAStateWithoutALookupIsNotNeeded() {
        let tracker = CredentialLookupTracker()
        _ = tracker.stateChanged(lookingUp: true)
        _ = tracker.stateChanged(lookingUp: false)
        XCTAssertEqual(tracker.current, .notNeeded)
    }

    func testALateResultFromAnEarlierStateIsDiscarded() {
        let tracker = CredentialLookupTracker()
        let phoneLookup = tracker.stateChanged(lookingUp: true)
        let passwordLookup = tracker.stateChanged(lookingUp: true)
        XCTAssertFalse(tracker.finish(phoneLookup, miss: nil), "the phone lookup finished after the state moved on")
        XCTAssertEqual(tracker.current, .pending)
        XCTAssertTrue(tracker.finish(passwordLookup, miss: .notStored))
        XCTAssertEqual(tracker.current, .absent)
    }

    // MARK: - In flight (auth_run waits while a Keychain value is on its way; #49 verify r2)

    func testALookupAndAFoundValueAreInFlight() {
        let tracker = CredentialLookupTracker()
        let generation = tracker.stateChanged(lookingUp: true)
        XCTAssertTrue(tracker.isInFlight, "pending")
        XCTAssertTrue(tracker.finish(generation, miss: nil))
        XCTAssertTrue(tracker.isInFlight, "found, not yet sent")
        tracker.submissionFailed(generation)
        XCTAssertFalse(tracker.isInFlight, "the submission failed")
    }

    func testNothingIsInFlightWithoutALookupOrWhenNothingWasFound() {
        let tracker = CredentialLookupTracker()
        XCTAssertFalse(tracker.isInFlight)
        let generation = tracker.stateChanged(lookingUp: true)
        XCTAssertTrue(tracker.finish(generation, miss: .notStored))
        XCTAssertFalse(tracker.isInFlight)
        _ = tracker.stateChanged(lookingUp: false)
        XCTAssertFalse(tracker.isInFlight)
    }

    // MARK: - Why nothing was found (auth_status reports it; #95)

    func testTheReasonIsRecordedForItsState() {
        let tracker = CredentialLookupTracker()
        let generation = tracker.stateChanged(lookingUp: true)
        XCTAssertNil(tracker.lastMiss, "pending")
        XCTAssertTrue(tracker.finish(generation, miss: .timedOut))
        XCTAssertEqual(tracker.lastMiss, .timedOut)
        XCTAssertEqual(tracker.current, .absent)
    }

    func testAFoundValueRecordsNoReason() {
        let tracker = CredentialLookupTracker()
        let generation = tracker.stateChanged(lookingUp: true)
        XCTAssertTrue(tracker.finish(generation, miss: nil))
        XCTAssertNil(tracker.lastMiss)
    }

    func testAStateChangeClearsTheReason() {
        let tracker = CredentialLookupTracker()
        let generation = tracker.stateChanged(lookingUp: true)
        XCTAssertTrue(tracker.finish(generation, miss: .notStored))
        _ = tracker.stateChanged(lookingUp: false)
        XCTAssertNil(tracker.lastMiss)
    }

    func testAReasonFromAnEarlierStateIsDiscarded() {
        let tracker = CredentialLookupTracker()
        let phoneLookup = tracker.stateChanged(lookingUp: true)
        _ = tracker.stateChanged(lookingUp: true)
        XCTAssertFalse(tracker.finish(phoneLookup, miss: .unavailable))
        XCTAssertNil(tracker.lastMiss)
    }

    /// auth_run's own lookup replaces the reason but leaves the settle status
    /// alone: it sends what it finds itself, nothing waits for it.
    func testANoteReplacesTheReasonWithoutChangingTheStatus() {
        let tracker = CredentialLookupTracker()
        let generation = tracker.stateChanged(lookingUp: true)
        XCTAssertTrue(tracker.finish(generation, miss: .timedOut))
        tracker.note(tracker.generationNow, miss: nil)
        XCTAssertNil(tracker.lastMiss, "the Keychain answered this time")
        XCTAssertEqual(tracker.current, .absent)
        tracker.note(tracker.generationNow, miss: .unavailable)
        XCTAssertEqual(tracker.lastMiss, .unavailable)
        XCTAssertFalse(tracker.isInFlight)
    }

    func testANoteWhileTheAutoFireLookupIsPendingKeepsItPending() {
        let tracker = CredentialLookupTracker()
        let generation = tracker.stateChanged(lookingUp: true)
        tracker.note(generation, miss: .notStored)
        XCTAssertEqual(tracker.current, .pending)
        XCTAssertEqual(tracker.lastMiss, .notStored)
    }

    func testANoteFromAnEarlierStateIsDiscarded() {
        let tracker = CredentialLookupTracker()
        let before = tracker.generationNow
        _ = tracker.stateChanged(lookingUp: false)
        tracker.note(before, miss: .notStored)
        XCTAssertNil(tracker.lastMiss)
    }
}
