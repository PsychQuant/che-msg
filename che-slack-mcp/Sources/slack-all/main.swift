import AppKit
import ArgumentParser
import Foundation
import SlackAllCore
import SlackWebLib

@main
struct SlackAll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slack-all",
        abstract: "Manage the Slack session credentials that che-slack-mcp uses.",
        version: "0.9.0",
        subcommands: [Auth.self]
    )
}

struct Auth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Import, check and remove Slack workspaces.",
        subcommands: [Import.self, Status.self, Remove.self]
    )
}

extension Auth {
    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Import every workspace signed in on app.slack.com, through the clipboard or the Slack desktop app.",
            discussion: """
                Prints a line to paste into the browser console of app.slack.com, then asks you to copy \
                the d cookie. Each workspace is verified with auth.test; only verified ones are stored in \
                the Keychain. No token or cookie is printed, and the clipboard is cleared at the end. \
                Exits 0 when at least one workspace was imported.

                With --from-desktop, reads the workspaces signed in to the Slack desktop app instead, from \
                temporary copies of its Cookies and Local Storage/leveldb (deleted before the command ends). \
                The d cookie is decrypted with the Keychain item "Slack Safe Storage": when macOS asks, click \
                Allow, not Always Allow. Only workspaces signed in to the desktop app are found.
                """
        )

        @Flag(name: .long, help: "Read the workspaces and the d cookie from the Slack desktop app instead of the clipboard.")
        var fromDesktop = false

        func run() async throws {
            let results = try await reportingErrors {
                let store = SlackCredentialStore()
                let client = SlackWebClient(pacing: .fromEnvironment())
                if fromDesktop {
                    return try await SlackDesktopImport(
                        store: store, client: client, terminal: StandardTerminal(),
                        data: .standard(home: FileManager.default.homeDirectoryForCurrentUser),
                        safeStorage: SecuritySafeStorageReader()).run()
                }
                return try await SlackAuthImport(store: store, client: client,
                                                 clipboard: PasteboardClipboard(), terminal: StandardTerminal()).run()
            }
            let status = SlackAuthImport.exitStatus(for: results)
            if status != 0 { throw ExitCode(status) }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the imported workspaces and whether each session is still valid.",
            discussion: "Exits 0 when at least one workspace is imported and every one is valid."
        )

        func run() async throws {
            let allValid = try await reportingErrors {
                try await SlackAuthStatus(store: SlackCredentialStore(), client: SlackWebClient(pacing: .fromEnvironment()),
                                          terminal: StandardTerminal()).run()
            }
            if !allValid { throw ExitCode.failure }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a workspace's token and cookie from the Keychain and drop it from the index."
        )

        @Argument(help: "The workspace's team id (e.g. T0123ABCD) or domain (e.g. myteam for myteam.slack.com).")
        var workspace: String

        func run() async throws {
            try await reportingErrors {
                try await SlackAuthRemove(store: SlackCredentialStore(), terminal: StandardTerminal()).run(workspace)
            }
        }
    }
}

/// Runs `body`; an error other than an exit code or cancellation is written
/// to standard error as its description (the core's errors never hold a
/// credential) and the command exits 1.
func reportingErrors<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch let error as ExitCode {
        throw error
    } catch is CancellationError {
        throw ExitCode.failure
    } catch {
        FileHandle.standardError.write(Data("slack-all: \(error)\n".utf8))
        throw ExitCode.failure
    }
}

/// The general pasteboard. Only this executable touches it.
struct PasteboardClipboard: SlackClipboard {
    func text() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func clear() {
        NSPasteboard.general.clearContents()
    }
}

/// Standard output, and Enter on standard input.
struct StandardTerminal: SlackAuthTerminal {
    func say(_ line: String) {
        print(line)
        fflush(stdout)
    }

    func waitForEnter() -> Bool {
        readLine(strippingNewline: true) != nil
    }
}
