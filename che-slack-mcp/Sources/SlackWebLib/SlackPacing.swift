import Foundation

/// Per-workspace request pacing (spec: slack-web-client, "Request pacing").
///
/// The defaults, 350 ms between request starts and 3 requests in flight, are
/// borrowed from jtalk22/slack-mcp-server and have not been measured in this
/// project (design: 預設請求間隔與並行上限). They lower the chance of tripping
/// Slack's anomaly detection; they cannot remove it.
public struct SlackPacingConfig: Sendable, Equatable {
    public static let defaultMinIntervalMilliseconds = 350
    public static let defaultMaxConcurrency = 3
    public static let minIntervalRange = 0...60_000
    public static let maxConcurrencyRange = 1...10

    public static let `default` = SlackPacingConfig(
        unchecked: defaultMinIntervalMilliseconds, defaultMaxConcurrency)

    public let minIntervalMilliseconds: Int
    public let maxConcurrency: Int

    /// Nil when either value is outside its range.
    public init?(minIntervalMilliseconds: Int, maxConcurrency: Int) {
        guard Self.minIntervalRange.contains(minIntervalMilliseconds),
              Self.maxConcurrencyRange.contains(maxConcurrency)
        else { return nil }
        self.init(unchecked: minIntervalMilliseconds, maxConcurrency)
    }

    private init(unchecked minIntervalMilliseconds: Int, _ maxConcurrency: Int) {
        self.minIntervalMilliseconds = minIntervalMilliseconds
        self.maxConcurrency = maxConcurrency
    }

    var minInterval: Duration { .milliseconds(minIntervalMilliseconds) }
}

extension SlackPacingConfig {
    public static let minIntervalVariable = "SLACK_MCP_MIN_INTERVAL_MS"
    public static let maxConcurrencyVariable = "SLACK_MCP_MAX_CONCURRENCY"

    /// Reads the two overrides from `environment`. A value that is not an
    /// integer inside its range is ignored: the default applies and one
    /// warning naming the variable is returned. A variable that is unset,
    /// empty or only whitespace counts as not overridden and gives no
    /// warning. Pure; `fromEnvironment` writes the warnings.
    public static func resolve(environment: [String: String]) -> (config: SlackPacingConfig, warnings: [String]) {
        var warnings: [String] = []
        let interval = override(minIntervalVariable, in: environment, range: minIntervalRange,
                                default: defaultMinIntervalMilliseconds, warnings: &warnings)
        let concurrency = override(maxConcurrencyVariable, in: environment, range: maxConcurrencyRange,
                                   default: defaultMaxConcurrency, warnings: &warnings)
        return (SlackPacingConfig(unchecked: interval, concurrency), warnings)
    }

    /// `resolve` on the process environment, writing each warning as one line
    /// to `warn` (standard error unless a test injects something else).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment,
                                       warn: (String) -> Void = SlackPacingConfig.writeToStandardError) -> SlackPacingConfig {
        let (config, warnings) = resolve(environment: environment)
        warnings.forEach(warn)
        return config
    }

    public static func writeToStandardError(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func override(_ name: String, in environment: [String: String], range: ClosedRange<Int>,
                                 default fallback: Int, warnings: inout [String]) -> Int {
        guard let raw = environment[name] else { return fallback }
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return fallback }
        if let number = Int(value), range.contains(number) { return number }
        warnings.append("warning: ignoring \(name)=\(String(reflecting: raw)): expected an integer from "
                        + "\(range.lowerBound) to \(range.upperBound); using the default \(fallback)")
        return fallback
    }
}

/// Holds each workspace's pacing state. Shared by every copy of one
/// `SlackWebClient`.
actor SlackPacer {
    private struct Lane {
        var lastStart: Duration?
        var inFlight = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let config: SlackPacingConfig
    private let clock: SlackClock
    private var lanes: [String: Lane] = [:]

    init(config: SlackPacingConfig, clock: SlackClock) {
        self.config = config
        self.clock = clock
    }

    /// Returns once a request to `workspace` may start: a concurrency slot is
    /// held and the minimum interval since the previous start has passed.
    /// The slot is taken first, so a request waiting out the interval already
    /// counts as in flight; slots are handed out in arrival order. Every
    /// successful `acquire` must be paired with one `release` when the
    /// request finishes; when `acquire` throws (cancellation) it has already
    /// released.
    func acquire(workspace: String) async throws {
        await takeSlot(workspace)
        do {
            try await waitForStart(workspace)
        } catch {
            release(workspace: workspace)
            throw error
        }
    }

    /// Frees the slot, handing it straight to the longest waiter if any.
    func release(workspace: String) {
        guard var lane = lanes[workspace], lane.inFlight > 0 else {
            assertionFailure("release without acquire for \(workspace)")
            return
        }
        if lane.waiters.isEmpty {
            lane.inFlight -= 1
            lanes[workspace] = lane
        } else {
            let next = lane.waiters.removeFirst()
            lanes[workspace] = lane
            next.resume()
        }
    }

    /// Callers waiting for a concurrency slot (for tests).
    func queuedCount(workspace: String) -> Int {
        lanes[workspace]?.waiters.count ?? 0
    }

    private func takeSlot(_ workspace: String) async {
        if lanes[workspace, default: Lane()].inFlight < config.maxConcurrency {
            lanes[workspace, default: Lane()].inFlight += 1
            return
        }
        // `release` hands the slot over without decrementing `inFlight`.
        await withCheckedContinuation { lanes[workspace, default: Lane()].waiters.append($0) }
    }

    /// The start is recorded before returning, with no suspension between the
    /// check and the record, so concurrent callers never share a start; one
    /// that wakes to find its start taken waits again.
    private func waitForStart(_ workspace: String) async throws {
        while true {
            let now = clock.now()
            if let last = lanes[workspace]?.lastStart, now < last + config.minInterval {
                try await clock.sleep(for: last + config.minInterval - now)
                continue
            }
            lanes[workspace, default: Lane()].lastStart = now
            return
        }
    }
}
