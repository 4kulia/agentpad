import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

/// Exercises the production argv builder, but never runs Claude. Transcripts
/// live only under the test's temporary directory, also in the live F6 test.
/// This verifies the continuation mechanism (UUID and --resume), not the
/// model's semantic memory: the inner runner returns a fixed answer.
final class F6Runner: TeamAgentRunner, @unchecked Sendable {
    let projects: URL
    let inner = ChatTeamCallsTests.OwnerRunner()
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var arguments: [[String]] { lock.withLock { recorded } }
    var writesTranscript = true
    var inspect: (@Sendable (TeamRunRequest) throws -> Void)?

    init(projects: URL) {
        self.projects = projects
        inner.holds = false
        inner.tellsProcess = false
    }
    func transcript(_ id: String) -> URL { projects.appendingPathComponent("-fixture/\(id).jsonl") }
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void) async throws -> TeamRunResult {
        try await run(request, onActivity: onActivity, onProcessStarted: { _ in })
    }
    func run(_ request: TeamRunRequest, onActivity: @escaping @Sendable (String) -> Void,
             onProcessStarted: @escaping @Sendable (TeamProcessStart) throws -> Void) async throws -> TeamRunResult {
        let args = try ClaudeCodeRunner.arguments(for: request, sessionFilesRoot: projects, visibility: .init(channelIds: []))
        lock.withLock { recorded.append(args) }
        try inspect?(request)
        let result = try await inner.run(request, onActivity: onActivity, onProcessStarted: onProcessStarted)
        if writesTranscript && !result.isError {
            let file = transcript(request.sessionId)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let previous = request.resume ? (try Data(contentsOf: file)) : Data()
            try (previous + Data((request.prompt + "\n").utf8)).write(to: file)
        }
        return result
    }
}

