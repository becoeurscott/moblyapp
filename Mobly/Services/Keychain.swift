import Foundation
import Security

/// Minimal Keychain wrapper for auth tokens.
///
/// Tokens must not live in `UserDefaults` — it's an unencrypted plist that is
/// included in device backups and readable on a jailbroken device. The Keychain
/// is encrypted and system-managed.
///
/// Accessibility is `AfterFirstUnlockThisDeviceOnly`: `ThisDeviceOnly` keeps the
/// item out of iCloud/iTunes backups so a restore onto another device can't
/// carry a live session, and `AfterFirstUnlock` (rather than `WhenUnlocked`)
/// still allows reads from a background refresh while the screen is locked.
enum Keychain {
    private static let service = "com.mobly.app.auth"

    static func set(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        // Delete-then-add: SecItemUpdate needs a different query shape and
        // silently no-ops when the item is absent.
        delete(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            assertionFailure("Keychain write failed for \(key): \(status)")
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
