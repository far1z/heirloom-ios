import Foundation
import Security

/// Thin wrapper over the iOS Keychain for seed storage.
///
/// Security posture:
///  - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: items are only readable while
///    the device is unlocked, are encrypted at rest by the Secure Enclave-protected
///    class keys, and are **never** included in iCloud/iTunes backups or transferable
///    to another device (no escrow, no sync).
///  - `kSecUseDataProtectionKeychain`: opts into the modern data-protection keychain.
///
/// Note on the Secure Enclave: the SE only performs P-256 operations, so a secp256k1
/// Bitcoin key cannot live *inside* the enclave. The industry-standard approach — used
/// here — is Keychain data protection (whose class keys are themselves SE-guarded)
/// plus a device-only accessibility class. This is documented honestly in
/// SECURITY_REVIEW.md rather than marketing "Secure Enclave key storage".
struct KeychainStore {
    static let service = "com.heirloomcrypto.heirloom"

    enum Key: String {
        case ownerMnemonic = "owner-mnemonic-v1"
        case heirMnemonic = "heir-mnemonic-v1"
    }

    static func save(_ data: Data, for key: Key) throws {
        // Delete-then-add gives idempotent overwrite semantics.
        try? delete(key)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        #if !targetEnvironment(simulator)
        query[kSecUseDataProtectionKeychain as String] = true
        #endif
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw HeirloomError.keychainError(status)
        }
    }

    static func load(_ key: Key) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { throw HeirloomError.seedNotFound }
            throw HeirloomError.keychainError(status)
        }
        return data
    }

    static func exists(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ key: Key) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HeirloomError.keychainError(status)
        }
    }

    /// Wipes every Heirloom keychain item. Used by the destructive "delete wallet" flow.
    static func deleteAll() {
        for key in [Key.ownerMnemonic, .heirMnemonic] {
            try? delete(key)
        }
    }
}
