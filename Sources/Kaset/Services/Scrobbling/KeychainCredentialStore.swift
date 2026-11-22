import Foundation
import Security

@MainActor
final class KeychainCredentialStore {
    private let servicePrefix: String

    init(servicePrefix: String = "com.sertacozercan.Kaset") {
        self.servicePrefix = servicePrefix
    }

    func saveLastFMSessionKey(_ sessionKey: String) throws {
        try self.save(key: "lastFMSessionKey", value: sessionKey)
    }

    func getLastFMSessionKey() -> String? {
        self.get(key: "lastFMSessionKey")
    }

    func saveLastFMUsername(_ username: String) throws {
        try self.save(key: "lastFMUsername", value: username)
    }

    func getLastFMUsername() -> String? {
        self.get(key: "lastFMUsername")
    }

    func removeLastFMCredentials() {
        self.delete(key: "lastFMSessionKey")
        self.delete(key: "lastFMUsername")
    }

    private func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let account = "\(self.servicePrefix).\(key)"

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: self.servicePrefix,
        ]

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = updateQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.saveFailed(status: updateStatus)
        }
    }

    private func get(key: String) -> String? {
        let account = "\(self.servicePrefix).\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: self.servicePrefix,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    private func delete(key: String) {
        let account = "\(self.servicePrefix).\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecAttrService as String: self.servicePrefix,
        ]

        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error, LocalizedError {
    case encodingFailed
    case saveFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            "Failed to encode value for Keychain storage."
        case let .saveFailed(status):
            "Keychain save failed with status: \(status)"
        }
    }
}
