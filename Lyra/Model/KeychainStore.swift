import Foundation
import Security

/// Stores WebDAV passwords outside the preferences file, which is backed up
/// and readable to processes with access to the app container.
enum KeychainStore {
    private static let service = "care.davinci.lyra.webdav"

    static func password(for libraryID: String) throws -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: libraryID,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else { throw KeychainError(status: status) }
        return password
    }

    /// A scan or an offline reconcile can run while the device is locked —
    /// background audio keeps the process alive — and the Keychain default of
    /// "when unlocked" would hand back nothing there, degrading a working
    /// library into "sign in again". `ThisDeviceOnly` also keeps the secret out
    /// of backups restored onto another device.
    private static var accessibility: CFString { kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }

    static func setPassword(_ password: String, for libraryID: String) throws {
        let attributes: [CFString: Any] = [
            kSecValueData: Data(password.utf8),
            kSecAttrAccessible: accessibility,
        ]
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: libraryID,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData] = Data(password.utf8)
            item[kSecAttrAccessible] = accessibility
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainError(status: updateStatus)
        }
    }

    static func deletePassword(for libraryID: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: libraryID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Could not update the WebDAV password."
    }
}
