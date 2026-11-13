import Foundation
import CheSlackMCPCore

// --version answers before anything else, so the release build's check
// (PsychQuant/che-msg#114) starts no server: no Keychain item, no stdin, no
// network. Every other argv starts the server, as before.
if CheSlackMCPServer.asksForVersion(CommandLine.arguments) {
    print(CheSlackMCPServer.versionLine)
    exit(0)
}

do {
    let server = try await CheSlackMCPServer()
    try await server.run()
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
