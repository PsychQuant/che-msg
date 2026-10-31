import Foundation
import CheSlackMCPCore

do {
    let server = try await CheSlackMCPServer()
    try await server.run()
} catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
