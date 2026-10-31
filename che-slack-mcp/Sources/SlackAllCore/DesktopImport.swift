import Foundation
import SlackWebLib

/// Where the Slack desktop app keeps its data. The executable passes the
/// user's home; tests pass a temporary one, so no test resolves the real
/// folders.
public struct SlackDesktopData: Sendable {
    public let candidates: [URL]

    public init(candidates: [URL]) { self.candidates = candidates }

    /// The Mac App Store version's container, then the direct download's
    /// folder (spec: slack-credentials, "Desktop import").
    public static func standard(home: URL) -> SlackDesktopData {
        SlackDesktopData(candidates: [
            home.appendingPathComponent("Library/Containers/com.tinyspeck.slackmacgap/Data/Library/Application Support/Slack",
                                        isDirectory: true),
            home.appendingPathComponent("Library/Application Support/Slack", isDirectory: true),
        ])
    }

    static let cookies = "Cookies"
    static let leveldb = "Local Storage/leveldb"

    /// The first candidate holding both `Cookies` and `Local Storage/leveldb`;
    /// else the first that is a folder (so the copy step names what it
    /// lacks); else nil. A container left behind by an uninstalled version
    /// therefore does not hide the other version's data.
    func locate() -> URL? {
        let folders = candidates.filter { isDirectory($0) }
        return folders.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(Self.cookies).path)
                && isDirectory($0.appendingPathComponent(Self.leveldb))
        } ?? folders.first
    }

    private func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}

/// A desktop import that stopped before verifying any workspace: which step
/// failed and why. The detail is written from fixed phrases, paths and file
/// names; it never holds a token, a cookie or the Safe Storage password.
public struct SlackDesktopImportError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// The steps that can fail, in the order they run. A closed list.
    public enum Step: String, Equatable, Sendable, CaseIterable {
        case findDataFolder = "find the Slack desktop app's data"
        case copyData = "copy Cookies and Local Storage/leveldb"
        case readLocalConfig = "read localConfig_v2"
        case readCookie = "read the d cookie"
        case readSafeStorage = "read Slack Safe Storage"
        case decryptCookie = "decrypt the d cookie"
    }

    public let step: Step
    public let detail: String

    public init(_ step: Step, _ detail: String) {
        self.step = step
        self.detail = detail
    }

    public var description: String {
        "Desktop import stopped at the step \"\(step.rawValue)\": \(detail) Nothing was imported. "
            + "Run slack-all auth import to import through the browser and the clipboard instead."
    }

    public var errorDescription: String? { description }
}

/// `slack-all auth import --from-desktop` (spec: slack-credentials,
/// "Desktop import").
///
/// Order, and where the spec is silent:
/// - The data folder is found first, so a Mac without the desktop app stops
///   before anything else, touching no Keychain item.
/// - The index is read next, as in the clipboard import, so a broken
///   `SLACK_WORKSPACES` stops before Slack's data is copied.
/// - `Cookies` and the `.ldb`, `.sst` and `.log` files of
///   `Local Storage/leveldb` (regular files only, no links) are copied into
///   a new folder with permissions 0700 under the temporary directory; both
///   are read from the copies, and the copies are deleted before
///   `Slack Safe Storage` is read, so they are not left on disk while the
///   user answers the macOS prompt. They are deleted on every path, success
///   or failure; a deletion that fails is reported with the folder's path.
/// - `localConfig_v2` and the cookie row are read before the Keychain is
///   asked, so unreadable data never costs the user a prompt.
/// - The index is checked to fit one Keychain write before
///   `Slack Safe Storage` is read, for the same reason.
/// - A team entry without one of the five fields is skipped and counted.
/// - The workspaces are then verified and stored by `ImportVerifier`, the
///   clipboard import's own path.
public struct SlackDesktopImport: Sendable {
    let store: SlackCredentialStore
    let client: SlackWebClient
    let terminal: any SlackAuthTerminal
    let data: SlackDesktopData
    let safeStorage: any SlackSafeStorageReader
    let temporaryDirectory: URL

