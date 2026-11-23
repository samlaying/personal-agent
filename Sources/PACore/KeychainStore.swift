import Foundation
import Security

/// Secrets live in the login keychain, never in `UserDefaults` or on disk in plain text.
public enum KeychainStore {
    public enum KeychainError: Error, LocalizedError, Hashable, Sendable {
        case unexpected(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpected(let status): "钥匙串操作失败（状态码 \(status)）"
            }
        }
    }

    public static func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpected(status)
        }
        guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpected(errSecDecode)
        }
        return text
    }

    public static func write(_ value: String, service: String, account: String) throws {
        try delete(service: service, account: account)
        guard !value.isEmpty else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpected(status)
        }
    }

    public static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpected(status)
        }
    }
}
