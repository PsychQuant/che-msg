import Foundation
import Testing
@testable import SlackWebLib

/// spec: slack-web-client — Requirement "Request pacing", the overrides.
@Suite("Request pacing: environment overrides")
struct PacingConfigTests {
    static let interval = "SLACK_MCP_MIN_INTERVAL_MS"
    static let concurrency = "SLACK_MCP_MAX_CONCURRENCY"

    @Test("unset variables give 350 ms and 3 with no warning")
    func unset() {
        let (config, warnings) = SlackPacingConfig.resolve(environment: ["PATH": "/usr/bin"])

        #expect(config.minIntervalMilliseconds == 350)
        #expect(config.maxConcurrency == 3)
        #expect(warnings.isEmpty)
    }

    @Test("in-range overrides apply, including both ends of each range", arguments: [
        ([interval: "0"], 0, 3), ([interval: "1000"], 1000, 3), ([interval: "60000"], 60000, 3),
        ([concurrency: "1"], 350, 1), ([concurrency: "5"], 350, 5), ([concurrency: "10"], 350, 10),
        ([interval: " 500 ", concurrency: "2"], 500, 2),
    ] as [([String: String], Int, Int)])
    func inRange(environment: [String: String], intervalMs: Int, maxConcurrency: Int) {
        let (config, warnings) = SlackPacingConfig.resolve(environment: environment)

        #expect(config.minIntervalMilliseconds == intervalMs)
        #expect(config.maxConcurrency == maxConcurrency)
        #expect(warnings.isEmpty)
    }

    @Test("an override outside its range or not an integer is ignored with a warning naming the variable", arguments: [
        (interval, "-1"), (interval, "60001"), (interval, "abc"), (interval, "1.5"), (interval, "3e2"),
        (concurrency, "0"), (concurrency, "11"), (concurrency, "50"), (concurrency, "three"),
        (concurrency, "99999999999999999999"),
    ])
    func outOfRange(variable: String, value: String) throws {
        let (config, warnings) = SlackPacingConfig.resolve(environment: [variable: value])

        #expect(config == .default)
        #expect(config.minIntervalMilliseconds == 350)
        #expect(config.maxConcurrency == 3)
        let warning = try #require(warnings.count == 1 ? warnings.first : nil)
        #expect(warning.contains(variable))
    }

    @Test("two bad overrides give two warnings and both defaults")
    func bothBad() {
        let (config, warnings) = SlackPacingConfig.resolve(environment: [Self.interval: "-5", Self.concurrency: "0"])

        #expect(config == .default)
        #expect(warnings.count == 2)
        #expect(warnings.contains { $0.contains(Self.interval) })
        #expect(warnings.contains { $0.contains(Self.concurrency) })
    }

    @Test("an empty value is treated as unset", arguments: ["", "   "])
    func emptyIsUnset(value: String) {
        let (config, warnings) = SlackPacingConfig.resolve(environment: [Self.interval: value, Self.concurrency: value])

        #expect(config == .default)
        #expect(warnings.isEmpty)
    }

    @Test("SLACK_MCP_MAX_CONCURRENCY=50: a warning naming it is written and at most 3 requests run at once")
    func scenarioFifty() async throws {
        var written: [String] = []
        let config = SlackPacingConfig.fromEnvironment([Self.concurrency: "50"], warn: { written.append($0) })
        #expect(written.count == 1)
        #expect(written.first?.contains(Self.concurrency) == true)

        let transport = GatedTransport()
        let client = SlackWebClient(transport: transport, pacing: config, clock: VirtualClock())
        let (inFlight, settled) = try await ConcurrencyLimitTests.run(client, transport, total: 5)

        #expect(settled)
        #expect(inFlight == 3)
        #expect(await transport.gate.maxInFlight == 3)
    }

    @Test("SLACK_MCP_MIN_INTERVAL_MS=1000 spaces back-to-back requests by 1 s")
    func intervalOverrideEndToEnd() async throws {
        var written: [String] = []
        let config = SlackPacingConfig.fromEnvironment([Self.interval: "1000"], warn: { written.append($0) })
        let clock = VirtualClock()
        let transport = RecordingTransport(clock: clock)
        let client = SlackWebClient(transport: transport, pacing: config, clock: clock)
        let credential = SlackCredential(teamID: "T01", token: "xoxc-1", cookie: "abc")

        _ = try await client.call("auth.test", parameters: [:], credential: credential)
        _ = try await client.call("auth.test", parameters: [:], credential: credential)

        #expect(written.isEmpty)
        #expect(await transport.starts == [.zero, .seconds(1)])
    }

    @Test("the initializer refuses values outside the ranges", arguments: [
        (-1, 3, false), (60_001, 3, false), (350, 0, false), (350, 11, false),
        (0, 1, true), (60_000, 10, true),
    ])
    func initializerRanges(intervalMs: Int, maxConcurrency: Int, accepted: Bool) {
        let config = SlackPacingConfig(minIntervalMilliseconds: intervalMs, maxConcurrency: maxConcurrency)

        #expect((config != nil) == accepted)
    }
}
