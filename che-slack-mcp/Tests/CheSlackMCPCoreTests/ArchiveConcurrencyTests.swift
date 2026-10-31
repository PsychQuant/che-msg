import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-chat-archive, "Archive concurrency and partial progress",
/// the first sentence: two archives of one conversation of one workspace
/// into one `output_dir` never run at once. A first call is held inside
/// Slack by `HeldTransport` while a second call is made, so the overlap is
/// real and needs no sleep.
@Suite("archive_conversation_to_markdown concurrency")
struct ArchiveConcurrencyTests {
    static func conversationDir(_ output: TemporaryDirectory, _ conversation: String = "C01") -> URL {
        output.url.appendingPathComponent("T01/\(conversation)")
    }

    /// A first call into `output` held inside its first Slack request. The
    /// task opens `entered` itself when it ends, so a call that never
    /// reached Slack fails the test instead of hanging it.
    static func heldCall(into output: TemporaryDirectory,
                         _ extra: [String: Value] = ["utc_offset": .string("+08:00")])
        async throws -> (HeldTransport, Task<CallTool.Result, Never>) {
        let held = HeldTransport(ArchiveSafetyTests.slack())
        let handler = try await archiveHandler(over: held)
        let task = Task {
            let result = await ArchiveToolTests.archive(handler, into: output, extra)
            held.entered.open()
            return result
        }
        try await held.entered.pass()
        return (held, task)
    }

    @Test("spec: a second archive of the conversation while one runs is refused, calls no Slack, writes nothing",
          .timeLimit(.minutes(1)))
    func concurrentCallRefused() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let (held, running) = try await Self.heldCall(into: output)
        let before = output.listing()
        let second = ArchiveSafetyTests.slack()
        let (secondHandler, _) = try await readHandler(second)

        let refused = await ArchiveToolTests.archive(secondHandler, into: output)
        let afterRefusal = output.listing()
        held.release.open()
        let first = await running.value

        expectError(refused, containing: ["Another archive of conversation C01", "T01", output.path, "running",
                                          "Nothing was written"])
        #expect(second.calls.isEmpty, "the refused call reached Slack: \(second.calls)")
        #expect(afterRefusal == before, "the refused call wrote \(afterRefusal)")
        #expect(first.isError == false, "\(text(first))")
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-11-01.md", "T01/C01/manifest.json"])
        #expect(!ArchiveLockProbe.isLocked(Self.conversationDir(output)), "the lock outlived the call")
    }

    /// Several Claude sessions each run their own server: the lock is a
    /// `flock`, which a descriptor of another process holds the same way as
    /// this probe's.
    @Test("a lock held through another descriptor (as by another server process) refuses the call")
    func lockHeldElsewhere() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let conversation = Self.conversationDir(output)
        try FileManager.default.createDirectory(at: conversation, withIntermediateDirectories: true)
        let transport = ArchiveSafetyTests.slack()
        let (handler, _) = try await readHandler(transport)
        let descriptor = try ArchiveLockProbe.hold(conversation)

        let refused = await ArchiveToolTests.archive(handler, into: output)
        close(descriptor)
        let after = await ArchiveToolTests.archive(handler, into: output)

        expectError(refused, containing: ["Another archive of conversation C01", "running"])
        #expect(transport.methods == ["conversations.history", "users.info"], "only the second call reaches Slack")
        #expect(after.isError == false, "\(text(after))")
    }

    @Test("while one runs, another conversation into the same output_dir and the same one elsewhere are not refused",
          .timeLimit(.minutes(1)))
    func scopeIsOneConversationInOneDirectory() async throws {
        let output = TemporaryDirectory()
        let elsewhere = TemporaryDirectory()
        defer { output.remove(); elsewhere.remove() }
        let (held, running) = try await Self.heldCall(into: output)
        let (handler, _) = try await readHandler(ArchiveSafetyTests.slack())

        let otherConversation = await ArchiveToolTests.archive(handler, into: output, [
            "utc_offset": .string("+08:00"), "conversation_id": .string("C02"),
        ])
        let otherDirectory = await ArchiveToolTests.archive(handler, into: elsewhere)
        held.release.open()
        let first = await running.value

        #expect(otherConversation.isError == false, "\(text(otherConversation))")
        #expect(otherDirectory.isError == false, "\(text(otherDirectory))")
        #expect(first.isError == false, "\(text(first))")
        #expect(output.listing().contains("T01/C02/2026-11-01.md"))
        #expect(elsewhere.listing().contains("T01/C01/2026-11-01.md"))
    }

    /// Safe default: the lock goes with the call however it ends. A call
    /// cancelled inside Slack wrote nothing, so the directories it created
    /// to take the lock are removed again.
    @Test("a cancelled call releases the lock and leaves nothing behind", .timeLimit(.minutes(1)))
    func cancelledCallReleasesLock() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let (_, running) = try await Self.heldCall(into: output)
        let lockedMeanwhile = ArchiveLockProbe.isLocked(Self.conversationDir(output))

        running.cancel()
        let cancelled = await running.value

        expectError(cancelled, containing: ["cancelled"])
        #expect(lockedMeanwhile, "the running call did not hold the lock")
        #expect(!ArchiveLockProbe.isLocked(Self.conversationDir(output)))
        #expect(!FileManager.default.fileExists(atPath: output.path), "left behind: \(output.listing())")
        let (handler, _) = try await readHandler(ArchiveSafetyTests.slack())
        let after = await ArchiveToolTests.archive(handler, into: output)
        #expect(after.isError == false, "\(text(after))")
    }

    /// Silent failure: a day file that cannot be written ends the call with
    /// an error under the lock; the lock is released all the same.
    @Test("a call that fails under the lock releases it")
    func failedCallReleasesLock() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let conversation = Self.conversationDir(output)
        try FileManager.default.createDirectory(at: conversation, withIntermediateDirectories: true)
        #expect(chmod(conversation.path, 0o500) == 0)
        let (handler, _) = try await readHandler(ArchiveSafetyTests.slack())

        let result = await ArchiveToolTests.archive(handler, into: output)

        expectError(result, containing: ["Could not write"])
        #expect(!ArchiveLockProbe.isLocked(conversation))
        #expect(output.listing() == ["T01", "T01/C01"])
    }
}
