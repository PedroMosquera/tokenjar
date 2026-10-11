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

    /// The user was asked and said no: Deny on the access prompt (errSecAuthFailed), Cancel on an unlock prompt
    /// (errSecUserCanceled), or there was no way to ask.
    public var isRefusal: Bool {
        switch self {
        case .keychain(let status):
            [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed, errSecInteractionRequired].contains(status)
        }
    }
}

extension SecretStore {
    /// The key stored under `account`, or nil when there is none or it could not be read. A refusal throws
    /// `FetchError.keychainDenied` instead, because pasting the key again would not get past the prompt.
    public func pastedKey(account: String) throws -> String? {
        do {
            return try read(account: account)
        } catch let error as SecretStoreError where error.isRefusal {
            throw FetchError.keychainDenied
        } catch {
            return nil
        }
    }
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

    func addQuery(_ account: String, data: Data) -> [String: Any] {
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "Tokenjar API key"
        return q
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
            let add = SecItemAdd(addQuery(account, data: data) as CFDictionary, nil)
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

/// Holds each key in memory for the life of the process, so the Keychain is asked once per account name per launch.
/// An ad-hoc signature changes with every build, so each read can bring back the Keychain prompt, and a Deny is not
/// remembered. Whatever the first read finds (a key, no key, or an error such as a refusal) is held, and later reads
/// return it without asking again. Only `allowRead`, for a check the user asked for, lets the next read ask again.
/// Keys are never written to disk or logged.
public final class SessionSecretStore: SecretStore, @unchecked Sendable {
    private let backing: any SecretStore
    private let lock = NSLock()
    /// Serializes asking the backing store, so two accounts naming the same item do not prompt twice. Writes and
    /// deletes never wait on it: a prompt can stay up for as long as the user leaves it.
    private let asking = NSLock()
    private var held: [String: Result<String?, any Error>] = [:]

    public init(_ backing: any SecretStore) { self.backing = backing }

    public func read(account: String) throws -> String? {
        if let outcome = lock.withLock({ held[account] }) { return try outcome.get() }
        return try asking.withLock {
            if let outcome = lock.withLock({ held[account] }) { return outcome }
            let outcome = Result { try backing.read(account: account) }
            // A key saved or deleted while this read waited on a prompt is newer than what the read found.
            return lock.withLock {
                if held[account] == nil { held[account] = outcome }
                return held[account]!
            }
        }.get()
    }

    public func write(_ secret: String, account: String) throws {
        try backing.write(secret, account: account)
        lock.withLock { held[account] = .success(secret) }
    }

    public func delete(account: String) throws {
        try backing.delete(account: account)
        lock.withLock { held[account] = .success(nil) }
    }

    /// For a check the user asked for: the next read asks the backing store again, unless it holds a key. A held key
    /// is kept, because a user who chose Allow rather than Always Allow would be prompted on every check.
    public func allowRead(account: String) {
        lock.withLock {
            if case .success(.some) = held[account] { return }
            held[account] = nil
        }
    }
}