    public init(store: SlackCredentialStore, client: SlackWebClient, terminal: any SlackAuthTerminal,
                data: SlackDesktopData, safeStorage: any SlackSafeStorageReader,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.store = store
        self.client = client
        self.terminal = terminal
        self.data = data
        self.safeStorage = safeStorage
        self.temporaryDirectory = temporaryDirectory
    }

    static let cookieHost = ".slack.com"
    static let cookieName = "d"

    /// What was read from the copies.
    private struct DesktopRead {
        let candidates: [ImportCandidate]
        let skipped: Int
        let cookie: EncryptedCookie
    }

    /// Reads the desktop app's workspaces and cookie, then verifies and
    /// stores each workspace, printing one line each.
    ///
    /// - Throws: `SlackDesktopImportError` naming the step that failed;
    ///   `SlackCredentialError` when the index cannot be read;
    ///   `SlackAuthCommandError` when the index would not fit one Keychain
    ///   write, or cannot be written after an import.
    public func run() async throws -> [SlackImportResult] {
        guard let folder = data.locate() else {
            let places = data.candidates.map(\.path).joined(separator: " or in ")
            throw SlackDesktopImportError(.findDataFolder, "No Slack desktop data was found in \(places).")
        }
        let existing = try await store.workspaces()
        terminal.say("Reading the Slack desktop app's data in \(folder.path).")
        let read = try readCopies(of: folder)

        var redact = Redaction(secrets: read.candidates.map(\.token))
        let names = read.candidates.map(\.workspace.name).joined(separator: ", ")
        terminal.say(redact("Read \(read.candidates.count) workspace(s) from localConfig_v2: \(names)."))
        if read.skipped > 0 {
            let entries = read.skipped == 1 ? "1 team entry" : "\(read.skipped) team entries"
            terminal.say("Skipped \(entries) in localConfig_v2 without a string id, domain, name, token and user_id.")
        }
        let verifier = ImportVerifier(store: store, client: client, terminal: terminal)
        try verifier.checkIndexFits(read.candidates, existing: existing)
        let cookie = try await decrypt(read.cookie)
        redact = Redaction(secrets: redact.secrets + [cookie])

        return try await verifier.verifyAndStore(read.candidates, cookie: cookie, redact: redact)
    }

    // MARK: - Reading the copies

    /// Copies the two databases into a private folder, reads them, and
    /// deletes the folder before returning or throwing.
    private func readCopies(of folder: URL) throws -> DesktopRead {
        let copies: URL
        do {
            copies = try Self.makePrivateFolder(in: temporaryDirectory)
        } catch {
            throw SlackDesktopImportError(.copyData, "A private temporary folder could not be created in \(temporaryDirectory.path).")
        }
        defer { deleteCopies(copies) }

        let cookies = copies.appendingPathComponent(SlackDesktopData.cookies)
        let leveldb = copies.appendingPathComponent("leveldb", isDirectory: true)
        try copyFile(folder.appendingPathComponent(SlackDesktopData.cookies), to: cookies)
        try copyLevelDB(folder.appendingPathComponent(SlackDesktopData.leveldb, isDirectory: true), to: leveldb)
        terminal.say("Copied Cookies and Local Storage/leveldb to \(copies.path); the copies are deleted once read.")

        let (candidates, skipped) = try readLocalConfig(leveldb)
        let cookie: EncryptedCookie
        do {
            cookie = try ChromiumCookieDatabase.encryptedCookie(at: cookies, hostKey: Self.cookieHost, name: Self.cookieName)
        } catch let error as DesktopFormatError {
            throw SlackDesktopImportError(.readCookie, "\(Self.sentence(error.reason)) (read from a copy of \(folder.path)/Cookies)")
        }
        return DesktopRead(candidates: candidates, skipped: skipped, cookie: cookie)
    }

