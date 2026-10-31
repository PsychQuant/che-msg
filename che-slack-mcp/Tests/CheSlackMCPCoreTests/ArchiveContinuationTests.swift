import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-chat-archive, "Incremental archive and manifest": a walk
/// stopped before its lower bound is recorded in the manifest's
/// `continuation` (the newest top-level ts the walk started from, `top_ts`,
/// and the oldest top-level ts it wrote, `below_ts`), and the next call
/// continues it below `below_ts`, sent as `latest`. Times at +08:00: the
/// first run is 2026-11-01 11:05 (`1793502300`).
@Suite("archive_conversation_to_markdown unfinished walks")
struct ArchiveContinuationTests {
    static let lookback0: [String: Value] = ["utc_offset": .string("+08:00"), "thread_lookback_days": .int(0)]

    /// Writes `content` as the conversation's manifest before a run.
    static func preset(_ output: TemporaryDirectory, manifest content: String) throws {
        let file = output.url.appendingPathComponent(ArchiveManifestTests.manifestPath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: false, encoding: .utf8)
    }

    /// A manifest whose bookmark is `1793451600.000100` (2026-10-31 21:00)
    /// with a walk from `1793498700.000100` (2026-11-01 10:05) left
    /// unfinished below `1793498000.000100` (09:53:20).
    static let pending = ArchiveManifestSafetyTests.manifest([
        "newest_ts": #""1793451600.000100""#,
        "continuation": #"{"top_ts": "1793498700.000100", "below_ts": "1793498000.000100"}"#,
    ])

    /// Every day file's anchors, in file order.
    static func anchors(_ output: TemporaryDirectory) throws -> [String] {
        try output.listing().filter { $0.hasSuffix(".md") }.flatMap { path in
            try output.read(path).components(separatedBy: "\n").filter { $0.hasPrefix("<!-- msg:") }
        }
    }

