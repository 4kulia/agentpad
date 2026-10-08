import CryptoKit
import Darwin
import Foundation

/// A server address in one spelling: scheme, lowercase host, explicit port
/// (docs/agentpad/CHAT-PLAN.md C1). `https` only; `http` only for this Mac.
struct ChatServerAddress: Hashable, Codable, Sendable, CustomStringConvertible {
    let scheme: String
    let host: String
    let port: Int

    enum Problem: Error, Equatable, LocalizedError {
        case notAnAddress
        case insecure
        case hasPath

        var errorDescription: String? {
            switch self {
            case .notAnAddress: "Not a server address."
            case .insecure: "The server address must start with https://."
            case .hasPath: "The server address must not have a path, query or user name."
            }
        }
    }

    static let localHosts: Set<String> = ["localhost", "127.0.0.1"]

    init(scheme: String, host: String, port: Int) {
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    /// `HTTPS://Host:443/` and `https://host` are the same address.
    init(parsing raw: String) throws {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: text), let rawScheme = parts.scheme?.lowercased(),
              let rawHost = parts.host, !rawHost.isEmpty
        else { throw Problem.notAnAddress }
        guard parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/"
        else { throw Problem.hasPath }
        let host = rawHost.lowercased()
        switch rawScheme {
        case "https": break
        case "http": guard Self.localHosts.contains(host) else { throw Problem.insecure }
        default: throw Problem.notAnAddress
        }
        let port = parts.port ?? (rawScheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { throw Problem.notAnAddress }
        self.init(scheme: rawScheme, host: host, port: port)
    }

    /// `https://host:443` — the port is always written.
    var description: String { "\(scheme)://\(host):\(port)" }

    var baseURL: URL { URL(string: description)! }

    init(from decoder: Decoder) throws {
        try self.init(parsing: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// What every piece of chat data is keyed by: server, account, organization
/// (6.11). Each triple has its own cache file.
struct ChatOrgKey: Hashable, Sendable {
    let server: ChatServerAddress
    let accountId: String
    let orgId: String

    /// `<first 16 hex digits of sha256("server|account|org")>.sqlite`.
    var cacheFileName: String {
        let digest = SHA256.hash(data: Data("\(server)|\(accountId.lowercased())|\(orgId.lowercased())".utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16) + ".sqlite"
    }
}

/// One signed-in server, as kept in `chat/servers.json`. No token: that is in
/// the keychain (`ChatKeychain`).
struct ChatConnection: Codable, Equatable, Sendable {
    var server: ChatServerAddress
    var accountId: String
    var sessionId: String
    var deviceName: String
    /// The organization the app shows; nil until one is chosen.
    var orgId: String?
    /// The server ended this session (401/4401): its token is not used
    /// again, even when deleting it failed (DESIGN-D6 §7.1, review D6-2).
    var revoked: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case server
        case accountId = "account_id"
        case sessionId = "session_id"
        case deviceName = "device_name"
        case orgId = "org_id"
        case revoked
    }

    /// The keychain account of this connection's token: one per session, so
    /// the record and the token it names always belong together (review C13-1).
    var tokenAccount: String { "\(server)|\(accountId.lowercased())|\(sessionId)" }

    var orgKey: ChatOrgKey? { orgId.map { ChatOrgKey(server: server, accountId: accountId, orgId: $0) } }
}

/// `Application Support/agentpad/chat/`: 0700, files 0600, created on the
/// first connection only (6.11). Its `servers.json` keeps the shape
/// `TeamMode.resolve` reads: `{"servers": [...]}`.
struct ChatFiles: Sendable {
    let directory: URL

    static var standard: ChatFiles { ChatFiles(directory: TeamMode.standardChatDirectory) }

    var serversURL: URL { TeamMode.serversURL(in: directory) }
    var journalURL: URL { directory.appendingPathComponent("journal.sqlite") }
    var devTokenURL: URL { directory.appendingPathComponent("dev-token") }
    /// Earlier sessions of this Mac still to close on the server, with their tokens kept until then.
    var closingURL: URL { directory.appendingPathComponent("closing-sessions.json") }

    func loadClosing() -> [ChatConnection] {
        guard let data = try? Data(contentsOf: closingURL) else { return [] }
        return (try? JSONDecoder().decode([ChatConnection].self, from: data)) ?? []
    }

    func saveClosing(_ connections: [ChatConnection]) throws {
        if connections.isEmpty {
            if FileManager.default.fileExists(atPath: closingURL.path) { try FileManager.default.removeItem(at: closingURL) }
            return
        }
        try writePrivate(try JSONEncoder().encode(connections), to: closingURL)
    }
    func cacheURL(_ key: ChatOrgKey) -> URL { directory.appendingPathComponent(key.cacheFileName) }

    var attachmentStorage: ChatAttachmentStorage {
        directory == Self.standard.directory ? .standard : ChatAttachmentStorage(root: directory.appendingPathComponent("attachments"))
    }

    /// Saved originals belong to this cache even if no attachment manager was
    /// opened this time. Remove them before their ownership records disappear.
    func removeCache(_ key: ChatOrgKey) {
        try? FileManager.default.removeItem(at: attachmentStorage.directory(key))
        let url = cacheURL(key)
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    private struct ServersFile: Codable {
        var servers: [ChatConnection]
    }

    /// The saved connections; none when there is no file. Throws when the
    /// file cannot be read — `TeamMode.resolve` has then already turned team
    /// work off.
    func loadConnections() throws -> [ChatConnection] {
        guard FileManager.default.fileExists(atPath: serversURL.path) else { return [] }
        do {
            return try JSONDecoder().decode(ServersFile.self, from: Data(contentsOf: serversURL)).servers
        } catch {
            throw ChatError.storage("cannot read servers.json: \(error.localizedDescription)")
        }
    }

    func saveConnections(_ connections: [ChatConnection]) throws {
        if connections.isEmpty {
            // No record, no automatic connection (6.11).
            do {
                if FileManager.default.fileExists(atPath: serversURL.path) { try FileManager.default.removeItem(at: serversURL) }
            } catch {
                throw ChatError.storage("cannot remove servers.json: \(error.localizedDescription)")
            }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(try encoder.encode(ServersFile(servers: connections)), to: serversURL)
    }

    func prepareDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw ChatError.storage("cannot prepare \(directory.path): \(error.localizedDescription)")
        }
    }

    /// Written beside the target and renamed into place, 0600.
    func writePrivate(_ data: Data, to url: URL) throws {
        try prepareDirectory()
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temp.path, url.path) == 0
        else { throw ChatError.storage("cannot write \(url.lastPathComponent)") }
    }
}

enum ChatError: Error, Equatable, LocalizedError {
    case storage(String)
    case keychain(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .storage(let detail): "Chat data: \(detail)"
        case .keychain(let detail): "Keychain: \(detail)"
        case .notConnected: "not connected to a server"
        }
    }
}
