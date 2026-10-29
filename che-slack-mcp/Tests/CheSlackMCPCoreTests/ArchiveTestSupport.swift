import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// A fresh directory under the system temporary directory, removed by
/// `remove()`. Its path is not created until a test creates it, so a test
/// can also check that nothing was written there.
struct TemporaryDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("che-slack-archive-test-\(UUID().uuidString)")
    }

    var path: String { url.path }

    func create() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Restores write permission everywhere below, so a test that made a
    /// directory read-only still cleans up, then removes the tree.
    func remove() {
        if let walker = FileManager.default.enumerator(atPath: path) {
            for case let relative as String in walker {
                chmod(url.appendingPathComponent(relative).path, 0o700)
            }
        }
        chmod(path, 0o700)
        try? FileManager.default.removeItem(at: url)
    }

    /// Every path below the directory, relative and sorted; empty when it
    /// does not exist.
    func listing() -> [String] {
        (FileManager.default.subpaths(atPath: path) ?? []).sorted()
    }

    func read(_ relative: String) throws -> String {
        try String(contentsOf: url.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The permission bits of `relative` (the directory itself for "").
    func mode(_ relative: String) throws -> Int {
        let target = relative.isEmpty ? path : url.appendingPathComponent(relative).path
        let attributes = try FileManager.default.attributesOfItem(atPath: target)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

/// `conversations.history`, `conversations.replies` and `users.info`
/// answers built from message JSON objects.
enum ArchiveFake {
    static func history(_ messages: [String], cursor: String? = nil) -> String {
        let metadata = cursor.map { #","response_metadata":{"next_cursor":"\#($0)"}"# } ?? ""
        return #"{"ok":true,"messages":[\#(messages.joined(separator: ","))],"has_more":\#(cursor != nil)\#(metadata)}"#
    }

    /// With `hasMore`, every page offers a next cursor, as Slack does for a
    /// thread longer than the client's page limit.
    static func replies(_ messages: [String], hasMore: Bool = false) -> String {
        let metadata = hasMore ? #","response_metadata":{"next_cursor":"more"}"# : ""
        return #"{"ok":true,"messages":[\#(messages.joined(separator: ","))],"has_more":\#(hasMore)\#(metadata)}"#
    }

    static func user(_ id: String, display: String) -> String {
        #"{"ok":true,"user":{"id":"\#(id)","name":"handle.\#(id)","profile":{"display_name":"\#(display)"}}}"#
    }

    /// Answers `users.info` from `names` (id → display name), and
    /// `user_not_found` for anyone else.
    static func users(_ names: [String: String], _ call: SlackCall) -> ScriptedAnswer {
        let id = call.parameters["user"] ?? ""
        return .body(names[id].map { user(id, display: $0) } ?? Fake.slackError("user_not_found"))
    }
}

/// A one-shot signal. `pass()` returns once `open()` was called (at once if
/// it already was) and throws `CancellationError` when the waiting task is
/// cancelled first, so a test synchronizes without sleeping.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func open() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            isOpen = true
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        for waiter in pending { waiter.resume() }
    }

    func pass() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Under the lock, so a cancellation either is seen here or
                // finds the waiter registered.
                let now: Result<Void, Error>? = lock.withLock {
                    if isOpen { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    waiters[id] = continuation
                    return nil
                }
                if let now { continuation.resume(with: now) }
            }
        } onCancel: {
            lock.withLock { waiters.removeValue(forKey: id) }?.resume(throwing: CancellationError())
        }
    }
}

/// Holds every request until `release` opens, then answers from `inner`.
/// The first request opens `entered`, so a test awaiting it knows the call
/// is inside Slack, past taking the archive lock.
final class HeldTransport: SlackTransport, @unchecked Sendable {
    let inner: MethodTransport
    let entered = Gate()
    let release = Gate()

    init(_ inner: MethodTransport) { self.inner = inner }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        entered.open()
        try await release.pass()
        return try await inner.send(request)
    }
}

/// A one-workspace (`T01 alpha`) handler over any transport.
func archiveHandler(over transport: any SlackTransport) async throws -> SlackToolHandler {
    let keychain = try await MemoryKeychain.with([Fake.alpha])
    return SlackToolHandler(
        store: SlackCredentialStore(reader: keychain, writer: keychain),
        client: SlackWebClient(transport: transport,
                               pacing: SlackPacingConfig(minIntervalMilliseconds: 0, maxConcurrency: 1)!,
                               clock: InstantClock()))
}

/// The archive lock as another process would take it: an exclusive `flock`
/// on the conversation directory through a descriptor of the test's own. A
/// `flock` belongs to the open file description, so this conflicts with the
/// server's lock exactly as a second process's would.
enum ArchiveLockProbe {
    /// A descriptor holding the lock on `directory`; close it to release.
    static func hold(_ directory: URL) throws -> Int32 {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(descriptor >= 0, "could not open \(directory.path)")
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "could not lock \(directory.path)")
        return descriptor
    }

    /// Whether some descriptor holds the lock on `directory`; false when the
    /// directory does not exist.
    static func isLocked(_ directory: URL) -> Bool {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(descriptor, LOCK_UN)
        return false
    }
}
