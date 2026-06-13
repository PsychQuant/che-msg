import Foundation
import MCP
import TelegramAllLib

/// Format elapsed wall-clock since `start` and emit to stderr with `[startup]`
/// prefix. Used by `CheTelegramAllMCPServer.init` when
/// `CHE_TELEGRAM_LOG_STARTUP=1` to attribute cold-start latency (#29).
///
/// File-scope (not a method) so it does not leak into the public API surface
/// of `CheTelegramAllMCPServer`. stdout is reserved for MCP JSON-RPC traffic;
/// startup logs go strictly to stderr.
internal func logStartupDuration(_ phase: String, since start: DispatchTime) {
    let elapsedNs = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
    let seconds = Double(elapsedNs) / 1_000_000_000.0
    fputs(String(format: "[startup] %@=%.3fs\n", phase, seconds), stderr)
}

/// Decide whether `CheTelegramAllMCPServer.init` should emit startup timing
/// lines. Pure function — takes the env dictionary explicitly so unit tests
/// can pin the truthy contract without touching `ProcessInfo`.
///
/// Strict `== "1"` (no `"true"` / `"yes"` / `"TRUE"` aliases): matches the
/// help text exactly + avoids surprising behavior from typos like `=truee`
/// silently disabling logging. The verify-29 audit confirmed that loosening
/// this would force re-coordination across help text and Claude Code env
/// docs.
internal func shouldLogStartup(env: [String: String]) -> Bool {
    return env["CHE_TELEGRAM_LOG_STARTUP"] == "1"
}

public final class CheTelegramAllMCPServer {
    private let server: Server
    private let transport: StdioTransport
    private let tools: [Tool]
    private let tdlib: TDLibClient

    public init() async throws {
        // Diagnostic hook (#29): when CHE_TELEGRAM_LOG_STARTUP=1, print
        // per-phase wall-clock to stderr so we can attribute the ~10s cold
        // start (TDLib framework load? tools registration? handler wiring?).
        // stderr is safe — MCP stdio uses stdout for JSON-RPC. Default off.
        //
        // Failure-path observability (#29 verify F2): each phase wraps in
        // do/catch so a throw still emits its phase line (with `_FAILED`
        // suffix) before re-throwing. Without this, the diagnostic story
        // only covers the success path — but the user reaching for this
        // env var is exactly the user with a slow init that may be
        // throwing.
        let logStartup = shouldLogStartup(env: ProcessInfo.processInfo.environment)
        let totalStart = DispatchTime.now()

        let tdlibStart = DispatchTime.now()
        do {
            tdlib = try await TDLibClient()
            if logStartup { logStartupDuration("tdlib_init", since: tdlibStart) }
        } catch {
            if logStartup { logStartupDuration("tdlib_init_FAILED", since: tdlibStart) }
            if logStartup { logStartupDuration("total_FAILED", since: totalStart) }
            throw error
        }

        let toolsStart = DispatchTime.now()
        tools = Self.defineTools()
        if logStartup {
            logStartupDuration("tools_define", since: toolsStart)
        }

        server = Server(
            name: "che-telegram-all-mcp",
            version: "0.5.0",
            capabilities: .init(tools: .init())
        )

        transport = StdioTransport()

        let registerStart = DispatchTime.now()
        await registerHandlers()
        if logStartup {
            logStartupDuration("register_handlers", since: registerStart)
            logStartupDuration("total", since: totalStart)
        }
    }

