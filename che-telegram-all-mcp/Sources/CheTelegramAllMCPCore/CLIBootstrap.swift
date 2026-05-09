import Foundation

/// Decision result for argv parsing — what should the binary do this invocation?
public enum CLIAction: Equatable {
    /// Print version string to stdout, exit 0. No TDLib init.
    case showVersion
    /// Print help text to stdout, exit 0. No TDLib init.
    case showHelp
    /// Default: spawn the MCP server (stdio JSON-RPC + TDLib).
    case runServer
    /// Unknown `-`-prefixed flag — print error to stderr, exit 2. No TDLib init.
    /// Non-flag positionals (paths, config names) still fall through to runServer
    /// so historical callers passing positional args are not broken.
    case unknownFlag(String)
}

/// Pure argv parser + help text holder. Lives in `CheTelegramAllMCPCore` (not in
/// the executable target) so unit tests can pin down the contract without
/// spawning a subprocess.
///
/// The dispatcher in `main.swift` is intentionally trivial — print + exit for
/// `.showVersion` / `.showHelp`, fall through to existing server flow for
/// `.runServer`. Keeping the decision pure here is the testable seam.
public enum CLIBootstrap {

    /// Single source of truth for the binary's version string. Mirrored in:
    /// - `Server.swift` `Server(version: ...)` — MCP `serverInfo` field
    /// - `Package.swift` (no — that's `swift-tools-version`, different)
    /// - `bin/che-telegram-all-mcp-wrapper.sh` `DESIRED_VERSION` (separate repo)
    ///
    /// Bumping requires updating all three places. Future cleanup: thread this
    /// constant through to `Server.swift` so only one literal exists. Out of
    /// scope for #29.
    public static let version = "0.5.0"

    /// Help text printed by `--help` / `-h`. Plain text, no markdown — this
    /// goes to a terminal.
    public static let helpText = """
        che-telegram-all-mcp \(version)

        Stdio JSON-RPC MCP server (TDLib personal-account Telegram client).
        Primary mode is stdio JSON-RPC — connect via Claude Code's MCP plugin
        configuration, not by invoking interactively.

        Usage:
          che-telegram-all-mcp              Run the MCP server (stdio JSON-RPC)
          che-telegram-all-mcp --version    Print version and exit (fast, no TDLib init)
          che-telegram-all-mcp -v           Same as --version
          che-telegram-all-mcp --help       Print this help and exit
          che-telegram-all-mcp -h           Same as --help

        Environment variables:
          TELEGRAM_API_ID, TELEGRAM_API_HASH    Telegram API credentials (required)
          TELEGRAM_PHONE                         Phone for auto-fire authentication
          TELEGRAM_AUTH_CODE                     SMS code for auto-fire (rare; usually \
        prompted via tool call)
          TELEGRAM_2FA_PASSWORD                  2FA password for auto-fire authentication
          CHE_TELEGRAM_LOG_STARTUP=1             Emit `[startup]` timing lines to stderr \
        during init (diagnostic; default: off)

        For tool documentation, connect via stdio JSON-RPC and call `tools/list`.
        """

    /// Decide what to do based on argv. Pure function — no side effects, no
    /// dependency on `ProcessInfo` or `CommandLine` (caller must inject argv
    /// for testability).
    ///
    /// - Parameter args: full argv including binary name at index 0.
    ///
    /// Rejection policy (#29 verify F3):
    /// - Recognized flags (`--version`, `-v`, `--help`, `-h`) dispatch to their
    ///   action.
    /// - Unrecognized `-`-prefixed strings return `.unknownFlag` — the user
    ///   asserted "this is a flag" by typing the dash, so a typo like
    ///   `--versoin` should fail loudly with an error message rather than
    ///   silently entering stdio MCP mode (which then hangs on stdin).
    /// - Non-flag positional arguments (no leading `-`) still fall through to
    ///   `.runServer`. This preserves backward compat for any caller that
    ///   historically passed paths or config names as the first argument —
    ///   the MCP server itself ignores argv beyond [0], so the positional
    ///   is harmless.
    public static func parse(_ args: [String]) -> CLIAction {
        guard args.count > 1 else { return .runServer }
        let first = args[1]
        switch first {
        case "--version", "-v":
            return .showVersion
        case "--help", "-h":
            return .showHelp
        default:
            if first.hasPrefix("-") {
                return .unknownFlag(first)
            }
            return .runServer
        }
    }
}
