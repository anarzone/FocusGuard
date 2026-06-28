import Foundation
import Security

/// Minimal Keychain wrapper for the AI credentials (API keys / subscription
/// tokens). This is the first secure-storage code in the app — everything else
/// is local SwiftData / UserDefaults. Secrets are stored as generic passwords
/// under a single service, keyed by `account`, so each provider+auth-mode can
/// hold its own value without clobbering the others.
enum KeychainStore {
    private static let service = "com.anar.focusguard.ai"

    /// Stores (or overwrites) the secret for `account`. Passing an empty string
    /// deletes the entry — treat "" as "no secret".
    @discardableResult
    static func set(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else { return delete(account: account) }
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update if present, otherwise add. Avoids errSecDuplicateItem.
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Returns the stored secret for `account`, or nil if absent.
    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func has(account: String) -> Bool { get(account: account) != nil }
}
