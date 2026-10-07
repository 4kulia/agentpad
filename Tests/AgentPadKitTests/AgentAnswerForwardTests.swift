import AppKit
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class AgentAnswerForwardTests: XCTestCase {
    private var root: URL!
    private var fixture: ChatChannelExecutionTests.Fixture?
    private let channel = "f5000000-0000-4000-8000-000000000001"
    private let thread = "a0000000-0000-4000-8000-000000000001"
    private let caller = ChatLocalCaller(surface: "a0000000-0000-4000-8000-000000000002", claudePID: 42,
                                        claudeStart: 100, signature: "Review tab")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("answer-forward-\(UUID())")
        ChatNotifications.badgeChanged = {}
    }
    override func tearDown() async throws {
        fixture?.sender?.hold()
        await fixture?.service.disconnect()
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeModel() async throws -> AgentAnswerForward {
        let f = try await ChatChannelExecutionTests.Fixture(root: root)
        fixture = f
        f.service.serverCapabilities[f.key.server] = ["chat.session_tools"]
        f.service.isServerKnown = { _, _ in true }
        let channel = channel, thread = thread
        let team = "f5000000-0000-4000-8000-000000000004"
        ChatStubProtocol.reset { request, _ in
            let object: [String: Any]
            if request.url?.path.hasSuffix("/channels") == true {
                object = ["channels": [["channel_id": channel, "team_id": team, "name": "reviews", "archived": false, "version": 1],
                                        ["channel_id": "a0000000-0000-4000-8000-000000000009", "team_id": team, "name": "archive", "archived": true, "version": 1]], "next": NSNull()]
            } else {
                object = ["messages": [["message_id": thread, "channel_id": channel, "author_account_id": CallJSON.anna,
                                         "text": "Release review", "revision": 1, "seq": 1, "created_at": "2026-01-01T00:00:00Z"]],
                          "next": NSNull(), "head": 1]
            }
            return .success(.init(status: 200, body: try! JSONSerialization.data(withJSONObject: object)))
        }
        return AgentAnswerForward(text: "# Answer\n\nOriginal **Markdown**", caller: caller,
                                  sourceTitle: "Claude Code · Review tab", service: f.service)
    }

    private func prepare(_ model: AgentAnswerForward) async {
        await model.loadChannels()
        model.channel = channel
        await model.loadThreads()
    }

    func testOpeningSelectingEditingAndClosingNeverQueues() async throws {
        let model = try await makeModel()
        let f = try XCTUnwrap(fixture)
        await prepare(model)
        XCTAssertNil(model.problem)
        XCTAssertEqual(model.channels.count, 1, "archived channels cannot be forwarded to")
        XCTAssertEqual(model.threads.first?.id, thread)
        model.thread = thread
        model.text = "Edited *answer*"
        XCTAssertTrue(model.canSend)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        model.active = false
        await model.send()
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testPersistedOrMonitoredConversationNeedsAHookForTheCurrentProcess() throws {
        let store = makeTestStore()
        defer { store.terminate() }
        let session = try XCTUnwrap(store.active?.activeSession)
        session.agent = .claudeCode
        let engine = try XCTUnwrap(session.engine as? TestEngine)
        engine.foregroundPid = ProcessInfo.processInfo.processIdentifier
        let id = UUID().uuidString.lowercased()
        session.conversationId = id
        XCTAssertNil(session.answerBinding, "a fresh launch must not copy the saved session")
        session.resumedConversationId = id
        XCTAssertNil(session.answerBinding, "a resume argument is not a report from the running process")
        session.resumedConversationId = nil
        store.applyConversationId(conversationId: id, sessionId: session.id)
        XCTAssertNil(session.answerBinding, "a monitor only updates history")
        store.applyHookConversationId(conversationId: id, sessionId: session.id)
        XCTAssertNil(session.answerBinding, "a hook without process evidence cannot bind")
        let fixture = AnswerProcessFixture()
        try fixture.bind(session, conversation: id)
        XCTAssertEqual(session.answerBinding?.conversation, id, "same-ID hook still establishes the runtime binding")
        XCTAssertEqual(session.answerBinding?.process.pid, engine.foregroundPid)
        session.agent = .terminal
        store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
        XCTAssertNil(session.answerBinding, "starting a new agent in the shell clears the old binding")
        try fixture.bind(session, conversation: id)
        XCTAssertEqual(session.answerBinding?.conversation, id)
        store.applyHookEvent(agent: .claudeCode, event: .running, sessionId: session.id)
        XCTAssertEqual(session.answerBinding?.conversation, id, "a turn in the same agent retains the binding")
    }

    func testExplicitForwardUsesSessionAttributionThreadAndByteLimitOnlyOnce() async throws {
        let model = try await makeModel()
        let f = try XCTUnwrap(fixture)
        await prepare(model)
        model.thread = thread
        model.text = String(repeating: "Готово 👩🏽‍💻\n", count: 2000)
        XCTAssertTrue(model.truncated)
        XCTAssertTrue(model.canSend)
        await model.send()
        XCTAssertNil(model.problem)
        XCTAssertTrue(model.submitted)
        await model.send()
        let posts = try f.store.outbox.commands().filter { $0.type == "message.post_from_session" }
        XCTAssertEqual(posts.count, 1)
        let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: XCTUnwrap(posts.first).bodyBytes)
        XCTAssertEqual(envelope.args["author_session_name"]?.string, caller.signature)
        XCTAssertNil(envelope.args["author_agent_id"])
        XCTAssertEqual(envelope.args["channel_id"]?.string, channel)
        XCTAssertEqual(envelope.args["thread_root_id"]?.string, thread)
        XCTAssertEqual(envelope.args["text"]?.string, model.outgoingText)
        XCTAssertLessThanOrEqual(try XCTUnwrap(envelope.args["text"]?.string).utf8.count, ChatChannelModel.maxBytes)
        XCTAssertGreaterThan(model.text.utf8.count, ChatChannelModel.maxBytes)
    }

    func testPublishedAgentAttributionMatchesChatPost() async throws {
        let model = try await makeModel()
        let f = try XCTUnwrap(fixture)
        f.agent.sessionId = UUID().uuidString.lowercased()
        let agentID = f.agent.id.uuidString.lowercased()
        try await f.journal.queue.write { db in
            try db.execute(sql: "UPDATE assignments SET published_session = ? WHERE agent_id = ?", arguments: ["s-anna", agentID])
        }
        try f.service.bindPublication(f.key, agent: f.agent.id.uuidString.lowercased(), surface: UUID(uuidString: caller.surface))
        await prepare(model)
        XCTAssertEqual(model.signature, f.agent.name)
        await model.send()
        let post = try XCTUnwrap(f.store.outbox.commands().first { $0.type == "message.post_from_session" })
        let envelope = try JSONDecoder().decode(ChatCommandEnvelope.self, from: post.bodyBytes)
        XCTAssertEqual(envelope.args["author_agent_id"]?.string, f.agent.id.uuidString.lowercased())
        XCTAssertNil(envelope.args["author_session_name"])
    }

    func testOfflineOnlyCopySaveAndNoQueue() async throws {
        let model = try await makeModel()
        let f = try XCTUnwrap(fixture)
        await prepare(model)
        f.service.isServerKnown = { _, _ in false }
        XCTAssertFalse(model.online)
        XCTAssertFalse(model.canSend)
        XCTAssertTrue(model.organizations.isEmpty)
        await model.send()
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        AgentAnswerForwardView.copy(model.text, to: board)
        XCTAssertEqual(board.string(forType: .string), model.text)
    }

    func testSourceChangeInvalidatesForward() async throws {
        let model = try await makeModel()
        let f = try XCTUnwrap(fixture)
        await prepare(model)
        model.sourceIsCurrent = { false }
        await model.send()
        XCTAssertFalse(model.canSend)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testNewServerSessionCannotAdoptAnOpenForwardDraft() async throws {
        let model = try await makeModel()
        let f = try XCTUnwrap(fixture)
        await prepare(model)
        var connection = try XCTUnwrap(f.service.connection)
        connection.sessionId = "replacement-session"
        try f.service.saveSignIn(connection, token: "test-only")
        XCTAssertFalse(model.online)
        XCTAssertTrue(model.organizations.isEmpty)
        await model.send()
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testSourceChangeDuringPostPreflightNeverQueues() async throws {
        let model = try await makeModel()
        let f = try XCTUnwrap(fixture)
        await prepare(model)
        let entered = expectation(description: "preflight"), gate = Gate()
        gate.close(); defer { gate.open() }
        ChatStubProtocol.reset { _, _ in
            entered.fulfill(); gate.pass()
            return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8)))
        }
        let task = Task { await model.send() }
        await fulfillment(of: [entered], timeout: 3)
        model.sourceIsCurrent = { false }
        gate.open()
        await task.value
        XCTAssertNotNil(model.problem)
        XCTAssertFalse(model.submitted)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testClearingThreadSelectionDoesNotCancelAChannelRefresh() async throws {
        let model = try await makeModel()
        await prepare(model)
        let entered = expectation(description: "channels refresh"), gate = Gate()
        gate.close(); defer { gate.open() }
        let channel = channel
        ChatStubProtocol.reset { _, _ in
            entered.fulfill(); gate.pass()
            let rows: [String: Any] = ["channels": [["channel_id": channel, "team_id": "f5000000-0000-4000-8000-000000000004",
                                                    "name": "refreshed", "archived": false, "version": 1]], "next": NSNull()]
            return .success(.init(status: 200, body: try! JSONSerialization.data(withJSONObject: rows)))
        }
        let task = Task { await model.loadChannels() }
        await fulfillment(of: [entered], timeout: 3)
        XCTAssertEqual(model.channel, "")
        await model.loadThreads() // SwiftUI reacts to clearing the previous channel.
        XCTAssertTrue(model.loading, "the channels request is still in flight")
        gate.open()
        await task.value
        XCTAssertEqual(model.channels.first?.id, channel)
        XCTAssertFalse(model.loading)
    }
}
