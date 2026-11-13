import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// Where the archive refuses to write, and what a failure leaves behind.
/// Every refusal before the first Slack call leaves Slack uncalled; every
/// failure is an error result naming the path or the argument.
@Suite("archive_conversation_to_markdown safety")
struct ArchiveSafetyTests {
    static func slack() -> MethodTransport {
        ArchiveToolTests.slack(history: ArchiveFake.history([ArchiveToolTests.alexPlain]))
    }

    static let dayFile = """
        ---
        team_id: "T01"
        conversation_id: "C01"
        date: 2026-11-01
        utc_offset: "+09:00"
        ---

        <!-- msg:1793498820.000200 -->
        **11:07 我**：
        earlier

        """

    @Test("missing output_dir and parents are created, every created directory 0700")
    func createdDirectories() async throws {
        let transport = Self.slack()
        let (handler, _) = try await readHandler(transport)
        let root = TemporaryDirectory()
        defer { root.remove() }

        let result = await handler.callTool(name: ArchiveToolTests.tool, arguments: [
            "conversation_id": .string("C01"), "output_dir": .string(root.path + "/a/b"), "utc_offset": .string("+08:00"),
        ])

        #expect(result.isError == false, "\(text(result))")
        for directory in ["", "a", "a/b", "a/b/T01", "a/b/T01/C01"] {
            #expect(try root.mode(directory) == 0o700, "\(directory)")
        }
        #expect(try root.mode("a/b/T01/C01/2026-11-01.md") == 0o600)
    }

    @Test("a symbolic link as the team or conversation directory is refused before Slack is called",
          arguments: ["T01", "T01/C01"])
    func symlinkedDirectory(linked: String) async throws {
        let transport = Self.slack()
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        let elsewhere = TemporaryDirectory()
        defer { output.remove(); elsewhere.remove() }
        try output.create()
        try elsewhere.create()
        let link = output.url.appendingPathComponent(linked)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere.url)

        let result = await ArchiveToolTests.archive(handler, into: output)

