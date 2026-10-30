import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// The manifest is never reset silently: one that is missing means a first
/// run; one that cannot be read, or was not written by this tool for this
/// conversation, refuses the call before Slack is called and leaves every
/// file as it was. A manifest that cannot be written is an error result,
/// and the previous bookmark stays.
@Suite("archive_conversation_to_markdown manifest safety")
struct ArchiveManifestSafetyTests {
    static let lastRun = #""last_run": {"at": "2026-11-01T11:05:00+08:00", "top_level_messages": 1, "thread_replies": 0, "new_messages": 1}"#

    /// A manifest this tool would write, with `fields` replacing or adding
    /// top-level fields (written as JSON text).
    static func manifest(_ fields: [String: String] = [:]) -> String {
        var all = [
            "format": #""che-slack-mcp archive manifest""#, "version": "1", "team_id": #""T01""#,
            "conversation_id": #""C01""#, "newest_ts": #""1793498700.000100""#, "newest_reply_ts": "{}",
        ]
        all.merge(fields) { $1 }
        return "{" + all.sorted { $0.key < $1.key }.map { #""\#($0.key)": \#($0.value)"# }.joined(separator: ", ")
            + ", " + lastRun + "}"
    }

    static let damaged: [(String, String)] = [
        ("not JSON", #"{"format": "che-slack-mcp archive manifest","#),
        ("empty", ""),
        ("a JSON array", "[]"),
        ("newest_ts as a number", manifest(["newest_ts": "1793498700.000100"])),
        ("newest_ts missing", manifest().replacingOccurrences(of: #""newest_ts": "1793498700.000100", "#, with: "")),
        ("newest_ts not a Slack ts", manifest(["newest_ts": #""yesterday""#])),
        ("a reply record keyed by a non-ts", manifest(["newest_reply_ts": #"{"x": "1793498820.000200"}"#])),
        ("a reply record holding a number", manifest(["newest_reply_ts": #"{"1793498700.000100": 1793498820}"#])),
        ("a count as a string", manifest().replacingOccurrences(of: #""new_messages": 1"#, with: #""new_messages": "1""#)),
        ("another tool's format", manifest(["format": #""telegram archive""#])),
        ("another version", manifest(["version": "2"])),
        ("another conversation", manifest(["conversation_id": #""C02""#])),
        ("another workspace", manifest(["team_id": #""T02""#])),
        ("a continuation that is not an object", manifest(["continuation": #""1793498000.000100""#])),
        ("a continuation without below_ts", manifest(["continuation": #"{"top_ts": "1793585100.000100"}"#])),
        ("a continuation ts as a number",
         manifest(["continuation": #"{"top_ts": "1793585100.000100", "below_ts": 1793585000.000100}"#])),
        ("a continuation ts that is not a Slack ts",
         manifest(["continuation": #"{"top_ts": "1793585100.000100", "below_ts": "today"}"#])),
        // Without newest_ts only the ts check can refuse it: "y" sorts after
        // "x", so the order check alone would accept it.
        ("continuation ts that are not Slack ts, with newest_ts null",
         manifest(["newest_ts": "null", "continuation": #"{"top_ts": "y", "below_ts": "x"}"#])),
        ("a continuation whose below_ts is newer than its top_ts",
         manifest(["continuation": #"{"top_ts": "1793585000.000100", "below_ts": "1793585100.000100"}"#])),
        ("a continuation whose below_ts is not newer than newest_ts",
         manifest(["continuation": #"{"top_ts": "1793585100.000100", "below_ts": "1793498700.000100"}"#])),
    ]

    @Test("a manifest that is damaged, mistyped or not this conversation's refuses the call; nothing is written",
          arguments: damaged)
    func refusedManifest(_ name: String, content: String) async throws {
        let transport = ArchiveSafetyTests.slack()
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }
        let file = output.url.appendingPathComponent(ArchiveManifestTests.manifestPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: false, encoding: .utf8)

        let result = await ArchiveToolTests.archive(handler, into: output)

        expectError(result, containing: [file.path, "manifest", "nothing was archived"])
        #expect(transport.calls.isEmpty, "\(name): Slack was called")
        #expect(output.listing() == ["T01", "T01/C01", ArchiveManifestTests.manifestPath], "\(name)")
        #expect(try output.read(ArchiveManifestTests.manifestPath) == content, "\(name)")
    }

    /// A manifest written before continuations existed has none: it is read
    /// as having no unfinished walk. One with a continuation is continued.
    @Test("the well-formed manifest of the damaged cases is accepted, with or without a continuation",
          arguments: [(manifest(), nil as String?),
                      (manifest(["continuation": #"{"top_ts": "1793585100.000100", "below_ts": "1793585000.000100"}"#]),
                       "1793585000.000100")])
    func wellFormedManifest(_ content: String, latest: String?) async throws {
        let transport = ArchiveSafetyTests.slack()
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }
        let file = output.url.appendingPathComponent(ArchiveManifestTests.manifestPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: false, encoding: .utf8)

        let result = await ArchiveToolTests.archive(handler, into: output, ["utc_offset": .string("+08:00"),
                                                                            "thread_lookback_days": .int(0)])

        #expect(result.isError == false, "\(text(result))")
        #expect(transport.calls.first?.parameters["oldest"] == "1793498700.000100")
        #expect(transport.calls.first?.parameters["latest"] == latest)
    }

    @Test("a manifest that cannot be read (mode 000) refuses the call naming it")
    func unreadableManifest() async throws {
        let transport = ArchiveSafetyTests.slack()
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }
        let file = output.url.appendingPathComponent(ArchiveManifestTests.manifestPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.manifest().write(to: file, atomically: false, encoding: .utf8)
        #expect(chmod(file.path, 0o000) == 0)

        let result = await ArchiveToolTests.archive(handler, into: output)

        expectError(result, containing: [file.path, "nothing was archived"])
        #expect(transport.calls.isEmpty)
        #expect(output.listing() == ["T01", "T01/C01", ArchiveManifestTests.manifestPath])
    }

    @Test("a manifest larger than the limit is refused without being read whole")
    func oversizedManifest() async throws {
        let transport = ArchiveSafetyTests.slack()
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }
        let file = output.url.appendingPathComponent(ArchiveManifestTests.manifestPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let padded = Self.manifest() + String(repeating: " ", count: ArchiveDirectory.maxManifestBytes)
        try padded.write(to: file, atomically: false, encoding: .utf8)

        let result = await ArchiveToolTests.archive(handler, into: output)

        expectError(result, containing: [file.path, "larger than"])
        #expect(transport.calls.isEmpty)
    }

    @Test("a manifest that is a symbolic link is refused; its target is left alone")
    func symlinkedManifest() async throws {
        let transport = ArchiveSafetyTests.slack()
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        let elsewhere = TemporaryDirectory()
        defer { output.remove(); elsewhere.remove() }
        try elsewhere.create()
        let target = elsewhere.url.appendingPathComponent("manifest.json")
        try Self.manifest().write(to: target, atomically: false, encoding: .utf8)
        let file = output.url.appendingPathComponent(ArchiveManifestTests.manifestPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)

        let result = await ArchiveToolTests.archive(handler, into: output)

        expectError(result, containing: [file.path, "not a regular file"])
        #expect(transport.calls.isEmpty)
        #expect(try String(contentsOf: target, encoding: .utf8) == Self.manifest())
        #expect(elsewhere.listing() == ["manifest.json"])
    }

    /// Silent failure: the conversation directory turns read-only after the
    /// new message's day file is written (inside the second history page's
    /// answer), so only the manifest cannot be replaced. The day file
    /// stays, the manifest keeps the previous bookmark, no temporary file
    /// is left, and the next call reads from that bookmark again.
    @Test("a manifest that cannot be written is an error naming it; the previous bookmark stays and is read again")
    func manifestWriteFailure() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let (first, _) = try await readHandler(ArchiveToolTests.slack(
            history: ArchiveFake.history([ArchiveToolTests.alexPlain])))
        _ = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, first), into: output)
        let manifestBefore = try output.read(ArchiveManifestTests.manifestPath)
        let conversation = output.url.appendingPathComponent("T01/C01")
        let later = MethodTransport { call in
            switch (call.method, call.parameters["cursor"]) {
            case ("conversations.history", nil):
                return .body(ArchiveFake.history([#"{"user":"U02","text":"new","ts":"1793585100.000100"}"#],
                                                 cursor: "c2"))
            case ("conversations.history", "c2"?):
                chmod(conversation.path, 0o500)
                return .body(ArchiveFake.history([]))
            case ("users.info", _): return ArchiveFake.users(["U02": "Alex"], call)
            default: return .body(Fake.slackError("no_scripted_answer"))
            }
        }
        let (laterHandler, _) = try await readHandler(later)
        let noLookback: [String: Value] = ["utc_offset": .string("+08:00"), "thread_lookback_days": .int(0)]
        let nextDay = ArchiveManifestTests.firstRun + ArchiveManifestTests.day

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(nextDay, laterHandler), into: output,
                                                    noLookback)

        expectError(result, containing: [conversation.appendingPathComponent("manifest.json").path,
                                         "Could not write the manifest", "previous bookmark"])
        #expect(try output.read(ArchiveManifestTests.manifestPath) == manifestBefore)
        #expect(try output.read("T01/C01/2026-11-02.md").contains("<!-- msg:1793585100.000100 -->"))
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-11-01.md", "T01/C01/2026-11-02.md",
                                     ArchiveManifestTests.manifestPath])
        #expect(chmod(conversation.path, 0o700) == 0)
        let again = ArchiveToolTests.slack(history: ArchiveFake.history([]))
        let (againHandler, _) = try await readHandler(again)
        _ = await ArchiveToolTests.archive(ArchiveManifestTests.at(nextDay, againHandler), into: output, noLookback)
        #expect(again.calls.first?.parameters["oldest"] == "1793498700.000100")
    }
}
