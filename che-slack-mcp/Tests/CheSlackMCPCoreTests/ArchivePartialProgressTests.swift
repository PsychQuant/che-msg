import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-chat-archive, "Archive concurrency and partial progress":
/// when the client gives up on `rateLimited` (after its 3 retries), the
/// day files written so far stay, the manifest's newest top-level ts does
/// not move, the manifest records the oldest top-level ts written as the
/// point the next run continues below (its `continuation`), and the result
/// is not an error. Times at +08:00:
/// `1793451600.000100` is 2026-10-31 21:00, `1793498700.000100` 2026-11-01
/// 10:05; runs are at 2026-11-01 11:05 (`1793502300`).
@Suite("archive_conversation_to_markdown partial progress")
struct ArchivePartialProgressTests {
    static let bookmarkTS = "1793451600.000100"
    static let newestTS = "1793498700.000100"
    static let question = #"{"user":"U02","text":"question","ts":"1793451600.000100"}"#
    static let rateLimited = ScriptedAnswer.response(status: 429, headers: ["Retry-After": "30"], body: "")
    static let lookback0: [String: Value] = ["utc_offset": .string("+08:00"), "thread_lookback_days": .int(0)]

    /// What the result says about a stop after `written` messages.
    static func note(_ written: String) -> String {
        "Slack kept rate limiting this workspace after the client's retries, so the run stopped early with "
            + "\(written) written. The manifest's newest ts did not move: calling the tool again, after "
            + "retry_after_seconds, continues where the manifest records this walk stopped, or reads the same range "
            + "again when nothing was recorded, and merges the blocks already written in place."
    }