    /// spec: "Unfinished walk continues on the next call". The 12000
    /// top-level messages are 60 s apart: the oldest `1792782300.000100`
    /// (2026-10-24 03:05), the newest `1792782300 + 60 * 11999 =
    /// 1793502240.000100` (2026-11-01 11:04). 50 pages of 200 hold the newest
    /// 10000, so the oldest written is message 2000 (counting from 0),
    /// `1792782300 + 60 * 2000 = 1792902300.000100`. The second call is an
    /// hour later, 12:05.
    @Test("spec: a first archive of 12000 messages cut at 50 pages records where it stops; the next call writes the 2000 older ones, then sets newest_ts")
    func unfinishedWalkContinues() async throws {
        let all = (0..<12000).reversed().map { "\(1_792_782_300 + 60 * $0).000100" }
        let slack = { MethodTransport { call in
            switch call.method {
            case "conversations.history": return PagedSlack.history(all, call)
            default: return ArchiveFake.users(["U02": "Alex"], call)
            }
        } }
        let first = slack()
        let (firstHandler, _) = try await readHandler(first)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let firstResult = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun,
                                                                                 firstHandler), into: output)

        #expect(text(firstResult).contains(#""complete":false"#)
                    && text(firstResult).contains(#""top_level_messages":10000"#), "\(text(firstResult))")
        let firstHistory = first.calls.filter { $0.method == "conversations.history" }
        #expect(firstHistory.count == 50)
        #expect(firstHistory.allSatisfy { $0.parameters["latest"] == nil && $0.parameters["oldest"] == nil })
        #expect(try ArchiveManifestTests.manifest(output) == ArchiveManifestTests.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": null, "newest_reply_ts": {},
             "continuation": {"top_ts": "1793502240.000100", "below_ts": "1792902300.000100"},
             "last_run": {"at": "2026-11-01T11:05:00+08:00", "top_level_messages": 10000, "thread_replies": 0,
                          "new_messages": 10000}}
            """))
        let second = slack()
        let (secondHandler, _) = try await readHandler(second)

        let secondResult = await ArchiveToolTests.archive(
            ArchiveManifestTests.at(ArchiveManifestTests.firstRun + 3600, secondHandler), into: output)

        // Newer messages were not looked for, so the call is not complete.
        #expect(text(secondResult).contains(#""complete":false"#)
                    && text(secondResult).contains(#""top_level_messages":2000"#)
                    && text(secondResult).contains(#""new_messages":2000"#), "\(text(secondResult))")
        let secondHistory = second.calls.filter { $0.method == "conversations.history" }
        #expect(secondHistory.count == 10)
        #expect(secondHistory.allSatisfy {
            $0.parameters["latest"] == "1792902300.000100" && $0.parameters["oldest"] == nil
        }, "\(secondHistory.prefix(2))")
        #expect(try ArchiveManifestTests.manifest(output) == ArchiveManifestTests.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": "1793502240.000100", "newest_reply_ts": {},
             "last_run": {"at": "2026-11-01T12:05:00+08:00", "top_level_messages": 2000, "thread_replies": 0,
                          "new_messages": 2000}}
            """))
        let anchors = try Self.anchors(output)
        #expect(anchors.count == 12000 && Set(anchors).count == 12000)
        #expect(output.listing().filter { $0.hasSuffix(".md") }
                    == (24...31).map { "T01/C01/2026-10-\($0).md" } + ["T01/C01/2026-11-01.md"])
    }

    /// A call that continues a walk and is cut again by the page limit moves
    /// `below_ts` down to the oldest message it wrote; `top_ts` and
    /// `newest_ts` stay. Page p holds `1793497999 - p`, so page 49 ends at
    /// `1793497950.000100`.
    @Test("a continued walk cut again by the page limit moves below_ts down and keeps top_ts and newest_ts")
    func continuedWalkCutAgain() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try Self.preset(output, manifest: Self.pending)
        let slack = MethodTransport { call in
            guard call.method == "conversations.history" else { return ArchiveFake.users(["U02": "Alex"], call) }
            let page = Int(call.parameters["cursor"] ?? "0") ?? 0
            return .body(ArchiveFake.history([#"{"user":"U02","text":"m","ts":"\#(1_793_497_999 - page).000100"}"#],
                                             cursor: String(page + 1)))
        }
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output, Self.lookback0)

        #expect(text(result).contains(#""complete":false"#) && text(result).contains(#""top_level_messages":50"#),
                "\(text(result))")
        let history = slack.calls.filter { $0.method == "conversations.history" }
        #expect(history.count == 50)
        #expect(history.allSatisfy {
            $0.parameters["latest"] == "1793498000.000100" && $0.parameters["oldest"] == "1793451600.000100"
        })
        #expect(try ArchiveManifestTests.manifest(output) == ArchiveManifestTests.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": "1793451600.000100", "newest_reply_ts": {},
             "continuation": {"top_ts": "1793498700.000100", "below_ts": "1793497950.000100"},
             "last_run": {"at": "2026-11-01T11:05:00+08:00", "top_level_messages": 50, "thread_replies": 0,
                          "new_messages": 50}}
            """))
    }

    /// spec: "has_more without a cursor does not move the bookmark". The
    /// bookmark is `1793451600.000100` (2026-10-31 21:00). Slack answers the
    /// first page with the two messages newer than it, 2026-11-01 10:07 and
    /// 10:05, and `has_more: true` with no `next_cursor`, so the walk cannot
    /// go on below 10:05 and has not reached the bookmark: the messages
    /// between were not read.
    @Test("spec: has_more without a next cursor stops the walk above its bound: not complete, continuation recorded, newest_ts kept")
    func hasMoreWithoutCursor() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try Self.preset(output, manifest: ArchiveManifestSafetyTests.manifest([
            "newest_ts": #""1793451600.000100""#,
        ]))
        let page = #"{"ok":true,"messages":[{"user":"U02","text":"two","ts":"1793498820.000200"},"#
            + #"{"user":"U02","text":"one","ts":"1793498700.000100"}],"has_more":true}"#
        let slack = ArchiveToolTests.slack(history: page)
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output, Self.lookback0)

        expectJSON(result, #"{"complete":false,"conversation_id":"C01","files":["T01/C01/2026-11-01.md"],"#
                   + #""lookback_complete":false,"new_messages":2,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":0,"top_level_messages":2,"utc_offset":"+08:00"}"#)
        #expect(ArchiveRangeTests.history(slack).count == 1)
        #expect(try ArchiveRangeTests.state(output) == ArchiveRangeTests.expected("""
            "newest_ts": "1793451600.000100", "newest_reply_ts": {},
            "continuation": {"top_ts": "1793498820.000200", "below_ts": "1793498700.000100"}
            """))
    }

    /// Silent failure: a continued walk stopped by a rate limit before it
    /// wrote anything leaves the manifest, its continuation included,
    /// byte-identical.
    @Test("a continued walk rate limited on its first page leaves the manifest and its continuation byte-identical")
    func continuationKeptOnRateLimit() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try Self.preset(output, manifest: Self.pending)
        let slack = MethodTransport { _ in ArchivePartialProgressTests.rateLimited }
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output, Self.lookback0)

        #expect(text(result).contains(#""stopped_reason":"rate_limited""#), "\(text(result))")
        #expect(slack.calls.first?.parameters["latest"] == "1793498000.000100")
        #expect(try output.read(ArchiveManifestTests.manifestPath) == Self.pending)
    }

    /// spec: after_ts and since_date read their own range. With a
    /// continuation pending they neither continue it nor move `newest_ts`
    /// (the continuation's lower bound), even for a range that starts below
    /// `newest_ts` and reaches its bound; the continuation is kept.
    @Test("after_ts with a continuation pending sends no latest, keeps the continuation and leaves newest_ts")
    func explicitRangeKeepsContinuation() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try Self.preset(output, manifest: Self.pending)
        let slack = ArchiveToolTests.slack(history: ArchiveFake.history([
            #"{"user":"U02","text":"new","ts":"1793498820.000200"}"#,
        ]))
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun, handler),
                                                    into: output, Self.lookback0.merging([
                                                        "after_ts": .string("1793400000.000100"),
                                                    ]) { $1 })

        #expect(text(result).contains(#""new_messages":1"#), "\(text(result))")
        #expect(slack.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": "1793400000.000100"])
        let manifest = try ArchiveManifestTests.manifest(output)
        #expect(manifest["newest_ts"] as? String == "1793451600.000100")
        #expect(manifest["continuation"] as? NSDictionary
                    == ["top_ts": "1793498700.000100", "below_ts": "1793498000.000100"])
    }

    /// spec: "Thread replies and lookback", "Long thread continues on the
    /// next call". The parent `1793451600.000100` (2026-10-31 21:00) has
    /// 1300 replies one second apart, `1793451601.000200` to
    /// `1793452900.000200`; one call reads at most 5 pages of 200, so the
    /// 1000th is `1793451600 + 1000 = 1793452600.000200`. The second call
    /// is a day later, 2026-11-02 11:05 (`1793588700`); the parent is
    /// inside its 30-day window and lists `latest_reply` `1793452900.000200`.
    @Test("spec: a 1300-reply thread is archived to its 1000th reply, then the next call asks only for the 300 after it")
    func longThreadContinues() async throws {
        let parentTS = "1793451600.000100"
        let parent = #"{"user":"U02","text":"question","ts":"\#(parentTS)","thread_ts":"\#(parentTS)","reply_count":1300,"latest_reply":"1793452900.000200"}"#
        let replies = (1...1300).map { "\(1_793_451_600 + $0).000200" }
        let slack = { MethodTransport { call in
            switch call.method {
            case "conversations.history": return .body(ArchiveFake.history([parent]))
            case "conversations.replies": return PagedSlack.replies(parent: parent, parentTS: parentTS, replies, call)
            default: return ArchiveFake.users(["U02": "Alex", "U03": "Kim"], call)
            }
        } }
        let first = slack()
        let (firstHandler, _) = try await readHandler(first)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let firstResult = await ArchiveToolTests.archive(ArchiveManifestTests.at(ArchiveManifestTests.firstRun,
                                                                                 firstHandler), into: output)

        expectJSON(firstResult, #"{"complete":false,"conversation_id":"C01","files":["T01/C01/2026-10-31.md"],"#
                   + #""lookback_complete":true,"new_messages":1001,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":1000,"top_level_messages":1,"utc_offset":"+08:00"}"#)
        let firstReplies = first.calls.filter { $0.method == "conversations.replies" }
        #expect(firstReplies.count == 5 && firstReplies.allSatisfy { $0.parameters["oldest"] == nil })
        #expect(try ArchiveManifestTests.manifest(output)["newest_reply_ts"] as? NSDictionary
                    == [parentTS: "1793452600.000200"])
        let second = slack()
        let (secondHandler, _) = try await readHandler(second)

        let secondResult = await ArchiveToolTests.archive(
            ArchiveManifestTests.at(ArchiveManifestTests.firstRun + ArchiveManifestTests.day, secondHandler),
            into: output)

        expectJSON(secondResult, #"{"complete":true,"conversation_id":"C01","files":["T01/C01/2026-10-31.md"],"#
                   + #""lookback_complete":true,"new_messages":300,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":300,"top_level_messages":0,"utc_offset":"+08:00"}"#)
        let secondReplies = second.calls.filter { $0.method == "conversations.replies" }
        #expect(secondReplies.map { $0.parameters["cursor"] } == [nil, "200"])
        #expect(secondReplies.allSatisfy {
            $0.parameters["oldest"] == "1793452600.000200" && $0.parameters["ts"] == parentTS
        }, "\(secondReplies)")
        #expect(try ArchiveManifestTests.manifest(output)["newest_reply_ts"] as? NSDictionary
                    == [parentTS: "1793452900.000200"])
        let anchors = try Self.anchors(output)
        #expect(anchors.count == 1301 && Set(anchors).count == 1301)
        #expect(anchors.last == "<!-- msg:1793452900.000200 -->")
    }
}
