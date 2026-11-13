import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-web-client — Requirement "Request pacing", the interval half.
/// All times are virtual; expected values are derived by hand.
@Suite("Request pacing: interval")
struct RequestPacingTests {
    static func credential(_ team: String) -> SlackCredential {
        SlackCredential(teamID: team, token: "xoxc-1", cookie: "abc")
    }

    static func client(_ transport: RecordingTransport, _ clock: VirtualClock,
                       intervalMs: Int = SlackPacingConfig.defaultMinIntervalMilliseconds) -> SlackWebClient {
        let pacing = SlackPacingConfig(minIntervalMilliseconds: intervalMs, maxConcurrency: 3)!
        return SlackWebClient(transport: transport, pacing: pacing, clock: clock)
    }

    @Test("two requests back to back: the second starts 350 ms after the first")
    func backToBack() async throws {
        let clock = VirtualClock()
        let transport = RecordingTransport(clock: clock)
        let client = SlackWebClient(transport: transport, clock: clock) // default pacing

        _ = try await client.call("auth.test", parameters: [:], credential: Self.credential("T01"))
        _ = try await client.call("auth.test", parameters: [:], credential: Self.credential("T01"))

        #expect(await transport.starts == [.zero, .milliseconds(350)])
    }

    @Test("two requests issued concurrently are spaced the same way")
    func concurrentPair() async throws {
        let clock = VirtualClock()
        let transport = RecordingTransport(clock: clock)
        let client = Self.client(transport, clock)

        async let first = client.call("auth.test", parameters: [:], credential: Self.credential("T01"))
        async let second = client.call("auth.test", parameters: [:], credential: Self.credential("T01"))
        _ = try await (first, second)

        #expect(await transport.starts.sorted() == [.zero, .milliseconds(350)])
    }

    @Test("time already elapsed since the previous start counts toward the interval", arguments: [
        // elapsed -> second start: max(elapsed, 350 ms)
        (Duration.milliseconds(200), Duration.milliseconds(350)),
        (.milliseconds(350), .milliseconds(350)),
        (.seconds(1), .seconds(1)),
    ])
    func elapsedTimeCounts(elapsed: Duration, expectedStart: Duration) async throws {
        let clock = VirtualClock()
        let transport = RecordingTransport(clock: clock)
        let client = Self.client(transport, clock)

        _ = try await client.call("auth.test", parameters: [:], credential: Self.credential("T01"))
        clock.advance(by: elapsed)
        _ = try await client.call("auth.test", parameters: [:], credential: Self.credential("T01"))

        #expect(await transport.starts == [.zero, expectedStart])
    }

    @Test("each workspace is paced on its own")
    func perWorkspace() async throws {
        let clock = VirtualClock()
        let transport = RecordingTransport(clock: clock)
        let client = Self.client(transport, clock)

        for team in ["T01", "T02", "T01"] {
            _ = try await client.call("auth.test", parameters: [:], credential: Self.credential(team))
        }

        // T01 at 0, T02 at 0 (other workspace), T01 again 350 ms after its first
        #expect(await transport.starts == [.zero, .zero, .milliseconds(350)])
    }

    @Test("the configured interval is used", arguments: [(0, Duration.zero), (1000, .seconds(1)), (60_000, .seconds(60))])
    func configuredInterval(intervalMs: Int, expectedSecondStart: Duration) async throws {
        let clock = VirtualClock()
        let transport = RecordingTransport(clock: clock)
        let client = Self.client(transport, clock, intervalMs: intervalMs)

        _ = try await client.call("auth.test", parameters: [:], credential: Self.credential("T01"))
        _ = try await client.call("auth.test", parameters: [:], credential: Self.credential("T01"))

        #expect(await transport.starts == [.zero, expectedSecondStart])
    }

    @Test("a rate-limit retry is paced too")
    func retryIsPaced() async throws {
        let clock = VirtualClock()
        let transport = RecordingTransport([.respond(status: 429, headers: ["Retry-After": "0"], body: ""), .ok],
                                           clock: clock)
        let client = Self.client(transport, clock)

        _ = try await client.call("auth.test", parameters: [:], credential: Self.credential("T01"))

        // Retry-After 0 ends at 0; pacing still holds the retry to 350 ms
        #expect(await transport.starts == [.zero, .milliseconds(350)])
    }
}
