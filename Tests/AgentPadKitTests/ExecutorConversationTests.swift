import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class ExecutorConversationTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("executor-conversations-\(UUID())")
    }

    override func tearDown() async throws {
        ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }

    func testExecutorConversationRemainsDeniedAndFilteredAfterJournalReset() async throws {
        for channel in [false, true] {
            let folder = root.appendingPathComponent(channel ? "channel" : "personal")
            let f = try await ChatChannelExecutionTests.Fixture(root: folder)
            let runner = RecordingRunner()
            let executor = try ExecutorFixture(root: folder, runner: runner, journal: f.journal)
            if channel { executor.request.channelId = UUID().uuidString.lowercased() }
            let approval = try executor.approve()
            let files = executor.files
            runner.onCall = { request in
                XCTAssertFalse(ChannelConversationFilter.current(journalURL: files.journalURL).allows(conversationId: request.sessionId),
                               "The executor must be excluded before its process can launch")
            }
            _ = try await executor.launcher.launch(approvalId: approval.id)
            let id = try XCTUnwrap(runner.requests.first?.sessionId)
            let caller = ChatLocalCaller(surface: UUID().uuidString.lowercased(), claudePID: 2, claudeStart: 3, signature: "Personal")
            XCTAssertThrowsError(try ChatPersonalAccess.require(.init(id), caller: caller, service: f.service))
            try f.service.resetJournal()
            XCTAssertEqual(try f.service.journal?.runs().count, 0)
            for conversation in [ChatPersonalAccess.Conversation(id.uppercased()), .init(UUID().uuidString, launchId: id)] {
                XCTAssertThrowsError(try ChatPersonalAccess.require(conversation, caller: caller, service: f.service)) {
                    XCTAssertEqual(($0 as? ChatSessionTools.Failure)?.code, "dm_not_allowed")
                }
            }
            XCTAssertFalse(ChannelConversationFilter.current(journalURL: files.journalURL).allows(conversationId: id.uppercased()))
            XCTAssertTrue(ChannelConversationFilter.current(journalURL: files.journalURL).allows(conversationId: UUID().uuidString))
            await f.service.disconnect()
        }
    }

    func testLegacyRunsSeedOnceWithoutLosingEarlierMarksAndSurviveResetAndCacheRemoval() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("chat"))
        try files.prepareDirectory()
        let legacy = try ChatDatabase.open(files.journalURL, migrator: ChatStoreMigrations.journal)
        let old = (0..<3).map { _ in UUID().uuidString.lowercased() }
        try await legacy.write { db in
            let approval = ChatApproval(id: "a", server: "s", accountId: "a", orgId: "o", requestId: "r", agentId: "agent",
                kind: "initial", params: "{}", paramsHash: "hash", runId: "run", startCommandId: "cmd", generation: "g", createdAt: Date())
            try approval.insert(db)
            for (id, kind) in zip(old, ["personal", "channel", "future-kind"]) {
                try ChatRunRecord(runId: UUID().uuidString, requestId: "r", approvalId: "a", agentId: "agent",
                    conversationId: id.uppercased(), startedAt: Date(), kind: kind).insert(db)
            }
        }
        try legacy.close()
        let markers = ExecutorConversations(files: files), earlier = UUID().uuidString.lowercased()
        try markers.record(earlier)
        let journal = try ChatJournal.open(files: files)
        try markers.record(earlier.uppercased())
        XCTAssertEqual(try markers.ids(), Set(old + [earlier]))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: markers.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try journal.queue.close()
        // A completed seed never needs to read even a closed legacy journal.
        XCTAssertNoThrow(try markers.seedOnce(from: journal.queue))
        let fresh = try ChatJournal.reset(files: files)
        XCTAssertTrue(try fresh.runs().isEmpty)
        let key = ChatOrgKey(server: try ChatServerAddress(parsing: "https://example.com"), accountId: "a", orgId: "o")
        files.removeCache(key)
        try fresh.queue.close()
        try FileManager.default.removeItem(at: files.journalURL)
        XCTAssertEqual(try ExecutorConversations(files: files).ids(), Set(old + [earlier]))
        let filter = ChannelConversationFilter.current(journalURL: files.journalURL)
        for id in old + [earlier] { XCTAssertFalse(filter.allows(conversationId: id.uppercased())) }
        XCTAssertTrue(filter.allows(conversationId: UUID().uuidString))
    }

    func testDamagedMarkerStoreDeniesPersonalAccessFilteringAndLaunch() async throws {
        let f = try await ChatChannelExecutionTests.Fixture(root: root)
        let runner = RecordingRunner()
        let executor = try ExecutorFixture(root: root, runner: runner, journal: f.journal)
        let approval = try executor.approve()
        let markers = ExecutorConversations(files: executor.files)
        try Data("damaged".utf8).write(to: markers.url)
        let id = UUID().uuidString
        let caller = ChatLocalCaller(surface: UUID().uuidString.lowercased(), claudePID: 2, claudeStart: 3, signature: "Personal")
        XCTAssertThrowsError(try ChatPersonalAccess.require(.init(id), caller: caller, service: f.service))
        XCTAssertFalse(ChannelConversationFilter.current(journalURL: executor.files.journalURL).allows(conversationId: id))
        do { _ = try await executor.launcher.launch(approvalId: approval.id); XCTFail("launched without durable provenance") }
        catch {}
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertTrue(try f.journal.runs().isEmpty)
        XCTAssertNil(try f.journal.approval(approval.id)?.consumedAt)
        await f.service.disconnect()
    }

    func testResetSeedsOldJournalBeforeItsFirstSuccessfulOpen() throws {
        let files = ChatFiles(directory: root.appendingPathComponent("chat"))
        try files.prepareDirectory()
        let legacy = try ChatDatabase.open(files.journalURL, migrator: ChatStoreMigrations.journal)
        let old = UUID().uuidString.lowercased()
        try legacy.write { db in
            let approval = ChatApproval(id: "a", server: "s", accountId: "a", orgId: "o", requestId: "r", agentId: "agent",
                kind: "initial", params: "{}", paramsHash: "hash", runId: "run", startCommandId: "cmd", generation: "g", createdAt: Date())
            try approval.insert(db)
            try ChatRunRecord(runId: "run", requestId: "r", approvalId: "a", agentId: "agent",
                conversationId: old.uppercased(), startedAt: Date(), kind: "personal").insert(db)
        }
        try legacy.close()
        let fresh = try ChatJournal.reset(files: files)
        XCTAssertTrue(try fresh.runs().isEmpty)
        XCTAssertTrue(try fresh.executorConversations.contains(old))
        XCTAssertFalse(ChannelConversationFilter.current(journalURL: files.journalURL).allows(conversationId: old))
        XCTAssertTrue(ChannelConversationFilter.current(journalURL: files.journalURL).allows(conversationId: UUID().uuidString))
    }

    func testUnreadableLegacyResetDeniesOldHistoryAfterReopenButAllowsNewHistory() throws {
        let files = ChatFiles(directory: root.appendingPathComponent("chat"))
        let projects = root.appendingPathComponent("projects")
        let old = UUID().uuidString.lowercased(), new = UUID().uuidString.lowercased(), undated = UUID().uuidString.lowercased()
        let before = Date().addingTimeInterval(-60), after = Date().addingTimeInterval(60)
        let formatter = ISO8601DateFormatter()
        func transcript(_ id: String, startedAt: Date?) throws -> AgentSessionRecord {
            let stamp = startedAt.map { ",\"timestamp\":\"\(formatter.string(from: $0))\"" } ?? ""
            let file = try SessionStoreFixtures.writeFile("\(id).jsonl", in: projects.appendingPathComponent("-project"), lines: [
                "{\"type\":\"user\",\"cwd\":\"/tmp\",\"message\":{\"content\":\"fixture\"}\(stamp)}",
                "{\"type\":\"assistant\",\"timestamp\":\"\(formatter.string(from: after))\"}"
            ], mtime: after)
            return try XCTUnwrap(AgentSessionScanner.claudeRecord(file: file, mtime: after))
        }
        let oldRecord = try transcript(old, startedAt: before)
        let newRecord = try transcript(new, startedAt: after)
        // No timestamp at all must not be mistaken for a new conversation.
        _ = try SessionStoreFixtures.writeFile("\(undated).jsonl", in: projects.appendingPathComponent("-project"),
            lines: [#"{"type":"user","cwd":"/tmp","message":{"content":"undated"}}"#])
        try files.prepareDirectory()
        try Data("unreadable legacy journal".utf8).write(to: files.journalURL)
        XCTAssertThrowsError(try ChatJournal.open(files: files))
        let service = ChatService(files: files, tokens: FakeTokenStore())
        service.claudeProjectsRoot = projects
        try service.resetJournal()
        let caller = ChatLocalCaller(surface: UUID().uuidString.lowercased(), claudePID: 2, claudeStart: 3, signature: "Personal")
        for _ in 0..<2 {
            for conversation in [ChatPersonalAccess.Conversation(old.uppercased()), .init(new, launchId: old),
                                 .init(undated), .init(UUID().uuidString)] {
                XCTAssertThrowsError(try ChatPersonalAccess.require(conversation, caller: caller, service: service)) {
                    XCTAssertEqual(($0 as? ChatSessionTools.Failure)?.code, "dm_not_allowed")
                }
            }
            XCTAssertNoThrow(try ChatPersonalAccess.require(.init(new), caller: caller, service: service))
            let filter = ChannelConversationFilter.current(journalURL: files.journalURL)
            XCTAssertEqual(filter.apply([oldRecord, newRecord]).map(\.conversationId), [new])
            XCTAssertEqual(AgentSessionScanner.scan(roots: [AgentTemplate.claudeCodeID: projects], visibility: filter).map(\.conversationId), [new])
            XCTAssertEqual(ClaudeSessionResume.resolve(old, root: projects, visibility: filter), .failure(.channelConversation))
            XCTAssertEqual(try ClaudeSessionResume.resolve(new, root: projects, visibility: filter).get(), new)
            XCTAssertNil(TeamSessionFiles.file(for: old, root: projects, visibility: filter))
            XCTAssertNotNil(TeamSessionFiles.file(for: new, root: projects, visibility: filter))
            try service.journal?.queue.close()
            let reopened = try ChatJournal.open(files: files)
            try reopened.queue.close()
            try service.resetJournal() // a fresh journal must never erase the incomplete seed
        }
        try service.journal?.queue.close()
        try FileManager.default.removeItem(at: files.journalURL)
        let withoutJournal = ChannelConversationFilter.current(journalURL: files.journalURL)
        XCTAssertEqual(withoutJournal.apply([oldRecord, newRecord]).map(\.conversationId), [new])
    }

    func testResetCannotReplaceOldJournalWithoutDurableExecutorProvenance() throws {
        let files = ChatFiles(directory: root.appendingPathComponent("chat"))
        try files.prepareDirectory()
        let bytes = Data("unreadable old journal".utf8)
        try bytes.write(to: files.journalURL)
        try Data("unwritable provenance".utf8).write(to: ExecutorConversations(files: files).url)
        XCTAssertThrowsError(try ChatJournal.reset(files: files))
        XCTAssertEqual(try Data(contentsOf: files.journalURL), bytes)
    }

    func testMarkedExecutorCanContinueOnlyThroughApprovalAndCannotBeForkSource() throws {
        let transcript = try ClaudeResumeFixture()
        let files = ChatFiles(directory: root.appendingPathComponent("chat"))
        try ExecutorConversations(files: files).record(transcript.id)
        let visibility = ChannelConversationFilter.current(journalURL: files.journalURL)
        let agent = TeamPublishedAgent(name: "executor", description: "", folder: root.path)
        var request = TeamRunRequest(agent: agent, prompt: "continue", sessionId: transcript.id, resume: true,
            callerName: "Peer", callerProject: nil, dmHistoryFiles: files)
        XCTAssertThrowsError(try ClaudeCodeRunner.arguments(for: request, sessionFilesRoot: transcript.root, visibility: visibility))
        request.isExecutorConversation = true
        let args = try ClaudeCodeRunner.arguments(for: request, sessionFilesRoot: transcript.root, visibility: visibility)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--resume")) + 1], transcript.id)
        request.agent.sessionId = transcript.id
        let fork = TeamRunRequest(agent: request.agent, prompt: "fork", sessionId: UUID().uuidString, resume: false,
            callerName: "Peer", callerProject: nil, isExecutorConversation: true, dmHistoryFiles: files)
        XCTAssertThrowsError(try ClaudeCodeRunner.arguments(for: fork, sessionFilesRoot: transcript.root, visibility: visibility))
    }

    func testRunnerMarksActualFreshConversationBeforeExecutionAndRefusesFailedWrite() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = try NativeVersionFixture.make(in: root)
        let files = ChatFiles(directory: root.appendingPathComponent("chat")), old = UUID().uuidString.lowercased()
        try ChatDMHistory(files: files).record(old)
        let request = TeamRunRequest(agent: TeamPublishedAgent(name: "executor", description: "", folder: root.path),
            prompt: "continue", sessionId: old, resume: true, callerName: "Peer", callerProject: nil, dmHistoryFiles: files)
        let markers = ExecutorConversations(files: files)
        let runner = ClaudeCodeRunner(fixturePath: binary.path)
        let started = Counter()
        _ = try await runner.run(request, onActivity: { _ in }, onProcessStarted: { _ in
            started.increment()
            let ids = try markers.ids()
            XCTAssertEqual(ids.count, 1)
            XCTAssertFalse(ids.contains(old), "The tainted ID was replaced before launch")
        })
        XCTAssertEqual(started.value, 1)
        try Data("damaged".utf8).write(to: markers.url)
        do {
            _ = try await runner.run(request, onActivity: { _ in }, onProcessStarted: { _ in started.increment() })
            XCTFail("launched without durable provenance")
        } catch {}
        XCTAssertEqual(started.value, 1)
    }
}
