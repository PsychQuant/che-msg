import XCTest
@testable import TelegramAllLib

/// End-to-end verification of `dump_chat_to_markdown` against real Telegram.
///
/// Covers design decision "分頁方向 newest → oldest + early-terminate" and the full
/// MarkdownExporter pipeline: pagination → sender resolve → markdown write → metadata.
///
/// Prerequisites:
///   export TELEGRAM_API_ID=<your_api_id>
///   export TELEGRAM_API_HASH=<your_api_hash>
///   export TELEGRAM_E2E_CHAT_ID=<a_chat_id_you_have_access_to>
///
/// Run:
///   swift test --filter E2ETests/DumpChatToMarkdownE2ETests
///
/// IMPORTANT: TDLib's receive loop is process-global — E2E tests MUST be run separately
/// from unit tests via `--filter E2ETests`, not alongside them.
final class DumpChatToMarkdownE2ETests: XCTestCase {

    /// Per-class shared client. TDLib allows only one receive thread per process,
    /// so tests share a single client instance.
    private static var sharedClient: TDLibClient?
    private var client: TDLibClient { Self.sharedClient! }

    override class func setUp() {
        super.setUp()
        let env = ProcessInfo.processInfo.environment
        guard let idStr = env["TELEGRAM_API_ID"], let apiId = Int(idStr),
              let apiHash = env["TELEGRAM_API_HASH"] else { return }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let c = try await TDLibClient()
                try await Task.sleep(nanoseconds: 500_000_000)
                if c.authState == .waitingForParameters {
                    try await c.setParameters(apiId: apiId, apiHash: apiHash)
                }
                for _ in 0..<150 {
                    if c.authState == .ready { break }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                sharedClient = c
            } catch {
                print("E2E setUp failed: \(error)")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    override func setUpWithError() throws {
        if Self.sharedClient == nil {
            throw XCTSkip("E2E setUp skipped — TELEGRAM_API_ID / TELEGRAM_API_HASH not set or auth not ready")
        }
    }

    // MARK: - Full-flow dump

    /// Dump a real chat to a temp file, verify metadata + file content shape.
    /// Requires `TELEGRAM_E2E_CHAT_ID` env var pointing at a chat with at least a few messages.
    func testDumpChatToMarkdownRealChat() async throws {
        guard let chatIdStr = ProcessInfo.processInfo.environment["TELEGRAM_E2E_CHAT_ID"],
              let chatId = Int64(chatIdStr)
        else {
            throw XCTSkip("TELEGRAM_E2E_CHAT_ID not set")
        }

        let tmp = NSTemporaryDirectory()
        let outputPath = (tmp as NSString).appendingPathComponent(
            "dump-e2e-\(UUID().uuidString).md"
        )

        let exporter = MarkdownExporter(client: client)
        let summaryJSON = try await exporter.dumpChatToMarkdown(
            chatId: chatId,
            outputPath: outputPath,
            maxMessages: 200,
            sinceDate: nil,
            untilDate: nil,
            selfLabel: "我"
        )

        // Summary JSON contains expected fields.
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(summaryJSON.utf8)) as? [String: Any]
        )
        XCTAssertEqual(summary["path"] as? String, outputPath)
        XCTAssertNotNil(summary["message_count"])
        XCTAssertNotNil(summary["senders"])
        XCTAssertNotNil(summary["date_range"])

        // File was written and is not empty.
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: outputPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: outputPath))
        let content = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(content.hasPrefix("# 對話"),
                      "Markdown output MUST start with level-1 `# 對話` heading")
        XCTAssertTrue(content.contains("---"),
                      "Markdown output MUST include metadata separator")

        try? fm.removeItem(atPath: outputPath)
    }

    // MARK: - Output path validation (E2E: wrong path → immediate throw, no TDLib call)

    func testDumpChatToMarkdownRejectsInvalidOutputPath() async throws {
        let bogus = "/definitely/does/not/exist/\(UUID().uuidString)/out.md"
        let exporter = MarkdownExporter(client: client)
        do {
            _ = try await exporter.dumpChatToMarkdown(
                chatId: 0,
                outputPath: bogus,
                maxMessages: 10,
                sinceDate: nil,
                untilDate: nil,
                selfLabel: "我"
            )
            XCTFail("MUST throw when output_path parent directory is missing")
        } catch MarkdownExporter.ExportError.outputPathNotWritable(let path) {
            XCTAssertEqual(path, bogus)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}
