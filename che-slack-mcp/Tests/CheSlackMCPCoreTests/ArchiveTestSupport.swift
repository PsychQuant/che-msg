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
