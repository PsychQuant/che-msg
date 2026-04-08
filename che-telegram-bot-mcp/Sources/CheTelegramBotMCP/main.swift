import Foundation
import CheTelegramBotMCPCore

do {
    let server = try await CheTelegramBotMCPServer()
    try await server.run()
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
