import XCTest
@testable import TelegramAllLib

/// The part of the auto-fire chain that runs outside TDLib's callback thread
/// (PsychQuant/che-msg#49): what is looked up, what is sent, and what the
/// lookup status says afterwards. `TDLibClient` only wires real lookups and
/// sends into `runCredentialPlan`, so these tests cover the wiring's logic
/// without a TDLib session.
final class CredentialPlanRunnerTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var lookups: [KeychainCredential] = []
        private var sent: [String] = []
        private var failures: [(error: Error, inFlightWhenRecorded: Bool)] = []
        func lookedUp(_ c: KeychainCredential) { lock.withLock { lookups.append(c) } }
        func send(_ v: String) { lock.withLock { sent.append(v) } }
        func failed(_ e: Error, inFlight: Bool) { lock.withLock { failures.append((e, inFlight)) } }
        var lookupList: [KeychainCredential] { lock.withLock { lookups } }
        var sentList: [String] { lock.withLock { sent } }
        var failureList: [(error: Error, inFlightWhenRecorded: Bool)] { lock.withLock { failures } }
    }

    private struct Rejected: Error {}

    private func run(_ plan: CredentialPlan, lookupResult: KeychainLookup = .absent,
                     duringLookup: (@Sendable (CredentialLookupTracker) -> Void)? = nil,
                     duringSubmit: (@Sendable (CredentialLookupTracker) -> Void)? = nil,
                     submitFails: Bool = false) async -> (Calls, CredentialLookupTracker, Error?) {
        let calls = Calls()
        let tracker = CredentialLookupTracker()
        var lookingUp = false
        if case .lookUp = plan { lookingUp = true }
        let generation = tracker.stateChanged(lookingUp: lookingUp)
        await runCredentialPlan(
            plan, generation: generation, tracker: tracker,
            lookup: { credential in
                calls.lookedUp(credential)
                duringLookup?(tracker)
                return lookupResult
            },
            submit: { value in
                calls.send(value)
                duringSubmit?(tracker)
                if submitFails { throw Rejected() }
            },
            recordFailure: { error in calls.failed(error, inFlight: tracker.isInFlight) })
        return (calls, tracker, calls.failureList.first?.error)
    }

    func testAnEnvironmentValueIsSentWithoutALookup() async {
        let (calls, tracker, error) = await run(.fire("+886912345678"))
        XCTAssertEqual(calls.sentList, ["+886912345678"])
        XCTAssertEqual(calls.lookupList, [])
        XCTAssertEqual(tracker.current, .notNeeded)
        XCTAssertNil(error)
    }

    func testAKeychainValueIsLookedUpOnceAndSent() async {
        let (calls, tracker, error) = await run(.lookUp(.password), lookupResult: .found("from-keychain"))
        XCTAssertEqual(calls.lookupList, [.password])
        XCTAssertEqual(calls.sentList, ["from-keychain"])
        XCTAssertEqual(tracker.current, .found)
        XCTAssertNil(error)
    }

    func testNoKeychainValueSendsNothingAndSettles() async {
        let (calls, tracker, _) = await run(.lookUp(.phone), lookupResult: .absent)
        XCTAssertEqual(calls.sentList, [])
        XCTAssertEqual(tracker.current, .absent)
    }

    func testATimedOutOrFailedLookupSendsNothingAndSettles() async {
        for result in [KeychainLookup.timedOut, .unavailable(exitStatus: 51)] {
            let (calls, tracker, _) = await run(.lookUp(.password), lookupResult: result)
            XCTAssertEqual(calls.sentList, [], "\(result)")
            XCTAssertEqual(tracker.current, .absent, "\(result)")
        }
    }

    func testAValueFoundAfterTheStateMovedOnIsNotSent() async {
        let (calls, tracker, _) = await run(.lookUp(.phone), lookupResult: .found("+886912345678"),
                                            duringLookup: { _ = $0.stateChanged(lookingUp: false) })
        XCTAssertEqual(calls.sentList, [], "the state changed while the lookup ran")
        XCTAssertEqual(tracker.current, .notNeeded)
    }

    func testAFailedSubmissionSettlesAndIsReported() async {
        let (calls, tracker, error) = await run(.lookUp(.password), lookupResult: .found("wrong"), submitFails: true)
        XCTAssertEqual(calls.sentList, ["wrong"])
        XCTAssertNotNil(error, "the error is recorded for auth_status")
        XCTAssertEqual(calls.failureList.first?.inFlightWhenRecorded, true,
                       "recorded before the state counts as settled, so a settled answer carries the error")
        XCTAssertEqual(tracker.current, .absent, "a settle check must not wait for a submission that failed")
    }

    func testAFailureAfterTheStateMovedOnIsNotRecorded() async {
        let (calls, tracker, _) = await run(.lookUp(.password), lookupResult: .found("old"),
                                            duringSubmit: { _ = $0.stateChanged(lookingUp: false) }, submitFails: true)
        XCTAssertEqual(calls.failureList.count, 0, "the error belongs to a state that is gone")
        XCTAssertEqual(tracker.current, .notNeeded)
    }

    func testAFailedEnvironmentSubmissionIsRecorded() async {
        let (calls, _, error) = await run(.fire("+886900000417"), submitFails: true)
        XCTAssertEqual(calls.sentList, ["+886900000417"])
        XCTAssertNotNil(error)
    }

    func testNothingToDoDoesNothing() async {
        let (calls, tracker, error) = await run(.nothing)
        XCTAssertEqual(calls.lookupList, [])
        XCTAssertEqual(calls.sentList, [])
        XCTAssertEqual(tracker.current, .notNeeded)
        XCTAssertNil(error)
    }

    // MARK: - The reason a lookup found nothing (#95)

    func testEachLookupResultRecordsItsReason() async {
        let cases: [(KeychainLookup, KeychainMiss?)] = [
            (.absent, .notStored), (.timedOut, .timedOut), (.unavailable(exitStatus: 36), .unavailable), (.found("v"), nil),
        ]
        for (result, expected) in cases {
            let (_, tracker, _) = await run(.lookUp(.password), lookupResult: result)
            XCTAssertEqual(tracker.lastMiss, expected, "\(result)")
        }
    }

    func testAnEnvironmentValueRecordsNoReason() async {
        let (_, tracker, _) = await run(.fire("+886912345678"))
        XCTAssertNil(tracker.lastMiss)
    }
}
