import Foundation
import CheTelegramAllMCPCore

// Argv dispatch BEFORE any TDLib/MCP init so --version / --help return in
// sub-second wall-clock without paying the ~10s cold-start cost (#29).
switch CLIBootstrap.parse(CommandLine.arguments) {
case .showVersion:
    // The wrapper parses this line; see CLIBootstrap.versionLine.
    print(CLIBootstrap.versionLine)
    exit(0)
case .showHelp:
    print(CLIBootstrap.helpText)
    exit(0)
case .unknownFlag(let flag):
    // Typo on a recognized flag (e.g. `--versoin`) — fail loud so the user
    // sees their mistake instead of silently entering stdio MCP mode and
    // hanging on stdin. Exit 2 (POSIX convention: misuse of CLI), distinct
    // from exit 1 (runtime error in server flow below).
    fputs("Error: unknown flag '\(flag)'. Run with --help for usage.\n", stderr)
    exit(2)
case .runServer:
    // Answers can be written after the input has ended (#57). A client that
    // has also closed its end of stdout would otherwise kill the server with
    // SIGPIPE before it closes TDLib; ignored, the write fails with EPIPE.
    signal(SIGPIPE, SIG_IGN)
    do {
        let server = try await CheTelegramAllMCPServer()
        try await server.run()
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}