    public func run() async throws {
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    // MARK: - Tool Definitions

    static func defineTools() -> [Tool] {
        [
            // Authentication
            tool("auth_set_parameters",
                 description: "Step 1: Set Telegram API credentials. Get api_id and api_hash from https://my.telegram.org",
                 properties: [
                    "api_id": prop("integer", "Telegram API ID (numeric)"),
                    "api_hash": prop("string", "Telegram API hash (string)"),
                 ],
                 required: ["api_id", "api_hash"]),

            tool("auth_send_phone",
                 description: "Step 2: Send your phone number to start authentication",
                 properties: [
                    "phone_number": prop("string", "Phone number with country code, e.g. +886912345678"),
                 ],
                 required: ["phone_number"]),

            tool("auth_send_code",
                 description: "Step 3: Enter the verification code received via Telegram/SMS",
                 properties: [
                    "code": prop("string", "Verification code"),
                 ],
                 required: ["code"]),

            tool("auth_send_password",
                 description: "Step 3b: Enter 2FA password (only if two-step verification is enabled)",
                 properties: [
                    "password": prop("string", "Two-step verification password"),
                 ],
                 required: ["password"]),

            tool("auth_status",
                 description: "Check current authentication status. Returns {state, next_step, last_error} where next_step describes what to call next (or null when ready) and last_error reports any auto-fire failure.",
                 properties: [:], required: []),

            tool("auth_run",
                 description: "Drive the authentication state machine by one step. Call repeatedly with optional args until state == 'ready'. Auto-fires from env vars (TELEGRAM_API_ID/HASH, TELEGRAM_PHONE, TELEGRAM_2FA_PASSWORD) when present; otherwise returns next_step.required_args identifying what to provide. SMS verification code MUST be supplied via the 'code' arg (never auto-fired).",
                 properties: [
                    "phone": prop("string", "Phone number (international format) — only honored when state == waitingForPhoneNumber"),
                    "code": prop("string", "SMS verification code — only honored when state == waitingForCode"),
                    "password": prop("string", "2FA password — only honored when state == waitingForPassword"),
                 ],
                 required: []),

            tool("logout",
                 description: "Log out from Telegram",
                 properties: [:], required: []),

            // User Info
            tool("get_me",
                 description: "Get your own Telegram profile info",
                 properties: [:], required: []),

            tool("get_user",
                 description: "Get info about a user by ID",
                 properties: [
                    "user_id": prop("integer", "Telegram user ID"),
                 ],
                 required: ["user_id"]),

            tool("get_contacts",
                 description: "Get your contact list",
                 properties: [
                    "limit": prop("integer", "Max contacts to return (default 200, max 10000)"),
                 ],
                 required: []),

            // Chat Operations
            tool("get_chats",
                 description: "Get your chat list (recent conversations)",
                 properties: [
                    "limit": prop("integer", "Max number of chats to return (default 50)"),
                 ],
                 required: []),

            tool("get_chat",
                 description: "Get detailed info about a specific chat",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                 ],
                 required: ["chat_id"]),

            tool("search_chats",
                 description: "Search for chats by name",
                 properties: [
                    "query": prop("string", "Search query"),
                    "limit": prop("integer", "Max results (default 20)"),
                 ],
                 required: ["query"]),

            // Message Operations
            tool("get_chat_history",
                 description: "Get message history from a chat",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "limit": prop("integer", "Max messages to return (default 50)"),
                    "from_message_id": prop("integer", "Start from this message ID (0 = latest)"),
                    "since_date": prop("string", "Lower bound inclusive, ISO date YYYY-MM-DD (optional)"),
                    "until_date": prop("string", "Upper bound inclusive — includes whole day (23:59:59 local). ISO date YYYY-MM-DD (optional)"),
                    "max_messages": prop("integer", "Total message cap — enables auto-pagination. Defaults to limit when from_message_id=0"),
                 ],
                 required: ["chat_id"]),

            tool("send_message",
                 description: "Send a text message to any chat (personal, group, channel)",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "text": prop("string", "Message text"),
                    "reply_to_message_id": prop("integer", "Optional: message ID to reply to"),
                 ],
                 required: ["chat_id", "text"]),

