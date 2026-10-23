import Foundation
import Security

/// Minimal generic-password wrapper for the app's few secrets (the Mac-sync
/// pairing token and vocabulary request headers). On iOS: device-only,
/// available after first unlock so auto-push keeps working in the
/// background. On macOS: the login keychain, with its default access.
enum KeychainStore {
    private static let service = "edu.davidson.luxicon"

    static func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Set or (with nil) delete.
    static func set(_ value: Data?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = value
        #if os(iOS)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        SecItemAdd(add as CFDictionary, nil)
    }

    static func string(for key: String) -> String? {
        data(for: key).map { String(decoding: $0, as: UTF8.self) }
    }

    static func set(_ value: String?, for key: String) {
        set(value.flatMap { $0.isEmpty ? nil : Data($0.utf8) }, for: key)
    }
}
