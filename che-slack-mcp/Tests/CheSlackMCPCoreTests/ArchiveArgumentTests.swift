import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-chat-archive, "Slack archive tool parameters". A refused
/// argument is an error naming it, reads no Keychain item, calls no Slack
/// method and writes no file.
@Suite("archive_conversation_to_markdown arguments")
struct ArchiveArgumentTests {
    static let tool = "archive_conversation_to_markdown"

    /// spec: "Relative output directory is refused".
    @Test("output_dir archives/slack is refused naming output_dir, and nothing is written")
    func relativeOutputDir() async throws {
        let transport = MethodTransport([:])
        let (handler, keychain) = try await readHandler(transport)
        let relative = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("archives")
        let existedBefore = FileManager.default.fileExists(atPath: relative.path)

        let result = await handler.callTool(name: Self.tool, arguments: [
            "conversation_id": .string("C01"), "output_dir": .string("archives/slack"),
        ])

        expectRefused(result, naming: "output_dir", transport: transport, keychain: keychain)
        #expect(FileManager.default.fileExists(atPath: relative.path) == existedBefore)
    }

    struct Refusal: Sendable, CustomTestStringConvertible {
        let names: String
        let value: Value?
        var testDescription: String { "\(names) = \(value.map { "\($0)" } ?? "absent")" }
    }

    static let refusals: [Refusal] = [
        Refusal(names: "output_dir", value: nil),
        Refusal(names: "output_dir", value: .string("")),
        Refusal(names: "output_dir", value: .int(1)),
        Refusal(names: "output_dir", value: .string("~/archive")),
        Refusal(names: "conversation_id", value: .string("#general")),
        Refusal(names: "after_ts", value: .double(1793498700.0001)),
        Refusal(names: "after_ts", value: .string("yesterday")),
        Refusal(names: "since_date", value: .string("2026-13-01")),
        Refusal(names: "since_date", value: .string("2026-02-30")),
        Refusal(names: "since_date", value: .string("2026-1-01")),
        Refusal(names: "since_date", value: .int(20261101)),
        Refusal(names: "utc_offset", value: .string("+18:30")),
        Refusal(names: "utc_offset", value: .string("+8:00")),
        Refusal(names: "utc_offset", value: .string("08:00")),
        Refusal(names: "utc_offset", value: .string("+08:60")),
        Refusal(names: "utc_offset", value: .int(8)),
        Refusal(names: "thread_lookback_days", value: .int(-1)),
        Refusal(names: "thread_lookback_days", value: .int(366)),
        Refusal(names: "thread_lookback_days", value: .string("30")),
        Refusal(names: "thread_lookback_days", value: .double(1.5)),
    ]

    @Test("an argument outside its form or range is refused naming it; nothing is read, called or written",
          arguments: refusals)
    func refused(_ refusal: Refusal) async throws {
        let transport = MethodTransport([:])
        let (handler, keychain) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }
        var arguments: [String: Value] = ["conversation_id": .string("C01"), "output_dir": .string(output.path)]
        arguments[refusal.names] = refusal.value

        let result = await handler.callTool(name: Self.tool, arguments: arguments)

        expectRefused(result, naming: refusal.names, transport: transport, keychain: keychain)
        #expect(!FileManager.default.fileExists(atPath: output.path), "a refused call created output_dir")
    }

    @Test("the boundaries are accepted: utc_offset ±18:00, thread_lookback_days 0 and 365, a leap day",
          arguments: [("utc_offset", Value.string("-18:00")), ("utc_offset", .string("+18:00")),
                      ("thread_lookback_days", .int(0)), ("thread_lookback_days", .int(365)),
                      ("since_date", .string("2028-02-29"))])
    func boundaries(name: String, value: Value) async throws {
        let transport = MethodTransport(["conversations.history": ArchiveFake.history([])])
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await handler.callTool(name: Self.tool, arguments: [
            "conversation_id": .string("C01"), "output_dir": .string(output.path), name: value,
        ])

        #expect(result.isError == false, "\(text(result))")
    }
}

@Suite("archive_conversation_to_markdown schema")
struct ArchiveSchemaTests {
    @Test("conversation_id and output_dir are required; after_ts, since_date, utc_offset, thread_lookback_days (0 to 365, default 30) and workspace are optional")
    func schema() throws {
        let tool = try #require(SlackToolHandler.tools.first { $0.name == "archive_conversation_to_markdown" })
        let schema = try #require(tool.inputSchema.objectValue)
        let properties = try #require(schema["properties"]?.objectValue)
        #expect(schema["required"] == .array([.string("conversation_id"), .string("output_dir")]))
        #expect(properties.keys.sorted() == ["after_ts", "conversation_id", "output_dir", "since_date",
                                             "thread_lookback_days", "utc_offset", "workspace"])
        for name in ["after_ts", "conversation_id", "output_dir", "since_date", "utc_offset", "workspace"] {
            #expect(properties[name]?.objectValue?["type"] == .string("string"), "\(name)")
        }
        let lookback = try #require(properties["thread_lookback_days"]?.objectValue)
        #expect(lookback["type"] == .string("integer"))
        #expect(lookback["minimum"] == .int(0))
        #expect(lookback["maximum"] == .int(365))
        #expect(lookback["default"] == .int(30))
    }
}
