import Foundation
import CheTelegramAllMCPCore

do {
    let server = try await CheTelegramAllMCPServer()
    try await server.run()
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
