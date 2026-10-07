import Foundation
import XCTest
@testable import AgentPadKit

/// Against the deployed server; opt-in. `AGENTPAD_LIVE_SIGNIN` names an
/// `e2e-client-…@example.com` address that owns an organization there
/// (`create-org`); codes come from the operator command `issue-code` over
/// ssh and are never printed. Shared deployment settings: Tests/LIVE-TESTS.md.
@MainActor
final class ChatLiveTests: XCTestCase {
    private var root: URL!
    private var live: ChatLiveConfiguration!
    private let server = try! ChatServerAddress(parsing: "https://agentpad.rabbitshat.ai")

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-live-\(UUID().uuidString)")
        live = try ChatLiveConfiguration()
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ condition: @MainActor () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func testSignInMeSetNameRepeatSignInAgainAndDisconnect() async throws {
        guard let address = ProcessInfo.processInfo.environment["AGENTPAD_LIVE_SIGNIN"] else {
            throw XCTSkip("set AGENTPAD_LIVE_SIGNIN=e2e-client-…@example.com")
        }
        try live.validate(email: address)
        let tokens = FakeTokenStore()
        let service = ChatService(files: ChatFiles(directory: root), tokens: tokens)
        service.executorRunner = UnconfiguredLiveRunner()
        service.claudeProjectsRoot = root.appendingPathComponent("claude-projects")
        // 1. Sign-in (the service's steps: the window also needs `events.ws`,
        // which production announces only with stage B).
        try await service.requestCode(server: server, email: address)
        let answer = try await service.authenticate(server: server, email: address, code: try live.issueCode(address), deviceName: "e2e client test")
        let connection = try await service.completeSignIn(answer, server: server, deviceName: "e2e client test", orgId: answer.orgs.first?.orgId)
        try await service.keepSignIn()
        let key = try XCTUnwrap(connection.orgKey)
        let token = try XCTUnwrap(tokens.stored(connection.tokenAccount))

        // 2. /v1/me answers for the new session.
        let api = ChatAPI(server: server)
        let me = try await api.me(token: token)
        XCTAssertEqual(me.sessionId, connection.sessionId)
        XCTAssertEqual(me.accountId, connection.accountId)
        XCTAssertTrue(me.orgs.contains { $0.orgId == key.orgId })

        // 3. member.set_name through a send queue, then the same bytes again.
        let name = "E2E Client \(Int(Date().timeIntervalSince1970) % 100_000)"
        let store = try XCTUnwrap(service.session(for: key).store)
        let outbox = ChatOutbox(queues: [store.outbox], api: api, token: token, sessionId: connection.sessionId)
        var answers: [ChatCommandAnswer] = []
        outbox.onSent = { _, answer in if let answer { answers.append(answer) } }
        try outbox.enqueue(org: key.orgId, type: "member.set_name", args: .object(["name": .string(name)]))
        try await waitUntil { try store.commands().last?.state == .sent }
        let sent = try XCTUnwrap(try store.commands().last)
        let renamed = try await api.me(token: token)
        XCTAssertEqual(renamed.orgs.first { $0.orgId == key.orgId }?.name, name)
        let repeated = try await api.postCommand(sent.bodyBytes, token: token)
        XCTAssertEqual(repeated.status, 200)
        let again = try JSONDecoder().decode(ChatCommandAnswer.self, from: repeated.body)
        XCTAssertEqual(again.events, answers.first?.events, "the saved answer, nothing written twice")
        XCTAssertEqual(answers.first?.events.count, 1)

        // 4. Signing in again closes the old session with the old token.
        let secondAnswer = try await service.authenticate(server: server, email: address, code: try live.issueCode(address), deviceName: "e2e client test")
        let second = try await service.completeSignIn(secondAnswer, server: server, deviceName: "e2e client test", orgId: connection.orgId)
        try await service.keepSignIn()
        XCTAssertNotEqual(second.sessionId, connection.sessionId)
        do {
            _ = try await api.me(token: token)
            XCTFail("the old session is still open")
        } catch let error as ChatAPIError {
            XCTAssertEqual(error.code, "unauthorized")
        }
        let newToken = try XCTUnwrap(tokens.stored(second.tokenAccount))
        let meAgain = try await api.me(token: newToken)
        XCTAssertEqual(meAgain.sessionId, second.sessionId)

        // 5. Disconnect closes the session and keeps nothing.
        await service.disconnect()
        do {
            _ = try await api.me(token: newToken)
            XCTFail("the session survived Disconnect")
        } catch let error as ChatAPIError {
            XCTAssertEqual(error.code, "unauthorized")
        }
        XCTAssertNil(tokens.stored(second.tokenAccount))
    }
}