            tool("edit_message",
                 description: "Edit a message you sent",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "message_id": prop("integer", "Message ID to edit"),
                    "text": prop("string", "New text"),
                 ],
                 required: ["chat_id", "message_id", "text"]),

            tool("delete_messages",
                 description: "Delete messages",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "message_ids": arrayOfIntsProp("List of message IDs to delete"),
                    "revoke": prop("boolean", "Delete for everyone (default true)"),
                 ],
                 required: ["chat_id", "message_ids"]),

            tool("forward_messages",
                 description: "Forward messages from one chat to another",
                 properties: [
                    "chat_id": prop("integer", "Target chat ID"),
                    "from_chat_id": prop("integer", "Source chat ID"),
                    "message_ids": arrayOfIntsProp("List of message IDs to forward"),
                 ],
                 required: ["chat_id", "from_chat_id", "message_ids"]),

            tool("search_messages",
                 description: "Search for messages within a chat",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "query": prop("string", "Search query"),
                    "limit": prop("integer", "Max results (default 50)"),
                 ],
                 required: ["chat_id", "query"]),

            // Group Management
            tool("get_chat_members",
                 description: "Get members of a group/supergroup",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "limit": prop("integer", "Max members (default 200)"),
                 ],
                 required: ["chat_id"]),

            tool("pin_message",
                 description: "Pin a message in a chat",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "message_id": prop("integer", "Message ID to pin"),
                    "disable_notification": prop("boolean", "Pin silently"),
                 ],
                 required: ["chat_id", "message_id"]),

            tool("unpin_message",
                 description: "Unpin a message",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "message_id": prop("integer", "Message ID to unpin"),
                 ],
                 required: ["chat_id", "message_id"]),

            tool("set_chat_title",
                 description: "Change a chat's title",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "title": prop("string", "New title"),
                 ],
                 required: ["chat_id", "title"]),

            tool("set_chat_description",
                 description: "Change a chat's description",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "description": prop("string", "New description"),
                 ],
                 required: ["chat_id", "description"]),

            // Read State
            tool("mark_as_read",
                 description: "Mark messages as read",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "message_ids": arrayOfIntsProp("List of message IDs to mark as read"),
                 ],
                 required: ["chat_id", "message_ids"]),

            // Group Creation
            tool("create_group",
                 description: "Create a new basic group chat",
                 properties: [
                    "title": prop("string", "Group title"),
                    "user_ids": arrayOfIntsProp("List of user IDs to add as initial members"),
                 ],
                 required: ["title", "user_ids"]),

            tool("add_chat_member",
                 description: "Add a member to a group chat",
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "user_id": prop("integer", "User ID to add"),
                 ],
                 required: ["chat_id", "user_id"]),

            // History Export (heavy operation: paginates TDLib, writes Markdown file)
            tool("dump_chat_to_markdown",
                 description: """
                 Export a chat's message history to a Markdown file. \
                 Heavy operation — paginates TDLib, resolves sender names, writes to output_path. \
                 Returns summary metadata (path, message_count, date_range, senders) — does NOT \
                 return Markdown content in the response. Use get_chat_history for quick peeks.
                 """,
                 properties: [
                    "chat_id": prop("integer", "Chat ID"),
                    "output_path": prop("string", "Absolute filesystem path to write the .md file"),
                    "max_messages": prop("integer", "Upper bound on messages fetched (default 5000)"),
                    "since_date": prop("string", "Lower bound inclusive, ISO date YYYY-MM-DD (optional)"),
                    "until_date": prop("string", "Upper bound inclusive — includes whole day (23:59:59 local). ISO date YYYY-MM-DD (optional)"),
                    "self_label": prop("string", "Label for outgoing messages (default \"我\")"),
                 ],
                 required: ["chat_id", "output_path"]),
        ]
    }

    // MARK: - Handler Registration

    private func registerHandlers() async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: self.tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await self.handleToolCall(name: params.name, arguments: params.arguments ?? [:])
        }
    }

    // MARK: - Tool Call Dispatch

    private func handleToolCall(name: String, arguments args: [String: Value]) async -> CallTool.Result {
        do {
            let result: String

            switch name {
            // Authentication
            case "auth_set_parameters":
                guard let apiId = args["api_id"]?.intValue,
                      let apiHash = args["api_hash"]?.stringValue else {
                    return errorResult("api_id and api_hash are required")
                }
                try await tdlib.setParameters(apiId: apiId, apiHash: apiHash)
                result = "{\"status\": \"\(tdlib.getAuthState().rawValue)\", \"next_step\": \"Use auth_send_phone to send your phone number\"}"

            case "auth_send_phone":
                guard let phone = args["phone_number"]?.stringValue else {
                    return errorResult("phone_number is required")
                }
                try await tdlib.sendPhoneNumber(phone)
                result = "{\"status\": \"\(tdlib.getAuthState().rawValue)\", \"next_step\": \"Use auth_send_code with the code you received\"}"

            case "auth_send_code":
                guard let code = args["code"]?.stringValue else {
                    return errorResult("code is required")
                }
                try await tdlib.sendAuthCode(code)
                if tdlib.getAuthState() == .waitingForPassword {
                    result = "{\"status\": \"waitingForPassword\", \"next_step\": \"Use auth_send_password with your 2FA password\"}"
                } else {
                    result = "{\"status\": \"\(tdlib.getAuthState().rawValue)\"}"
                }

            case "auth_send_password":
                guard let password = args["password"]?.stringValue else {
                    return errorResult("password is required")
                }
                try await tdlib.sendPassword(password)
                result = "{\"status\": \"\(tdlib.getAuthState().rawValue)\"}"

            case "auth_status":
                return authStatusResult(
                    state: tdlib.getAuthState(),
                    lastError: tdlib.getLastAutoFireError()
                )

            case "auth_run":
                let env = ProcessInfo.processInfo.environment
                let action = decideAuthRunAction(
                    state: tdlib.getAuthState(),
                    phone: args["phone"]?.stringValue,
                    code: args["code"]?.stringValue,
                    password: args["password"]?.stringValue,
                    envApiId: env["TELEGRAM_API_ID"].flatMap(Int.init),
                    envApiHash: env["TELEGRAM_API_HASH"],
                    envPhone: env["TELEGRAM_PHONE"],
                    envPassword: env["TELEGRAM_2FA_PASSWORD"]
                )
                switch action {
                case .callSetParameters(let apiId, let apiHash):
                    try await tdlib.setParameters(apiId: apiId, apiHash: apiHash)
                case .callSendPhone(let phone):
                    try await tdlib.sendPhoneNumber(phone)
                case .callSendCode(let code):
                    try await tdlib.sendAuthCode(code)
                case .callSendPassword(let password):
                    try await tdlib.sendPassword(password)
                case .noOpReady, .needsArgs:
                    break
                case .errorClosed:
                    return errorResult("Authentication session is closed. Restart the MCP server to retry.")
                }
                return authStatusResult(
                    state: tdlib.getAuthState(),
                    lastError: tdlib.getLastAutoFireError()
                )

            case "logout":
                result = try await tdlib.logout()

            // User Info
            case "get_me":
                result = try await tdlib.getMe()

            case "get_user":
                let userId = try requiredInt64(args, "user_id")
                result = try await tdlib.getUser(userId: userId)

            case "get_contacts":
                let limit = try parseLimit(args, default: 200)
                result = try await tdlib.getContacts(limit: limit)

            // Chat Operations
            case "get_chats":
                let limit = try parseLimit(args, default: 50)
                result = try await tdlib.getChats(limit: limit)

            case "get_chat":
                let chatId = try requiredInt64(args, "chat_id")
                result = try await tdlib.getChat(chatId: chatId)

            case "search_chats":
                guard let query = args["query"]?.stringValue else {
                    return errorResult("query is required")
                }
                let limit = try parseLimit(args, default: 20)
                result = try await tdlib.searchChats(query: query, limit: limit)

            // Message Operations
            case "get_chat_history":
                let parsed: GetChatHistoryArgs
                do {
                    parsed = try parseGetChatHistoryArgs(args)
                } catch {
                    return errorResultFromParse(error)
                }
                result = try await tdlib.getChatHistory(
                    chatId: parsed.chatId,
                    limit: parsed.limit,
                    fromMessageId: parsed.fromMessageId,
                    maxMessages: parsed.maxMessages,
                    sinceDate: parsed.sinceDate,
                    untilDate: parsed.untilDate
                )

            case "send_message":
                let ids = try parseSendMessageIds(args)
                guard let text = args["text"]?.stringValue else {
                    return errorResult("text is required")
                }
                result = try await tdlib.sendMessage(chatId: ids.chatId, text: text, replyToMessageId: ids.replyToMessageId)

            case "edit_message":
                let ids = try parseChatMessageIds(args)
                guard let text = args["text"]?.stringValue else {
                    return errorResult("text is required")
                }
                result = try await tdlib.editMessage(chatId: ids.chatId, messageId: ids.messageId, text: text)

            case "delete_messages":
                let chatId = try requiredInt64(args, "chat_id")
                guard let msgIds = int64ArrayArg(args, "message_ids") else {
                    return errorResult("message_ids is required")
                }
                let revoke = args["revoke"]?.boolValue ?? true
                result = try await tdlib.deleteMessages(chatId: chatId, messageIds: msgIds, revoke: revoke)

            case "forward_messages":
                let ids = try parseChatForwardIds(args)
                guard let msgIds = int64ArrayArg(args, "message_ids") else {
                    return errorResult("message_ids is required")
                }
                result = try await tdlib.forwardMessages(chatId: ids.chatId, fromChatId: ids.fromChatId, messageIds: msgIds)

            case "search_messages":
                let chatId = try requiredInt64(args, "chat_id")
                guard let query = args["query"]?.stringValue else {
                    return errorResult("query is required")
                }
                let limit = try parseLimit(args, default: 50)
                result = try await tdlib.searchMessages(chatId: chatId, query: query, limit: limit)

            // Group Management
            case "get_chat_members":
                let chatId = try requiredInt64(args, "chat_id")
                let limit = try parseLimit(args, default: 200)
                result = try await tdlib.getChatMembers(chatId: chatId, limit: limit)

            case "pin_message":
                let ids = try parseChatMessageIds(args)
                let silent = args["disable_notification"]?.boolValue ?? false
                result = try await tdlib.pinMessage(chatId: ids.chatId, messageId: ids.messageId, disableNotification: silent)

            case "unpin_message":
                let ids = try parseChatMessageIds(args)
                result = try await tdlib.unpinMessage(chatId: ids.chatId, messageId: ids.messageId)

            case "set_chat_title":
                let chatId = try requiredInt64(args, "chat_id")
                guard let title = args["title"]?.stringValue else {
                    return errorResult("title is required")
                }
                result = try await tdlib.setChatTitle(chatId: chatId, title: title)

            case "set_chat_description":
                let chatId = try requiredInt64(args, "chat_id")
                guard let desc = args["description"]?.stringValue else {
                    return errorResult("description is required")
                }
                result = try await tdlib.setChatDescription(chatId: chatId, description: desc)

            case "mark_as_read":
                let chatId = try requiredInt64(args, "chat_id")
                guard let msgIds = int64ArrayArg(args, "message_ids") else {
                    return errorResult("message_ids is required")
                }
                result = try await tdlib.markAsRead(chatId: chatId, messageIds: msgIds)

            // Group Creation
            case "create_group":
                guard let title = args["title"]?.stringValue,
                      let userIds = int64ArrayArg(args, "user_ids") else {
                    return errorResult("title and user_ids are required")
                }
                result = try await tdlib.createGroup(title: title, userIds: userIds)

            case "add_chat_member":
                let ids = try parseChatUserIds(args)
                result = try await tdlib.addChatMember(chatId: ids.chatId, userId: ids.userId)

            // History Export
            case "dump_chat_to_markdown":
                let parsed: DumpChatToMarkdownArgs
                do {
                    parsed = try parseDumpChatToMarkdownArgs(args)
                } catch {
                    return errorResultFromParse(error)
                }
                let exporter = MarkdownExporter(client: tdlib)
                result = try await exporter.dumpChatToMarkdown(
                    chatId: parsed.chatId,
                    outputPath: parsed.outputPath,
                    maxMessages: parsed.maxMessages,
                    sinceDate: parsed.sinceDate,
                    untilDate: parsed.untilDate,
                    selfLabel: parsed.selfLabel
                )

            default:
                return errorResult("Unknown tool: \(name)")
            }

            return CallTool.Result(content: [.text(text: result, annotations: nil, _meta: nil)], isError: false)

        } catch TDLibClient.TDError.tdlibError(let code, let message) {
            return tdlibErrorResult(code: code, message: message)
        } catch {
            // Use errorResultFromParse so HandlerArgError / DateParseError
            // thrown by parseLimit / parseGetChatHistoryArgs / etc. surface
            // their `description` (user-friendly message) rather than the
            // generic Swift `Error.localizedDescription` fallback. Other
            // error types still fall through to localizedDescription inside
            // errorResultFromParse. Improves observability for the cluster
            // #22 / #23 / #25 throw paths that were previously silent.
            return errorResultFromParse(error)
        }
    }

    // MARK: - Helpers

    private func int64ArrayArg(_ args: [String: Value], _ key: String) -> [Int64]? {
        guard let arr = args[key]?.arrayValue else { return nil }
        let result = arr.compactMap { value -> Int64? in
            if let n = value.intValue { return Int64(n) }
            if let s = value.stringValue { return Int64(s) }
            return nil
        }
        return result.isEmpty ? nil : result
    }

    private func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: "Error: \(message)", annotations: nil, _meta: nil)], isError: true)
    }

    // MARK: - Schema Builder Helpers

    private static func prop(_ type: String, _ description: String) -> Value {
        .object([
            "type": .string(type),
            "description": .string(description)
        ])
    }

    private static func arrayOfIntsProp(_ description: String) -> Value {
        let itemSchema: [String: Value] = ["type": .string("integer")]
        return .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(itemSchema)
        ])
    }

    private static func tool(
        _ name: String,
        description: String,
        properties: [String: Value],
        required: [String]
    ) -> Tool {
        Tool(
            name: name,
            description: description,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) })
            ])
        )
    }
}
