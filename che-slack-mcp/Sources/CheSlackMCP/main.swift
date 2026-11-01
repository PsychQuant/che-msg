import Foundation
import CheSlackMCPCore

// Release checks must return before constructing the server, its transport,
// or its credential store. Keep the version shared with MCP serverInfo.
if CommandLine.arguments.dropFirst().elementsEqual(["--version"]) {
    print("\(CheSlackMCPServer.name) \(CheSlackMCPServer.version)")
    exit(0)
}

do {
    let server = try await CheSlackMCPServer()
    try await server.run()
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
