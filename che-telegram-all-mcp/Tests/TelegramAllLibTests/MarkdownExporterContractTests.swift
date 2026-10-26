import XCTest
@testable import TelegramAllLib

/// Verifies three facets of the `dump_chat_to_markdown` contract:
///   (a) Output path validation and error reporting
///   (b) Secret chat history warning
///   (c) Self label override
///
/// Covers spec requirements:
///   - "Output path validation and error reporting"
///   - "Secret chat history warning"
///   - (portion of) "`dump_chat_to_markdown` MCP tool" — self_label parameter behavior
///
/// Corresponds to design decisions:
///   - "Markdown dump 必填 output_path，回 summary metadata"
///   - "Self 訊息用可覆寫的 label 區分"
final class MarkdownExporterContractTests: XCTestCase {

    // MARK: - (a) Output path validation

    func testValidateOutputPathThrowsWhenParentMissing() {
        let path = "/definitely/does/not/exist/\(UUID().uuidString)/chat.md"
        do {
            try validateOutputPath(path)
            XCTFail("MUST throw when parent directory is missing")
        } catch MarkdownExporter.ExportError.outputPathNotWritable(let thrownPath) {
            XCTAssertEqual(thrownPath, path,
                           "Thrown error payload MUST include the original invalid path")
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testValidateOutputPathSucceedsForWritableParent() {
        let tmp = NSTemporaryDirectory()
        let path = (tmp as NSString).appendingPathComponent("test-\(UUID().uuidString).md")
        XCTAssertNoThrow(try validateOutputPath(path),
                         "Writable parent directory MUST pass validation")
    }

    // MARK: - (a') Export root (#21)

    /// Unset or empty means no root; any other value is kept as given (not
    /// trimmed) and judged when a dump runs.
    func testExportRootParse() {
        XCTAssertEqual(ExportRoot.environmentVariable, "CHE_TELEGRAM_ALL_EXPORT_ROOT")
        XCTAssertNil(ExportRoot.parse(nil))
        XCTAssertNil(ExportRoot.parse(""))
        XCTAssertEqual(ExportRoot.parse("/Users/me/exports"), "/Users/me/exports")
        XCTAssertEqual(ExportRoot.parse(" exports "), " exports ")
        XCTAssertNil(ExportRoot.fromEnvironment([:]))
        XCTAssertNil(ExportRoot.fromEnvironment(["CHE_TELEGRAM_ALL_EXPORT_ROOT": ""]))
        XCTAssertEqual(ExportRoot.fromEnvironment(["CHE_TELEGRAM_ALL_EXPORT_ROOT": "/r"]), "/r")
        XCTAssertNil(ExportRoot.fromEnvironment(["CHE_TELEGRAM_EXPORT_ROOT": "/r"]),
                     "only the CHE_TELEGRAM_ALL_ name is read")
    }

    /// Scenarios "Path inside the export root accepted", "Path outside the
    /// export root refused", "Symbolic link escape refused" and "Unusable
    /// export root refuses every dump", in a temporary directory:
    ///
    ///     <base>/exports/2026/            root and a subdirectory
    ///     <base>/exports/escape  -> <base>/outside
    ///     <base>/exports/inner   -> <base>/exports/2026
    ///     <base>/exports/file-link.md -> <base>/outside/target.md
    ///     <base>/exports/dangling.md  -> <base>/outside/missing.md
    ///     <base>/exports/notes.txt     a regular file
    ///     <base>/exportsx/            a sibling sharing the root's prefix
    ///     <base>/outside/target.md
    func testValidateOutputPathRespectsExportRoot() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("export-root-\(UUID().uuidString)")
        addTeardownBlock { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("exports")
        let outside = base.appendingPathComponent("outside")
        for dir in [root.appendingPathComponent("2026"), outside, base.appendingPathComponent("exportsx")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let outsideFile = outside.appendingPathComponent("target.md")
        try "original".write(to: outsideFile, atomically: true, encoding: .utf8)
        try "notes".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appendingPathComponent("inner"), withDestinationURL: root.appendingPathComponent("2026"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("file-link.md"), withDestinationURL: outsideFile)
        try fm.createSymbolicLink(at: root.appendingPathComponent("dangling.md"),
                                  withDestinationURL: outside.appendingPathComponent("missing.md"))
        let r = root.path

        // Inside the root, symlinks resolved.
        for path in ["\(r)/chat.md", "\(r)/2026/chat.md", "\(r)/inner/chat.md", "\(r)/2026/../chat.md", "\(r)/./chat.md"] {
            XCTAssertNoThrow(try validateOutputPath(path, exportRoot: r), path)
        }
        // The temporary directory sits under /var -> /private/var: either spelling resolves the same.
        if r.hasPrefix("/var/") {
            XCTAssertNoThrow(try validateOutputPath("/private\(r)/chat.md", exportRoot: r))
            XCTAssertNoThrow(try validateOutputPath("\(r)/chat.md", exportRoot: "/private\(r)"))
        }

        // Outside, or not resolvable to check.
        let refused = [
            "\(outside.path)/chat.md",                  // plainly outside
            "\(outside.path)/missing-dir/chat.md",      // outside wins over a missing parent
            "\(r)/escape/chat.md",                      // directory symlink out of the root
            "\(r)/file-link.md",                        // file symlink out of the root
            "\(r)/dangling.md",                         // dangling symlink
            "\(r)/missing/../../outside/chat.md",       // '..' in components that do not exist
            "\(r)/2026/../../outside/chat.md",          // '..' in the existing prefix, resolved
            "\(r)/notes.txt/chat.md",                   // a prefix that is a file (ENOTDIR)
            "\(base.path)/exportsx/chat.md",            // shares the root's prefix as a string
            r,                                          // the root itself
            "\(r)/chat\u{0}.md",                        // NUL: C would see another path
            "exports/chat.md",                          // relative
        ]
        for path in refused {
            XCTAssertThrowsError(try validateOutputPath(path, exportRoot: r), path) { error in
                guard case MarkdownExporter.ExportError.outsideExportRoot(let p, let root) = error else {
                    return XCTFail("\(path): wrong error \(error)")
                }
                XCTAssertEqual(p, path)
                XCTAssertEqual(root, r)
            }
        }
        XCTAssertEqual(try String(contentsOf: outsideFile, encoding: .utf8), "original")

        // Inside the root but the parent is missing: the existing check reports it.
        XCTAssertThrowsError(try validateOutputPath("\(r)/missing/chat.md", exportRoot: r)) { error in
            guard case MarkdownExporter.ExportError.outputPathNotWritable(let p) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertEqual(p, "\(r)/missing/chat.md")
        }

        // A root that is not an absolute path to an existing directory refuses every path.
        for badRoot in ["exports", " ", "\(base.path)/nope", "\(r)/notes.txt", "\(r)/dangling.md"] {
            XCTAssertThrowsError(try validateOutputPath("\(r)/chat.md", exportRoot: badRoot), badRoot) { error in
                guard case MarkdownExporter.ExportError.exportRootUnusable(let root) = error else {
                    return XCTFail("\(badRoot): wrong error \(error)")
                }
                XCTAssertEqual(root, badRoot)
            }
        }

        // No root: only the parent-directory check, as before.
        XCTAssertNoThrow(try validateOutputPath("\(outside.path)/chat.md", exportRoot: nil))
    }

    func testExportRootErrorsNameThePathAndTheRoot() {
        XCTAssertEqual(
            MarkdownExporter.ExportError.outsideExportRoot(path: "/tmp/chat.md", root: "/Users/me/exports").errorDescription,
            "Output path is outside CHE_TELEGRAM_ALL_EXPORT_ROOT (/Users/me/exports) or could not be resolved: /tmp/chat.md")
        XCTAssertEqual(
            MarkdownExporter.ExportError.exportRootUnusable(root: "exports").errorDescription,
            "CHE_TELEGRAM_ALL_EXPORT_ROOT is not an absolute path to an existing directory: exports")
    }

    // MARK: - (b) Secret chat warning in summary JSON

    func testSummaryContainsSecretChatWarningWhenFlagSet() throws {
        let json = buildSummaryJSON(
            path: "/tmp/x.md",
            messages: [],
            senderNames: [:],
            sinceDate: nil,
            untilDate: nil,
            isSecretChat: true
        )
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        let warning = obj["warning"] as? String
        XCTAssertNotNil(warning,
                        "Summary MUST include `warning` field when chat is secret")
        XCTAssertTrue(warning?.contains("secret") == true || warning?.contains("Secret") == true,
                      "Warning text MUST mention secret chat semantics")
    }

    func testSummaryOmitsWarningWhenNotSecret() throws {
        let json = buildSummaryJSON(
            path: "/tmp/x.md",
            messages: [],
            senderNames: [:],
            sinceDate: nil,
            untilDate: nil,
            isSecretChat: false
        )
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertNil(obj["warning"],
                     "Summary MUST NOT include `warning` field for non-secret chats")
    }

    func testSummaryContainsRequiredFields() throws {
        let json = buildSummaryJSON(
            path: "/tmp/out.md",
            messages: Array(repeating: ["id": Int64(1)], count: 42),
            senderNames: [10: "Alice", 20: "Bob"],
            sinceDate: nil,
            untilDate: nil,
            isSecretChat: false
        )
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["path"] as? String, "/tmp/out.md")
        XCTAssertEqual(obj["message_count"] as? Int, 42)
        XCTAssertNotNil(obj["senders"])
        XCTAssertNotNil(obj["date_range"])
    }

    // MARK: - (c) Self label override

    private func outgoingMsg(at date: Foundation.Date) -> [String: Any] {
        [
            "id": Int64(1),
            "date": Int(date.timeIntervalSince1970),
            "sender": ["type": "user", "user_id": Int64(99)],
            "is_outgoing": true,
            "type": "text",
            "text": "hello",
        ]
    }

    func testSelfLabelDefaultsAreHonoredWhenPassedThrough() {
        let calendar = Calendar(identifier: .gregorian)
        let at = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 10, minute: 0))!
        let md = formatMarkdown(
            messages: [outgoingMsg(at: at)],
            senderNames: [:],
            selfLabel: "我",
            chatTitle: "T",
            chatId: 1,
            sinceDate: nil,
            untilDate: nil,
            exportedAt: at
        )
        XCTAssertTrue(md.contains("**10:00 我**"),
                      "Default self_label \"我\" MUST label outgoing messages")
    }

    func testSelfLabelOverrideChangesOutput() {
        let calendar = Calendar(identifier: .gregorian)
        let at = calendar.date(from: DateComponents(year: 2026, month: 4, day: 14, hour: 10, minute: 0))!
        let md = formatMarkdown(
            messages: [outgoingMsg(at: at)],
            senderNames: [:],
            selfLabel: "che",
            chatTitle: "T",
            chatId: 1,
            sinceDate: nil,
            untilDate: nil,
            exportedAt: at
        )
        XCTAssertTrue(md.contains("**10:00 che**"),
                      "Overridden self_label MUST be used verbatim for outgoing messages")
        XCTAssertFalse(md.contains("**10:00 我**"),
                       "Default label MUST NOT leak when override is provided")
    }
}
