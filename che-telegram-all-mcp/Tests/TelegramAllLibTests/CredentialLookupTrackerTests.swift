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
        XCTAssertTrue(tracker.finish(generation, found: true))
        XCTAssertEqual(tracker.current, .found)
    }

    func testALookupThatFindsNothingIsAbsent() {
        let tracker = CredentialLookupTracker()
        let generation = tracker.stateChanged(lookingUp: true)
        XCTAssertTrue(tracker.finish(generation, found: false))
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
        XCTAssertFalse(tracker.finish(phoneLookup, found: true), "the phone lookup finished after the state moved on")
        XCTAssertEqual(tracker.current, .pending)
        XCTAssertTrue(tracker.finish(passwordLookup, found: false))
        XCTAssertEqual(tracker.current, .absent)
    }
}
