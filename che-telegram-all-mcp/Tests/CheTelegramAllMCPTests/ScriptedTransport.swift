import Foundation
import Logging
import MCP

/// A transport that delivers `messages` and then ends its input, as stdin does
/// when the client closes it, and keeps what the server sends (#57).
actor ScriptedTransport: Transport {
    nonisolated let logger = Logger(label: "scripted-transport", factory: { _ in SwiftLogNoOpLogHandler() })
    private let messages: [Data]
    private let sendDelay: TimeInterval
    private let sendError: Error?
    private(set) var sent: [Data] = []

    /// - Parameters:
    ///   - sendDelay: seconds each send takes before it is recorded.
    ///   - sendError: thrown by every send, which then records nothing.
    init(_ messages: [String], sendDelay: TimeInterval = 0, sendError: Error? = nil) {
        self.messages = messages.map { Data($0.utf8) }
        self.sendDelay = sendDelay
        self.sendError = sendError
    }

    func connect() async throws {}
    func disconnect() async {}

    func send(_ data: Data) async throws {
        if sendDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(sendDelay * 1_000_000_000)) }
        if let sendError { throw sendError }
        sent.append(data)
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            for message in messages { continuation.yield(message) }
            continuation.finish()
        }
    }

    /// The sent JSON-RPC objects, batches flattened.
    var sentObjects: [[String: Any]] {
        sent.flatMap { data -> [[String: Any]] in
            let json = try? JSONSerialization.jsonObject(with: data)
            return (json as? [[String: Any]]) ?? [json as? [String: Any]].compactMap { $0 }
        }
    }

    /// The integer ids of the sent responses (objects with an id and no method).
    var respondedIDs: [Int] {
        sentObjects.compactMap { $0["method"] == nil ? $0["id"] as? Int : nil }
    }
}

enum ScriptedMessages {
    static func initialize(id: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}"#
    }
    static let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
    static func toolsList(id: Int) -> String { #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/list"}"# }
}
