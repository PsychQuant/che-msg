import XCTest
@testable import TelegramAllLib

/// `close(timeout:)` returns within its timeout even when TDLib never answers
/// the close request (PsychQuant/che-msg#64). TDLibKit routes no answer to a
/// client it has already dropped, so a close that awaited the request could
/// wait forever and, with one logout at a time, refuse every later logout.
/// A fake request stands in for TDLib.
final class TDLibCloseBoundTests: XCTestCase {
    final class Probe: @unchecked Sendable {
        var now: TimeInterval = 0
        var sent = 0
        var closedAt: TimeInterval?
        var isClosed: Bool { closedAt.map { now >= $0 } ?? false }
    }

    /// A close request that is not answered for 10 s of real time, far past
    /// what a fake-clock close takes; a close that awaited it would take that long.
    private static func neverAnswered(_ probe: Probe) -> @Sendable () async -> Void {
        { probe.sent += 1; try? await Task.sleep(nanoseconds: 10 * 1_000_000_000) }
    }

    private func runClose(_ probe: Probe, timeout: TimeInterval = 30) async -> Bool {
        await TDLibClient.close(timeout: timeout, now: { probe.now },
                                sleep: { probe.now += $0; await Task.yield() },
                                isClosed: { probe.isClosed }, send: Self.neverAnswered(probe))
    }

    func testAnUnansweredRequestStillReturnsFalseAtTheTimeout() async {
        let probe = Probe()
        let start = Date()
        let closed = await runClose(probe)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the close did not wait for the request's answer")
        XCTAssertFalse(closed)
        XCTAssertGreaterThanOrEqual(probe.now, 30)
        XCTAssertLessThan(probe.now, 30.5)
        XCTAssertEqual(probe.sent, 1)
    }

    /// TDLib can close (and report it as an update) without answering the request.
    func testAnUnansweredRequestStillSeesTDLibClose() async {
        let probe = Probe()
        probe.closedAt = 3
        let closed = await runClose(probe)
        XCTAssertTrue(closed)
        XCTAssertLessThan(probe.now, 3.5)
    }

    func testAnAlreadyClosedClientSendsNothing() async {
        let probe = Probe()
        probe.closedAt = 0
        let closed = await runClose(probe)
        XCTAssertTrue(closed)
        XCTAssertEqual(probe.sent, 0)
        XCTAssertEqual(probe.now, 0)
    }

    /// The instance method goes through the bounded helper rather than
    /// awaiting the request before its deadline.
    func testTheClientsCloseUsesTheBoundedHelper() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TelegramAllLib/TDLibClient.swift"), encoding: .utf8)
        let body = try XCTUnwrap(source.components(separatedBy: "public func close(timeout: TimeInterval) async -> Bool {")
            .dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(body.contains("await Self.close(timeout: timeout"), body)
        XCTAssertFalse(body.contains("await client.close()"), "the request is not awaited before the deadline: \(body)")
    }
}
