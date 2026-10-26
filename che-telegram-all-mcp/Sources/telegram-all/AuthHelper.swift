import Foundation
import TelegramAllLib

enum AuthHelper {
    /// Opens TDLib under the TDLib lock (#61), sets parameters from env, and
    /// runs `body` with the client.
    static func withAuthedClient<T>(_ body: (TDLibClient) async throws -> T) async throws -> T {
        let env = ProcessInfo.processInfo.environment
        guard let idStr = env["TELEGRAM_API_ID"], let apiId = Int(idStr),
              let apiHash = env["TELEGRAM_API_HASH"] else {
            throw AuthError.missingEnv
        }

        return try await TelegramAll.withTDLib { client in
            try await Task.sleep(nanoseconds: 1_000_000_000)

            do {
                try await client.setParameters(apiId: apiId, apiHash: apiHash)
            } catch {
                // Parameters may already be set
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await body(client)
        }
    }

    static func status() async throws {
        try await withAuthedClient { client in
            do {
                let me = try await client.getMe()
                print("Authenticated ✓")
                print(me)
            } catch {
                print("Not authenticated (or auth incomplete)")
                print("Run: telegram-all auth-phone <phone>")
            }
        }
    }

    static func sendPhone(_ phone: String) async throws {
        try await withAuthedClient { client in
            do {
                try await client.sendPhoneNumber(phone)
                print("Phone number sent ✓")
                print("Check your Telegram app for the verification code.")
                print("Then run: telegram-all auth-code <code>")
            } catch {
                print("Error: \(error.localizedDescription)")
                throw error
            }
        }
    }

    static func sendCode(_ code: String) async throws {
        try await withAuthedClient { client in
            do {
                try await client.sendAuthCode(code)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                do {
                    let me = try await client.getMe()
                    print("Authentication successful ✓")
                    print(me)
                } catch {
                    print("Code accepted but 2FA may be required.")
                    print("Run: telegram-all auth-password <password>")
                }
            } catch {
                print("Error: \(error.localizedDescription)")
                throw error
            }
        }
    }

    static func sendPassword(_ password: String) async throws {
        try await withAuthedClient { client in
            do {
                try await client.sendPassword(password)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let me = try await client.getMe()
                print("Authentication successful ✓")
                print(me)
            } catch {
                print("Error: \(error.localizedDescription)")
                throw error
            }
        }
    }

    enum AuthError: LocalizedError {
        case missingEnv

        var errorDescription: String? {
            "TELEGRAM_API_ID / TELEGRAM_API_HASH not set"
        }
    }
}
