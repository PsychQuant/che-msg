import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-chat-archive, "Incremental archive and manifest", for calls
/// with `after_ts` or `since_date`: the bookmark moves only for a range
/// that starts at or before it and has reached its lower bound, and a range
/// stopped before its lower bound is recorded in the manifest's `range`
/// (its lower bound `oldest_ts`, the newest ts it wrote contiguously
/// `newest_ts`, and its `continuation`), which a call with the same lower
/// bound continues. Times at +08:00; runs are at 2026-11-01 11:05
/// (`1793502300`) and an hour apart.
@Suite("archive_conversation_to_markdown explicit ranges")
struct ArchiveRangeTests {
    static let lookback0: [String: Value] = ["utc_offset": .string("+08:00"), "thread_lookback_days": .int(0)]
    static let bookmarkTS = "1793451600.000100"

    /// `handler` at `seconds` since 1970, reading at most `pages` history
    /// pages per call.
    static func at(_ seconds: Int, pages: Int = SlackToolHandler.archiveHistoryMaxPages,
                   _ handler: SlackToolHandler) -> SlackToolHandler {
        var limited = ArchiveManifestTests.at(seconds, handler)
        limited.archiveMaxPages = pages
        return limited
    }

    /// A fake Slack whose history is `messages` (ts, newest first), paged as
    /// Slack pages it.
    static func paged(_ messages: [String]) -> MethodTransport {
        MethodTransport { call in
            switch call.method {
            case "conversations.history": return PagedSlack.history(messages, call)
            default: return ArchiveFake.users(["U02": "Alex"], call)
            }
        }
    }

    static func history(_ transport: MethodTransport) -> [SlackCall] {
        transport.calls.filter { $0.method == "conversations.history" }
    }

    /// The manifest after a run, with `last_run` left out.
    static func state(_ output: TemporaryDirectory) throws -> NSDictionary {
        let manifest = try #require(try ArchiveManifestTests.manifest(output).mutableCopy() as? NSMutableDictionary)
        manifest.removeObject(forKey: "last_run")
        return manifest
    }

    /// `fields` with the manifest's fixed ones, without `last_run`.
    static func expected(_ fields: String) throws -> NSDictionary {
        try ArchiveManifestTests.expected("""
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             \(fields)}
            """)
    }

    /// A range from `1793400000.000100` (2026-10-31 06:40) left unfinished
    /// below `1793420200.000100` (12:16:40), its walk having started at
    /// `1793460000.000100` (23:20).
    static let otherRange = #"{"oldest_ts": "1793400000.000100", "newest_ts": null, "continuation": {"top_ts": "1793460000.000100", "below_ts": "1793420200.000100"}}"#

