import Foundation
import Security

/// Minimal generic-password wrapper around the macOS Keychain.
///
/// This is the only place OAuth tokens are ever written. They never go to disk, never to
/// `UserDefaults`, never to a log line, and never into source control.
public struct KeychainStore {

    public enum KeychainError: LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)
        case decodingFailed

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
                return "Keychain error \(status): \(message)"
            case .decodingFailed:
                return "Stored credentials could not be decoded."
            }
        }
    }

    public let service: String

    public init(service: String) { self.service = service }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func setData(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        // Available whenever the Mac is unlocked, and never synced to iCloud or included
        // in an unencrypted backup — this is a device-scoped credential.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        query.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    public func data(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        return item as? Data
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: Codable convenience

    public func setValue<T: Encodable>(_ value: T, account: String) throws {
        try setData(try JSONEncoder().encode(value), account: account)
    }

    public func value<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        guard let data = try data(account: account) else { return nil }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw KeychainError.decodingFailed }
    }
}
