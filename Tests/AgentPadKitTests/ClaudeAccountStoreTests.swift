import XCTest
@testable import AgentPadKit

final class MemoryClaudeTokens: ChatTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var fails = false
    var beforeWrite: (() throws -> Void)?
    var beforeDelete: (() throws -> Void)?
    func read(account: String) throws -> String? {
        try lock.withLock {
            if fails { throw CocoaError(.fileReadNoPermission) }
            return values[account]
        }
    }
    func write(_ token: String, account: String) throws {
        try beforeWrite?()
        try lock.withLock {
            if fails { throw CocoaError(.fileWriteNoPermission) }
            values[account] = token
        }
    }
    func delete(account: String) throws {
        try beforeDelete?()
        try lock.withLock {
            if fails { throw CocoaError(.fileWriteNoPermission) }
            values[account] = nil
        }
    }
    func accounts() throws -> [String] { lock.withLock { Array(values.keys) } }
}

@MainActor
final class ClaudeAccountStoreTests: XCTestCase {
    private struct AccountArchive: Decodable {
        let version: Int
        let accounts: [ClaudeAccount]
    }

    private var root: URL!
    private var tokens: MemoryClaudeTokens!
    private var profiles: AgentProfileStore!
    private var accounts: ClaudeAccountStore { profiles.claudeAccounts }
    private var file: URL { root.appendingPathComponent("agent-profiles.json") }
    private var accountFile: URL { root.appendingPathComponent("claude-accounts.json") }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-accounts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tokens = MemoryClaudeTokens()
        profiles = AgentProfileStore(fileURL: file, accountTokens: tokens)
    }
    override func tearDown() async throws {
        tokens.beforeWrite = nil
        tokens.beforeDelete = nil
        try FileManager.default.removeItem(at: root)
    }

    func testMetadataArchiveAndProfileSelectionRoundTripWithoutToken() throws {
        let secret = UUID().uuidString
        let account = try accounts.add(name: "Work", token: " \n" + secret + "\n ")
        let profile = try profiles.add(template: .claudeCode, folder: root)
        try profiles.setClaudeAccount(profileID: profile.id, accountID: account.id)
        XCTAssertEqual(accounts.list, [account])
        XCTAssertTrue(try accounts.token(id: account.id) == secret)
        XCTAssertEqual(try tokens.accounts(), [account.id.uuidString])
        for url in [file, accountFile] {
            XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains(secret))
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: accountFile)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["version", "accounts"])
        XCTAssertEqual(json["version"] as? Int, 1)
        let metadata = try XCTUnwrap((json["accounts"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(metadata.keys), ["id", "name", "createdAt", "credentialRevision"])
        let reloaded = AgentProfileStore(fileURL: file, accountTokens: tokens)
        XCTAssertEqual(reloaded.claudeAccounts.list, [account])
        XCTAssertEqual(reloaded.profile(profile.id)?.claudeAccountID, account.id)
        try reloaded.setClaudeAccount(profileID: profile.id, accountID: nil)
        XCTAssertNil(AgentProfileStore(fileURL: file, accountTokens: tokens).profile(profile.id)?.claudeAccountID)
    }

    func testValidationAndReplacement() throws {
        for invalid in ["", " \n\t", "two words", "two\nlines", "two\rlines", "two\twords", "two\u{00a0}words", "a\0b"] {
            XCTAssertThrowsError(try accounts.add(name: "Work", token: invalid))
        }
        XCTAssertTrue(accounts.list.isEmpty)
        XCTAssertTrue(try tokens.accounts().isEmpty)
        let account = try accounts.add(name: "Work", token: UUID().uuidString)
        let replacement = UUID().uuidString
        try accounts.replaceToken(id: account.id, token: " " + replacement + " ")
        let updated = try XCTUnwrap(accounts.account(account.id))
        XCTAssertNotEqual(updated.credentialRevision, account.credentialRevision)
        XCTAssertEqual(updated.id, account.id)
        XCTAssertEqual(updated.name, account.name)
        XCTAssertEqual(updated.createdAt, account.createdAt)
        XCTAssertTrue(try accounts.token(id: account.id) == replacement)
        XCTAssertThrowsError(try accounts.replaceToken(id: account.id, token: "bad input"))
        XCTAssertTrue(try accounts.token(id: account.id) == replacement)
        XCTAssertEqual(accounts.list, [updated])
    }

    func testRemovalRefusesWhileAnyProfileUsesAccount() throws {
        let account = try accounts.add(name: "Work", token: UUID().uuidString)
        let first = try profiles.add(template: .claudeCode, folder: root)
        let second = try profiles.add(template: .claudeCode, folder: root, launchOptions: "--model opus")
        try profiles.setClaudeAccount(profileID: second.id, accountID: account.id)
        XCTAssertThrowsError(try accounts.remove(id: account.id))
        XCTAssertEqual(accounts.list, [account])
        XCTAssertNotNil(try tokens.read(account: account.id.uuidString))
        XCTAssertNil(profiles.profile(first.id)?.claudeAccountID)
        try profiles.setClaudeAccount(profileID: second.id, accountID: nil)
        try accounts.remove(id: account.id)
        XCTAssertTrue(accounts.list.isEmpty)
        XCTAssertTrue(try tokens.accounts().isEmpty)
        XCTAssertTrue(AgentProfileStore(fileURL: file, accountTokens: tokens).claudeAccounts.list.isEmpty)
    }

    func testUnreadableTokensAndUnknownIDsThrowWithoutExposingStoreErrors() throws {
        let account = try accounts.add(name: "Work", token: UUID().uuidString)
        tokens.fails = true
        XCTAssertThrowsError(try accounts.token(id: account.id))
        XCTAssertThrowsError(try accounts.replaceToken(id: account.id, token: UUID().uuidString))
        XCTAssertThrowsError(try accounts.add(name: "Other", token: UUID().uuidString))
        XCTAssertEqual(accounts.list, [account])
        tokens.fails = false
        try tokens.delete(account: account.id.uuidString)
        XCTAssertThrowsError(try accounts.token(id: account.id))
        XCTAssertThrowsError(try accounts.token(id: UUID()))
        let profile = try profiles.add(template: .claudeCode, folder: root)
        XCTAssertThrowsError(try profiles.setClaudeAccount(profileID: profile.id, accountID: UUID()))
        XCTAssertThrowsError(try profiles.setClaudeAccount(profileID: UUID(), accountID: nil))
        XCTAssertNil(profiles.profile(profile.id)?.claudeAccountID)
    }

    func testOldProfileArchiveDecodesUnchangedWithoutAccountField() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/agent-profiles-1.1.15.json")
        let data = try Data(contentsOf: fixture)
        try data.write(to: file)
        let old = AgentProfileStore(fileURL: file, accountTokens: tokens)
        XCTAssertNil(old.problem)
        XCTAssertEqual(old.profiles.count, 1)
        XCTAssertNil(try XCTUnwrap(old.profiles.first).claudeAccountID)
        XCTAssertEqual(old.bindings.count, 5)
        try old.flush()
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testCorruptAndFutureAccountArchivesAreNeverOverwritten() throws {
        for data in [Data("bad json".utf8), Data(#"{"version":999,"accounts":[]}"#.utf8)] {
            try data.write(to: accountFile)
            let store = AgentProfileStore(fileURL: file, accountTokens: tokens).claudeAccounts
            XCTAssertThrowsError(try store.add(name: "Work", token: UUID().uuidString))
            XCTAssertEqual(try Data(contentsOf: accountFile), data)
            XCTAssertTrue(try tokens.accounts().isEmpty)
        }
    }

    func testFailedArchiveWritesDoNotPublishAccountOrLeaveAddedToken() throws {
        let store = ClaudeAccountStore(fileURL: accountFile, tokens: tokens, isUsed: { _ in false },
            write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try store.add(name: "Work", token: UUID().uuidString))
        XCTAssertTrue(store.list.isEmpty)
        XCTAssertTrue(try tokens.accounts().isEmpty)
    }

    func testLegacyRevisionIsStableAcrossLoadsAndReplacementPersistsNewRevision() throws {
        let id = UUID()
        let legacy: [String: Any] = ["version": 1, "accounts": [
            ["id": id.uuidString, "name": "Legacy", "createdAt": 12.0],
        ]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: accountFile)
        let first = ClaudeAccountStore(fileURL: accountFile, tokens: tokens, isUsed: { _ in false })
        let second = ClaudeAccountStore(fileURL: accountFile, tokens: tokens, isUsed: { _ in false })
        XCTAssertEqual(first.list, [ClaudeAccount(id: id, name: "Legacy", createdAt: Date(timeIntervalSinceReferenceDate: 12), credentialRevision: id)])
        XCTAssertEqual(second.list, first.list)
        try first.replaceToken(id: id, token: "fake-replacement")
        let replaced = try XCTUnwrap(first.account(id))
        XCTAssertNotEqual(replaced.credentialRevision, id)
        XCTAssertEqual(ClaudeAccountStore(fileURL: accountFile, tokens: tokens, isUsed: { _ in false }).list, [replaced])
    }

    func testReplacementPersistsRevisionBeforeCredentialWrite() throws {
        let account = try accounts.add(name: "Work", token: "fake-original")
        let accountFile = self.accountFile
        var persistedAtCredentialWrite: AccountArchive?
        var credentialBeforeWrite: String?
        let tokens = try XCTUnwrap(self.tokens)
        tokens.beforeWrite = {
            persistedAtCredentialWrite = try JSONDecoder().decode(AccountArchive.self, from: Data(contentsOf: accountFile))
            credentialBeforeWrite = try tokens.read(account: account.id.uuidString)
        }

        try accounts.replaceToken(id: account.id, token: "fake-replacement")

        let updated = try XCTUnwrap(accounts.account(account.id))
        XCTAssertNotEqual(updated.credentialRevision, account.credentialRevision)
        XCTAssertEqual(try XCTUnwrap(persistedAtCredentialWrite).version, 1)
        XCTAssertEqual(persistedAtCredentialWrite?.accounts, [updated])
        XCTAssertEqual(credentialBeforeWrite, "fake-original")
        XCTAssertEqual(try tokens.read(account: account.id.uuidString), "fake-replacement")
    }

    func testFailedRevisionSaveDoesNotAttemptCredentialWrite() throws {
        let account = try accounts.add(name: "Work", token: "fake-original")
        let saved = try Data(contentsOf: accountFile)
        var credentialWrites = 0
        tokens.beforeWrite = { credentialWrites += 1 }
        let store = ClaudeAccountStore(fileURL: accountFile, tokens: tokens, isUsed: { _ in false },
            write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        XCTAssertThrowsError(try store.replaceToken(id: account.id, token: "fake-replacement")) { error in
            XCTAssertEqual(error.localizedDescription, ClaudeAccountStore.Problem.storage.localizedDescription)
        }
        XCTAssertEqual(credentialWrites, 0)
        XCTAssertEqual(store.list, [account])
        XCTAssertEqual(try tokens.read(account: account.id.uuidString), "fake-original")
        XCTAssertEqual(try Data(contentsOf: accountFile), saved)
    }

    func testFailedReplacementRestoresTokenAndRetainsNewRevision() throws {
        let account = try accounts.add(name: "Work", token: "fake-original")
        let tokens = try XCTUnwrap(self.tokens)
        var credentialWrites = 0
        tokens.beforeWrite = {
            credentialWrites += 1
            if credentialWrites == 1 {
                // ChatKeychain replaces by deleting then adding; an add failure can leave no token.
                try tokens.delete(account: account.id.uuidString)
                throw CocoaError(.fileWriteNoPermission)
            }
        }

        XCTAssertThrowsError(try accounts.replaceToken(id: account.id, token: "fake-replacement")) { error in
            XCTAssertEqual(error.localizedDescription, ClaudeAccountStore.Problem.keychain.localizedDescription)
        }

        XCTAssertEqual(credentialWrites, 2)
        XCTAssertEqual(try tokens.read(account: account.id.uuidString), "fake-original")
        try assertRevisionChangedAndPersisted(from: account)
    }

    func testFailedReplacementRollbackIsReportedAndRetainsNewRevision() throws {
        let account = try accounts.add(name: "Work", token: "fake-original")
        let tokens = try XCTUnwrap(self.tokens)
        var credentialWrites = 0
        tokens.beforeWrite = {
            credentialWrites += 1
            try tokens.delete(account: account.id.uuidString)
            throw NSError(domain: "fake-credential-provider-detail", code: 1)
        }

        XCTAssertThrowsError(try accounts.replaceToken(id: account.id, token: "fake-replacement")) { error in
            XCTAssertEqual(error.localizedDescription, ClaudeAccountStore.Problem.rollback.localizedDescription)
        }

        XCTAssertEqual(credentialWrites, 2)
        XCTAssertNil(try tokens.read(account: account.id.uuidString))
        try assertRevisionChangedAndPersisted(from: account)
    }

    func testFailedReplacementWithoutPreviousTokenReportsCleanupFailure() throws {
        let account = try accounts.add(name: "Work", token: "fake-original")
        try tokens.delete(account: account.id.uuidString)
        tokens.beforeWrite = { throw CocoaError(.fileWriteNoPermission) }
        var cleanupAttempts = 0
        tokens.beforeDelete = {
            cleanupAttempts += 1
            throw NSError(domain: "fake-credential-provider-detail", code: 1)
        }

        XCTAssertThrowsError(try accounts.replaceToken(id: account.id, token: "fake-replacement")) { error in
            XCTAssertEqual(error.localizedDescription, ClaudeAccountStore.Problem.rollback.localizedDescription)
        }

        XCTAssertEqual(cleanupAttempts, 1)
        XCTAssertNil(try tokens.read(account: account.id.uuidString))
        try assertRevisionChangedAndPersisted(from: account)
    }

    func testFailedArchiveSaveReportsAddedTokenCleanupFailure() throws {
        tokens.beforeDelete = { throw NSError(domain: "fake-credential-provider-detail", code: 1) }
        let store = ClaudeAccountStore(fileURL: accountFile, tokens: tokens, isUsed: { _ in false },
            write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })

        XCTAssertThrowsError(try store.add(name: "Work", token: "fake-token")) { error in
            XCTAssertEqual(error.localizedDescription, ClaudeAccountStore.Problem.rollback.localizedDescription)
        }

        XCTAssertTrue(store.list.isEmpty)
        let credentialAccount = try XCTUnwrap(tokens.accounts().first)
        XCTAssertEqual(try tokens.accounts(), [credentialAccount])
        XCTAssertEqual(try tokens.read(account: credentialAccount), "fake-token")
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountFile.path))
    }

    func testFailedRemovalArchiveSaveReportsTokenRestorationFailure() throws {
        let account = try accounts.add(name: "Work", token: "fake-original")
        let saved = try Data(contentsOf: accountFile)
        tokens.beforeWrite = { throw NSError(domain: "fake-credential-provider-detail", code: 1) }
        let store = ClaudeAccountStore(fileURL: accountFile, tokens: tokens, isUsed: { _ in false },
            write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })

        XCTAssertThrowsError(try store.remove(id: account.id)) { error in
            XCTAssertEqual(error.localizedDescription, ClaudeAccountStore.Problem.rollback.localizedDescription)
        }

        XCTAssertEqual(store.list, [account])
        XCTAssertEqual(try Data(contentsOf: accountFile), saved)
        XCTAssertNil(try tokens.read(account: account.id.uuidString))
    }

    private func assertRevisionChangedAndPersisted(from account: ClaudeAccount,
                                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let updated = try XCTUnwrap(accounts.account(account.id), file: file, line: line)
        XCTAssertNotEqual(updated.credentialRevision, account.credentialRevision, file: file, line: line)
        let expected = ClaudeAccount(id: account.id, name: account.name, createdAt: account.createdAt,
                                     credentialRevision: updated.credentialRevision)
        XCTAssertEqual(accounts.list, [expected], file: file, line: line)
        let reloaded = ClaudeAccountStore(fileURL: accountFile, tokens: tokens, isUsed: { _ in false })
        XCTAssertEqual(reloaded.list, [expected], file: file, line: line)
    }
}
