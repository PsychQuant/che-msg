import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-web-client — Requirement "Request pacing", the concurrency
/// half.
@Suite("Request pacing: concurrency")
struct ConcurrencyLimitTests {
    static func credential(_ team: String) -> SlackCredential {
        SlackCredential(teamID: team, token: "xoxc-1", cookie: "abc")
    }

    /// Issues `total` concurrent calls to `team`, waits until every call is
    /// either in the transport or queued in the pacer, records how many are
    /// in the transport, then lets them all finish.
    static func run(_ client: SlackWebClient, _ transport: GatedTransport,
                    total: Int, team: String = "T01") async throws -> (settledInFlight: Int, settled: Bool) {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<total {
                group.addTask { _ = try await client.call("auth.test", parameters: [:], credential: credential(team)) }
            }
            let settled = await eventually {
                let queued = await client.pacer.queuedCount(workspace: team)
                return await transport.gate.inFlight + queued == total
            }
            let inFlight = await transport.gate.inFlight
            await transport.gate.open()
            try await group.waitForAll()
            return (inFlight, settled)
        }
    }

    @Test("no more than the maximum concurrency of requests to one workspace are in flight", arguments: [1, 3, 10])
    func limitHolds(limit: Int) async throws {
        let transport = GatedTransport()
        let pacing = SlackPacingConfig(minIntervalMilliseconds: 0, maxConcurrency: limit)!
        let client = SlackWebClient(transport: transport, pacing: pacing, clock: VirtualClock())
        let total = limit + 2

        let (inFlight, settled) = try await Self.run(client, transport, total: total)

        #expect(settled)
        #expect(inFlight == limit)
        #expect(await transport.gate.maxInFlight == limit)
        #expect(await transport.gate.completed == total)
    }

    @Test("the default limit is 3, with the default interval")
    func defaultLimit() async throws {
        let transport = GatedTransport()
        let client = SlackWebClient(transport: transport, clock: VirtualClock())

        let (inFlight, settled) = try await Self.run(client, transport, total: 5)

        #expect(settled)
        #expect(inFlight == 3)
        #expect(await transport.gate.maxInFlight == 3)
        #expect(await transport.gate.completed == 5)
    }

    @Test("the limit is per workspace")
    func limitIsPerWorkspace() async throws {
        let transport = GatedTransport()
        let pacing = SlackPacingConfig(minIntervalMilliseconds: 0, maxConcurrency: 1)!
        let client = SlackWebClient(transport: transport, pacing: pacing, clock: VirtualClock())

        try await withThrowingTaskGroup(of: Void.self) { group in
            for team in ["T01", "T02"] {
                group.addTask { _ = try await client.call("auth.test", parameters: [:], credential: Self.credential(team)) }
            }
            #expect(await eventually { await transport.gate.inFlight == 2 })
            await transport.gate.open()
            try await group.waitForAll()
        }
        #expect(await transport.gate.maxInFlight == 2)
    }

    @Test("a call cancelled while waiting for its start gives its slot back")
    func cancelledWaitReleasesSlot() async throws {
        let clock = StuckClock()
        let transport = RecordingTransport()
        let pacing = SlackPacingConfig(minIntervalMilliseconds: 1000, maxConcurrency: 1)!
        let client = SlackWebClient(transport: transport, pacing: pacing, clock: clock)
        let credential = Self.credential("T01")

        _ = try await client.call("auth.test", parameters: [:], credential: credential) // starts at 0
        let waiting = Task { try await client.call("auth.test", parameters: [:], credential: credential) }
        #expect(await eventually { clock.sleepers == 1 }) // holds the only slot, waiting for 1 s
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }

        clock.set(.seconds(2)) // interval has passed; only a leaked slot could block now
        let next = Task { try await client.call("auth.test", parameters: [:], credential: credential) }
        let reached = await eventually(timeout: .seconds(2)) { await transport.requests.count == 2 }
        #expect(reached)
        if reached { _ = try await next.value } else { next.cancel() }
    }
}
