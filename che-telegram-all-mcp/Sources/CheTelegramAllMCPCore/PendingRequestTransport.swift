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
    /// SDK answers later, in a task of its own. A cancelled request is still
    /// counted: the tool handler does not stop when cancelled, so the SDK
    /// still answers it (a cancel that comes before the SDK has started the
    /// handler is ignored; one that comes after it has started but before the
    /// handler runs leaves the request unanswered, and `run()` then waits
    /// for the bound).
    private func read(_ data: Data) {
        for id in Self.laterAnsweredRequestIDs(in: data) { unanswered[id, default: 0] += 1 }
    }

    private func remove(_ id: ID) {
        guard let count = unanswered[id] else { return }
        unanswered[id] = count > 1 ? count - 1 : nil
    }

    /// The ids of the requests in `data` that the SDK answers in a task of
    /// their own. Decodes `data` the way swift-sdk 0.12's `Server.start` does,
    /// in the same order and with the SDK's own message types: a batch is read
    /// only when every item is a request or a notification (else it gets one
    /// error with a random id) and is answered inside the receive loop; a
    /// single message is a response first (no answer), then a request; anything
    /// else is answered inside the receive loop.
    private static func laterAnsweredRequestIDs(in data: Data) -> [ID] {
        let decoder = JSONDecoder()
        if let items = try? decoder.decode([Value].self, from: data) {
            return batchRequestIDs(items) ?? []
        }
        if (try? decoder.decode(Response<AnyRequestMethod>.self, from: data)) != nil { return [] }
        if let request = try? decoder.decode(Request<AnyRequestMethod>.self, from: data) { return [request.id] }
        return []
    }

    /// The ids of the requests in a batch, or nil when the SDK cannot read it:
    /// it re-encodes each item and reads one with an `id` key as a request,
    /// any other as a notification.
    private static func batchRequestIDs(_ items: [Value]) -> [ID]? {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var ids: [ID] = []
        for item in items {
            guard case .object(let fields) = item, let data = try? encoder.encode(item) else { return nil }
            if fields["id"] != nil {
                guard let request = try? decoder.decode(Request<AnyRequestMethod>.self, from: data) else { return nil }
                ids.append(request.id)
            } else {
                guard (try? decoder.decode(Message<AnyMessageNotification>.self, from: data)) != nil else { return nil }
            }
        }
        return ids
    }

    /// The SDK's type-erased method and notification (`AnyMethod`,
    /// `AnyNotification`) are internal; these have the same parameters and
    /// result, so the SDK's `Request`, `Response` and `Message` decode with
    /// them exactly as they do inside the SDK.
    private enum AnyRequestMethod: MCP.Method {
        static let name = ""
        typealias Parameters = Value
        typealias Result = Value
    }

    private struct AnyMessageNotification: MCP.Notification {
        static let name = ""
        typealias Parameters = Value
    }

    /// The JSON-RPC objects in `data`: one, or the items of a batch.
    private static func messages(in data: Data) -> [Sent] {
        if let batch = try? JSONDecoder().decode([Sent].self, from: data) { return batch }
        return (try? JSONDecoder().decode(Sent.self, from: data)).map { [$0] } ?? []
    }

    /// What the server sends: a response has an id and no method.
    private struct Sent: Decodable {
        let id: ID?
        let method: String?
    }
}
