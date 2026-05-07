import Foundation
import CheTelegramAllMCPCore

// Argv dispatch BEFORE any TDLib/MCP init so --version / --help return in
// sub-second wall-clock without paying the ~10s cold-start cost (#29).
switch CLIBootstrap.parse(CommandLine.arguments) {
case .showVersion:
    print("che-telegram-all-mcp \(CLIBootstrap.version)")
    exit(0)
case .showHelp:
    print(CLIBootstrap.helpText)
    exit(0)
case .runServer:
    do {
        let server = try await CheTelegramAllMCPServer()
        try await server.run()
    } catch {
        fputs("Error: \(error)\n", stderr)
        exit(1)
    }
}
