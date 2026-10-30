import Foundation
import MCP
import Testing
@testable import CheSlackMCPCore
import SlackWebLib

/// spec: slack-chat-archive, "Slack day file format" and "Slack markup
/// conversion", through the tool with a fake Slack. The workspace is
/// `T01 alpha`, whose user is `U01`. `1793498700` is 2026-11-01 10:05 at
/// +08:00, `1793498820` 10:07, `1793451600` 2026-10-31 21:00, `1793494800`
/// 2026-11-01 09:00.
@Suite("archive_conversation_to_markdown")
struct ArchiveToolTests {
    static let tool = "archive_conversation_to_markdown"

    static let alexParent = #"{"type":"message","user":"U02","text":"hello","ts":"1793498700.000100","thread_ts":"1793498700.000100","reply_count":1}"#
    static let alexPlain = #"{"type":"message","user":"U02","text":"hello","ts":"1793498700.000100"}"#
    static let ownReply = #"{"type":"message","user":"U01","text":"thanks","ts":"1793498820.000200","thread_ts":"1793498700.000100","parent_user_id":"U02"}"#

    /// A fake Slack answering history with `history`, replies with `replies`
    /// and users.info from `names`.
    static func slack(history: String, replies: String = ArchiveFake.replies([]),
                      names: [String: String] = ["U02": "Alex"]) -> MethodTransport {
        MethodTransport { call in
            switch call.method {
            case "conversations.history": return .body(history)
            case "conversations.replies": return .body(replies)
            case "users.info": return ArchiveFake.users(names, call)
            default: return .body(Fake.slackError("no_scripted_answer"))
            }
        }
    }

    static func archive(_ handler: SlackToolHandler, into output: TemporaryDirectory,
                        _ extra: [String: Value] = ["utc_offset": .string("+08:00")]) async -> CallTool.Result {
        await handler.callTool(name: tool, arguments: [
            "conversation_id": .string("C01"), "output_dir": .string(output.path),
        ].merging(extra) { $1 })
    }

