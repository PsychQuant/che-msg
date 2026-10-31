import CommonCrypto
import Foundation
import SQLite3
import SlackWebLib

/// Chromium's cookie encryption on macOS (`v10`): AES-128-CBC with a key
/// derived from the app's Safe Storage password. Every error is a fixed
/// phrase; nothing decrypted, and not the password, is ever quoted.
enum ChromiumCookieCrypto {
    static let prefix = Array("v10".utf8)
    /// The `meta` version from which the plaintext begins with SHA256 of
    /// the cookie's host.
    static let hostHashVersion = 24

    /// PBKDF2-HMAC-SHA1(password, salt `saltysalt`, 1003 rounds), 16 bytes.
    static func key(password: String) -> [UInt8] {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        return status == kCCSuccess ? key : []
    }

    /// The cookie value in `encrypted` (`v10` and an AES-128-CBC ciphertext,
    /// IV 16 spaces, PKCS#7). From `meta` version 24 the plaintext must
    /// begin with SHA256(`hostKey`), which is removed. The result must be a
    /// `d` cookie value (`xoxd-…`) of characters the Keychain write accepts.
    static func decrypt(_ encrypted: [UInt8], password: String, hostKey: String, metaVersion: Int) throws -> String {
        guard encrypted.starts(with: prefix) else { throw DesktopFormatError("the d cookie is not encrypted in the v10 format") }
        let ciphertext = Array(encrypted.dropFirst(prefix.count))
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else {
            throw DesktopFormatError("the d cookie's ciphertext is not a whole number of AES blocks")
        }
        let key = key(password: password)
        guard !key.isEmpty else { throw DesktopFormatError("the key could not be derived from the Safe Storage password") }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var plain = [UInt8](repeating: 0, count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES128), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, ciphertext, ciphertext.count, &plain, plain.count, &moved)
        guard status == kCCSuccess else {
            throw DesktopFormatError("the d cookie could not be decrypted with Slack Safe Storage (a wrong password gives this)")
        }
        var value = Array(plain.prefix(moved))
        if metaVersion >= hostHashVersion {
            guard value.starts(with: sha256(Array(hostKey.utf8))) else {
                throw DesktopFormatError("the decrypted d cookie does not begin with the hash of its host")
            }
            value.removeFirst(Int(CC_SHA256_DIGEST_LENGTH))
        }
        guard value.starts(with: Array("xoxd-".utf8)), let text = String(bytes: value, encoding: .ascii),
              SlackKeychain.acceptsValue(text) else {
            throw DesktopFormatError("the decrypted d cookie is not a d cookie value of the characters A-Z a-z 0-9 - _ . % + / =")
        }
        return text
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
        return digest
    }
}

/// The encrypted `d` cookie and the database's `meta` version. The
/// description never shows the ciphertext.
struct EncryptedCookie: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let metaVersion: Int
    let encryptedValue: [UInt8]

    var description: String { "EncryptedCookie(metaVersion: \(metaVersion), \(encryptedValue.count) bytes)" }
    var debugDescription: String { description }
}

/// A Chromium `Cookies` SQLite database, opened read-only with
/// `immutable=1`: SQLite neither locks nor writes it and ignores any
/// journal, which suits the temporary copy this is used on.
enum ChromiumCookieDatabase {
    /// The `meta` version and the encrypted value of the cookie `name` for
    /// `hostKey`; of several such rows, the one created last.
    ///
    /// - Throws: `DesktopFormatError` (a fixed phrase, with SQLite's result
    ///   code) when the file cannot be opened or queried as a cookie
    ///   database, has no `meta` version, or has no such cookie with an
    ///   encrypted value.
    static func encryptedCookie(at url: URL, hostKey: String, name: String) throws -> EncryptedCookie {
        guard FileManager.default.fileExists(atPath: url.path) else { throw DesktopFormatError("Cookies does not exist") }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        let uri = url.absoluteString + "?immutable=1"
        let opened = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard opened == SQLITE_OK else { throw DesktopFormatError("Cookies cannot be opened as a SQLite database (SQLite error \(opened))") }

        let version = try firstRow(db, "SELECT value FROM meta WHERE key = 'version'", []) { statement in
            sqlite3_column_text(statement, 0).flatMap { Int(String(cString: $0)) }
        }
        guard let metaVersion = version ?? nil else { throw DesktopFormatError("Cookies has no meta version") }

        let sql = "SELECT encrypted_value FROM cookies WHERE host_key = ?1 AND name = ?2 ORDER BY creation_utc DESC LIMIT 1"
        let value = try firstRow(db, sql, [hostKey, name]) { statement -> [UInt8] in
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, let bytes = sqlite3_column_blob(statement, 0) else { return [] }
            return Array(UnsafeRawBufferPointer(start: bytes, count: count))
        }
        guard let encrypted = value else { throw DesktopFormatError("Cookies has no \(name) cookie for \(hostKey)") }
        guard !encrypted.isEmpty else { throw DesktopFormatError("the \(name) cookie in Cookies has no encrypted value") }
        return EncryptedCookie(metaVersion: metaVersion, encryptedValue: encrypted)
    }

    /// `read` applied to the first row of `sql` with `parameters` bound as
    /// text, or nil when there is no row.
    private static func firstRow<T>(_ db: OpaquePointer?, _ sql: String, _ parameters: [String],
                                    _ read: (OpaquePointer?) -> T) throws -> T? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            throw DesktopFormatError("Cookies is not a cookie database this import can read (SQLite error \(prepared))")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, parameter) in parameters.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), parameter, -1, transient)
        }
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return read(statement)
        case SQLITE_DONE: return nil
        case let code: throw DesktopFormatError("Cookies could not be read (SQLite error \(code))")
        }
    }
}
