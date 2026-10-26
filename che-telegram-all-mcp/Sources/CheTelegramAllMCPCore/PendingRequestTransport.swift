import Foundation
import Logging
import MCP

/// Wraps the server's transport and counts the requests read from it that
/// have not been answered yet (PsychQuant/che-msg#57).
///
/// The SDK handles each request in a task of its own, and
/// `Server.waitUntilCompleted()` returns when the input ends, not when those
/// tasks have answered; `run()` waits on `waitUntilAnswered(timeout:)` before
/// it closes TDLib. Counting at the transport sees every request, including
/// `initialize` and `tools/list` that the SDK answers itself, and a request is
/// counted before the server can read it, so its answer cannot come first.
actor PendingRequestTransport: Transport {
    nonisolated let logger: Logger
    private let inner: any Transport
    /// Unanswered requests by id; a count, since a client may reuse an id.
    private var unanswered: [ID: Int] = [:]

    init(wrapping inner: any Transport) async {
        logger = await inner.logger
        self.inner = inner
    }

    /// How many requests read so far have no answer yet.
    var unansweredCount: Int { unanswered.values.reduce(0, +) }

    func connect() async throws { try await inner.connect() }

    func disconnect() async { await inner.disconnect() }

    /// Sends `data`, then counts each response in it as answered. A send that
    /// fails counts too: nothing more can be sent for that request.
    func send(_ data: Data) async throws {
        defer { Self.messages(in: data).forEach { if $0.method == nil, let id = $0.id { remove(id) } } }
        try await inner.send(data)
    }

    /// The inner transport's messages, each counted before it is passed on.
    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        let forwarding = Task { await forward(to: continuation) }
        continuation.onTermination = { _ in forwarding.cancel() }
        return stream
    }

    /// Waits until every request read so far has been answered, or `timeout`
    /// seconds pass; returns whether all were answered.
    func waitUntilAnswered(timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !unanswered.isEmpty {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func forward(to continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation) async {
        do {
            for try await data in await inner.receive() {
                read(data)
                continuation.yield(data)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Counts the requests in a message the server is about to read that the
    /// SDK answers later, in a task of its own, and forgets a request that a
    /// `notifications/cancelled` names, since the SDK may never answer it.
    /// Follows how swift-sdk 0.12's `Server.start` reads a message: a batch is
    /// read only when every item is a request or a notification, else it gets
    /// one error with a random id; a client's response gets no answer; a
    /// message that is none of these is answered inside the receive loop.
    private func read(_ data: Data) {
        let messages: [Envelope]
        if let batch = try? JSONDecoder().decode([Envelope].self, from: data) {
            guard !batch.isEmpty, batch.allSatisfy(\.isBatchItem) else { return }
            messages = batch
        } else if let message = try? JSONDecoder().decode(Envelope.self, from: data), !message.isResponse {
            messages = [message]
        } else {
            return
        }
        for message in messages where message.isVersion2 && message.method != nil {
            if let id = message.id {
                unanswered[id, default: 0] += 1
            } else if message.method == CancelledNotification.name, let id = message.cancelledID {
                remove(id)
            }
        }
    }

    private func remove(_ id: ID) {
        guard let count = unanswered[id] else { return }
        unanswered[id] = count > 1 ? count - 1 : nil
    }

    /// The JSON-RPC objects in `data`: one, or the items of a batch.
    private static func messages(in data: Data) -> [Envelope] {
        if let batch = try? JSONDecoder().decode([Envelope].self, from: data) { return batch }
        return (try? JSONDecoder().decode(Envelope.self, from: data)).map { [$0] } ?? []
    }

    /// The fields of a JSON-RPC object that decide whether it is answered.
    private struct Envelope: Decodable {
        let isVersion2: Bool
        let hasID: Bool
        /// The id as the SDK reads it (null is the empty string); nil when
        /// there is none or it is not a string or an integer.
        let id: ID?
        let method: String?
        let isResponse: Bool
        let cancelledID: ID?

        /// Whether the SDK can read this as an item of a batch.
        var isBatchItem: Bool { isVersion2 && method != nil && (!hasID || id != nil) }

        private enum Keys: String, CodingKey { case jsonrpc, id, method, params, result, error }
        private struct CancelledParams: Decodable { let requestId: ID? }

        init(from decoder: Decoder) throws {
            let object = try decoder.container(keyedBy: Keys.self)
            isVersion2 = (try? object.decode(String.self, forKey: .jsonrpc)) == "2.0"
            hasID = object.contains(.id)
            id = hasID ? try? object.decode(ID.self, forKey: .id) : nil
            method = try? object.decode(String.self, forKey: .method)
            isResponse = object.contains(.result) || object.contains(.error)
            cancelledID = (try? object.decode(CancelledParams.self, forKey: .params))?.requestId
        }
    }
}
