import Foundation
import Security

/// Where the session token lives. Read only by the app's own process.
protocol ChatTokenStore: Sendable {
    /// nil when there is none; throws when the store could not be read (a
    /// locked keychain, the user declined a system prompt).
    func read(account: String) throws -> String?
    func write(_ token: String, account: String) throws
    func delete(account: String) throws
    /// Every account with a token here (no token is read).
    func accounts() throws -> [String]
}

/// The token in the login keychain, readable only by AgentPad
/// (docs/agentpad/K1-keychain.md): a generic password whose access list
/// trusts this app alone, by its designated requirement — so an update
/// signed the same way reads it without a prompt, while `security`, ad hoc
/// builds and AgentPad's own helper binaries get a system prompt.
struct ChatKeychain: ChatTokenStore {
    static let service = "com.4kulia.agentpad.chat"
    var service = ChatKeychain.service

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func read(account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data, let token = String(data: data, encoding: .utf8) else {
            throw ChatError.keychain(Self.message(status))
        }
        return token
    }

    func write(_ token: String, account: String) throws {
        // Replaced rather than updated, so the access list is always this one.
        try delete(account: account)
        var me: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &me)
        guard status == errSecSuccess, let me else { throw ChatError.keychain(Self.message(status)) }
        var access: SecAccess?
        status = SecAccessCreate("AgentPad server session" as CFString, [me] as CFArray, &access)
        guard status == errSecSuccess, let access else { throw ChatError.keychain(Self.message(status)) }
        var q = query(account)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccess as String] = access
        q[kSecAttrLabel as String] = "AgentPad server session"
        status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw ChatError.keychain(Self.message(status)) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ChatError.keychain(Self.message(status)) }
    }

    func accounts() throws -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { throw ChatError.keychain(Self.message(status)) }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    static func message(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
    }

    /// True when this process carries a Team ID (a Developer ID build).
    static var isTeamSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return false }
        return dict[kSecCodeInfoTeamIdentifier as String] != nil
    }

    /// The keychain; in a build from source, and only when the developer
    /// asks with `AGENTPAD_DEV_TOKEN_FILE=1`, the file `chat/dev-token`
    /// (an ad hoc signature changes with every build, and each new build
    /// would meet a keychain prompt). A signed build never uses the file.
    static func standard(
        files: ChatFiles = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        teamSigned: Bool = isTeamSigned
    ) -> ChatTokenStore {
        if environment["AGENTPAD_DEV_TOKEN_FILE"] == "1", !teamSigned { return ChatDevTokenFile(files: files) }
        return ChatKeychain()
    }
}

/// `chat/dev-token` (0600): a build for development only. One line per
/// account: `<account>\t<token>`.
struct ChatDevTokenFile: ChatTokenStore {
    let files: ChatFiles

    private func entries() throws -> [String: String] {
        let url = files.devTokenURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ChatError.storage("cannot read dev-token") }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 { out[String(parts[0])] = String(parts[1]) }
        }
        return out
    }

    private func save(_ entries: [String: String]) throws {
        if entries.isEmpty {
            // Only "already gone" is not an error: Disconnect must see a file
            // that stays (review C6-10).
            do { try FileManager.default.removeItem(at: files.devTokenURL) } catch CocoaError.fileNoSuchFile {
            } catch {
                throw ChatError.keychain("the token file could not be removed: \(error.localizedDescription)")
            }
            return
        }
        let text = entries.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)\n" }.joined()
        try files.writePrivate(Data(text.utf8), to: files.devTokenURL)
    }

    func read(account: String) throws -> String? { try entries()[account] }

    func write(_ token: String, account: String) throws {
        var all = try entries()
        all[account] = token
        try save(all)
    }

    func delete(account: String) throws {
        var all = try entries()
        guard all.removeValue(forKey: account) != nil else { return }
        try save(all)
    }

    func accounts() throws -> [String] { try Array(entries().keys) }
}