    /// spec: "Example: day file".
    @Test("the spec's example: a message and the user's own thread reply in T01/C01/2026-11-01.md, owner-only")
    func specExample() async throws {
        let transport = Self.slack(history: ArchiveFake.history([Self.alexParent]),
                                   replies: ArchiveFake.replies([Self.alexParent, Self.ownReply]))
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await Self.archive(handler, into: output)

        expectJSON(result, #"{"complete":true,"conversation_id":"C01","files":["T01/C01/2026-11-01.md"],"#
                   + #""lookback_complete":true,"new_messages":2,"skipped_messages":0,"team_id":"T01","#
                   + #""thread_replies":1,"top_level_messages":1,"utc_offset":"+08:00"}"#)
        #expect(output.listing() == ["T01", "T01/C01", "T01/C01/2026-11-01.md", "T01/C01/manifest.json"])
        #expect(try output.read("T01/C01/2026-11-01.md") == SlackDayFileTests.exampleFile)
        #expect(try output.mode("") == 0o700)
        #expect(try output.mode("T01") == 0o700)
        #expect(try output.mode("T01/C01") == 0o700)
        #expect(try output.mode("T01/C01/2026-11-01.md") == 0o600)
        #expect(transport.calls.map(\.description) == [
            "conversations.history [(key: \"channel\", value: \"C01\"), (key: \"limit\", value: \"200\")]",
            "conversations.replies [(key: \"channel\", value: \"C01\"), (key: \"limit\", value: \"200\"), "
                + "(key: \"ts\", value: \"1793498700.000100\")]",
            "users.info [(key: \"user\", value: \"U02\")]",
        ])
    }

    /// spec: "Reply lands in its own day".
    @Test("a reply posted the day after its parent is written in its own day's file")
    func replyInItsOwnDay() async throws {
        let parent = #"{"user":"U02","text":"question","ts":"1793451600.000100","thread_ts":"1793451600.000100","reply_count":1}"#
        let reply = #"{"user":"U03","text":"answer","ts":"1793494800.000200","thread_ts":"1793451600.000100"}"#
        let transport = Self.slack(history: ArchiveFake.history([parent]), replies: ArchiveFake.replies([parent, reply]),
                                   names: ["U02": "Alex", "U03": "Kim"])
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await Self.archive(handler, into: output)

        #expect(result.isError == false, "\(text(result))")
        #expect(try output.read("T01/C01/2026-10-31.md") == """
            ---
            team_id: "T01"
            conversation_id: "C01"
            date: 2026-10-31
            utc_offset: "+08:00"
            ---

            <!-- msg:1793451600.000100 -->
            **21:00 Alex**：
            question


            """)
        #expect(try output.read("T01/C01/2026-11-01.md") == """
            ---
            team_id: "T01"
            conversation_id: "C01"
            date: 2026-11-01
            utc_offset: "+08:00"
            ---

            <!-- msg:1793494800.000200 -->
            **09:00 Kim** ↳ thread:1793451600.000100：
            answer


            """)
    }

    /// spec: the sender rules and the markup conversion. Spec silent,
    /// chosen: a message with neither user nor bot is `Unknown`; a message
    /// whose ts is not a Slack timestamp is skipped and counted.
    @Test("senders: 我, a display name, Bot <bot_id>, User <user_id>; mentions and files converted; each user looked up once")
    func sendersAndMarkup() async throws {
        let history = ArchiveFake.history([
            #"{"user":"U02","ts":"1793498760.000600","files":[{"id":"F1","name":"plan.pdf","permalink":"https://t.slack.com/files/U9/F1/plan.pdf","url_private":"https://files.slack.com/x"}]}"#,
            #"{"user":"U02","text":"also here","ts":"1793498750.000500","thread_ts":"1793498000.000001","subtype":"thread_broadcast"}"#,
            #"{"subtype":"tombstone","text":"gone","ts":"1793498740.000400"}"#,
            #"{"user":"U01","text":"mine <@U02>","ts":"1793498730.000300"}"#,
            #"{"user":"U05","text":"<@U9> hi <@U02> <#C7|general> &amp; <https://x.example|the doc>","ts":"1793498720.000200"}"#,
            #"{"subtype":"bot_message","bot_id":"B01","username":"deploybot","text":"deployed","ts":"1793498710.000100"}"#,
            #"{"user":"U02","text":"bad ts","ts":"17934987x0.0"}"#,
        ])
        let transport = Self.slack(history: history)
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await Self.archive(handler, into: output)

        expectJSON(result, #"{"complete":true,"conversation_id":"C01","files":["T01/C01/2026-11-01.md"],"#
                   + #""lookback_complete":true,"new_messages":6,"skipped_messages":1,"team_id":"T01","#
                   + #""thread_replies":1,"top_level_messages":5,"utc_offset":"+08:00"}"#)
        #expect(try output.read("T01/C01/2026-11-01.md") == """
            ---
            team_id: "T01"
            conversation_id: "C01"
            date: 2026-11-01
            utc_offset: "+08:00"
            ---

            <!-- msg:1793498710.000100 -->
            **10:05 Bot B01**：
            deployed

            <!-- msg:1793498720.000200 -->
            **10:05 User U05**：
            @U9 hi @Alex #general & [the doc](https://x.example)

            <!-- msg:1793498730.000300 -->
            **10:05 我**：
            mine @Alex

            <!-- msg:1793498740.000400 -->
            **10:05 Unknown**：
            gone

            <!-- msg:1793498750.000500 -->
            **10:05 Alex** ↳ thread:1793498000.000001：
            also here

            <!-- msg:1793498760.000600 -->
            **10:06 Alex**：
            [file: plan.pdf](https://t.slack.com/files/U9/F1/plan.pdf)


            """)
        let lookedUp = transport.calls.filter { $0.method == "users.info" }.compactMap { $0.parameters["user"] }
        #expect(lookedUp.sorted() == ["U02", "U05", "U9"])
        #expect(!transport.methods.contains("conversations.replies"), "a reply is not a thread parent")
        #expect(!text(result).contains("plan.pdf") && !text(result).contains("deployed") && !text(result).contains("Alex"))
    }

    @Test("since_date is midnight at the effective offset, sent as oldest")
    func sinceDate() async throws {
        let transport = Self.slack(history: ArchiveFake.history([Self.alexPlain]))
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await Self.archive(handler, into: output,
                                        ["utc_offset": .string("+08:00"), "since_date": .string("2026-11-01")])

        #expect(result.isError == false, "\(text(result))")
        #expect(transport.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": "1793462400"])
    }

    /// spec: "When both after_ts and since_date are given, after_ts SHALL
    /// take precedence." A message at after_ts itself is not archived again.
    @Test("after_ts takes precedence over since_date, and only messages after it are written")
    func afterTSPrecedence() async throws {
        let history = ArchiveFake.history([
            #"{"user":"U02","text":"new","ts":"1793498820.000200"}"#,
            Self.alexPlain,
        ])
        let transport = Self.slack(history: history)
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await Self.archive(handler, into: output, [
            "utc_offset": .string("+08:00"), "since_date": .string("2026-01-01"), "after_ts": .string("1793498700.000100"),
        ])

        #expect(result.isError == false, "\(text(result))")
        #expect(transport.calls.first?.parameters == ["channel": "C01", "limit": "200", "oldest": "1793498700.000100"])
        let file = try output.read("T01/C01/2026-11-01.md")
        #expect(file.contains("<!-- msg:1793498820.000200 -->"))
        #expect(!file.contains("<!-- msg:1793498700.000100 -->"))
    }

    /// spec: "When utc_offset is absent, the server's local offset at the
    /// time of the call SHALL be used."
    @Test("without utc_offset the server's offset is used for the frontmatter, the times and since_date")
    func localOffset() async throws {
        let transport = Self.slack(history: ArchiveFake.history([Self.alexPlain]))
        var (handler, _) = try await readHandler(transport)
        handler.localOffsetSeconds = { 9 * 3600 }
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await Self.archive(handler, into: output, ["since_date": .string("2026-11-01")])

        #expect(result.isError == false, "\(text(result))")
        #expect(text(result).contains(#""utc_offset":"+09:00""#))
        #expect(transport.calls.first?.parameters["oldest"] == "1793458800")
        let file = try output.read("T01/C01/2026-11-01.md")
        #expect(file.contains("utc_offset: \"+09:00\"\n"))
        #expect(file.contains("**11:05 Alex**：\nhello\n"))
    }

    @Test("history pages are followed by cursor")
    func cursor() async throws {
        let transport = MethodTransport { call in
            switch (call.method, call.parameters["cursor"]) {
            case ("conversations.history", nil):
                return .body(ArchiveFake.history([#"{"user":"U02","text":"two","ts":"1793498820.000200"}"#], cursor: "c2"))
            case ("conversations.history", "c2"?):
                return .body(ArchiveFake.history([Self.alexPlain]))
            case ("users.info", _): return ArchiveFake.users(["U02": "Alex"], call)
            default: return .body(Fake.slackError("no_scripted_answer"))
            }
        }
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await Self.archive(handler, into: output)

        #expect(text(result).contains(#""complete":true"#) && text(result).contains(#""top_level_messages":2"#))
        #expect(transport.calls.filter { $0.method == "conversations.history" }.map { $0.parameters["cursor"] } == [nil, "c2"])
    }

    /// Spec silent, chosen: one call reads at most 50 pages of 200
    /// top-level messages, and says it is not complete when Slack had more.
    @Test("one call reads at most 50 history pages and then reports complete false")
    func pageCap() async throws {
        let transport = MethodTransport { call in
            guard call.method == "conversations.history" else { return ArchiveFake.users(["U02": "Alex"], call) }
            let page = Int(call.parameters["cursor"] ?? "0") ?? 0
            return .body(ArchiveFake.history([#"{"user":"U02","text":"m","ts":"\#(1793498000 + page).000100"}"#],
                                             cursor: String(page + 1)))
        }
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await Self.archive(handler, into: output)

        #expect(SlackToolHandler.archiveHistoryMaxPages == 50)
        #expect(transport.calls.filter { $0.method == "conversations.history" }.count == 50)
        #expect(text(result).contains(#""complete":false"#) && text(result).contains(#""top_level_messages":50"#))
    }

    @Test("a thread with more replies than one walk reads leaves complete false")
    func truncatedThread() async throws {
        let transport = Self.slack(history: ArchiveFake.history([Self.alexParent]),
                                   replies: ArchiveFake.replies([Self.alexParent, Self.ownReply], hasMore: true))
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }

        let result = await Self.archive(handler, into: output)

        #expect(text(result).contains(#""complete":false"#) && text(result).contains(#""thread_replies":1"#))
    }

    /// Merge into an existing day file: its blocks and the text before the
    /// first anchor are kept.
    @Test("an existing day file keeps its blocks; the archived message is added in ts order")
    func mergeIntoExisting() async throws {
        let transport = Self.slack(history: ArchiveFake.history([Self.alexPlain]))
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }
        try FileManager.default.createDirectory(at: output.url.appendingPathComponent("T01/C01"),
                                                withIntermediateDirectories: true)
        try """
            ---
            team_id: "T01"
            conversation_id: "C01"
            date: 2026-11-01
            utc_offset: "+08:00"
            ---

            my notes

            <!-- msg:1793498820.000200 -->
            **10:07 我**：
            written earlier

            """.write(to: output.url.appendingPathComponent("T01/C01/2026-11-01.md"), atomically: false, encoding: .utf8)

        let result = await Self.archive(handler, into: output)

        #expect(text(result).contains(#""new_messages":1"#), "\(text(result))")
        #expect(try output.read("T01/C01/2026-11-01.md") == """
            ---
            team_id: "T01"
            conversation_id: "C01"
            date: 2026-11-01
            utc_offset: "+08:00"
            ---

            my notes

            <!-- msg:1793498700.000100 -->
            **10:05 Alex**：
            hello

            <!-- msg:1793498820.000200 -->
            **10:07 我**：
            written earlier

            """)
        #expect(try output.mode("T01/C01/2026-11-01.md") == 0o600)
    }

    @Test("archiving the same messages again leaves the day file byte-identical and lists no file")
    func rerun() async throws {
        let transport = Self.slack(history: ArchiveFake.history([Self.alexParent]),
                                   replies: ArchiveFake.replies([Self.alexParent, Self.ownReply]))
        let (handler, _) = try await readHandler(transport)
        let output = TemporaryDirectory()
        defer { output.remove() }
        _ = await Self.archive(handler, into: output)

        let second = await Self.archive(handler, into: output)

        #expect(text(second).contains(#""files":[]"#) && text(second).contains(#""new_messages":0"#), "\(text(second))")
        #expect(try output.read("T01/C01/2026-11-01.md") == SlackDayFileTests.exampleFile)
    }
}
