import XCTest
import MCP
@testable import CheTelegramAllMCPCore

/// Verifies the MCP tool schema surface for the chat history export capability.
///
/// Covers spec requirements:
///   - "`dump_chat_to_markdown` MCP tool"
///   - "`get_chat_history` MCP tool remains a thin wrapper"
///
/// Corresponds to design decisions:
///   - "既有 `get_chat_history` MCP tool 維持 thin wrapper 不加 flag"
///   - "砍掉中間層 `get_chat_history_full` MCP tool" (no third tool registered)
final class ServerDumpChatToolTests: XCTestCase {

    // MARK: - Helpers

    /// Locate a tool by name in the registered tool set.
    private func tool(_ name: String) -> Tool? {
        CheTelegramAllMCPServer.defineTools().first { $0.name == name }
    }

    /// Extract property names and required set from a tool's inputSchema.
    private func schemaShape(of t: Tool) -> (properties: Set<String>, required: Set<String>)? {
        guard case .object(let schema) = t.inputSchema else { return nil }
        var props: Set<String> = []
        if let propsVal = schema["properties"], case .object(let p) = propsVal {
            props = Set(p.keys)
        }
        var req: Set<String> = []
        if let reqVal = schema["required"], case .array(let r) = reqVal {
            req = Set(r.compactMap { v -> String? in
                if case .string(let s) = v { return s }
                return nil
            })
        }
        return (props, req)
    }

    // MARK: - dump_chat_to_markdown schema

    func testDumpChatToMarkdownRegistered() {
        XCTAssertNotNil(tool("dump_chat_to_markdown"),
                        "dump_chat_to_markdown MUST be registered")
    }

    func testDumpChatToMarkdownProperties() {
        guard let t = tool("dump_chat_to_markdown"),
              let shape = schemaShape(of: t) else {
            XCTFail("dump_chat_to_markdown schema missing")
            return
        }
        XCTAssertEqual(shape.properties, [
            "chat_id", "output_path", "max_messages",
            "since_date", "until_date", "self_label",
        ], "dump_chat_to_markdown MUST expose exactly six properties")
    }

    func testDumpChatToMarkdownRequiredFields() {
        guard let t = tool("dump_chat_to_markdown"),
              let shape = schemaShape(of: t) else {
            XCTFail("dump_chat_to_markdown schema missing")
            return
        }
        XCTAssertEqual(shape.required, ["chat_id", "output_path"],
                       "dump_chat_to_markdown MUST require chat_id and output_path")
    }

    // MARK: - get_chat_history schema (#3, #4)

    func testGetChatHistoryProperties() {
        guard let t = tool("get_chat_history"),
              let shape = schemaShape(of: t) else {
            XCTFail("get_chat_history schema missing")
            return
        }
        XCTAssertEqual(shape.properties, [
            "chat_id", "limit", "from_message_id",
            "since_date", "until_date", "max_messages",
        ], "get_chat_history MUST expose six properties (#4)")
        XCTAssertEqual(shape.required, ["chat_id"],
                       "get_chat_history MUST require only chat_id")
    }

    // MARK: - Middle-tier tool explicitly absent

    func testNoGetChatHistoryFullTool() {
        // Design decision: the middle layer `get_chat_history_full` MCP tool was
        // deliberately NOT added. If someone later registers it, this test fails to
        // force a re-visit of the design rationale.
        XCTAssertNil(tool("get_chat_history_full"),
                     "get_chat_history_full MUST NOT be registered (design decision: cut the middle tier)")
    }
}
