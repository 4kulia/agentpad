import Foundation
import XCTest
@testable import AgentPadKit

/// A token store that counts every use and can fail.
final class FakeTokenStore: ChatTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    private var uses = 0
    var failure: ChatError?

    var calls: Int { lock.withLock { uses } }
    func stored(_ account: String) -> String? { lock.withLock { tokens[account] } }
    var items: [String: String] { lock.withLock { tokens } }

    func read(account: String) throws -> String? {
        try lock.withLock {
            uses += 1
            if let failure { throw failure }
            return tokens[account]
        }
    }
    func write(_ token: String, account: String) throws {
        try lock.withLock {
            uses += 1
            if let failure { throw failure }
            tokens[account] = token
        }
    }
    func accounts() throws -> [String] {
        try lock.withLock {
            uses += 1
            if let failure { throw failure }
            return Array(tokens.keys)
        }
    }
    /// Deletes that fail, until cleared.
    var deleteFailure: ChatError?
    func delete(account: String) throws {
        try lock.withLock {
            uses += 1
            if let deleteFailure { throw deleteFailure }
            tokens[account] = nil
        }
    }
}

@MainActor
final class ChatConnectionTests: XCTestCase {
    private var root: URL!

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-conn-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        try? FileManager.default.removeItem(at: root)
    }

    private var files: ChatFiles { ChatFiles(directory: root.appendingPathComponent("chat")) }
    /// What AgentPad 1.0.x keeps; never read.
    private var team: URL { root.appendingPathComponent("team") }

    private func connection(org: String? = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10") throws -> ChatConnection {
        ChatConnection(
            server: try ChatServerAddress(parsing: "https://chat.example.com"),
            accountId: "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40", sessionId: "4f1d6a62-2d0e-4b8e-9d6b-5f0e6c3b8f11",
            deviceName: "Anna's Mac", orgId: org
        )
    }

    // (1) and (2): nothing in `off` mode, also after 1.0.x left `team/`.
    func testOffModeTouchesNeitherFilesNorKeychain() async throws {
        let tokens = FakeTokenStore()
        let service = ChatService(files: files, tokens: tokens)
        let empty = TeamMode.resolve(chatDirectory: files.directory)
        XCTAssertEqual(empty.mode, TeamMode.off)
        try await service.start(mode: empty.mode)
        // An installation updated from 1.0.6: `team/` exists, `chat/` does not.
        try FileManager.default.createDirectory(at: team, withIntermediateDirectories: true)
        try Data(#"{"enabled": true, "displayName": "A"}"#.utf8).write(to: team.appendingPathComponent("config.json"))
        let updated = TeamMode.resolve(chatDirectory: files.directory)
        XCTAssertEqual(updated.mode, TeamMode.off)
        try await service.start(mode: updated.mode)
        XCTAssertEqual(tokens.calls, 0)
        XCTAssertEqual(service.state, .off)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.directory.path))
    }

    func testSignInIsKeptAndReadAtTheNextLaunch() async throws {
        let tokens = FakeTokenStore()
        let conn = try connection()
        try ChatService(files: files, tokens: tokens).saveSignIn(conn, token: "aps_x")
        XCTAssertEqual(TeamMode.resolve(chatDirectory: files.directory).mode, .server)
        let perms = try FileManager.default.attributesOfItem(atPath: files.serversURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
        XCTAssertFalse(try String(contentsOf: files.serversURL, encoding: .utf8).contains("aps_x"), "no token in the file")

        let next = ChatService(files: files, tokens: tokens)
        try await next.start(mode: .server)
        XCTAssertEqual(next.state, .signedIn)
        XCTAssertEqual(next.connection, conn)
        XCTAssertEqual(next.token, "aps_x")
        XCTAssertEqual(Array(next.orgSessions.keys), [try XCTUnwrap(conn.orgKey)])
    }

    // (3)
    func testUnreadableKeychainMeansSignInAgainWithoutAFile() async throws {
        let tokens = FakeTokenStore()
        try ChatService(files: files, tokens: tokens).saveSignIn(try connection(), token: "aps_x")
        tokens.failure = .keychain("User interaction is not allowed.")
        let service = ChatService(files: files, tokens: tokens)
        try await service.start(mode: .server)
        XCTAssertEqual(service.state, .needsSignIn("Keychain: User interaction is not allowed."))
        XCTAssertNil(service.token)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.devTokenURL.path))
        let after = tokens.calls
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(tokens.calls, after, "no retries")
    }

    /// C14-2, C15-1: every token no record names — of earlier sessions,
    /// another account or another server, left by a crash on either side of
    /// the record or by a delete that failed — goes at the next start;
    /// Disconnect removes them all.
    func testTokensNoRecordNamesGoAtStartAndWithDisconnect() async throws {
        let tokens = FakeTokenStore()
        let conn = try connection()
        try ChatService(files: files, tokens: tokens).saveSignIn(conn, token: "aps_x")
        let other = try ChatServerAddress(parsing: "https://other.example.com")
        let left = [
            "\(conn.server)|\(conn.accountId)|s-unkept",
            "\(conn.server)|\(conn.accountId)|s-replaced",
            "\(conn.server)|\(conn.accountId)",
            "\(conn.server)|account-a|s-a",
            "\(other)|account-a|s-a",
        ]
        for account in left { try tokens.write("aps_left", account: account) }
        let service = ChatService(files: files, tokens: tokens)
        service.closeRemoteSession = { _, _ in }
        try await service.start(mode: .server)
        XCTAssertEqual(service.token, "aps_x")
        XCTAssertEqual(Set(tokens.items.keys), [conn.tokenAccount])

        // A delete that fails is not forgotten: the next start takes it.
        tokens.deleteFailure = .keychain("locked")
        try tokens.write("aps_late", account: "\(other)|account-b|s-b")
        try await service.start(mode: .server)
        XCTAssertNotNil(tokens.stored("\(other)|account-b|s-b"))
        tokens.deleteFailure = nil
        try await service.start(mode: .server)
        XCTAssertNil(tokens.stored("\(other)|account-b|s-b"))

        try tokens.write("aps_left", account: "\(other)|account-c|s-c")
        await service.disconnect()
        XCTAssertTrue(tokens.items.isEmpty)
    }

    /// C15-1: connection A is replaced by B of another account and server;
    /// A's token outlives the switch (a crash before it went, or a failed
    /// delete) and goes at the next start.
    func testReplacedAccountsTokenGoesAtTheNextStart() async throws {
        let tokens = FakeTokenStore()
        let a = try connection()
        try ChatService(files: files, tokens: tokens).saveSignIn(a, token: "aps_a")
        let service = ChatService(files: files, tokens: tokens)
        service.closeRemoteSession = { _, _ in }
        try await service.start(mode: .server)
        let other = try ChatServerAddress(parsing: "https://other.example.com")
        let answer = ChatSignIn(token: "aps_b", sessionId: "s-b", accountId: "account-b", orgs: [])
        let b = try await service.completeSignIn(answer, server: other, deviceName: "Mac", orgId: "org-b")
        tokens.deleteFailure = .keychain("locked")
        try await service.keepSignIn()
        XCTAssertEqual(tokens.stored(a.tokenAccount), "aps_a", "the failed delete left it")
        tokens.deleteFailure = nil
        let next = ChatService(files: files, tokens: tokens)
        try await next.start(mode: .server)
        XCTAssertEqual(next.connection, b)
        XCTAssertEqual(Set(tokens.items.keys), [b.tokenAccount])
    }

    /// C15-2: signed in again into the same organization while its queue
    /// is kept (`/v1/me` not answered yet): a new command goes under the new
    /// session and is not dropped as the old one's; the queue waits for the
    /// new connection's hello.
    func testNewCommandAfterSigningInAgainGoesUnderTheNewSession() async throws {
        let tokens = FakeTokenStore()
        let conn = try connection()
        let key = try XCTUnwrap(conn.orgKey)
        let service = ChatService(files: files, tokens: tokens)
        service.closeRemoteSession = { _, _ in }
        try service.saveSignIn(conn, token: "aps_x")
        try await service.start(mode: .server)
        let session = service.session(for: key)
        session.startSending(api: ChatAPI(server: conn.server), token: "aps_x", sessionId: conn.sessionId, journal: service.journal,
                             onUnauthorized: {})
        let outbox = try XCTUnwrap(session.outbox)

        let answer = ChatSignIn(token: "aps_y", sessionId: "s-new", accountId: conn.accountId, orgs: [])
        try await service.completeSignIn(answer, server: conn.server, deviceName: "Mac", orgId: key.orgId)
        try await service.keepSignIn()
        try await service.start(mode: .server)
        XCTAssertEqual(outbox.sessionId, "s-new", "the kept queue moved to the new session at start")
        XCTAssertFalse(outbox.isSending, "and waits for the new connection's hello")
        let record = try service.enqueue(key, type: "member.set_name", args: .object(["name": .string("Anna")]))
        XCTAssertEqual(record.sessionId, "s-new")
        // The organization's queue starting for the new session later drops nothing new.
        session.startSending(api: ChatAPI(server: conn.server), token: "aps_y", sessionId: "s-new", journal: service.journal,
                             onUnauthorized: {})
        let stored = try XCTUnwrap(try session.store?.commands().first { $0.commandId == record.commandId })
        XCTAssertEqual(stored.state, .pending)
    }

    /// C14-4: the journal could not be opened when the queue was made; once
    /// it opens (a new sign-in), its waiting run commands join that queue.
    func testJournalOpenedLaterJoinsTheExistingQueue() async throws {
        let conn = try connection()
        let key = try XCTUnwrap(conn.orgKey)
        let waiting = ChatCommandRecord(commandId: ChatUUID.v7(), sessionId: conn.sessionId, type: "run.finished",
                                        bodyBytes: Data("{}".utf8), orderKey: "exec:run-1", dependsOn: nil, createdAt: Date(), state: .pending)
        do {
            let journal = try ChatJournal.open(files: files)
            try journal.enqueue(waiting, key: key)
        }
        // The journal cannot be read for now.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: files.journalURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.journalURL.path) }
        let service = ChatService(files: files, tokens: FakeTokenStore())
        try service.saveSignIn(conn, token: "aps_x")
        XCTAssertNotNil(service.journalProblem)
        let session = service.session(for: key)
        session.startSending(api: ChatAPI(server: conn.server), token: "aps_x", sessionId: conn.sessionId, journal: service.journal,
                             onUnauthorized: {})
        let outbox = try XCTUnwrap(session.outbox)
        XCTAssertEqual(outbox.queues.count, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: files.journalURL.path)
        let answer = ChatSignIn(token: "aps_y", sessionId: conn.sessionId, accountId: conn.accountId, orgs: [])
        try await service.completeSignIn(answer, server: conn.server, deviceName: "Mac", orgId: key.orgId)
        XCTAssertNil(service.journalProblem)
        guard outbox.queues.count == 2 else { return XCTFail("the journal's table did not join the queue") }
        XCTAssertEqual(try outbox.queues[1].commands().map(\.commandId), [waiting.commandId])
        XCTAssertFalse(outbox.isSending, "held until a new hello prepares the generation")
    }

    func testStartWithoutASavedConnectionFails() async throws {
        let service = ChatService(files: files, tokens: FakeTokenStore())
        do {
            try await service.start(mode: .server)
            XCTFail("expected an error")
        } catch {}
    }

    // (4) and (6)
    func testDisconnectWithoutNetworkRemovesTokenRecordAndCacheButKeepsTheJournal() async throws {
        let tokens = FakeTokenStore()
        let conn = try connection()
        let service = ChatService(files: files, tokens: tokens)
        try service.saveSignIn(conn, token: "aps_x")
        try await service.start(mode: .server)
        let cache = files.cacheURL(try XCTUnwrap(conn.orgKey))
        // Use the real SQLite files created by start. Disconnect must inspect
        // the own-message outbox before removing the cache, so marker bytes
        // would instead test an unreadable queue (covered by ChatDMTests).
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.journalURL.path))
        XCTAssertTrue(try XCTUnwrap(service.orgSessions[try XCTUnwrap(conn.orgKey)]?.store).outbox.commands().isEmpty)

        var order: [String] = []
        var remoteCalls = 0
        service.onBeforeDisconnect { order.append("stop runs") }
        service.closeRemoteSession = { _, token in
            order.append("close \(token)")
            remoteCalls += 1
            throw URLError(.notConnectedToInternet)
        }
        var disconnected = false
        service.onDisconnected = { disconnected = true }
        await service.disconnect()

        XCTAssertEqual(order, ["stop runs", "close aps_x"])
        XCTAssertTrue(disconnected)
        XCTAssertNil(tokens.stored(conn.tokenAccount))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.serversURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.journalURL.path))
        XCTAssertEqual(service.state, .off)

        // The next launch: off, and nothing reaches the network.
        let mode = TeamMode.resolve(chatDirectory: files.directory).mode
        XCTAssertEqual(mode, TeamMode.off)
        let next = ChatService(files: files, tokens: tokens)
        next.closeRemoteSession = { _, _ in remoteCalls += 1 }
        try await next.start(mode: mode)
        XCTAssertEqual(remoteCalls, 1)
        XCTAssertEqual(next.state, .off)
    }

    // (5)
    func testAddressesAreNormalized() throws {
        let a = try ChatServerAddress(parsing: "HTTPS://Host:443/")
        let b = try ChatServerAddress(parsing: "https://host")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.description, "https://host:443")
        XCTAssertEqual(try ChatServerAddress(parsing: "https://host:8443").description, "https://host:8443")
        XCTAssertEqual(try ChatServerAddress(parsing: "http://localhost:8080").description, "http://localhost:8080")
        XCTAssertEqual(try ChatServerAddress(parsing: "http://127.0.0.1").description, "http://127.0.0.1:80")
        XCTAssertThrowsError(try ChatServerAddress(parsing: "http://example.com")) { XCTAssertEqual($0 as? ChatServerAddress.Problem, .insecure) }
        XCTAssertThrowsError(try ChatServerAddress(parsing: "https://host/v1"))
        XCTAssertThrowsError(try ChatServerAddress(parsing: "https://u@host"))
        XCTAssertThrowsError(try ChatServerAddress(parsing: "ftp://host"))
        XCTAssertThrowsError(try ChatServerAddress(parsing: "host"))
    }

    // (7)
    func testTwoOrganizationsOfOneAccountHaveSeparateSessions() throws {
        let service = ChatService(files: files, tokens: FakeTokenStore())
        let conn = try connection(org: nil)
        let one = ChatOrgKey(server: conn.server, accountId: conn.accountId, orgId: UUID().uuidString.lowercased())
        let two = ChatOrgKey(server: conn.server, accountId: conn.accountId, orgId: UUID().uuidString.lowercased())
        let a = service.session(for: one), b = service.session(for: two)
        XCTAssertFalse(a === b)
        XCTAssertTrue(service.session(for: one) === a)
        XCTAssertEqual(service.orgSessions.count, 2)
        XCTAssertNotEqual(one.cacheFileName, two.cacheFileName)
    }

    func testDevelopmentTokenFileOnlyInAnUnsignedBuildThatAsksForIt() throws {
        XCTAssertTrue(ChatKeychain.standard(files: files, environment: [:], teamSigned: false) is ChatKeychain)
        XCTAssertTrue(ChatKeychain.standard(files: files, environment: ["AGENTPAD_DEV_TOKEN_FILE": "1"], teamSigned: true) is ChatKeychain)
        let dev = ChatKeychain.standard(files: files, environment: ["AGENTPAD_DEV_TOKEN_FILE": "1"], teamSigned: false)
        XCTAssertTrue(dev is ChatDevTokenFile)
        try dev.write("aps_y", account: "https://h:443|a")
        XCTAssertEqual(try dev.read(account: "https://h:443|a"), "aps_y")
        let perms = try FileManager.default.attributesOfItem(atPath: files.devTokenURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
        try dev.delete(account: "https://h:443|a")
        XCTAssertNil(try dev.read(account: "https://h:443|a"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.devTokenURL.path))
    }

    /// The real login keychain; opt-in, since it writes there.
    /// C7: Disconnect of a named connection: checked inside the serialized
    /// part; another connection is left alone; the outcome is the call's own.
    func testDisconnectOfANamedConnection() async throws {
        let service = ChatService(files: files, tokens: FakeTokenStore())
        var closed = 0
        service.closeRemoteSession = { _, _ in closed += 1 }
        let mine = try connection()
        try service.saveSignIn(mine, token: "aps_t")
        var other = mine
        other.sessionId = "00000000-0000-4000-8000-0000000000ff"
        let staleOutcome = await service.disconnect(expecting: other)
        XCTAssertEqual(staleOutcome, .stale)
        XCTAssertEqual(service.connection, mine)
        XCTAssertEqual(closed, 0)
        let outcome = await service.disconnect(expecting: mine)
        XCTAssertEqual(outcome, .done)
        XCTAssertNil(service.connection)
        XCTAssertEqual(closed, 1)
        // Already gone: nothing to do for it.
        let again = await service.disconnect(expecting: mine)
        XCTAssertEqual(again, .stale)
    }

    func testKeychainRoundTrip() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTPAD_KEYCHAIN_TESTS"] == "1", "set AGENTPAD_KEYCHAIN_TESTS=1")
        let keychain = ChatKeychain(service: "com.4kulia.agentpad.chat.tests")
        let account = "test|\(UUID().uuidString)"
        defer { try? keychain.delete(account: account) }
        XCTAssertNil(try keychain.read(account: account))
        try keychain.write("aps_1", account: account)
        try keychain.write("aps_2", account: account)
        XCTAssertEqual(try keychain.read(account: account), "aps_2")
        try keychain.delete(account: account)
        XCTAssertNil(try keychain.read(account: account))
    }
}
