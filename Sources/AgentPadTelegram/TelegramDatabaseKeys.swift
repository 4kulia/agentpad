import Foundation
import Security

public enum TelegramStorageError: Error, Equatable {
    case keyUnavailable, keyMissing, invalidKey, keyExists, unsafePath, lockedProfile, corruptProfile, accountMismatch, io
}

public protocol TelegramKeyStore: Sendable {
    func read(account: String) throws -> Data?
    /// Insert only. Never replace a key protecting an existing database.
    func insert(_ key: Data, account: String) throws
    func delete(account: String) throws
}

public struct TelegramDatabaseKeys: Sendable {
    let store: any TelegramKeyStore
    public init(store: any TelegramKeyStore = TelegramKeychain()) { self.store = store }

    func key(account: String, mayCreate: Bool) throws -> Data {
        if let key = try store.read(account: account) {
            guard key.count == 32 else { throw TelegramStorageError.invalidKey }
            return key
        }
        guard mayCreate else { throw TelegramStorageError.keyMissing }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw TelegramStorageError.keyUnavailable }
        try store.insert(bytes, account: account)
        return bytes
    }
    func delete(account: String) throws { try store.delete(account: account) }
}

public struct TelegramKeychain: TelegramKeyStore {
    public static let service = "com.4kulia.agentpad.telegram.database"
    public init() {}

    // File-based macOS Keychain ACLs pin the current app's designated
    // requirement. Helpers/CLI are not trusted, and iCloud sync is disabled.
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    public func read(account: String) throws -> Data? {
        var query = Self.query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let key = result as? Data else { throw TelegramStorageError.keyUnavailable }
        return key
    }

    public func insert(_ key: Data, account: String) throws {
        guard key.count == 32 else { throw TelegramStorageError.invalidKey }
        var app: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(nil, &app) == errSecSuccess, let app else {
            throw TelegramStorageError.keyUnavailable
        }
        var access: SecAccess?
        guard SecAccessCreate("AgentPad Telegram database" as CFString, [app] as CFArray, &access) == errSecSuccess,
              let access else { throw TelegramStorageError.keyUnavailable }
        var query = Self.query(account)
        query[kSecValueData as String] = key
        query[kSecAttrAccess as String] = access
        query[kSecAttrLabel as String] = "AgentPad Telegram database"
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw TelegramStorageError.keyExists }
        guard status == errSecSuccess else { throw TelegramStorageError.keyUnavailable }
    }

    public func delete(account: String) throws {
        let status = SecItemDelete(Self.query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw TelegramStorageError.keyUnavailable }
    }
}
