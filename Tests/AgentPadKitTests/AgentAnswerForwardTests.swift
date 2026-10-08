import AppKit
import GRDB
import XCTest
@testable import AgentPadKit

private final class ForwardDeliveryServer: @unchecked Sendable {
    private let lock = NSLock()
    private var posts: [String: ChatJSON] = [:]
    var count: Int { lock.lock(); defer { lock.unlock() }; return posts.count }
    func accept(_ data: Data) -> ChatStubProtocol.Answer {
        let command = try! JSONDecoder().decode(ChatCommandEnvelope.self, from: data)
        let id = command.args["message_id"]!.string!
        lock.lock(); defer { lock.unlock() }
        if let original = posts[id], original != command.args {
            return .init(status: 409, body: Data(#"{"error":"message_conflict"}"#.utf8))
        }
        posts[id] = command.args
        return .init(status: 200, body: try! JSONSerialization.data(withJSONObject: ["events": [], "result": [
            "message_id": id, "channel_id": command.args["channel_id"]!.string!, "author_account_id": CallJSON.anna]]))
    }
}

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
                                  sourceTitle: "Claude Code · Review tab", service: f.service, sourceIsCurrent: { true })
    }

    private func prepare(_ model: AgentAnswerForward) async {
        await model.loadChannels()
        model.channel = channel
        await model.loadThreads()
    }

    private func startSender(_ f: ChatChannelExecutionTests.Fixture) throws {
        let session = try XCTUnwrap(f.service.orgSessions[f.key])
        session.startSending(api: f.service.makeAPI(f.key.server), token: "test-only",
            sessionId: try XCTUnwrap(f.service.connection?.sessionId), journal: nil, onUnauthorized: {})
        let sender = try XCTUnwrap(session.outbox); f.sender = sender
        f.service.configureCommandCapabilities(sender, key: f.key)
        sender.onSent = { [weak f] record, answer in
            guard let f else { return }; f.service.commandAnswered(f.key, record, .taken(answer))
        }
        sender.allow(connection: 1, generation: "g1")
    }

    private func wait(_ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(try condition())
    }

    private func reconnect() async throws -> ChatChannelExecutionTests.Fixture {
        let next = try await ChatChannelExecutionTests.Fixture(root: root.appendingPathComponent(UUID().uuidString), sessionId: "new-session")
        fixture = next
        next.service.serverCapabilities[next.key.server] = ["chat.session_tools"]
        next.service.isServerKnown = { _, _ in true }
        return next
    }

    private func disconnectWhileSending(_ model: AgentAnswerForward, _ f: ChatChannelExecutionTests.Fixture) async throws -> ForwardDraft {
        let sending = Task { await model.send() }
        try await wait { try !f.store.outbox.commands().isEmpty }
        await f.service.disconnect()
        await sending.value
        XCTAssertNotNil(model.problem)
        XCTAssertNotNil(model.attemptID)
        return try JSONDecoder().decode(ForwardDraft.self, from: JSONEncoder().encode(model.draft))
    }

    private func confirmRestart(_ model: AgentAnswerForward) async throws {
        let id = try XCTUnwrap(model.attemptID)
        XCTAssertTrue(model.canStartAnotherAttempt)
        model.startAnotherAttempt()
        XCTAssertEqual(model.attemptID, id, "The warning must precede a new attempt")
        XCTAssertEqual(model.restartConfirmation.consequences, "The message may already have been delivered. Starting over can post a duplicate.")
        model.restartConfirmation.shown(true); model.restartConfirmation.confirm()
        try await wait { model.restartConfirmation.phase == .completed }
        XCTAssertNil(model.attemptID); XCTAssertNil(model.attemptSessionAuthor)
    }

    func testPublishedAuthorSurvivesDisconnectAndRetryWithSameMessageID() async throws {
        let model = try await makeModel(), f = try XCTUnwrap(fixture)
        f.agent.sessionId = UUID().uuidString.lowercased()
        let agentID = f.agent.id.uuidString.lowercased()
        try await f.journal.queue.write { db in
            try db.execute(sql: "UPDATE assignments SET published_session = ? WHERE agent_id = ?", arguments: ["s-anna", agentID])
        }
        try f.service.bindPublication(f.key, agent: agentID, surface: UUID(uuidString: caller.surface))
        await prepare(model)
        var saved: ForwardDraft?
        model.persist = { saved = model.draft }
        let server = ForwardDeliveryServer(), gate = Gate(), accepted = expectation(description: "server accepted post")
        gate.close(); defer { gate.open() }
        ChatStubProtocol.reset { request, body in
            if request.url?.path == "/v1/commands" {
                _ = server.accept(body); accepted.fulfill(); gate.pass()
                return .failure(URLError(.networkConnectionLost))
            }
            return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8)))
        }
        try startSender(f)
        let sending = Task { await model.send() }
        await fulfillment(of: [accepted], timeout: 5)
        let id = try XCTUnwrap(model.attemptID)
        await f.service.disconnect()
        XCTAssertNil(f.service.orgSessions[f.key]?.store)
        gate.open(); await sending.value
        XCTAssertTrue(model.submitted); XCTAssertEqual(model.attemptID, id)
        XCTAssertEqual(saved?.attemptID, id); XCTAssertEqual(saved?.attemptAuthor, .session)
        XCTAssertEqual(saved?.attemptSessionAuthor, .agent(agentID)); XCTAssertEqual(server.count, 1)

        let next = try await reconnect()
        XCTAssertEqual(try next.service.sessionAuthor(next.key, caller: caller, generation: "g1"), .session(caller.signature))
        let channel = channel
        ChatStubProtocol.reset { request, body in
            if request.url?.path == "/v1/commands" { return .success(server.accept(body)) }
            if request.url?.path.hasSuffix("/channels") == true {
                return .success(.init(status: 200, body: Data("{\"channels\":[{\"channel_id\":\"\(channel)\",\"team_id\":\"f5000000-0000-4000-8000-000000000004\",\"name\":\"reviews\",\"archived\":false,\"version\":1}],\"next\":null}".utf8)))
            }
            return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8)))
        }
        let persisted = try JSONDecoder().decode(ForwardDraft.self, from: JSONEncoder().encode(XCTUnwrap(saved)))
        let restored = AgentAnswerForward(draft: persisted, caller: caller, service: next.service, sourceIsCurrent: { true })
        await restored.refreshDestinations()
        XCTAssertEqual(restored.channel, channel); XCTAssertTrue(restored.canRetry); XCTAssertFalse(restored.canSendAsUser)
        await restored.sendAsUser()
        XCTAssertEqual(restored.attemptID, id); XCTAssertTrue(try next.store.outbox.commands().isEmpty)
        try startSender(next)
        await restored.retry(); await restored.retry()
        XCTAssertNil(restored.problem); XCTAssertEqual(restored.status, "Sent.")
        let commands = try next.store.outbox.commands()
        XCTAssertEqual(commands.count, 1); XCTAssertEqual(commands.first.map { ChatService.args($0)["message_id"]?.string }, id.uuidString.lowercased())
        XCTAssertEqual(commands.first.map { ChatService.args($0)["author_agent_id"]?.string }, agentID)
        XCTAssertEqual(server.count, 1, "The accepted message must not be published twice")
        XCTAssertTrue(restored.canStartAnotherAttempt)
    }

    func testUnknownAttemptRetryAfter429KeepsBothRecoveryActionsAndCommandBytes() async throws {
        let original = try await makeModel(), f = try XCTUnwrap(fixture)
        await prepare(original)
        let draft = try await disconnectWhileSending(original, f)
        let next = try await reconnect()
        let restored = AgentAnswerForward(draft: draft, caller: caller, service: next.service, sourceIsCurrent: { true })
        ChatStubProtocol.reset { request, _ in
            if request.url?.path == "/v1/commands" {
                return .success(.init(status: 429, headers: ["Retry-After": "60"], body: Data(#"{"error":"rate_limited"}"#.utf8)))
            }
            return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8)))
        }
        try startSender(next)
        XCTAssertTrue(restored.canRetry)
        await restored.retry()
        let command = try XCTUnwrap(next.store.outbox.commands().first)
        XCTAssertEqual(command.state, .failed); XCTAssertEqual(command.error, "rate_limited")
        XCTAssertNotNil(restored.problem)
        XCTAssertTrue(restored.canRetry); XCTAssertTrue(restored.canStartAnotherAttempt)
        await restored.retry() // Retry-After is still in force; this must remain recoverable.
        XCTAssertTrue(restored.canRetry); XCTAssertTrue(restored.canStartAnotherAttempt)
        XCTAssertEqual(try next.store.outbox.commands().first?.bodyBytes, command.bodyBytes)

        let server = ForwardDeliveryServer()
        ChatStubProtocol.reset { request, body in
            if request.url?.path == "/v1/commands" { return .success(server.accept(body)) }
            return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8)))
        }
        try next.write("UPDATE session_posts SET retry_after = 0")
        await restored.retry()
        XCTAssertNil(restored.problem); XCTAssertEqual(restored.status, "Sent.")
        XCTAssertEqual(restored.attemptID, draft.attemptID)
        XCTAssertEqual(try next.store.outbox.commands().map(\.bodyBytes), [command.bodyBytes])
        XCTAssertEqual(server.count, 1)
    }

    func testUnknownAttemptWithoutSourceOrOutboxCanStartOverOfflineAndSendAsAccount() async throws {
        let original = try await makeModel(), f = try XCTUnwrap(fixture)
        await prepare(original)
        let draft = try await disconnectWhileSending(original, f)
        let restored = AgentAnswerForward(draft: draft, caller: nil, service: f.service, sourceIsCurrent: { false })
        restored.loadingChannels = true; restored.loadingThreads = true
        XCTAssertNil(f.service.connection); XCTAssertNil(f.service.orgSessions[f.key]?.store)
        XCTAssertFalse(restored.canRetry); XCTAssertTrue(restored.readable)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        AgentAnswerForwardView.copy(restored.text, to: board)
        XCTAssertEqual(board.string(forType: .string), draft.markdown)
        restored.startAnotherAttempt(); restored.restartConfirmation.shown(true); restored.restartConfirmation.cancel()
        XCTAssertEqual(restored.attemptID, draft.attemptID)
        try await confirmRestart(restored)
        XCTAssertEqual(restored.text, draft.markdown); XCTAssertEqual(restored.snapshot, draft.snapshot)

        let next = try await reconnect(), channel = channel
        ChatStubProtocol.reset { request, _ in
            if request.url?.path.hasSuffix("/channels") == true {
                return .success(.init(status: 200, body: Data("{\"channels\":[{\"channel_id\":\"\(channel)\",\"team_id\":\"f5000000-0000-4000-8000-000000000004\",\"name\":\"reviews\",\"archived\":false,\"version\":1}],\"next\":null}".utf8)))
            }
            return .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8)))
        }
        let fresh = AgentAnswerForward(draft: restored.draft, caller: nil, service: next.service, sourceIsCurrent: { false })
        await fresh.loadInitialDestinations()
        XCTAssertTrue(fresh.canSendAsUser)
        await fresh.sendAsUser()
        XCTAssertNil(fresh.problem); XCTAssertNotEqual(fresh.attemptID, draft.attemptID)
        let post = try XCTUnwrap(next.store.outbox.commands().first)
        XCTAssertEqual(post.type, "message.post"); XCTAssertEqual(ChatService.args(post)["text"]?.string, draft.markdown)
    }

    func testUnknownAttemptRetriesSavedDestinationBeyondFirstPage() async throws {
        for hiddenChannel in [false, true] {
            let original = try await makeModel(), f = try XCTUnwrap(fixture)
            let channel = channel, thread = thread, server = ForwardDeliveryServer()
            ChatStubProtocol.reset { request, body in
                if request.url?.path == "/v1/commands" { return .success(server.accept(body)) }
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if request.url?.path.hasSuffix("/channels") == true {
                    if hiddenChannel && !query.contains(where: { $0.name == "after" }) {
                        return .success(.init(status: 200, body: Data(#"{"channels":[],"next":"older"}"#.utf8)))
                    }
                    return .success(.init(status: 200, body: Data("{\"channels\":[{\"channel_id\":\"\(channel)\",\"team_id\":\"f5000000-0000-4000-8000-000000000004\",\"name\":\"reviews\",\"archived\":false,\"version\":1}],\"next\":null}".utf8)))
                }
                if query.contains(where: { $0.name == "before" }) || request.url?.path.contains("/threads/") == true {
                    return .success(.init(status: 200, body: Data("{\"messages\":[{\"message_id\":\"\(thread)\",\"channel_id\":\"\(channel)\",\"author_account_id\":\"\(CallJSON.anna)\",\"text\":\"Older root\",\"revision\":1,\"seq\":1,\"created_at\":\"2026-01-01T00:00:00Z\"}],\"next\":null,\"head\":1}".utf8)))
                }
                return .success(.init(status: 200, body: Data(#"{"messages":[],"next":2,"head":3}"#.utf8)))
            }
            await original.loadChannels()
            if hiddenChannel { await original.loadChannels(more: true) }
            XCTAssertEqual(original.channels.first?.id, channel)
            original.channel = channel
            await original.loadThreads(); await original.loadThreads(more: true)
            XCTAssertEqual(original.threads.first?.id, thread)
            original.thread = thread
            let draft = try await disconnectWhileSending(original, f)
            let next = try await reconnect()
            let restored = AgentAnswerForward(draft: draft, caller: caller, service: next.service, sourceIsCurrent: { true })
            await restored.refreshDestinations()
            XCTAssertEqual(restored.channel, channel); XCTAssertEqual(restored.thread, thread)
            XCTAssertEqual(restored.channels.isEmpty, hiddenChannel); XCTAssertTrue(restored.threads.isEmpty)
            XCTAssertTrue(restored.canRetry); XCTAssertTrue(restored.canStartAnotherAttempt)
            try startSender(next)
            await restored.retry()
            XCTAssertNil(restored.problem); XCTAssertEqual(restored.status, "Sent.")
            let args = ChatService.args(try XCTUnwrap(next.store.outbox.commands().first))
            XCTAssertEqual(args["channel_id"]?.string, channel); XCTAssertEqual(args["thread_root_id"]?.string, thread)
            XCTAssertEqual(args["message_id"]?.string, draft.attemptID?.uuidString.lowercased())
            XCTAssertEqual(server.count, 1)
            next.sender?.hold(); await next.service.disconnect()
        }
    }

    func testCacheResetWhileAwaitingPostCannotProveNonDelivery() async throws {
        let model = try await makeModel(), f = try XCTUnwrap(fixture)
        await prepare(model)
        let sending = Task { await model.send() }
        let deadline = ContinuousClock.now + .seconds(5)
        while try f.store.outbox.commands().isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let id = try XCTUnwrap(model.attemptID)
        XCTAssertTrue(model.sending); XCTAssertEqual(try f.store.outbox.commands().count, 1)
        try f.write("UPDATE meta SET generation = 'replacement'")
        try f.write("DELETE FROM session_posts")
        try f.write("DELETE FROM outbox")
        try f.write("DELETE FROM messages")
        await sending.value
        XCTAssertEqual(model.attemptID, id); XCTAssertTrue(model.canStartAnotherAttempt)
        XCTAssertTrue(model.submitted); XCTAssertFalse(model.canSendAsUser)
    }

    func testRestoredUnqueuedAttemptRetriesOriginalIDAndRetainsItOnPreflightFailure() async throws {
        let original = try await makeModel(), f = try XCTUnwrap(fixture)
        await prepare(original)
        var draft = original.draft
        draft.attemptID = UUID(); draft.attemptAuthor = .session; draft.attemptSessionAuthor = .session(caller.signature)
        let restored = AgentAnswerForward(draft: draft, caller: caller, service: f.service, sourceIsCurrent: { true })
        await restored.loadInitialDestinations()
        ChatStubProtocol.reset { _, _ in .failure(URLError(.networkConnectionLost)) }
        await restored.retry()
        XCTAssertEqual(restored.attemptID, draft.attemptID)
        XCTAssertTrue(restored.canRetry); XCTAssertTrue(restored.canStartAnotherAttempt)
        XCTAssertFalse(restored.canSendAsUser)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: Data(#"{"messages":[],"next":null,"head":0}"#.utf8))) }
        await restored.retry()
        XCTAssertEqual(try f.store.outbox.commands().count, 1)
        XCTAssertEqual(try f.store.outbox.commands().first.map { ChatService.args($0)["message_id"]?.string }, draft.attemptID?.uuidString.lowercased())
    }

    func testRestoredSnapshotAfterRestartSendsOnlyExplicitlyAsAccount() async throws {
        let original = try await makeModel(), f = try XCTUnwrap(fixture)
        original.text = "# Saved edit\n\n@billing@anna is quoted text"
        let saved = try JSONDecoder().decode(ForwardDraft.self, from: JSONEncoder().encode(original.draft))
        f.service.serverCapabilities[f.key.server] = [] // User sending needs no session tools.
        let restored = AgentAnswerForward(draft: saved, caller: nil, service: f.service, sourceIsCurrent: { false })
        await prepare(restored)
        XCTAssertEqual(restored.snapshot, original.snapshot)
        XCTAssertEqual(restored.text, original.text)
        XCTAssertFalse(restored.canSend)
        XCTAssertTrue(restored.canSendAsUser)
        await restored.send()
        XCTAssertTrue(try f.store.outbox.commands().isEmpty, "Restore and Send from session cannot send a saved process identity")
        await restored.sendAsUser(); await restored.sendAsUser()
        XCTAssertNil(restored.problem)
        let commands = try f.store.outbox.commands()
        let post = try XCTUnwrap(commands.first)
        XCTAssertEqual(commands.count, 1); XCTAssertEqual(post.type, "message.post")
        let args = ChatService.args(post)
        XCTAssertEqual(args["text"]?.string, saved.markdown)
        XCTAssertNil(args["author_agent_id"]); XCTAssertNil(args["author_session_name"])
        XCTAssertEqual(args["mentions"], .array([]))
        let author = try await f.store.queue.read { try String.fetchOne($0, sql: "SELECT author_account_id FROM messages WHERE message_id = ?", arguments: [args["message_id"]?.string]) }
        XCTAssertEqual(author, f.key.accountId)
        let again = AgentAnswerForward(draft: restored.draft, caller: nil, service: f.service, sourceIsCurrent: { false })
        await prepare(again); await again.sendAsUser()
        XCTAssertFalse(again.canSendAsUser)
        XCTAssertEqual(try f.store.outbox.commands().count, 1)
    }

    func testClosedSourceCannotSendFromSessionButSavedEditsCanSendAsUser() async throws {
        let original = try await makeModel(), f = try XCTUnwrap(fixture)
        original.text = "Saved edits before closing source"
        let restored = AgentAnswerForward(draft: original.draft, caller: caller, service: f.service, sourceIsCurrent: { false })
        await prepare(restored)
        await restored.send()
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        await restored.sendAsUser()
        XCTAssertEqual(try f.store.outbox.commands().map(\.type), ["message.post"])
        XCTAssertEqual(try f.store.outbox.commands().first.map { ChatService.args($0)["text"]?.string }, original.text)
    }

    func testRestoredTabWithLiveBindingSendsSavedEditsAndUncertainAttemptCannotChangeAuthor() async throws {
        let original = try await makeModel(), f = try XCTUnwrap(fixture)
        original.text = "Edited old snapshot, not the agent's next answer"
        let restored = AgentAnswerForward(draft: original.draft, caller: caller, service: f.service, sourceIsCurrent: { true })
        await prepare(restored); await restored.send()
        XCTAssertNil(restored.problem)
        let post = try XCTUnwrap(f.store.outbox.commands().first)
        XCTAssertEqual(post.type, "message.post_from_session")
        XCTAssertEqual(ChatService.args(post)["text"]?.string, original.text)
        let persisted = try JSONDecoder().decode(ForwardDraft.self, from: JSONEncoder().encode(restored.draft))
        XCTAssertEqual(persisted.attemptAuthor, .session)
        let restarted = AgentAnswerForward(draft: persisted, caller: nil, service: f.service, sourceIsCurrent: { false })
        await prepare(restarted); await restarted.sendAsUser()
        XCTAssertFalse(restarted.canSendAsUser)
        XCTAssertEqual(restarted.attemptID, restored.attemptID)
        XCTAssertEqual(try f.store.outbox.commands().count, 1)
    }

    func testBothAuthorsRejectChangedConnectionRightsArchiveThreadAndDraftDuringPreflight() async throws {
        for fromSession in [false, true] {
        for change in ["connection", "rights", "generation", "archive", "thread", "draft"] {
            let original = try await makeModel(), f = try XCTUnwrap(fixture)
            let model = fromSession ? original : AgentAnswerForward(draft: original.draft, caller: nil, service: f.service, sourceIsCurrent: { false })
            await prepare(model)
            if change == "thread" {
                let thread = thread, channel = channel
                model.thread = thread
                try await f.store.queue.write { db in
                    try db.execute(sql: "INSERT INTO messages (message_id, channel_id, author_account_id, text, revision, seq, created_at, has_fixed, has_mutable) VALUES (?, ?, ?, 'root', 1, 1, '2026-01-01', 1, 1)", arguments: [thread, channel, f.key.accountId])
                }
            }
            let gate = Gate(), entered = expectation(description: change); gate.close()
            let channel = channel, thread = thread
            ChatStubProtocol.reset { request, _ in
                if request.url?.path.hasSuffix("/channels") == true {
                    return .success(.init(status: 200, body: Data("{\"channels\":[{\"channel_id\":\"\(channel)\",\"team_id\":\"f5000000-0000-4000-8000-000000000004\",\"name\":\"reviews\",\"archived\":false,\"version\":1}],\"next\":null}".utf8)))
                }
                entered.fulfill(); gate.pass()
                return .success(.init(status: 200, body: Data("{\"messages\":[{\"message_id\":\"\(thread)\",\"channel_id\":\"\(channel)\",\"author_account_id\":\"\(CallJSON.anna)\",\"text\":\"root\",\"revision\":1,\"seq\":1,\"created_at\":\"2026-01-01T00:00:00Z\"}],\"next\":null,\"head\":1}".utf8)))
            }
            let sending = Task { if fromSession { await model.send() } else { await model.sendAsUser() } }
            await fulfillment(of: [entered], timeout: 5)
            switch change {
            case "connection":
                var c = try XCTUnwrap(f.service.connection); c.sessionId = "new-session"; try f.service.saveSignIn(c, token: "fixture")
            case "rights": try f.write("UPDATE meta SET channel_access_epoch = channel_access_epoch + 1")
            case "generation": try f.write("UPDATE meta SET generation = 'g2'")
            case "archive": try f.write("UPDATE channels SET archived = 1")
            case "thread": try f.write("UPDATE messages SET revision = 2, deleted_at = 'now' WHERE message_id = ?", [thread])
            default: model.text = "Changed while checking"
            }
            gate.open(); await sending.value
            XCTAssertTrue(try f.store.outbox.commands().isEmpty, change)
            XCTAssertNotNil(model.problem, change)
            await f.service.disconnect(); fixture = nil
        }
        }
    }

    func testRestoredDestinationAndMarkdownSurviveInitialReadAndViewRemount() async throws {
        let original = try await makeModel(), f = try XCTUnwrap(fixture)
        original.channel = channel; original.thread = thread; original.text = "Saved draft with selected thread"
        let restored = AgentAnswerForward(draft: original.draft, caller: caller, service: f.service, sourceIsCurrent: { true })
        await restored.loadInitialDestinations()
        XCTAssertTrue(restored.canSend)
        XCTAssertEqual(restored.channel, channel); XCTAssertEqual(restored.thread, thread)
        restored.text = "Unsaved view edit"
        await restored.loadInitialDestinations()
        XCTAssertEqual(restored.text, "Unsaved view edit"); XCTAssertEqual(restored.thread, thread)
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
    }

    func testForwardAttemptIsDurableBeforeQueueAndSaveFailureDoesNotSend() async throws {
        for fromSession in [false, true] {
        let original = try await makeModel(), f = try XCTUnwrap(fixture)
        let model = fromSession ? original : AgentAnswerForward(draft: original.draft, caller: nil, service: f.service, sourceIsCurrent: { false })
        await prepare(model)
        var saved: ForwardDraft?
        model.persist = {
            saved = model.draft
            XCTAssertTrue(try f.store.outbox.commands().isEmpty)
            throw ChatError.storage("disk full")
        }
        if fromSession { await model.send() } else { await model.sendAsUser() }
        XCTAssertTrue(try f.store.outbox.commands().isEmpty)
        // Even a failed save retains the attempt; retry must persist it before queueing.
        XCTAssertNotNil(model.problem)
        let id = try XCTUnwrap(saved?.attemptID)
        XCTAssertEqual(saved?.attemptSessionAuthor, fromSession ? .session(caller.signature) : nil)
        XCTAssertTrue(model.canRetry)
        model.persist = { saved = model.draft }
        await model.retry()
        XCTAssertEqual(saved?.attemptID, id)
        XCTAssertNotNil(saved?.attemptID); XCTAssertEqual(saved?.attemptAuthor, fromSession ? .session : .account)
        XCTAssertEqual(try f.store.outbox.commands().count, 1)
        await f.service.disconnect(); fixture = nil
        }
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
