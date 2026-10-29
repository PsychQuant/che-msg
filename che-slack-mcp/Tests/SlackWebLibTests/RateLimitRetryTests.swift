import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-web-client — Requirement "Rate limit retry". All times are
/// virtual (see `VirtualClock`); expected values are derived by hand in the
/// comments.
@Suite("Rate limit retry")
struct RateLimitRetryTests {
    let credential = SlackCredential(teamID: "T01", token: "xoxc-1", cookie: "abc")

    static func tooMany(_ retryAfter: String?, latency: Duration = .zero) -> ScriptedStep {
        .respond(status: 429, headers: retryAfter.map { ["Retry-After": $0] } ?? [:], body: "", latency: latency)
    }

    @Test("429 with Retry-After 2, then success: returns the second answer, started 2 s after the first answered")
    func retrySucceedsAfterWaiting() async throws {
        let clock = VirtualClock()
        let second = #"{"ok":true,"attempt":2}"#
        let transport = RecordingTransport([
            Self.tooMany("2", latency: .milliseconds(100)),
            .respond(status: 200, body: second),
        ], clock: clock)
        let client = SlackWebClient(transport: transport, clock: clock)

        let data = try await client.call("auth.test", parameters: [:], credential: credential)

        #expect(String(decoding: data, as: UTF8.self) == second)
        // first starts at 0 and answers at 0.1; wait 2 s -> second starts at 2.1
        #expect(await transport.starts == [.zero, .milliseconds(2100)])
        #expect(await transport.answers.first == .milliseconds(100))
    }

    @Test("after 3 retries the call throws rateLimited with the last wait time")
    func retriesRunOut() async {
        let clock = VirtualClock()
        let transport = RecordingTransport([Self.tooMany("1"), Self.tooMany("2"), Self.tooMany("3"), Self.tooMany("4")],
                                           clock: clock)
        let client = SlackWebClient(transport: transport, clock: clock)

        await #expect(throws: SlackError.rateLimited(retryAfterSeconds: 4)) {
            try await client.call("auth.test", parameters: [:], credential: credential)
        }
        // 1 attempt + 3 retries; waits 1, 2, 3 -> starts 0, 1, 3, 6
        #expect(await transport.starts == [.zero, .seconds(1), .seconds(3), .seconds(6)])
    }

    @Test("the third retry may still succeed")
    func thirdRetrySucceeds() async throws {
        let clock = VirtualClock()
        let transport = RecordingTransport([Self.tooMany("1"), Self.tooMany("1"), Self.tooMany("1"), .ok], clock: clock)
        let client = SlackWebClient(transport: transport, clock: clock)

        _ = try await client.call("auth.test", parameters: [:], credential: credential)

        #expect(await transport.requests.count == 4)
    }

    @Test("spec classification table: HTTP 429 with Retry-After 5 is rateLimited")
    func tableRow429() async {
        let clock = VirtualClock()
        let transport = RecordingTransport([Self.tooMany("5")], clock: clock)
        let client = SlackWebClient(transport: transport, clock: clock)

        await #expect(throws: SlackError.rateLimited(retryAfterSeconds: 5)) {
            try await client.call("auth.test", parameters: [:], credential: credential)
        }
        // waits 5, 5, 5 -> starts 0, 5, 10, 15
        #expect(await transport.starts == [.zero, .seconds(5), .seconds(10), .seconds(15)])
    }

    @Test("absent or unusable Retry-After waits 1 second", arguments: [
        RateLimitRetryTests.tooMany(nil),
        RateLimitRetryTests.tooMany("soon"),
        RateLimitRetryTests.tooMany("-3"),
        ScriptedStep.slackError("ratelimited"),
    ])
    func defaultWait(first: ScriptedStep) async throws {
        let clock = VirtualClock()
        let transport = RecordingTransport([first, .ok], clock: clock)
        let client = SlackWebClient(transport: transport, clock: clock)

        _ = try await client.call("auth.test", parameters: [:], credential: credential)

        #expect(await transport.starts == [.zero, .seconds(1)])
    }

    @Test("other failures are not retried", arguments: [
        ScriptedStep.slackError("invalid_auth"),
        .slackError("channel_not_found"),
        .respond(status: 500, body: ""),
        .fail(URLError(.timedOut)),
    ])
    func otherFailuresAreNotRetried(step: ScriptedStep) async {
        let clock = VirtualClock()
        let transport = RecordingTransport([step, .ok], clock: clock)
        let client = SlackWebClient(transport: transport, clock: clock)

        await #expect(throws: SlackError.self) {
            try await client.call("auth.test", parameters: [:], credential: credential)
        }
        #expect(await transport.requests.count == 1)
    }
}
