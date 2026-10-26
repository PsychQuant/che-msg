import XCTest
import MCP
@testable import CheTelegramAllMCPCore
import TelegramAllLib

/// `parseDumpChatToMarkdownArgs` (#13): required arguments, defaults and caps.
/// Split out of ServerHandlerLogicTests.swift (#26).
final class ParseDumpArgsTests: XCTestCase {

    // MARK: - #13: parseDumpChatToMarkdownArgs

    func testDumpRequiresChatId() {
        // #11: assert exact contract message
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "output_path": .string("/tmp/x.md"),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "chat_id is required")
        }
    }

    func testDumpRequiresOutputPath() {
        // #11: assert exact contract message
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
        ])) { error in
            XCTAssertEqual((error as? HandlerArgError)?.description,
                           "output_path is required")
        }
    }

    func testDumpDefaultMaxMessagesIs5000() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
        ])
        XCTAssertEqual(parsed.chatId, 100)
        XCTAssertEqual(parsed.outputPath, "/tmp/x.md")
        XCTAssertEqual(parsed.maxMessages, 5000,
                       "default max_messages for dump_chat_to_markdown is 5000 (different from get_chat_history)")
    }

    func testDumpDefaultSelfLabel() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
        ])
        XCTAssertEqual(parsed.selfLabel, "我", "default self_label is 我")
    }

    func testDumpExplicitSelfLabel() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "self_label": .string("Alice"),
        ])
        XCTAssertEqual(parsed.selfLabel, "Alice")
    }

    /// Boundary parity with #15-C2 — dump handler must enforce the same
    /// upward cap. Without this, future cap policy changes in
    /// `validateMaxMessagesCap` could silently drift here.
    func testDumpMaxMessagesAt10001Rejected() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(10_001),
        ]))
    }

    func testDumpMaxMessagesAt10000Accepted() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(10_000),
        ])
        XCTAssertEqual(parsed.maxMessages, 10_000)
    }

    /// Symmetric downward boundary parity with #15 DA finding.
    func testDumpMaxMessagesAt9999Accepted() throws {
        let parsed = try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(9_999),
        ])
        XCTAssertEqual(parsed.maxMessages, 9_999)
    }

    // MARK: - #21: output_path guards

    private func dumpError(_ outputPath: String) -> String? {
        do {
            _ = try parseDumpChatToMarkdownArgs(["chat_id": .int(100), "output_path": .string(outputPath)])
            return nil
        } catch {
            return (error as? HandlerArgError)?.description ?? "unexpected error: \(error)"
        }
    }

    /// Scenario "Relative path refused": the server's working directory is
    /// not the caller's, and `~` is not expanded.
    func testDumpRejectsRelativePath() {
        for path in ["chat.md", "./chat.md", "~/chat.md", "exports/chat.md", "", "\u{301}/tmp/x.md"] {
            XCTAssertEqual(dumpError(path), "output_path must be an absolute path; got \"\(path)\"", path)
        }
        // A leading "/" followed by a combining mark is one Character but still
        // an absolute path to the OS.
        XCTAssertNil(dumpError("/\u{301}tmp/x.md"))
    }

    /// Scenario "Traversal component refused". Only a component that is
    /// exactly `..` counts.
    func testDumpRejectsTraversalPath() {
        for path in ["/tmp/exports/../../Users/me/notes.md", "/tmp/../x.md", "/../tmp/x.md", "/tmp/a/../b/..//c.md"] {
            XCTAssertEqual(dumpError(path), "output_path must not contain '..' components; got \"\(path)\"", path)
        }
        // A "/" followed by a combining mark (or ZWJ, a variation selector, CGJ)
        // fuses into one Character, so a Character split sees no separator; the
        // OS still separates there, and `..` climbs.
        for mark in ["\u{301}", "\u{200D}", "\u{FE0F}", "\u{34F}"] {
            for path in ["/tmp/..\u{2F}\(mark)esc.md", "/..\u{2F}\(mark)esc.md", "/tmp/a/..\u{2F}\(mark)b/x.md"] {
                XCTAssertEqual(dumpError(path), "output_path must not contain '..' components; got \"\(path)\"",
                               path.unicodeScalars.map { String(format: "U+%04X", $0.value) }.joined(separator: " "))
            }
        }
        for path in ["/tmp/..md", "/tmp/a..b/x.md", "/tmp/./x.md", "/tmp/...md", "/tmp/..\u{301}/x.md", "/tmp/\u{301}../x.md"] {
            XCTAssertNil(dumpError(path), path)
        }
    }

    /// Scenarios "Non-Markdown target refused" and "Upper-case extension accepted".
    func testDumpRejectsNonMarkdownExtension() {
        for path in ["/Users/me/.zshrc", "/Users/me/.ssh/authorized_keys", "/Users/me/Library/LaunchAgents/x.plist",
                     "/tmp/x.txt", "/tmp/x.mdx", "/tmp/x.md.sh", "/tmp/x.md/", "/tmp/x.md ", "/tmp/xmd", "/tmp/x.m d",
                     "/tmp/x.md\u{301}", "/tmp/x.md\u{2F}\u{301}", "/tmp/x.m\u{301}d"] {
            XCTAssertEqual(dumpError(path), "output_path must end in .md; got \"\(path)\"", path)
        }
        for path in ["/tmp/x.md", "/tmp/CHAT.MD", "/tmp/x.Md", "/tmp/x.mD", "/tmp/dir.md/x.md"] {
            XCTAssertNil(dumpError(path), path)
        }
    }

    /// The rules are checked in order: absolute, then `..`, then `.md`.
    func testDumpOutputPathRulesAreCheckedInOrder() {
        XCTAssertEqual(dumpError("../x.txt"), "output_path must be an absolute path; got \"../x.txt\"")
        XCTAssertEqual(dumpError("/tmp/../x.txt"), "output_path must not contain '..' components; got \"/tmp/../x.txt\"")
    }

    /// Through the handler's catch: the result is an error naming the rule.
    func testDumpOutputPathGuardSurfacesAsErrorResult() {
        do {
            _ = try parseDumpChatToMarkdownArgs(["chat_id": .int(100), "output_path": .string("/Users/me/.zshrc")])
            XCTFail("parser should have thrown")
        } catch {
            let result = errorResultFromParse(error)
            XCTAssertEqual(result.isError, true)
            guard case .text(let text, _, _)? = result.content.first else { return XCTFail("no text content") }
            XCTAssertEqual(text, "Error: output_path must end in .md; got \"/Users/me/.zshrc\"")
        }
    }

    func testDumpMaxMessagesRejectsZeroOrNegative() {
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(0),
        ]))
        XCTAssertThrowsError(try parseDumpChatToMarkdownArgs([
            "chat_id": .int(100),
            "output_path": .string("/tmp/x.md"),
            "max_messages": .int(-1),
        ]))
    }
}
