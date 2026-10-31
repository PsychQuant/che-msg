import Foundation
@testable import SlackWebLib

/// One scripted answer from the fake transport.
enum ScriptedStep: Sendable {
    /// Answers after `latency` of virtual time (needs a clock).
    case respond(status: Int, headers: [String: String] = [:], body: String, latency: Duration = .zero)
    case fail(any Error & Sendable)

    static let ok = ScriptedStep.respond(status: 200, body: #"{"ok":true}"#)

    static func slackError(_ error: String) -> ScriptedStep {
        .respond(status: 200, body: #"{"ok":false,"error":"\#(error)"}"#)
    }
}

actor RecordingTransportState {
    var requests: [URLRequest] = []
    var starts: [Duration] = []
    var answers: [Duration] = []
    private var steps: [ScriptedStep]

    init(steps: [ScriptedStep]) { self.steps = steps }

    /// Records `request` and its start time, and returns the next step; the
    /// last step repeats.
    func next(for request: URLRequest, at start: Duration) -> ScriptedStep {
        requests.append(request)
        starts.append(start)
        return steps.count > 1 ? steps.removeFirst() : steps[0]
    }

    func answered(at time: Duration) { answers.append(time) }
}

/// Records every request and answers from a script (default: `{"ok":true}`
/// forever).
final class RecordingTransport: SlackTransport, @unchecked Sendable {
    private let state: RecordingTransportState
    private let clock: VirtualClock
    var requests: [URLRequest] { get async { await state.requests } }
    /// Virtual time at which each request reached the transport.
    var starts: [Duration] { get async { await state.starts } }
    /// Virtual time at which each answer was returned.
    var answers: [Duration] { get async { await state.answers } }

    init(_ steps: [ScriptedStep] = [.ok], clock: VirtualClock = VirtualClock()) {
        precondition(!steps.isEmpty)
        state = RecordingTransportState(steps: steps)
        self.clock = clock
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step = await state.next(for: request, at: clock.now())
        switch step {
        case let .fail(error):
            await state.answered(at: clock.now())
            throw error
        case let .respond(status, headers, body, latency):
            if latency > .zero { try await clock.sleep(for: latency) }
            await state.answered(at: clock.now())
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (Data(body.utf8), response)
        }
    }
}

/// Virtual time: `sleep` returns at once after moving the clock forward by
/// the requested duration, so tests read exact start times without waiting.
/// Concurrent sleeps add up, which can only make later starts later, never
/// earlier; exact-time assertions are therefore made only where one task
/// sleeps at a time.
final class VirtualClock: SlackClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration = .zero
    private var recordedSleeps: [Duration] = []

    func now() -> Duration {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Every duration passed to `sleep`, in call order.
    var sleeps: [Duration] {
        lock.lock(); defer { lock.unlock() }
        return recordedSleeps
    }

    func advance(by duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        current += duration
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        advanceForSleep(duration)
        await Task.yield()
    }

    private func advanceForSleep(_ duration: Duration) {
        lock.lock(); defer { lock.unlock() }
        recordedSleeps.append(duration)
        if duration > .zero { current += duration }
    }
}

/// A transport error whose description echoes whatever it was given, used to
/// check that the client scrubs credentials out of transport descriptions.
struct EchoingTransportError: LocalizedError, Sendable {
    let text: String
    var errorDescription: String? { text }
}

/// The case name of a `SlackError`, for asserting the class alone.
func className(_ error: SlackError) -> String {
    switch error {
    case .sessionInvalid: return "sessionInvalid"
    case .rateLimited: return "rateLimited"
    case .enterpriseRestricted: return "enterpriseRestricted"
    case .slackError: return "slackError"
    case .network: return "network"
    }
}

actor GateState {
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var completed = 0
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
    }

    func leave() {
        inFlight -= 1
        completed += 1
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}

/// Holds every request in flight until `open()` and records how many were in
/// flight at once. Answers `{"ok":true}`.
final class GatedTransport: SlackTransport, @unchecked Sendable {
    let gate = GateState()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await gate.enter()
        await gate.leave()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(#"{"ok":true}"#.utf8), response)
    }
}

/// Polls `condition` in real time until it holds or `timeout` passes.
func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

/// A clock whose `sleep` lasts until the sleeping task is cancelled, and
/// whose time moves only when set.
final class StuckClock: SlackClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration = .zero
    private var sleeping = 0

    func now() -> Duration {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func set(_ time: Duration) {
        lock.lock(); defer { lock.unlock() }
        current = time
    }

    var sleepers: Int {
        lock.lock(); defer { lock.unlock() }
        return sleeping
    }

    func sleep(for duration: Duration) async throws {
        changeSleepers(by: 1)
        defer { changeSleepers(by: -1) }
        try await Task.sleep(for: .seconds(3600))
    }

    private func changeSleepers(by delta: Int) {
        lock.lock(); defer { lock.unlock() }
        sleeping += delta
    }
}