        expectError(result, containing: [link.path, "symbolic link"])
        #expect(transport.calls.isEmpty)
        #expect(elsewhere.listing().isEmpty)
    }

    @Test("a day file that is a symbolic link is refused before Slack is called")
    func symlinkedDayFile() async throws {
        let transport = Self.slack()
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        let elsewhere = TemporaryDirectory()
        defer { output.remove(); elsewhere.remove() }
        try elsewhere.create()
        let target = elsewhere.url.appendingPathComponent("target.md")
        try Self.dayFile.replacingOccurrences(of: "+09:00", with: "+08:00")
            .write(to: target, atomically: false, encoding: .utf8)
        let conversation = output.url.appendingPathComponent("T01/C01")
        try FileManager.default.createDirectory(at: conversation, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: conversation.appendingPathComponent("2026-11-01.md"),
                                                   withDestinationURL: target)
        let before = try String(contentsOf: target, encoding: .utf8)

        let result = await ArchiveToolTests.archive(handler, into: output)

        expectError(result, containing: ["2026-11-01.md", "not a regular file"])
        #expect(transport.calls.isEmpty)
        #expect(try String(contentsOf: target, encoding: .utf8) == before)
    }

    /// As in che-telegram-all-mcp: a day file written at another offset is
    /// not merged into, since its times and day would disagree.
    @Test("a day file written with another utc_offset refuses the call, naming utc_offset and the recorded offset")
    func offsetMismatch() async throws {
        let transport = Self.slack()
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }
        let conversation = output.url.appendingPathComponent("T01/C01")
        try FileManager.default.createDirectory(at: conversation, withIntermediateDirectories: true)
        try Self.dayFile.write(to: conversation.appendingPathComponent("2026-11-01.md"), atomically: false, encoding: .utf8)

        let result = await ArchiveToolTests.archive(handler, into: output)

        expectError(result, containing: ["utc_offset", "+09:00"])
        #expect(transport.calls.isEmpty)
        #expect(try output.read("T01/C01/2026-11-01.md") == Self.dayFile)
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-11-01.md"])
    }

    @Test("an output_dir that is a regular file is refused naming output_dir before Slack is called")
    func outputDirIsAFile() async throws {
        let transport = Self.slack()
        let (handler, _) = try await readHandler(transport)
        let root = TemporaryDirectory()
        defer { root.remove() }
        try root.create()
        let file = root.url.appendingPathComponent("file")
        try "x".write(to: file, atomically: false, encoding: .utf8)

        let result = await handler.callTool(name: ArchiveToolTests.tool, arguments: [
            "conversation_id": .string("C01"), "output_dir": .string(file.path), "utc_offset": .string("+08:00"),
        ])

        expectError(result, containing: ["output_dir", file.path])
        #expect(transport.calls.isEmpty)
        #expect(root.listing() == ["file"])
    }

    /// Silent failure: a day file that cannot be written is an error naming
    /// it; the existing file is untouched and no temporary file is left.
    @Test("a day file that cannot be written is an error naming its path; nothing partial is left behind")
    func writeFailure() async throws {
        let transport = Self.slack()
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }
        let conversation = output.url.appendingPathComponent("T01/C01")
        try FileManager.default.createDirectory(at: conversation, withIntermediateDirectories: true)
        let existing = Self.dayFile.replacingOccurrences(of: "+09:00", with: "+08:00")
        let file = conversation.appendingPathComponent("2026-11-01.md")
        try existing.write(to: file, atomically: false, encoding: .utf8)
        #expect(chmod(conversation.path, 0o500) == 0)

        let result = await ArchiveToolTests.archive(handler, into: output)

        expectError(result, containing: [file.path, "Could not write"])
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-11-01.md"])
        #expect(try output.read("T01/C01/2026-11-01.md") == existing)
    }

    /// The rename fails after the temporary file was written (the target is
    /// a non-empty directory): the temporary file is removed.
    @Test("a failed replace removes its temporary file and names the path")
    func replaceCleansUp() throws {
        let root = TemporaryDirectory()
        defer { root.remove() }
        let target = root.url.appendingPathComponent("2026-11-01.md")
        try FileManager.default.createDirectory(at: target.appendingPathComponent("inner"), withIntermediateDirectories: true)

        #expect(throws: ToolFailure.self) { try ArchiveDirectory.replace(target, with: Data("x".utf8)) }
        do {
            try ArchiveDirectory.replace(target, with: Data("x".utf8))
        } catch {
            #expect(error.message.contains(target.path))
        }
        #expect(root.listing() == ["2026-11-01.md", "2026-11-01.md/inner"])
    }

    @Test("a Slack error is an error result and creates nothing")
    func slackErrorCreatesNothing() async throws {
        let transport = MethodTransport(["conversations.history": Fake.slackError("channel_not_found")])
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await ArchiveToolTests.archive(handler, into: output)

        expectError(result, containing: ["T01 alpha", "channel_not_found"])
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("a team id that is not a plain Slack id is refused and nothing is written")
    func unsafeTeamID() async throws {
        let odd = SlackWorkspace(teamID: "..", domain: "odd", name: "Odd", userID: "U01")
        let keychain = try await MemoryKeychain.with([odd], credentials: ["..": (Fake.alphaToken, Fake.alphaCookie)])
        let transport = Self.slack()
        let output = TemporaryDirectory()
        defer { output.remove() }
        try output.create()

        let handler = SlackToolHandler(
            store: SlackCredentialStore(reader: keychain, writer: keychain),
            client: SlackWebClient(transport: transport,
                                   pacing: SlackPacingConfig(minIntervalMilliseconds: 0, maxConcurrency: 1)!,
                                   clock: InstantClock()))

        // `..` as a directory name would put the conversation next to output_dir.
        let outside = output.url.deletingLastPathComponent().appendingPathComponent("C01")
        let existedBefore = FileManager.default.fileExists(atPath: outside.path)

        let result = await ArchiveToolTests.archive(handler, into: output)

        expectError(result, containing: ["team id"])
        #expect(transport.calls.isEmpty)
        #expect(output.listing().isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.path) == existedBefore)
    }
}
