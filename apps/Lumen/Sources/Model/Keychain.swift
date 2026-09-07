import Foundation
import Security

/// The Wallhaven API key, kept in the login keychain.
///
/// It used to live in `UserDefaults`, which means a plain file under
/// `~/Library/Preferences` that anything running as the user can read. A key is
/// a credential — it is worth a rate limit and access to non-SFW results — so
/// it belongs behind the same door as a password.
///
/// The item is a generic password so `security find-generic-password` and
/// Keychain Access both show it under a recognisable name, which matters when
/// someone wants to revoke or replace it without launching Lumen.
enum Keychain {
    /// Redirected by the verify harness so a gate run cannot delete the key
    /// you actually use — `store.apiKey = ""` removes the item, and the
    /// harness sets an empty key on purpose.
    static var service = "cc.lumen.app"
    static let account = "wallhaven-api-key"

    /// The stored key, or nil when there is none.
    ///
    /// A keychain read can fail for reasons that are not "no key" — a locked
    /// keychain, a denied prompt — and all of them mean the same thing to the
    /// caller: carry on unauthenticated.
    static func apiKey() -> String? {
        value(service: service, account: account)
    }

    /// The generic-password read, with the item named explicitly.
    ///
    /// Parameterised so the gate can round-trip a throwaway item rather than
    /// overwriting the key you actually use.
    static func value(service: String, account: String) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    /// Stores `key`, replacing whatever was there. An empty key removes it.
    @discardableResult
    static func setAPIKey(_ key: String) -> Bool {
        set(key, service: service, account: account)
    }

    @discardableResult
    static func set(_ key: String, service: String, account: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return remove(service: service, account: account) }
        guard let data = trimmed.data(using: .utf8) else { return false }

        // Update first: SecItemAdd on an existing item fails with
        // errSecDuplicateItem rather than replacing it.
        let updated = SecItemUpdate(
            baseQuery(service: service, account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updated == errSecSuccess { return true }

        var insert = baseQuery(service: service, account: account)
        insert[kSecValueData as String] = data
        // Available whenever the machine is unlocked, and not synced to other
        // devices: this key is tied to how Lumen is used here.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        insert[kSecAttrLabel as String] = "Lumen — Wallhaven API key"
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func removeAPIKey() -> Bool {
        remove(service: service, account: account)
    }

    @discardableResult
    static func remove(service: String, account: String) -> Bool {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