    /// spec: "Explicit range newer than the bookmark keeps the bookmark".
    /// `since_date` 2026-10-25 at +08:00 is `1792857600`. The 30-day window
    /// starts at `1793502300 - 30 * 86400 = 1790910300` (2026-10-02 11:05),
    /// so the history is listed from there; `1791000000.000100` (2026-10-03)
    /// is listed but not written. Under the old rule the bookmark jumped to
    /// `1792980000.000100`, skipping everything between 2026-09-21 and
    /// 2026-10-25 for good.
    @Test("spec: since_date 2026-10-25 after a bookmark of 1789995600.000100 writes from that day on and keeps the bookmark")
    func rangeNewerThanBookmarkKeepsIt() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: ArchiveManifestSafetyTests.manifest([
            "newest_ts": #""1789995600.000100""#,
        ]))
        let slack = Self.paged(["1792980000.000100", "1792893600.000100", "1791000000.000100"])
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(Self.at(ArchiveManifestTests.firstRun, handler), into: output, [
            "utc_offset": .string("+08:00"), "since_date": .string("2026-10-25"),
        ])

        expectJSON(result, #"{"complete":true,"conversation_id":"C01","#
                   + #""files":["T01/C01/2026-10-25.md","T01/C01/2026-10-26.md"],"lookback_complete":true,"#
                   + #""new_messages":2,"skipped_messages":0,"team_id":"T01","thread_replies":0,"#
                   + #""top_level_messages":2,"utc_offset":"+08:00"}"#)
        #expect(Self.history(slack).map(\.parameters) == [["channel": "C01", "limit": "200", "oldest": "1790910300"]])
        #expect(try Self.state(output) == Self.expected(#""newest_ts": "1789995600.000100", "newest_reply_ts": {}"#))
    }

    /// spec: "Explicit range continues on the next call", modelled with a
    /// page limit of 5 pages (1000 messages) instead of 50 (10000), so 1500
    /// messages stand for the 15000. `since_date` 2026-01-01 at +08:00 is
    /// `1767196800`; the messages are 60 s apart from `1767200400.000100`
    /// (2026-01-01 01:00) to `1767200400 + 60 * 1499 = 1767290340.000100`
    /// (2026-01-02 01:59). The first call writes the newest 1000, down to
    /// `1767200400 + 60 * 500 = 1767230400.000100`. Before the third call a
    /// new message `1767290400.000100` arrives.
    @Test("spec: a since_date range cut by the page limit continues below where it stopped, then catches up and completes")
    func rangeContinuesAndConverges() async throws {
        let messages = (0..<1500).reversed().map { "\(1_767_200_400 + 60 * $0).000100" }
        let since: [String: Value] = ["utc_offset": .string("+08:00"), "since_date": .string("2026-01-01")]
        let output = TemporaryDirectory()
        defer { output.remove() }
        let first = Self.paged(messages)
        let (firstHandler, _) = try await readHandler(first)

        let firstResult = await ArchiveToolTests.archive(
            Self.at(ArchiveManifestTests.firstRun, pages: 5, firstHandler), into: output, since)

        #expect(text(firstResult).contains(#""complete":false"#)
                    && text(firstResult).contains(#""top_level_messages":1000"#), "\(text(firstResult))")
        #expect(Self.history(first).count == 5)
        #expect(Self.history(first).allSatisfy {
            $0.parameters["oldest"] == "1767196800" && $0.parameters["latest"] == nil
        })
        #expect(try Self.state(output) == Self.expected("""
            "newest_ts": null, "newest_reply_ts": {},
            "range": {"oldest_ts": "1767196800", "newest_ts": null,
                      "continuation": {"top_ts": "1767290340.000100", "below_ts": "1767230400.000100"}}
            """))
        let second = Self.paged(messages)
        let (secondHandler, _) = try await readHandler(second)

        let secondResult = await ArchiveToolTests.archive(
            Self.at(ArchiveManifestTests.firstRun + 3600, pages: 5, secondHandler), into: output, since)

        // Nothing newer than the first call's newest was looked for.
        #expect(text(secondResult).contains(#""complete":false"#)
                    && text(secondResult).contains(#""top_level_messages":500"#)
                    && text(secondResult).contains(#""new_messages":500"#), "\(text(secondResult))")
        #expect(Self.history(second).count == 3)
        #expect(Self.history(second).allSatisfy {
            $0.parameters["oldest"] == "1767196800" && $0.parameters["latest"] == "1767230400.000100"
        }, "\(Self.history(second).prefix(1))")
        #expect(try Self.state(output) == Self.expected("""
            "newest_ts": "1767290340.000100", "newest_reply_ts": {},
            "range": {"oldest_ts": "1767196800", "newest_ts": "1767290340.000100"}
            """))
        let third = Self.paged(["1767290400.000100"] + messages)
        let (thirdHandler, _) = try await readHandler(third)

        let thirdResult = await ArchiveToolTests.archive(
            Self.at(ArchiveManifestTests.firstRun + 7200, pages: 5, thirdHandler), into: output, since)

        expectJSON(thirdResult, #"{"complete":true,"conversation_id":"C01","files":["T01/C01/2026-01-02.md"],"#
                   + #""lookback_complete":true,"new_messages":1,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":0,"top_level_messages":1,"utc_offset":"+08:00"}"#)
        #expect(Self.history(third).map(\.parameters)
                    == [["channel": "C01", "limit": "200", "oldest": "1767290340.000100"]])
        #expect(try Self.state(output) == Self.expected(#""newest_ts": "1767290400.000100", "newest_reply_ts": {}"#))
        let anchors = try ArchiveContinuationTests.anchors(output)
        #expect(anchors.count == 1501 && Set(anchors).count == 1501)
    }

    /// An `after_ts` range that starts below the bookmark moves it, but only
    /// once the range has reached its lower bound. A page limit of 1: the
    /// 300 messages are 200 s apart from `1793400200.000100` to
    /// `1793460000.000100` (2026-10-31 23:20), the newest 42 of them newer
    /// than the bookmark; the first call writes down to
    /// `1793400200 + 200 * 100 = 1793420200.000100`.
    @Test("a range starting at or before the bookmark moves it once it reaches its lower bound, and not before")
    func rangeBelowBookmarkMovesIt() async throws {
        let messages = (0..<300).reversed().map { "\(1_793_400_200 + 200 * $0).000100" }
        let after = Self.lookback0.merging(["after_ts": .string("1793400000.000100")]) { $1 }
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: ArchiveManifestSafetyTests.manifest([
            "newest_ts": #""\#(Self.bookmarkTS)""#,
        ]))
        let first = Self.paged(messages)
        let (firstHandler, _) = try await readHandler(first)

        _ = await ArchiveToolTests.archive(Self.at(ArchiveManifestTests.firstRun, pages: 1, firstHandler),
                                           into: output, after)

        #expect(try Self.state(output) == Self.expected("""
            "newest_ts": "\(Self.bookmarkTS)", "newest_reply_ts": {}, "range": \(Self.otherRange)
            """))
        let second = Self.paged(messages)
        let (secondHandler, _) = try await readHandler(second)

        let secondResult = await ArchiveToolTests.archive(
            Self.at(ArchiveManifestTests.firstRun + 3600, pages: 1, secondHandler), into: output, after)

        #expect(text(secondResult).contains(#""complete":false"#)
                    && text(secondResult).contains(#""top_level_messages":100"#), "\(text(secondResult))")
        #expect(Self.history(second).map(\.parameters) == [[
            "channel": "C01", "limit": "200", "oldest": "1793400000.000100", "latest": "1793420200.000100",
        ]])
        #expect(try Self.state(output) == Self.expected("""
            "newest_ts": "1793460000.000100", "newest_reply_ts": {},
            "range": {"oldest_ts": "1793400000.000100", "newest_ts": "1793460000.000100"}
            """))
        let third = Self.paged(messages)
        let (thirdHandler, _) = try await readHandler(third)

        let thirdResult = await ArchiveToolTests.archive(
            Self.at(ArchiveManifestTests.firstRun + 7200, pages: 1, thirdHandler), into: output, after)

        #expect(text(thirdResult).contains(#""complete":true"#), "\(text(thirdResult))")
        #expect(Self.history(third).map(\.parameters)
                    == [["channel": "C01", "limit": "200", "oldest": "1793460000.000100"]])
        #expect(try Self.state(output) == Self.expected(#""newest_ts": "1793460000.000100", "newest_reply_ts": {}"#))
    }

    /// A call with another lower bound reads its own range from the top,
    /// and leaves the recorded range as it was when it reaches its bound;
    /// its bound is below the bookmark, so the bookmark moves.
    @Test("a range with another lower bound that reaches it neither continues nor drops the recorded range")
    func otherBoundKeepsRange() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: ArchiveManifestSafetyTests.manifest([
            "newest_ts": #""\#(Self.bookmarkTS)""#, "range": Self.otherRange,
        ]))
        let slack = Self.paged(["1793498700.000100"])
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(Self.at(ArchiveManifestTests.firstRun, handler), into: output,
                                                    Self.lookback0.merging([
                                                        "after_ts": .string("1793440000.000100"),
                                                    ]) { $1 })

        #expect(text(result).contains(#""complete":true"#), "\(text(result))")
        #expect(Self.history(slack).map(\.parameters)
                    == [["channel": "C01", "limit": "200", "oldest": "1793440000.000100"]])
        #expect(try Self.state(output) == Self.expected("""
            "newest_ts": "1793498700.000100", "newest_reply_ts": {}, "range": \(Self.otherRange)
            """))
    }

    /// A call with another lower bound whose walk stops before its bound
    /// replaces the record with its own. A page limit of 1: 250 messages
    /// 100 s apart from `1793440100.000100` to `1793465000.000100`; the walk
    /// writes down to `1793440100 + 100 * 50 = 1793445100.000100`.
    @Test("a range with another lower bound stopped before it replaces the recorded range with its own")
    func otherBoundStoppedReplacesRange() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: ArchiveManifestSafetyTests.manifest([
            "newest_ts": #""\#(Self.bookmarkTS)""#, "range": Self.otherRange,
        ]))
        let slack = Self.paged((0..<250).reversed().map { "\(1_793_440_100 + 100 * $0).000100" })
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(Self.at(ArchiveManifestTests.firstRun, pages: 1, handler),
                                                    into: output, Self.lookback0.merging([
                                                        "after_ts": .string("1793440000.000100"),
                                                    ]) { $1 })

        #expect(text(result).contains(#""complete":false"#), "\(text(result))")
        #expect(try Self.state(output) == Self.expected("""
            "newest_ts": "\(Self.bookmarkTS)", "newest_reply_ts": {},
            "range": {"oldest_ts": "1793440000.000100", "newest_ts": null,
                      "continuation": {"top_ts": "1793465000.000100", "below_ts": "1793445100.000100"}}
            """))
    }

    /// Without after_ts and since_date the run neither reads, continues
    /// nor changes the recorded range.
    @Test("a call without after_ts or since_date leaves the recorded range untouched")
    func defaultCallKeepsRange() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: ArchiveManifestSafetyTests.manifest([
            "newest_ts": #""\#(Self.bookmarkTS)""#, "range": Self.otherRange,
        ]))
        let slack = Self.paged(["1793498700.000100"])
        let (handler, _) = try await readHandler(slack)

        let result = await ArchiveToolTests.archive(Self.at(ArchiveManifestTests.firstRun, handler), into: output,
                                                    Self.lookback0)

        #expect(text(result).contains(#""complete":true"#), "\(text(result))")
        #expect(Self.history(slack).map(\.parameters)
                    == [["channel": "C01", "limit": "200", "oldest": Self.bookmarkTS]])
        #expect(try Self.state(output) == Self.expected("""
            "newest_ts": "1793498700.000100", "newest_reply_ts": {}, "range": \(Self.otherRange)
            """))
    }

    /// spec: "Archive concurrency and partial progress" for a range: a rate
    /// limit after page 1 records the range with the point to continue
    /// below; `newest_ts` stays null. `since_date` 2026-10-25 is
    /// `1792857600`.
    @Test("a since_date range rate limited after its first page records the range and where it continues")
    func rateLimitRecordsRange() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let slack = ArchivePartialProgressTests.twoPages([ArchiveToolTests.alexPlain],
                                                        then: ArchivePartialProgressTests.rateLimited)

        let result = await ArchiveToolTests.archive(try await ArchivePartialProgressTests.handler(slack), into: output,
                                                    Self.lookback0.merging([
                                                        "since_date": .string("2026-10-25"),
                                                    ]) { $1 })

        #expect(text(result).contains(#""stopped_reason":"rate_limited""#), "\(text(result))")
        #expect(try Self.state(output) == Self.expected("""
            "newest_ts": null, "newest_reply_ts": {},
            "range": {"oldest_ts": "1792857600", "newest_ts": null,
                      "continuation": {"top_ts": "1793498700.000100", "below_ts": "1793498700.000100"}}
            """))
    }

    /// The recorded range is continued below its `below_ts`; a rate limit
    /// after the continued walk wrote `1793497000.000100` moves `below_ts`
    /// down to it and keeps `top_ts`.
    @Test("a continued range rate limited after writing moves its below_ts down and keeps its top_ts")
    func rateLimitExtendsRange() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        try ArchiveContinuationTests.preset(output, manifest: ArchiveManifestSafetyTests.manifest([
            "newest_ts": #""\#(Self.bookmarkTS)""#,
            "range": #"{"oldest_ts": "1792857600", "newest_ts": null, "continuation": {"top_ts": "1793498700.000100", "below_ts": "1793498000.000100"}}"#,
        ]))
        let slack = ArchivePartialProgressTests.twoPages([#"{"user":"U02","text":"m","ts":"1793497000.000100"}"#],
                                                        then: ArchivePartialProgressTests.rateLimited)

        let result = await ArchiveToolTests.archive(try await ArchivePartialProgressTests.handler(slack), into: output,
                                                    Self.lookback0.merging([
                                                        "since_date": .string("2026-10-25"),
                                                    ]) { $1 })

        #expect(text(result).contains(#""stopped_reason":"rate_limited""#), "\(text(result))")
        #expect(slack.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": "1792857600",
                                                  "latest": "1793498000.000100"])
        #expect(try Self.state(output) == Self.expected("""
            "newest_ts": "\(Self.bookmarkTS)", "newest_reply_ts": {},
            "range": {"oldest_ts": "1792857600", "newest_ts": null,
                      "continuation": {"top_ts": "1793498700.000100", "below_ts": "1793497000.000100"}}
            """))
    }

    /// Silent failure: a range rate limited before it wrote anything leaves
    /// the manifest, its recorded range included, byte-identical.
    @Test("a range rate limited on its first page leaves the manifest byte-identical")
    func rateLimitBeforeWritingKeepsManifest() async throws {
        let output = TemporaryDirectory()
        defer { output.remove() }
        let manifest = ArchiveManifestSafetyTests.manifest([
            "newest_ts": #""\#(Self.bookmarkTS)""#,
            "range": #"{"oldest_ts": "1792857600", "newest_ts": null, "continuation": {"top_ts": "1793498700.000100", "below_ts": "1793498000.000100"}}"#,
        ])
        try ArchiveContinuationTests.preset(output, manifest: manifest)
        let slack = MethodTransport { _ in ArchivePartialProgressTests.rateLimited }

        let result = await ArchiveToolTests.archive(try await ArchivePartialProgressTests.handler(slack), into: output,
                                                    Self.lookback0.merging([
                                                        "since_date": .string("2026-10-25"),
                                                    ]) { $1 })

        #expect(text(result).contains(#""stopped_reason":"rate_limited""#), "\(text(result))")
        #expect(slack.calls.first?.parameters["latest"] == "1793498000.000100")
        #expect(try output.read(ArchiveManifestTests.manifestPath) == manifest)
    }

    /// `range` and `unfinished_threads` are optional: a manifest without
    /// them is read as having neither (ArchiveManifestSafetyTests), and one
    /// with them is written back field for field.
    @Test("a manifest with range and unfinished_threads decodes and encodes back to the same fields")
    func manifestRoundTrip() throws {
        let json = """
            {"format": "che-slack-mcp archive manifest", "version": 1, "team_id": "T01", "conversation_id": "C01",
             "newest_ts": "\(Self.bookmarkTS)", "newest_reply_ts": {"1788318000.000100": "1788319000.000200"},
             "range": \(Self.otherRange), "unfinished_threads": ["1788318000.000100"],
             \(ArchiveManifestSafetyTests.lastRun)}
            """
        let manifest = try JSONDecoder().decode(ArchiveManifest.self, from: Data(json.utf8))

        #expect(manifest.range == .init(oldest_ts: "1793400000.000100", newest_ts: nil,
                                        continuation: .init(top_ts: "1793460000.000100",
                                                            below_ts: "1793420200.000100")))
        #expect(manifest.unfinished_threads == ["1788318000.000100"])
        let written = try #require(try JSONSerialization.jsonObject(with: manifest.encoded()) as? NSDictionary)
        #expect(written == (try ArchiveManifestTests.expected(json)))
    }
}
