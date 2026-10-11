import Foundation
import Security

/// Storage for API keys the user pastes in Settings. Only the app's own Keychain service is ever touched.
public protocol SecretStore: Sendable {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

public enum SecretStoreError: Error {
    case keychain(OSStatus)
}

public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = AppPaths.keychainService) {
        self.service = service
    }

    func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read(account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStoreError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "Headroom API key"
            let add = SecItemAdd(q as CFDictionary, nil)
            guard add == errSecSuccess else { throw SecretStoreError.keychain(add) }
        } else if status != errSecSuccess {
            throw SecretStoreError.keychain(status)
        }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status) }
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func read(account: String) throws -> String? { lock.withLock { values[account] } }
    public func write(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    public func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