@MainActor
final class ChatThreadContinuationTests: XCTestCase {
    private var root: URL!
    private var fixtures: [ChatChannelExecutionTests.Fixture] = []
    private let channel = "f5000000-0000-4000-8000-000000000001"
    private let thread = "f5000000-0000-4000-8000-000000000002"
    private var sequence = 0

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-f6-\(UUID().uuidString)")
        ChatNotifications.badgeChanged = {}
    }
    override func tearDown() async throws {
        for f in fixtures { await f.service.disconnect() }
        fixtures = []
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }
    private func fixture(at directory: URL? = nil, sessionId: String = "s-anna") async throws -> (ChatChannelExecutionTests.Fixture, F6Runner) {
        let directory = directory ?? root.appendingPathComponent(UUID().uuidString)
        let runner = F6Runner(projects: directory.appendingPathComponent("claude-projects"))
        let f = try await ChatChannelExecutionTests.Fixture(root: directory, executor: runner, sessionId: sessionId)
        fixtures.append(f)
        ChatStubProtocol.reset { request, _ in
            if request.url?.path.hasSuffix("/content") == true {
                let id = request.url!.deletingLastPathComponent().lastPathComponent
                let content = ChatChannelContent(requestId: id, text: "Why twice?", context: [])
                return .success(.init(status: 200, body: try! JSONEncoder().encode(content)))
            }
            return .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
        }
        return (f, runner)
    }
    @discardableResult
    private func seed(_ f: ChatChannelExecutionTests.Fixture, caller: String = CallJSON.boris,
                      channel: String? = nil, thread: String? = nil, agent: String = CallJSON.agent) throws -> String {
        let id = UUID().uuidString.lowercased()
        sequence += 1
        var body = CallJSON.request(id, state: "awaiting_decision", version: 2, onThisDevice: true, initiator: caller)
        body["kind"] = "channel"
        body["channel_id"] = channel ?? self.channel
        body["thread_root_id"] = thread ?? self.thread
        body["agent_id"] = agent
        body["created_at"] = ChatCallStore.timestamp(Date(timeIntervalSince1970: 1_790_000_000 + Double(sequence)))
        body["deliver_by"] = ChatCallStore.timestamp(Date().addingTimeInterval(3600))
        try f.store.queue.write { try ChatCallStore.apply($0, CallJSON.wire(body), onThisDevice: true) }
        return id
    }
    private func move(_ f: ChatChannelExecutionTests.Fixture, _ id: String, _ state: String, _ version: Int, run: String? = nil) throws {
        let body = CallJSON.request(id, state: state, version: version, fixed: false, runId: run, onThisDevice: true)
        try f.store.queue.write { try ChatCallStore.apply($0, CallJSON.wire(body), onThisDevice: true) }
        f.calls.reload()
    }
    private func allow(_ f: ChatChannelExecutionTests.Fixture, _ id: String) async throws -> ChatApproval {
        let problem = await f.owner.decideChannel(f.key, requestId: id, allow: true, reason: nil)
        XCTAssertNil(problem)
        return try XCTUnwrap(f.journal.approval(f.key, requestId: id))
    }
    @discardableResult
    private func finish(_ f: ChatChannelExecutionTests.Fixture, _ id: String) async throws -> ChatRunRecord {
        let approval = try await allow(f, id)
        try move(f, id, "starting", 4, run: approval.runId)
        _ = try await XCTUnwrap(f.service.launcher).launch(approvalId: approval.id)
        try move(f, id, "finished", 7, run: approval.runId)
        return try XCTUnwrap(f.journal.run(approval.runId))
    }
    private func lookup(_ f: ChatChannelExecutionTests.Fixture, _ id: String) throws -> ChatService.ThreadLookup {
        f.service.threadLookup(try f.request(id), store: f.store, key: f.key)
    }
    private func wait(_ check: () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if try check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out", file: file, line: line)
    }

    // F6 (1), (2): a different participant gets the same conversation, but
    // no approval/run exists until that participant's request is allowed.
    func testSameThreadAcrossParticipantsRequiresANewDecisionAndResumes() async throws {
        let (f, runner) = try await fixture()
        let a = try seed(f)
        let first = try await finish(f, a)
        let b = try seed(f, caller: CallJSON.anna)
        XCTAssertEqual(try lookup(f, b), .known(conversation: first.conversationId))
        XCTAssertNil(try f.journal.approval(f.key, requestId: b))
        let refused = await f.owner.perform(.start, request: try f.request(b), key: f.key)
        XCTAssertEqual(refused, .done)
        XCTAssertEqual(runner.arguments.count, 1)
        XCTAssertNotNil(f.owner.decide(f.key, requestId: b, allow: true, reason: nil), "ordinary Team is not the channel gateway")
        let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: channel)
        let memory = try XCTUnwrap(model.decisionText(f.request(b)))
        XCTAssertTrue(memory.contains("remembers 1 earlier request"))
        XCTAssertTrue(memory.contains("Boris") && memory.contains("may grow before the run starts"))
        try f.write("UPDATE members SET name = 'Renamed since Allow' WHERE account_id = ?", [CallJSON.boris])
        XCTAssertTrue(try XCTUnwrap(model.decisionText(f.request(b))).contains("by Boris"), "memory names come from the journal")
        try f.write("UPDATE members SET name = 'Boris' WHERE account_id = ?", [CallJSON.boris])
        let second = try await finish(f, b)
        XCTAssertEqual(try f.commands().filter { $0.type == "request.decide" }.count, 2)
        XCTAssertEqual(second.conversationId, first.conversationId)
        let resume = try XCTUnwrap(runner.arguments[1].firstIndex(of: "--resume"))
        XCTAssertEqual(runner.arguments[1][resume + 1], first.conversationId)
        XCTAssertFalse(runner.arguments[1].contains("--fork-session"))
        let c = try seed(f)
        XCTAssertTrue(try XCTUnwrap(model.decisionText(f.request(c))).contains("remembers 2 earlier requests of this thread by Anna, Boris"))
        XCTAssertTrue(try ChatTeamCallStore(calls: f.store.calls, key: f.key).loadLog().incoming.isEmpty)
        XCTAssertNil(f.calls.serverConversation?(try XCTUnwrap(f.calls.executionIncoming(a))))
    }

    func testCancelOrStopOfAContinuationKeepsTheEarlierConversationForTheNextRequest() async throws {
        for action in ["cancel", "stop"] {
            let (f, runner) = try await fixture()
            let a = try seed(f), first = try await finish(f, a)
            let file = runner.transcript(first.conversationId)
            let earlier = try Data(contentsOf: file)
            let b = try seed(f, caller: CallJSON.anna), approval = try await allow(f, b)
            runner.inner.holds = true
            try move(f, b, "starting", 4, run: approval.runId)
            let launcher = try XCTUnwrap(f.service.launcher)
            let running = Task { try await launcher.launch(approvalId: approval.id) }
            defer { running.cancel() }
            try await wait { runner.inner.waiting == 1 }
            XCTAssertEqual(try f.journal.run(approval.runId)?.conversationId, first.conversationId)
            XCTAssertTrue(runner.arguments.last!.contains("--resume"))
            try move(f, b, "running", 5, run: approval.runId)
            if action == "cancel" { XCTAssertNil(f.service.cancelChannelRequest(f.key, requestId: b)) }
            else { XCTAssertNil(f.service.askToEnd(f.key, b, type: "request.stop", states: [.starting, .running])) }
            XCTAssertTrue(try f.commands().contains { $0.type == "request.\(action)" && ChatService.args($0)["request_id"]?.string == b })
            try move(f, b, "stop_requested", 6, run: approval.runId)
            f.service.reconcileChannelResults()
            XCTAssertEqual(try? Data(contentsOf: file), earlier, action)
            _ = await f.owner.perform(.stop, request: try f.request(b), key: f.key)
            _ = try? await running.value
            // The stand-in has no processes. Confirm their end as recovery
            // would; the production stopper otherwise keeps an unknown stop.
            let stopped = try XCTUnwrap(f.journal.run(approval.runId))
            _ = try f.service.end(stopped, outcome: .stoppedLocally, reason: "stopped_by_owner", result: nil,
                                  at: Date(), journal: f.journal, waitForState: false)
            XCTAssertEqual(try f.journal.run(approval.runId)?.outcome, .stoppedLocally)
            try move(f, b, "stopped", 7, run: approval.runId)
            f.service.reconcileChannelResults()
            XCTAssertEqual(try f.journal.run(approval.runId)?.resultErased, true)
            XCTAssertNil(try f.journal.run(approval.runId)?.resultText)
            XCTAssertEqual(try f.journal.run(first.runId)?.resultText, first.resultText)
            XCTAssertEqual(try? Data(contentsOf: file), earlier)
            runner.inner.holds = false
            let c = try seed(f)
            XCTAssertTrue(try XCTUnwrap(f.service.channelThreadMemory(f.key, requestId: c, channel: channel)).contains("remembers 1 earlier request"))
            let third = try await finish(f, c)
            XCTAssertEqual(third.conversationId, first.conversationId)
            let args = try XCTUnwrap(runner.arguments.last), resume = try XCTUnwrap(args.firstIndex(of: "--resume"))
            XCTAssertEqual(args[resume + 1], first.conversationId)
            XCTAssertTrue(try Data(contentsOf: file).starts(with: earlier), "A's transcript survives B and is resumed by C")
        }
    }

    func testEndingOneRequestErasesOnlyItsDraftAndPublication() async throws {
        for state in ["declined", "cancelled", "stop_requested", "stopped", "stop_failed"] {
            let (f, runner) = try await fixture()
            let a = try seed(f), first = try await finish(f, a)
            let b = try seed(f), second = try await finish(f, b)
            try f.write("UPDATE requests SET publication = 'awaiting_publish'")
            let kept = try f.service.publishChannelResult(f.key, requestId: a, publish: true)
            let erased = try f.service.publishChannelResult(f.key, requestId: b, publish: true)
            let file = runner.transcript(first.conversationId), earlier = try Data(contentsOf: file)
            try move(f, b, state, 8, run: second.runId)
            f.service.reconcileChannelResults()
            XCTAssertEqual(try f.journal.run(first.runId)?.resultText, first.resultText, state)
            XCTAssertNil(try f.journal.run(second.runId)?.resultText, state)
            XCTAssertEqual(try f.journal.run(second.runId)?.resultErased, true, state)
            XCTAssertEqual(try f.journal.run(second.runId)?.channelRevoked, false, state)
            let commands = try f.store.outbox.commands()
            XCTAssertTrue(commands.contains { $0.commandId == kept.commandId }, state)
            XCTAssertFalse(commands.contains { $0.commandId == erased.commandId }, state)
            XCTAssertEqual(try? Data(contentsOf: file), earlier, state)
            await f.service.disconnect()
            f.service.reconcileChannelResults()
            XCTAssertEqual(try? Data(contentsOf: file), earlier, "Disconnect cannot turn a request erasure into a channel revocation")
            let (signedIn, _) = try await fixture(at: runner.projects.deletingLastPathComponent(), sessionId: "s-again")
            signedIn.service.reconcileChannelResults()
            XCTAssertEqual(try? Data(contentsOf: file), earlier, "the erasure marker survives a journal reopen")
        }
    }

    func testDisconnectAndSignInResumeTheJournalThreadOutsideTheSnapshotWindow() async throws {
        let (f, runner) = try await fixture()
        let a = try seed(f), first = try await finish(f, a)
        let file = runner.transcript(first.conversationId), earlier = try Data(contentsOf: file)
        try f.write("UPDATE requests SET publication = 'published', created_at = '2026-01-01T00:00:00Z'")
        await f.service.disconnect()
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.url.path))
        XCTAssertNil(f.service.channelThreadMemory(f.key, requestId: a, channel: channel))
        XCTAssertEqual(try Data(contentsOf: file), earlier)
        let (signedIn, resumed) = try await fixture(at: runner.projects.deletingLastPathComponent(), sessionId: "s-again")
        XCTAssertNil(try signedIn.store.calls.request(a), "the new snapshot omits old published requests")
        let b = try seed(signedIn, caller: CallJSON.anna)
        XCTAssertEqual(try lookup(signedIn, b), .known(conversation: first.conversationId))
        let model = ChatChannelOwnerModel(service: signedIn.service, key: signedIn.key, channel: channel)
        let memory = try XCTUnwrap(model.decisionText(signedIn.request(b)))
        XCTAssertTrue(memory.contains("remembers 1 earlier request of this thread by Boris"))
        try signedIn.write("UPDATE meta SET rights_in_doubt = 1")
        XCTAssertNil(model.decisionText(try signedIn.request(b)), "journal memory still enters through the channel gateway")
        try signedIn.write("UPDATE meta SET rights_in_doubt = 0")
        let second = try await finish(signedIn, b)
        XCTAssertEqual(second.conversationId, first.conversationId)
        let args = try XCTUnwrap(resumed.arguments.last), resume = try XCTUnwrap(args.firstIndex(of: "--resume"))
        XCTAssertEqual(args[resume + 1], first.conversationId)
        XCTAssertTrue(try Data(contentsOf: file).starts(with: earlier))
    }

    func testChannelRevocationErasesTheSharedTranscriptIncludingLateWrites() async throws {
        let (f, runner) = try await fixture()
        let first = try await finish(f, seed(f)), second = try await finish(f, seed(f))
        XCTAssertEqual(first.conversationId, second.conversationId)
        let file = runner.transcript(first.conversationId)
        // Revocation must also mark a run whose per-request result was
        // already erased; that run must not protect the UUID indefinitely.
        try move(f, second.requestId, "cancelled", 8, run: second.runId)
        f.service.reconcileChannelResults()
        XCTAssertEqual(try f.journal.run(second.runId)?.resultErased, true)
        XCTAssertEqual(try f.journal.run(second.runId)?.channelRevoked, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        try f.write("DELETE FROM channels")
        f.service.reconcileChannelResults()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        for run in [first, second] {
            XCTAssertEqual(try f.journal.run(run.runId)?.resultErased, true)
            XCTAssertEqual(try f.journal.run(run.runId)?.channelRevoked, true)
            XCTAssertNil(try f.journal.run(run.runId)?.resultText)
        }
        await f.service.disconnect()
        // Reopen the journal as after a process restart. A late writer must
        // still be removed without treating Disconnect itself as revocation.
        let (reopened, _) = try await fixture(at: runner.projects.deletingLastPathComponent(), sessionId: "s-again")
        await reopened.service.disconnect()
        try Data("late writer".utf8).write(to: file)
        reopened.service.reconcileChannelResults()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAnAccessibleJournalReferenceProtectsATranscriptFromRevocationRetries() async throws {
        let (f, runner) = try await fixture()
        let first = try await finish(f, seed(f)), second = try await finish(f, seed(f))
        let file = runner.transcript(first.conversationId), earlier = try Data(contentsOf: file)
        // A durable revocation marker and a still accessible reference to
        // the same UUID can coexist after rejoining. Never erase the latter.
        try await f.journal.queue.write { db in
            try db.execute(sql: "UPDATE runs SET channel_revoked = 1, result_erased = 1, result_text = NULL WHERE run_id = ?", arguments: [second.runId])
        }
        try f.write("DELETE FROM requests")
        f.service.reconcileChannelResults()
        XCTAssertEqual(try Data(contentsOf: file), earlier, "the live reference is in the journal, outside the request window")
        let c = try seed(f)
        XCTAssertEqual(try lookup(f, c), .known(conversation: first.conversationId))
        XCTAssertTrue(try XCTUnwrap(f.service.channelThreadMemory(f.key, requestId: c, channel: channel)).contains("remembers 1 earlier request"))
        await f.service.disconnect()
        let (reopened, _) = try await fixture(at: runner.projects.deletingLastPathComponent(), sessionId: "s-again")
        reopened.service.reconcileChannelResults()
        XCTAssertEqual(try Data(contentsOf: file), earlier)
        try reopened.write("DELETE FROM channels")
        reopened.service.reconcileChannelResults()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "the last accessible reference was revoked")
    }

    func testFullKeyAndFrozenScopeIsolateOtherThreadsAgentsAndGenerations() async throws {
        let (f, runner) = try await fixture()
        let a = try seed(f)
        let first = try await finish(f, a)
        let b = try seed(f)
        for (column, value) in [("kind", "personal"), ("org", "other"), ("agent_id", "other"),
                                ("channel_id", "other"), ("thread_root_id", "other")] {
            let kept = try await f.journal.queue.read { try String.fetchOne($0, sql: "SELECT \(column) FROM runs WHERE run_id = ?", arguments: [first.runId]) }
            try await f.journal.queue.write { try $0.execute(sql: "UPDATE runs SET \(column) = ? WHERE run_id = ?", arguments: [value, first.runId]) }
            XCTAssertEqual(try lookup(f, b), .unknown, "persisted run scope: \(column)")
            try await f.journal.queue.write { try $0.execute(sql: "UPDATE runs SET \(column) = ? WHERE run_id = ?", arguments: [kept, first.runId]) }
        }
        let otherThread = try seed(f, thread: UUID().uuidString)
        XCTAssertEqual(try lookup(f, otherThread), .unknown)
        let otherRun = try await finish(f, otherThread)
        XCTAssertNotEqual(otherRun.conversationId, first.conversationId)
        XCTAssertFalse(runner.arguments.last!.contains("--resume"))
        for id in [try seed(f, channel: "different-channel"), try seed(f, agent: UUID().uuidString)] {
            XCTAssertEqual(try lookup(f, id), .unknown)
        }
        let scope = ChatService.ThreadScope.channel(channelId: channel, rootId: thread)
        XCTAssertNil(f.service.latestConversation([a], key: f.key, agentId: "other-agent", scope: scope))
        for key in [ChatOrgKey(server: f.key.server, accountId: "other", orgId: f.key.orgId),
                    ChatOrgKey(server: f.key.server, accountId: f.key.accountId, orgId: "other"),
                    ChatOrgKey(server: try ChatServerAddress(parsing: "https://other.example.com"), accountId: f.key.accountId, orgId: f.key.orgId)] {
            try f.journal.finish(key, "g1")
            XCTAssertNil(f.service.latestConversation([a], key: key, agentId: CallJSON.agent, scope: scope))
        }
        for wrong in [ChatService.ThreadScope.channel(channelId: "other", rootId: thread), .channel(channelId: channel, rootId: "other"), .personal(initiator: CallJSON.boris)] {
            XCTAssertNil(f.service.latestConversation([a], key: f.key, agentId: CallJSON.agent, scope: wrong))
        }
        // Cache attribution cannot widen the scope saved in the approval.
        try f.write("UPDATE requests SET thread_root_id = 'other' WHERE request_id = ?", [a])
        let changed = try seed(f, thread: "other")
        XCTAssertEqual(try lookup(f, changed), .unknown)
        try f.write("UPDATE requests SET thread_root_id = ? WHERE request_id = ?", [thread, a])
        try f.journal.finish(f.key, "g2")
        try f.store.finishGeneration("g2")
        XCTAssertEqual(try lookup(f, b), .unknown)
        let fresh = try await finish(f, b)
        XCTAssertNotEqual(fresh.conversationId, first.conversationId)
        XCTAssertFalse(runner.arguments.last!.contains("--resume"))
    }

    func testOtherChannelAndOtherAgentStartTheirOwnConversations() async throws {
        let (f, runner) = try await fixture()
        let first = try await finish(f, seed(f))
        let otherChannel = UUID().uuidString.lowercased()
        try f.write("INSERT INTO channels (channel_id, team_id, name, archived, version, stamp) SELECT ?, team_id, 'other', 0, 1, 0 FROM channels WHERE channel_id = ?", [otherChannel, channel])
        try f.write("INSERT INTO agent_channels (channel_id, agent_id, owner_account_id, name, access, enabled, available) VALUES (?, ?, ?, 'billing', 'read', 1, 1)", [otherChannel, CallJSON.agent, f.key.accountId])
        let other = try await finish(f, seed(f, channel: otherChannel))
        XCTAssertNotEqual(first.conversationId, other.conversationId)
        XCTAssertFalse(runner.arguments.last!.contains("--resume"))
        f.agent.id = UUID()
        try f.assign()
        let agent = f.agent.id.uuidString.lowercased()
        try f.write("INSERT INTO agent_channels (channel_id, agent_id, owner_account_id, name, access, enabled, available) VALUES (?, ?, ?, 'second', 'read', 1, 1)", [channel, agent, f.key.accountId])
        let another = try await finish(f, seed(f, agent: agent))
        XCTAssertNotEqual(first.conversationId, another.conversationId)
        XCTAssertFalse(runner.arguments.last!.contains("--resume"))
    }

    // F6 (3): both Allow clicks precede the first process. B must stay in
    // approved before A starts and while it runs; the journal is written first.
    func testTwoAllowsWaitInApprovedThenResumeAndKeepTheFolderContinuation() async throws { try await twoAllows(firstCreates: true) }
    func testTwoAllowsWhoseFirstCreatedNoConversationStartAnew() async throws { try await twoAllows(firstCreates: false) }
    private func twoAllows(firstCreates: Bool) async throws {
        let (f, runner) = try await fixture()
        runner.inner.holds = true
        if !firstCreates { runner.inner.cannotStart = true }
        let a = try seed(f), b = try seed(f, caller: CallJSON.anna)
        let first = try await allow(f, a), second = try await allow(f, b)
        let frozen = second.paramsHash
        try move(f, a, "approved", 3)
        try move(f, b, "approved", 3)
        func start(_ id: String) async throws -> ChatActionResult { await f.owner.perform(.start, request: try f.request(id), key: f.key) }
        func starts(_ approval: ChatApproval) throws -> Int {
            try f.commands().filter { $0.type == "run.start" && $0.orderKey == ChatService.runKey(approval.runId) }.count
        }
        _ = try await start(a)
        _ = try await start(b)
        XCTAssertEqual(try starts(first), 1)
        XCTAssertEqual(try starts(second), 0)
        XCTAssertEqual(try f.request(b).state, .approved)
        XCTAssertTrue(runner.arguments.isEmpty)
        try move(f, a, "starting", 4, run: first.runId)
        let runningA = Task { try await start(a) }
        try await wait { runner.inner.waiting == 1 }
        XCTAssertTrue(try XCTUnwrap(f.service.channelThreadMemory(f.key, requestId: b, channel: channel)).contains("0 earlier requests"),
                      "an unfinished run is not selected as the thread's conversation")
        _ = try await start(b)
        XCTAssertEqual(try starts(second), 0)
        XCTAssertNil(try f.journal.run(second.runId))
        runner.inner.release()
        _ = try await runningA.value
        runner.inner.cannotStart = false
        try move(f, a, firstCreates ? "finished" : "failed_to_start", 7, run: first.runId)
        _ = try await start(b)
        XCTAssertEqual(try starts(second), 1)
        try move(f, b, "starting", 4, run: second.runId)
        let journal = f.journal
        runner.inspect = { request in
            XCTAssertEqual(try journal.run(second.runId)?.conversationId, request.sessionId, "persist before process")
        }
        let runningB = Task { try await start(b) }
        try await wait { runner.inner.waiting == 1 }
        let request = try XCTUnwrap(runner.inner.requests.last)
        XCTAssertEqual(request.resume, firstCreates)
        XCTAssertEqual(request.sessionId == (try f.journal.run(first.runId)?.conversationId), firstCreates)
        XCTAssertEqual(try f.journal.approval(second.id)?.paramsHash, frozen)
        XCTAssertNil(try f.journal.approval(second.id)?.voidAt)
        if firstCreates {
            XCTAssertNil(f.service.continueRun(b, folders: ["/tmp"]))
            f.service.launcher?.threadConversation = { _ in XCTFail("folder continuation must not look up another conversation"); return nil }
            runner.inner.release()
            try await wait { runner.inner.calls == 3 && runner.inner.waiting == 1 }
            XCTAssertEqual(runner.inner.requests.last?.sessionId, request.sessionId)
        }
        runner.inner.release()
        _ = try await runningB.value
    }

    // F6 (5): both a missing file at review and a loss after Allow are new
    // conversations. Memory counts reset to the conversation actually kept.
    func testMissingTranscriptWarnsAndStartsAnewEvenAfterAllow() async throws {
        for afterAllow in [false, true] {
            let (f, runner) = try await fixture()
            let a = try seed(f), first = try await finish(f, a)
            let b = try seed(f)
            let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: channel)
            let approval: ChatApproval
            if afterAllow { approval = try await allow(f, b) }
            else { approval = try await allowAfterDeleting() }
            func allowAfterDeleting() async throws -> ChatApproval {
                try FileManager.default.removeItem(at: runner.transcript(first.conversationId))
                XCTAssertTrue(try XCTUnwrap(model.decisionText(f.request(b))).contains("The earlier conversation was not found; the agent starts anew"))
                return try await allow(f, b)
            }
            if afterAllow { try FileManager.default.removeItem(at: runner.transcript(first.conversationId)) }
            try move(f, b, "starting", 4, run: approval.runId)
            let answer = try await XCTUnwrap(f.service.launcher).launch(approvalId: approval.id)
            let next = try XCTUnwrap(f.journal.run(approval.runId))
            XCTAssertNotEqual(next.conversationId, first.conversationId)
            XCTAssertFalse(runner.arguments.last!.contains("--resume"))
            XCTAssertTrue(answer.text.contains("started anew: the earlier conversation was not found"))
            XCTAssertEqual(next.resultText, answer.text)
            try move(f, b, "finished", 7, run: approval.runId)
            let c = try seed(f)
            XCTAssertTrue(try XCTUnwrap(model.decisionText(f.request(c))).contains("remembers 1 earlier request"))
        }
    }

    func testSuccessfulRunnerWithoutATranscriptDoesNotResumeAPhantomConversation() async throws {
        let (f, runner) = try await fixture()
        runner.writesTranscript = false
        let a = try seed(f), first = try await finish(f, a)
        runner.writesTranscript = true
        let b = try seed(f), second = try await finish(f, b)
        XCTAssertNotEqual(first.conversationId, second.conversationId)
        XCTAssertFalse(runner.arguments.last!.contains("--resume"))
        XCTAssertTrue(second.resultText?.contains("started anew") == true)
    }

    func testClosedGatewayHidesMemoryAndRejectsEvenAStaleOpenSession() async throws {
        for change in ["rights", "snapshot", "membership", "agent", "archive", "generation", "channel"] {
            let (f, _) = try await fixture()
            let a = try seed(f)
            _ = try await finish(f, a)
            let b = try seed(f)
            let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: channel)
            XCTAssertNotNil(model.decisionText(try f.request(b)))
            XCTAssertTrue(model.canOpenSession(a))
            let old = TeamUI.openTab
            var opened = false
            TeamUI.openTab = { _, _, _ in opened = true }
            defer { TeamUI.openTab = old }
            switch change {
            case "rights": try f.write("UPDATE meta SET rights_in_doubt = 1")
            case "snapshot": f.service.orgSessions[f.key]?.snapshotOwed = true
            case "membership": try f.write("DELETE FROM team_members WHERE account_id = ?", [f.key.accountId])
            case "agent": try f.write("DELETE FROM agent_channels")
            case "archive": try f.write("UPDATE channels SET archived = 1")
            case "generation": try f.journal.finish(f.key, "other-generation")
            default: try f.write("DELETE FROM channels")
            }
            XCTAssertNil(model.decisionText(try f.request(b)), change)
            XCTAssertFalse(model.canOpenSession(a), change)
            XCTAssertNotNil(model.openSession(a), change)
            XCTAssertFalse(opened, change)
        }
    }

    // F6 (4): execute the real tab command against a fork-aware stand-in,
    // so dropping --fork-session changes bytes and fails this check.
    func testOwnerChannelAndPersonalCopiesLeaveTheSharedFileByteForByte() async throws {
        let (f, runner) = try await fixture()
        let a = try seed(f), run = try await finish(f, a)
        let file = runner.transcript(run.conversationId)
        let before = try Data(contentsOf: file)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let script = bin.appendingPathComponent("claude")
        try Data(#"""
            #!/bin/sh
            if [ "$1" != "--resume" ]; then exit 1; fi
            if [ "$3" = "--fork-session" ]; then
              cp "$SHARED_TRANSCRIPT" "$FORK_TRANSCRIPT"
              printf 'private continuation\n' >> "$FORK_TRANSCRIPT"
            else
              printf 'private continuation\n' >> "$SHARED_TRANSCRIPT"
            fi
            """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let old = TeamUI.openTab
        defer { TeamUI.openTab = old }
        var commands: [String] = []
        var sharedFile = file
        TeamUI.openTab = { _, command, _ in
            commands.append(command)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/sh")
            child.arguments = ["-c", command]
            child.environment = ["PATH": bin.path + ":/usr/bin:/bin", "SHARED_TRANSCRIPT": sharedFile.path,
                                 "FORK_TRANSCRIPT": self.root.appendingPathComponent("fork.jsonl").path]
            do { try child.run(); child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 0) }
            catch { XCTFail(error.localizedDescription) }
        }
        let model = ChatChannelOwnerModel(service: f.service, key: f.key, channel: channel)
        XCTAssertNil(model.openSession(a))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("fork.jsonl").path))
        XCTAssertEqual(commands, ["claude --resume \(run.conversationId) --fork-session"])
        // F5 still denies channel IDs through ordinary personal Continue.
        f.calls.sessionFilesRoot = runner.projects
        f.calls.conversationVisibility = { .current(journalURL: f.journal.url) }
        f.calls.useServer(nil, key: nil)
        f.calls.serverMode = false
        func call(_ id: String) -> TeamCalls.Incoming {
            .init(id: "copy", peer: "fixture", peerName: "Fixture", agentId: f.agent.id, agentName: f.agent.name,
                  prompt: "copy", threadId: id, resume: true, origin: nil, receivedAt: Date(),
                  decideBy: Date().addingTimeInterval(60), state: .done)
        }
        XCTAssertNotNil(TeamUI.continueYourself(call(run.conversationId), in: f.calls))
        let personal = UUID().uuidString.lowercased()
        try before.write(to: runner.transcript(personal))
        sharedFile = runner.transcript(personal)
        XCTAssertNil(TeamUI.continueYourself(call(personal), in: f.calls))
        XCTAssertEqual(commands.last, "claude --resume \(personal) --fork-session")
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try Data(contentsOf: runner.transcript(personal)), before)
    }

    func testDeletedRootDoesNotChangeTheThreadKey() async throws {
        let (f, runner) = try await fixture()
        let a = try seed(f), first = try await finish(f, a)
        // Requests refer to the root's identity, regardless of its tombstone
        // or whether this Mac's message window still includes it.
        try f.write("DELETE FROM messages WHERE message_id = ?", [thread])
        let b = try seed(f)
        let second = try await finish(f, b)
        XCTAssertEqual(second.conversationId, first.conversationId)
        XCTAssertTrue(runner.arguments.last!.contains("--resume"))
    }
}