    /// A new folder in `parent` that only the user can open (0700).
    static func makePrivateFolder(in parent: URL) throws -> URL {
        let folder = parent.appendingPathComponent("slack-all-desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    private func deleteCopies(_ copies: URL) {
        do {
            try FileManager.default.removeItem(at: copies)
        } catch {
            terminal.say("Warning: could not delete the temporary copies in \(copies.path). They hold Slack's tokens "
                + "and encrypted cookie; delete that folder yourself.")
        }
    }

    /// Copies `source`, which must be a regular file (not a link).
    private func copyFile(_ source: URL, to destination: URL) throws {
        guard Self.isRegularFile(source) else {
            throw SlackDesktopImportError(.copyData, "\(source.path) does not exist or is not a regular file.")
        }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw SlackDesktopImportError(.copyData, "\(source.path) could not be copied.")
        }
    }

    /// Copies the tables and logs of the LevelDB folder `source`.
    private func copyLevelDB(_ source: URL, to destination: URL) throws {
        let isFolder = (try? FileManager.default.attributesOfItem(atPath: source.path)[.type] as? FileAttributeType) == .typeDirectory
        guard isFolder, let names = try? FileManager.default.contentsOfDirectory(atPath: source.path) else {
            throw SlackDesktopImportError(.copyData, "\(source.path) does not exist, is not a folder, or cannot be listed.")
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw SlackDesktopImportError(.copyData, "A private temporary folder could not be created in \(temporaryDirectory.path).")
        }
        for name in names where [".ldb", ".sst", ".log"].contains(where: { name.hasSuffix($0) }) {
            let file = source.appendingPathComponent(name)
            if Self.isRegularFile(file) { try copyFile(file, to: destination.appendingPathComponent(name)) }
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    /// The candidates in the newest `localConfig_v2` of the copied folder.
    private func readLocalConfig(_ leveldb: URL) throws -> (candidates: [ImportCandidate], skipped: Int) {
        do {
            guard let value = try LevelDBFolder.newest(in: leveldb, matching: SlackLocalConfig.isKey)?.value else {
                throw DesktopFormatError("Local Storage/leveldb holds no localConfig_v2 for app.slack.com "
                    + "(sign in to a workspace in the Slack desktop app first)")
            }
            return try SlackLocalConfig.candidates(from: SlackLocalConfig.text(of: value))
        } catch let error as DesktopFormatError {
            throw SlackDesktopImportError(.readLocalConfig, Self.sentence(error.reason))
        }
    }

    // MARK: - Decrypting the cookie

    /// Tells the user how to answer the macOS prompt, reads the Safe Storage
    /// password and decrypts the cookie with it. The password is held only
    /// here and is never printed.
    private func decrypt(_ cookie: EncryptedCookie) async throws -> String {
        terminal.say("macOS will now ask whether security may use the Keychain item \"Slack Safe Storage\" "
            + "(type your login password if asked). Click Allow, not Always Allow: Always Allow would let any program "
            + "read Slack's cookie key through security from then on. Waiting up to \(formatSeconds(safeStorage.timeout)) s.")
        let password: String
        switch await safeStorage.readPassword() {
        case .found(let value):
            password = value
        case .absent:
            throw SlackDesktopImportError(.readSafeStorage, "The Keychain has no item \"Slack Safe Storage\"; "
                + "the Slack desktop app creates it when it first signs in.")
        case .timedOut(let seconds):
            throw SlackDesktopImportError(.readSafeStorage, "Reading \"Slack Safe Storage\" did not finish within "
                + "\(formatSeconds(seconds)) s, so the macOS prompt was probably not answered.")
        case .unavailable(let reason):
            throw SlackDesktopImportError(.readSafeStorage, "Reading \"Slack Safe Storage\" failed: \(reason). "
                + "If you clicked Deny, run the command again and click Allow.")
        }
        do {
            return try ChromiumCookieCrypto.decrypt(cookie.encryptedValue, password: password, hostKey: Self.cookieHost,
                                                    metaVersion: cookie.metaVersion)
        } catch let error as DesktopFormatError {
            throw SlackDesktopImportError(.decryptCookie, Self.sentence(error.reason))
        }
    }

    /// `reason` as a sentence: capitalised, ending with a period.
    private static func sentence(_ reason: String) -> String {
        guard let first = reason.first else { return reason }
        return first.uppercased() + reason.dropFirst() + (reason.hasSuffix(".") ? "" : ".")
    }
}
