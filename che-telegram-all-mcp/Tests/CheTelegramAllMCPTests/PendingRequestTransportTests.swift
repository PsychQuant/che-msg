import XCTest
import MCP
@testable import CheTelegramAllMCPCore

/// Which messages `PendingRequestTransport` counts as requests waiting for an
/// answer, and which sends answer them (PsychQuant/che-msg#57).
final class PendingRequestTransportTests: XCTestCase {

    private func request(_ id: String, _ method: String = "tools/list") -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#
    }

    private func response(_ id: String) -> String {
        #"{"id":\#(id),"jsonrpc":"2.0","result":{}}"#
    }

    /// Reads everything `inner` delivers through `tracker`, as the server's
    /// receive loop does, and returns it.
    @discardableResult
    private func readAll(_ tracker: PendingRequestTransport) async throws -> [String] {
        var read: [String] = []
        for try await data in await tracker.receive() { read.append(String(decoding: data, as: UTF8.self)) }
        return read
    }

    private func send(_ tracker: PendingRequestTransport, _ message: String) async throws {
        try await tracker.send(Data(message.utf8))
    }

    func testCountsRequestsByIDAndNotNotifications() async throws {
        let messages = [request("1"), request(#""1""#), ScriptedMessages.initialized, request("2"), request("2")]
        let inner = ScriptedTransport(messages)
        let tracker = await PendingRequestTransport(wrapping: inner)
        let read = try await readAll(tracker)
        XCTAssertEqual(read, messages, "messages pass through unchanged")
        var count = await tracker.unansweredCount
        XCTAssertEqual(count, 4, "1 and \"1\" are different ids; a reused id counts twice; the notification not at all")

        try await send(tracker, response(#""1""#))
        count = await tracker.unansweredCount
        XCTAssertEqual(count, 3, "the string id answers only the string-id request")
        try await send(tracker, response("1"))
        try await send(tracker, response("2"))
        count = await tracker.unansweredCount
        XCTAssertEqual(count, 1, "one answer for a reused id answers one of its requests")
        try await send(tracker, #"{"error":{"code":-32601,"message":"Method not found"},"id":2,"jsonrpc":"2.0"}"#)
        count = await tracker.unansweredCount
        XCTAssertEqual(count, 0, "an error response answers the request too")
        let sent = await inner.sent.count
        XCTAssertEqual(sent, 4)
    }

    func testABatchCountsEachRequestAndItsResponseArrayAnswersThem() async throws {
        let batch = "[\(request("3")),\(ScriptedMessages.initialized),\(request(#""b""#))]"
        let tracker = await PendingRequestTransport(wrapping: ScriptedTransport([batch]))
        try await readAll(tracker)
        var count = await tracker.unansweredCount
        XCTAssertEqual(count, 2)
        try await send(tracker, "[\(response("3")),\(response(#""b""#))]")
        count = await tracker.unansweredCount
        XCTAssertEqual(count, 0)
    }

    /// The SDK reads a batch only when it can read every item; otherwise, and
    /// for an empty batch, it sends one error with a random id, so none of the
    /// requests in it will be answered by id.
    func testABatchTheSDKCannotReadCountsNothing() async throws {
        let tracker = await PendingRequestTransport(wrapping: ScriptedTransport([
            "[\(request("4")),{\"id\":5,\"method\":\"tools/list\"}]",   // second item has no jsonrpc
            "[\(request("6")),{\"jsonrpc\":\"2.0\",\"id\":7}]",          // second item has no method
            "[\(request("8")),3]",
            "[]",
        ]))
        try await readAll(tracker)
        let count = await tracker.unansweredCount
        XCTAssertEqual(count, 0)
    }

    /// Responses from the client and messages the SDK cannot read as a request
    /// are not counted: the SDK either sends nothing for them or answers them
    /// in its receive loop, before `waitUntilCompleted()` returns.
    func testClientResponsesAndUnreadableMessagesAreNotCounted() async throws {
        let tracker = await PendingRequestTransport(wrapping: ScriptedTransport([
            response("9"),
            #"{"jsonrpc":"2.0","id":9,"error":{"code":1,"message":"x"}}"#,
            #"{"jsonrpc":"1.0","id":10,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":1.5,"method":"tools/list"}"#,      // the SDK reads this as a notification
            #"{"jsonrpc":"2.0","id":11}"#,
            "not json",
            "42",
        ]))
        try await readAll(tracker)
        let count = await tracker.unansweredCount
        XCTAssertEqual(count, 0)
    }

    /// The SDK reads a null id as the empty string and answers under it.
    func testANullIDIsCountedAsTheSDKReadsIt() async throws {
        let tracker = await PendingRequestTransport(wrapping: ScriptedTransport([request("null")]))
        try await readAll(tracker)
        var count = await tracker.unansweredCount
        XCTAssertEqual(count, 1)
        try await send(tracker, response(#""""#))
        count = await tracker.unansweredCount
        XCTAssertEqual(count, 0)
    }

    /// The SDK sends no answer to a request the client cancelled.
    func testACancelledRequestNoLongerCounts() async throws {
        let tracker = await PendingRequestTransport(wrapping: ScriptedTransport([
            request("12"), request("13"),
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":12,"reason":"x"}}"#,
            #"[{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":13}}]"#,
        ]))
        try await readAll(tracker)
        let count = await tracker.unansweredCount
        XCTAssertEqual(count, 0)
    }

    func testARequestTheServerSendsAnswersNothing() async throws {
        let tracker = await PendingRequestTransport(wrapping: ScriptedTransport([request("14")]))
        try await readAll(tracker)
        try await send(tracker, request("14", "ping"))
        try await send(tracker, #"{"jsonrpc":"2.0","method":"notifications/message","params":{}}"#)
        let count = await tracker.unansweredCount
        XCTAssertEqual(count, 1)
    }

    /// Nothing more can be sent for a request whose answer failed to send.
    func testAFailedSendStillAnswersTheRequest() async throws {
        let tracker = await PendingRequestTransport(wrapping: ScriptedTransport([request("15")],
                                                                                sendError: MCPError.connectionClosed))
        try await readAll(tracker)
        do {
            try await send(tracker, response("15"))
            XCTFail("the send error must reach the caller")
        } catch {}
        let count = await tracker.unansweredCount
        XCTAssertEqual(count, 0)
    }

    func testWaitUntilAnsweredEndsAtTheTimeoutOrWhenAllAreAnswered() async throws {
        let tracker = await PendingRequestTransport(wrapping: ScriptedTransport([request("16")]))
        var answered = await tracker.waitUntilAnswered(timeout: 1)
        XCTAssertTrue(answered, "nothing read yet, nothing to wait for")
        try await readAll(tracker)
        let start = ContinuousClock.now
        answered = await tracker.waitUntilAnswered(timeout: 0.1)
        XCTAssertFalse(answered)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(100))

        Task { try? await Task.sleep(nanoseconds: 50_000_000); try? await self.send(tracker, self.response("16")) }
        answered = await tracker.waitUntilAnswered(timeout: 5)
        XCTAssertTrue(answered)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2), "the wait ends when the answer is sent, not at the timeout")
    }
}
