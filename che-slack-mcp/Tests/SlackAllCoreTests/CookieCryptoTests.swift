import Foundation
import Testing
@testable import SlackAllCore

/// Chromium `v10` cookie decryption. Every expected value was produced
/// outside this package, by the script recorded in `CookieFixture`:
/// python3 `hashlib.pbkdf2_hmac('sha1', password, b'saltysalt', 1003, 16)`
/// for the key, `shasum -a 256` for SHA256(".slack.com"), and
/// `/usr/bin/openssl enc -aes-128-cbc -K <key> -iv 2020…20 -nosalt`
/// (LibreSSL 3.3.6, PKCS#7 padding) for each ciphertext.
@Suite("Chromium cookie decryption")
struct CookieCryptoTests {
    typealias C = CookieFixture

    @Test("the key is PBKDF2-HMAC-SHA1 of the password with salt saltysalt, 1003 rounds, 16 bytes")
    func key() {
        #expect(ChromiumCookieCrypto.key(password: C.password) == hex("8d980c26091f4ec99749af7dd4090b2e"))
    }

    @Test("from meta version 24 the plaintext starts with SHA256 of the host, which is removed")
    func version24() throws {
        #expect(try ChromiumCookieCrypto.decrypt(C.v24, password: C.password, hostKey: ".slack.com", metaVersion: 24) == C.cookie)
    }

    @Test("before meta version 24 the plaintext is the cookie itself")
    func version23() throws {
        #expect(try ChromiumCookieCrypto.decrypt(C.v23, password: C.password, hostKey: ".slack.com", metaVersion: 23)
                == "xoxd-test-old-format")
    }

    /// Each case: the encrypted value, password, host and meta version.
    static let failures: [(String, [UInt8], String, String, Int)] = [
        ("wrong password", C.v24, "another-password", ".slack.com", 24),
        ("not v10", Array("v11".utf8) + Array(C.v24.dropFirst(3)), C.password, ".slack.com", 24),
        ("no prefix", Array(C.v24.dropFirst(3)), C.password, ".slack.com", 24),
        ("prefix only", Array("v10".utf8), C.password, ".slack.com", 24),
        ("ciphertext not a whole number of blocks", Array(C.v24.dropLast(1)), C.password, ".slack.com", 24),
        ("host hash of another host", C.v24, C.password, ".example.com", 24),
        ("version 24 without the host hash", C.v24WithoutHash, C.password, ".slack.com", 24),
        ("not a d cookie value", C.v24NotACookie, C.password, ".slack.com", 24),
        ("a character the Keychain write refuses", C.v24BadCharacters, C.password, ".slack.com", 24),
        ("the hash read as a cookie under version 23", C.v24, C.password, ".slack.com", 23),
    ]

    @Test("a value that cannot be decrypted to a d cookie throws a fixed phrase", arguments: failures.indices)
    func failure(index: Int) {
        let (_, encrypted, password, host, version) = Self.failures[index]
        #expect {
            try ChromiumCookieCrypto.decrypt(encrypted, password: password, hostKey: host, metaVersion: version)
        } throws: { error in
            guard let error = error as? DesktopFormatError else { return false }
            return !["not-a-cookie", "has space", "xoxd-", password].contains { error.reason.contains($0) }
        }
    }
}

/// The synthetic cookie fixtures. Produced by this script (run once,
/// 2026-10-29; outputs pasted below):
///
///     PW="test-safe-storage-password"
///     KEY=$(python3 -I -c "import hashlib,sys; print(hashlib.pbkdf2_hmac('sha1', sys.argv[1].encode(), b'saltysalt', 1003, 16).hex())" "$PW")
///     IV=20202020202020202020202020202020
///     HOSTHASH=$(printf '%s' ".slack.com" | shasum -a 256 | cut -d' ' -f1)
///     enc() { /usr/bin/openssl enc -aes-128-cbc -K "$KEY" -iv "$IV" -nosalt | xxd -p | tr -d '\n'; }
///     { printf '%s' "$HOSTHASH" | xxd -r -p; printf '%s' 'xoxd-test%2Fcookie%3D'; } | enc            # v24
///     printf '%s' 'xoxd-test-old-format' | enc                                                       # v23
///     { printf '%s' "$HOSTHASH" | xxd -r -p; printf '%s' 'abcd-not-a-cookie'; } | enc                # v24NotACookie
///     { printf '%s' "$HOSTHASH" | xxd -r -p; printf '%s' 'xoxd-has space'; } | enc                   # v24BadCharacters
///     printf '%s' 'xoxd-test-without-host-hash-0123456789' | enc                                     # v24WithoutHash
enum CookieFixture {
    static let password = "test-safe-storage-password"
    static let cookie = "xoxd-test%2Fcookie%3D"
    static let v10 = Array("v10".utf8)

    static let v24 = v10 + hex("ddfa19849b4b1cae3b1cd3e57354905f7760f2089b5cbf59eb8c92bf496d68e19437f5e6430c3d0e2a4b488c6328423b"
        + "3744e6469686c623bf36451e2c65da60")
    static let v23 = v10 + hex("3b383deec92c0e1795f5060cead136939eb960f3bde3ec372956b91547e2eedb")
    static let v24NotACookie = v10 + hex("ddfa19849b4b1cae3b1cd3e57354905f7760f2089b5cbf59eb8c92bf496d68e1acea15066caf18bbf01b7328c4d79abb"
        + "2a8abbda80ad190be10a6f1b948de6b4")
    static let v24BadCharacters = v10 + hex("ddfa19849b4b1cae3b1cd3e57354905f7760f2089b5cbf59eb8c92bf496d68e1e0f74ff31ab230736cfc2dc668cfe344")
    static let v24WithoutHash = v10 + hex("badc51e2e287eedd6a941813e928fc8f60f50c58a713dba66cfd3bc59216bb33b5f92235cc0d04d6be5b9ffb9283dcf9")
}
