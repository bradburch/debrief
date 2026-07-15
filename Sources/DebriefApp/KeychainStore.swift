import Foundation
import Security

enum KeychainStore {
    static let service = "com.debrief.app"

    enum KeychainError: Error { case status(OSStatus) }

    static func save(key: String, value: String) throws {
        // Delete-then-add rather than SecItemUpdate: a plain update rewrites the data but
        // keeps the old access-control list, so a key first saved by an earlier or
        // differently-signed build keeps prompting for the keychain password on every read.
        // Re-adding recreates the ACL trusting the current (stable-signed) app → no prompts.
        // Back up the prior value first so a failed add can't wipe a working key.
        let previous = read(key: key)
        try? delete(key: key)
        let status = add(key: key, value: value)
        guard status == errSecSuccess else {
            if let previous { _ = add(key: key, value: previous) } // best-effort restore
            throw KeychainError.status(status)
        }
    }

    private static func add(key: String, value: String) -> OSStatus {
        SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
        ] as CFDictionary, nil)
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
