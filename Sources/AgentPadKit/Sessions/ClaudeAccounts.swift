import Foundation
import Observation

struct ClaudeAccount: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
    var credentialRevision = UUID()

    private enum CodingKeys: String, CodingKey { case id, name, createdAt, credentialRevision }

    init(id: UUID, name: String, createdAt: Date, credentialRevision: UUID = UUID()) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.credentialRevision = credentialRevision
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        credentialRevision = try values.decodeIfPresent(UUID.self, forKey: .credentialRevision) ?? id
    }
}

/// Only account metadata is archived. Credentials always go through the
/// parameterized login-keychain store, never the chat development token file.
@MainActor @Observable
final class ClaudeAccountStore {
    static let service = "com.4kulia.agentpad.claude-account"

    enum Problem: Error, LocalizedError {
        case unreadable, invalidToken, missingAccount, inUse, storage, keychain, rollback
        var errorDescription: String? {
            switch self {
            case .unreadable: "Claude accounts could not be read. The saved file has not been replaced."
            case .invalidToken: "Enter a non-empty, single-line token without spaces."
            case .missingAccount: "This Claude account is no longer available."
            case .inUse: "Move agents to another Claude account before removing this account."
            case .storage: "Claude accounts could not be saved."
            case .keychain: "The Claude account token could not be accessed in Keychain."
            case .rollback: "The Claude account change failed, and its previous Keychain state could not be restored."
            }
        }
    }

    private struct Archive: Codable {
        var version = 1
        var accounts: [ClaudeAccount] = []
    }
    private var archive = Archive()
    private var loadFailed = false
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let tokens: any ChatTokenStore
    @ObservationIgnored private let isUsed: (UUID) -> Bool
    @ObservationIgnored private let write: (Data, URL) throws -> Void
    var list: [ClaudeAccount] { archive.accounts }

    init(fileURL: URL? = nil, tokens: any ChatTokenStore,
         isUsed: @escaping (UUID) -> Bool,
         write: @escaping (Data, URL) throws -> Void = { data, url in
             try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
             try data.write(to: url, options: .atomic)
         }) {
        self.fileURL = fileURL; self.tokens = tokens; self.isUsed = isUsed; self.write = write
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
                guard saved.version == 1 else { throw Problem.unreadable }
                archive = saved
            } catch { loadFailed = true }
        }
    }

    func account(_ id: UUID) -> ClaudeAccount? { list.first { $0.id == id } }

    @discardableResult
    func add(name: String, token: String) throws -> ClaudeAccount {
        try checkReadable()
        let token = try Self.validated(token)
        let account = ClaudeAccount(id: UUID(), name: name, createdAt: Date())
        do { try tokens.write(token, account: account.id.uuidString) }
        catch { throw Problem.keychain }
        var next = archive; next.accounts.append(account)
        do { try commit(next) }
        catch {
            do { try tokens.delete(account: account.id.uuidString) }
            catch { throw Problem.rollback }
            throw error
        }
        return account
    }

    func replaceToken(id: UUID, token: String) throws {
        try checkReadable()
        guard let index = archive.accounts.firstIndex(where: { $0.id == id }) else { throw Problem.missingAccount }
        let token = try Self.validated(token)
        let previous: String?
        do { previous = try tokens.read(account: id.uuidString) }
        catch { throw Problem.keychain }
        var next = archive
        next.accounts[index].credentialRevision = UUID()
        // Persist the new revision before changing the credential. If interrupted,
        // previously installed host records must look out of date, never current
        // with a replacement token. Retain this revision even if restoration works.
        try commit(next)
        do { try tokens.write(token, account: id.uuidString) }
        catch {
            do {
                if let previous { try tokens.write(previous, account: id.uuidString) }
                else { try tokens.delete(account: id.uuidString) }
            } catch { throw Problem.rollback }
            throw Problem.keychain
        }
    }

    func remove(id: UUID) throws {
        try checkReadable()
        guard account(id) != nil else { throw Problem.missingAccount }
        guard !isUsed(id) else { throw Problem.inUse }
        let previous: String?
        do {
            previous = try tokens.read(account: id.uuidString)
            try tokens.delete(account: id.uuidString)
        } catch { throw Problem.keychain }
        var next = archive; next.accounts.removeAll { $0.id == id }
        do { try commit(next) }
        catch {
            do { if let previous { try tokens.write(previous, account: id.uuidString) } }
            catch { throw Problem.rollback }
            throw error
        }
    }

    func token(id: UUID) throws -> String {
        try checkReadable()
        guard account(id) != nil else { throw Problem.missingAccount }
        // Never propagate a credential provider's error text into UI/logs.
        do {
            guard let token = try tokens.read(account: id.uuidString) else { throw Problem.keychain }
            return try Self.validated(token)
        } catch { throw Problem.keychain }
    }

    private static func validated(_ value: String) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) else { throw Problem.invalidToken }
        return token
    }

    private func checkReadable() throws { if loadFailed { throw Problem.unreadable } }

    private func commit(_ next: Archive) throws {
        try checkReadable()
        do {
            if let fileURL { try write(JSONEncoder().encode(next), fileURL) }
        } catch { throw Problem.storage }
        archive = next
    }
}