    /// A first run that archives only `question`, leaving the manifest's
    /// newest top-level ts at `bookmarkTS`.
    static func archiveBookmark(into output: TemporaryDirectory) async throws {
        let (handler, _) = try await readHandler(ArchiveToolTests.slack(history: ArchiveFake.history([question])))
        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output, lookback0)
        #expect(result.isError == false, "\(text(result))")
        #expect(try ArchiveManifestTests.manifest(output)["newest_ts"] as? String == bookmarkTS)
    }

    /// History page 1 holds `first` and offers cursor `c2`; page 2 answers
    /// `second`. users.info knows Alex (U02) and Kim (U03).
    static func twoPages(_ first: [String], then second: ScriptedAnswer,
                         users: @escaping @Sendable (SlackCall) -> ScriptedAnswer = {
                             ArchiveFake.users(["U02": "Alex", "U03": "Kim"], $0)
                         }) -> MethodTransport {
        MethodTransport { call in
            switch (call.method, call.parameters["cursor"]) {
            case ("conversations.history", nil): return .body(ArchiveFake.history(first, cursor: "c2"))
            case ("conversations.history", "c2"?): return second
            case ("users.info", _): return users(call)
            default: return .body(Fake.slackError("no_scripted_answer"))
            }
        }
    }

    static func handler(_ transport: MethodTransport) async throws -> SlackToolHandler {
        ArchiveManifestTests.at(ArchiveManifestTests.firstRun, try await readHandler(transport).0)
    }

    /// spec: "Rate limit stops a run midway". The manifest is written only
    /// to record the continuation; its reply records stay as they were.
    @Test("spec: a rate limit midway keeps the day files, leaves newest_ts at 1793451600.000100, records 1793498700.000100 to continue below, not an error")
    func rateLimitStopsMidway() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try await Self.archiveBookmark(into: output)
        let older = try output.read("T01/C01/2026-10-31.md")
        let slack = Self.twoPages([ArchiveToolTests.alexPlain], then: Self.rateLimited)

        let result = await ArchiveToolTests.archive(try await Self.handler(slack), into: output, Self.lookback0)

        expectJSON(result, #"{"complete":false,"conversation_id":"C01","files":["T01/C01/2026-11-01.md"],"#
                   + #""lookback_complete":false,"new_messages":1,"note":"\#(Self.note("1 message"))","#
                   + #""retry_after_seconds":30,"skipped_messages":0,"stopped_reason":"rate_limited","team_id":"T01","#
                   + #""thread_replies":0,"top_level_messages":1,"utc_offset":"+08:00"}"#)
        #expect(try output.read("T01/C01/2026-11-01.md").contains("<!-- msg:\(Self.newestTS) -->\n**10:05 Alex**："))
        #expect(try output.read("T01/C01/2026-10-31.md") == older)
        #expect(try ArchiveManifestTests.manifest(output) == ArchiveManifestTests.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": "1793451600.000100", "newest_reply_ts": {},
             "continuation": {"top_ts": "1793498700.000100", "below_ts": "1793498700.000100"},
             "last_run": {"at": "2026-11-01T11:05:00+08:00", "top_level_messages": 1, "thread_replies": 0,
                          "new_messages": 1}}
            """))
        // The walk's lower bound was the bookmark; page 2 was tried once and
        // retried 3 times before the client gave up.
        #expect(slack.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": Self.bookmarkTS])
        #expect(slack.calls.filter { $0.parameters["cursor"] == "c2" }.count == 1 + SlackWebClient.maxRateLimitRetries)
        #expect(!ArchiveLockProbe.isLocked(ArchiveConcurrencyTests.conversationDir(output)))
    }

    /// The next call continues below the recorded `1793498700.000100`
    /// (sent as `latest`) down to the unmoved bookmark: only the range below
    /// is requested and written, the block written before the stop is left
    /// as it is, and newest_ts moves to the top of the walk. Messages newer
    /// than it were not looked for, so the call is not complete.
    @Test("calling again after the stop continues below the recorded ts, then moves newest_ts to the walk's top")
    func resumeAfterRateLimit() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try await Self.archiveBookmark(into: output)
        let limited = Self.twoPages([ArchiveToolTests.alexPlain], then: Self.rateLimited)
        _ = await ArchiveToolTests.archive(try await Self.handler(limited), into: output, Self.lookback0)
        let written = try output.read("T01/C01/2026-11-01.md")
        let below = #"{"user":"U03","text":"below","ts":"1793494800.000200"}"#
        let resumed = MethodTransport { call in
            switch call.method {
            case "conversations.history" where call.parameters["latest"] == Self.newestTS:
                return .body(ArchiveFake.history([below]))
            case "users.info": return ArchiveFake.users(["U02": "Alex", "U03": "Kim"], call)
            default: return .body(Fake.slackError("no_scripted_answer"))
            }
        }

        let result = await ArchiveToolTests.archive(try await Self.handler(resumed), into: output, Self.lookback0)

        expectJSON(result, #"{"complete":false,"conversation_id":"C01","files":["T01/C01/2026-11-01.md"],"#
                   + #""lookback_complete":true,"new_messages":1,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":0,"top_level_messages":1,"utc_offset":"+08:00"}"#)
        #expect(resumed.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": Self.bookmarkTS,
                                                    "latest": Self.newestTS])
        let file = try output.read("T01/C01/2026-11-01.md")
        #expect(file.contains("<!-- msg:1793494800.000200 -->\n**09:00 Kim**：\nbelow\n"))
        #expect(file.hasSuffix(String(written.drop { $0 != "<" })), "the block written before the stop changed")
        let manifest = try ArchiveManifestTests.manifest(output)
        #expect(manifest["newest_ts"] as? String == Self.newestTS)
        #expect(manifest["continuation"] == nil)
    }

    /// A rate limit on a thread's replies: the messages of the page listed
    /// so far, the parent included, are written; no further page is read.
    /// The parent's replies were not read, so the continuation stops above
    /// it: the next run lists the parent again and fetches its replies.
    @Test("a rate limit on replies writes the page's messages listed so far; the continuation stops above the parent")
    func repliesRateLimited() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let newer = #"{"user":"U02","text":"newer","ts":"1793498820.000200"}"#
        let slack = MethodTransport { call in
            switch call.method {
            case "conversations.history":
                return .body(ArchiveFake.history([newer, ArchiveToolTests.alexParent], cursor: "c2"))
            case "conversations.replies": return Self.rateLimited
            default: return ArchiveFake.users(["U02": "Alex"], call)
            }
        }

        let result = await ArchiveToolTests.archive(try await Self.handler(slack), into: output)

        expectJSON(result, #"{"complete":false,"conversation_id":"C01","files":["T01/C01/2026-11-01.md"],"#
                   + #""lookback_complete":false,"new_messages":2,"note":"\#(Self.note("2 messages"))","#
                   + #""retry_after_seconds":30,"skipped_messages":0,"stopped_reason":"rate_limited","team_id":"T01","#
                   + #""thread_replies":0,"top_level_messages":2,"utc_offset":"+08:00"}"#)
        #expect(slack.methods == ["conversations.history"] + Array(repeating: "conversations.replies", count: 4)
                + ["users.info"])
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-11-01.md", ArchiveManifestTests.manifestPath])
        let file = try output.read("T01/C01/2026-11-01.md")
        #expect(file.contains("<!-- msg:1793498700.000100 -->") && file.contains("<!-- msg:1793498820.000200 -->"))
        #expect(try ArchiveManifestTests.manifest(output) == ArchiveManifestTests.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": null, "newest_reply_ts": {},
             "continuation": {"top_ts": "1793498820.000200", "below_ts": "1793498820.000200"},
             "last_run": {"at": "2026-11-01T11:05:00+08:00", "top_level_messages": 2, "thread_replies": 0,
                          "new_messages": 2}}
            """))
    }

    /// Conservative: a message is written only with its sender's name, so
    /// a page whose name lookup is rate limited is not written; the pages
    /// before it are, and the continuation stops at the oldest of them.
    @Test("a rate limit on users.info leaves that page unwritten and keeps the pages before it")
    func userLookupRateLimited() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let kim = #"{"user":"U03","text":"kim","ts":"1793494800.000200"}"#
        let slack = Self.twoPages([ArchiveToolTests.alexPlain], then: .body(ArchiveFake.history([kim]))) { call in
            call.parameters["user"] == "U03" ? Self.rateLimited : ArchiveFake.users(["U02": "Alex"], call)
        }

        let result = await ArchiveToolTests.archive(try await Self.handler(slack), into: output)

        expectJSON(result, #"{"complete":false,"conversation_id":"C01","files":["T01/C01/2026-11-01.md"],"#
                   + #""lookback_complete":false,"new_messages":1,"note":"\#(Self.note("1 message"))","#
                   + #""retry_after_seconds":30,"skipped_messages":0,"stopped_reason":"rate_limited","team_id":"T01","#
                   + #""thread_replies":0,"top_level_messages":1,"utc_offset":"+08:00"}"#)
        #expect(try !output.read("T01/C01/2026-11-01.md").contains("1793494800.000200"))
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-11-01.md", ArchiveManifestTests.manifestPath])
        #expect(try ArchiveManifestTests.manifest(output)["continuation"] as? NSDictionary
                    == ["top_ts": Self.newestTS, "below_ts": Self.newestTS])
    }

    @Test("a rate limit on the first page of a first run writes nothing, creates nothing, and is not an error")
    func firstPageRateLimited() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let slack = MethodTransport { _ in Self.rateLimited }

        let result = await ArchiveToolTests.archive(try await Self.handler(slack), into: output)

        expectJSON(result, #"{"complete":false,"conversation_id":"C01","files":[],"lookback_complete":false,"#
                   + #""new_messages":0,"note":"\#(Self.note("0 messages"))","retry_after_seconds":30,"#
                   + #""skipped_messages":0,"stopped_reason":"rate_limited","team_id":"T01","thread_replies":0,"#
                   + #""top_level_messages":0,"utc_offset":"+08:00"}"#)
        #expect(!FileManager.default.fileExists(atPath: output.path), "created: \(output.listing())")
    }

    /// Conservative: reply bookmarks stay as they were too, even for a
    /// thread whose replies were all written before the stop, so the next
    /// run fetches them again and merges in place rather than trusting a
    /// partly written run. No top-level message was written, so there is
    /// nothing to continue and the manifest is not written at all. The second run is 20 days after the first;
    /// Kim's reply `1795140300.000300` is 2026-11-20 10:05.
    @Test("a rate limit leaves the reply bookmarks as they were, even for a thread fully written before it")
    func replyBookmarksKept() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let (first, _) = try await readHandler(ArchiveManifestTests.firstRunSlack())
        _ = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, first), into: output)
        let manifest = try output.read(ArchiveManifestTests.manifestPath)
        let late = "1795140300.000300"
        let parent = ArchiveManifestTests.parent(replies: 2, latest: late)
        let reply = #"{"user":"U03","text":"late answer","ts":"\#(late)","thread_ts":"1793498700.000100"}"#
        let slack = MethodTransport { call in
            switch (call.method, call.parameters["cursor"]) {
            case ("conversations.history", nil): return .body(ArchiveFake.history([parent], cursor: "c2"))
            case ("conversations.history", "c2"?): return Self.rateLimited
            case ("conversations.replies", _):
                return .body(ArchiveFake.replies([parent, ArchiveToolTests.ownReply, reply]))
            default: return ArchiveFake.users(["U02": "Alex", "U03": "Kim"], call)
            }
        }
        let (later, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(
            ArchiveManifestTests.at(ArchiveManifestTests.firstRun + 20 * ArchiveManifestTests.day, later), into: output,
            ArchiveManifestTests.lookback30)

        #expect(result.isError == false, "\(text(result))")
        #expect(text(result).contains(#""stopped_reason":"rate_limited""#), "\(text(result))")
        #expect(try output.read("T01/C01/2026-11-20.md").contains("<!-- msg:\(late) -->"))
        #expect(try output.read(ArchiveManifestTests.manifestPath) == manifest)
    }

    /// Other Slack errors keep their behaviour: an error result. Every page
    /// merged before the error stays written; the manifest is not written.
    @Test("a session error on page 2 is an error result; page 1 stays written, no manifest, the lock is released")
    func otherErrorsStayErrors() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let slack = Self.twoPages([ArchiveToolTests.alexPlain], then: .body(Fake.slackError("invalid_auth")))

        let result = await ArchiveToolTests.archive(try await Self.handler(slack), into: output)

        expectError(result, containing: ["T01 alpha", "invalid_auth"])
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-11-01.md"])
        #expect(!ArchiveLockProbe.isLocked(ArchiveConcurrencyTests.conversationDir(output)))
    }
}
