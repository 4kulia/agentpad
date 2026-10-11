import Foundation

/// Application credentials are separate from the user's Keychain session key.
/// No CustomStringConvertible/Codable conformance: never include them in diagnostics.
public struct TelegramCredentials: Sendable {
    let apiID: Int32
    let apiHash: String

    public init(apiID: Int32, apiHash: String) throws {
        guard apiID > 0, apiHash.utf8.count == 32,
              apiHash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw TelegramConfigurationError.invalid
        }
        self.apiID = apiID
        self.apiHash = apiHash
    }

    public static func load(environment: [String: String], resource: URL?) throws -> Self? {
        let id = environment["AGENTPAD_TELEGRAM_API_ID"]
        let hash = environment["AGENTPAD_TELEGRAM_API_HASH"]
        if id != nil || hash != nil {
            guard let id, let value = Int32(id), let hash else { throw TelegramConfigurationError.invalid }
            return try Self(apiID: value, apiHash: hash)
        }
        guard let resource else { return nil }
        do {
            let bytes = try Data(contentsOf: resource)
            guard let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  let id = plist["api_id"] as? String, let value = Int32(id),
                  let hash = plist["api_hash"] as? String else { throw TelegramConfigurationError.invalid }
            return try Self(apiID: value, apiHash: hash)
        } catch { throw TelegramConfigurationError.invalid }
    }
}

public enum TelegramConfigurationError: Error { case invalid }

public enum TelegramEnvironment: String, Codable, Sendable {
    case production, test
}

public enum TelegramBuild {
    public static let version = "1.8.67"
    public static let commit = "42e6a5259551178d1dab54a22ad96d14bd906e20"
    public static let privacyText = "Telegram settings stay on this Mac. TDLib caches Telegram history locally and connects directly to Telegram. Nothing related to Telegram is sent to the AgentPad server in 1.2.0."
}
