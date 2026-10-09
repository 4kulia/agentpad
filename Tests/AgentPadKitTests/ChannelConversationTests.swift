import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class ChannelConversationTests: XCTestCase {
    private var root: URL!
    private var journal: ChatJournal!
    private let channel = "aa000000-0000-4000-8000-000000000001"
    private let personal = "aa000000-0000-4000-8000-000000000002"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("channel-conversations-\(UUID().uuidString)")
        journal = try ChatJournal.open(files: ChatFiles(directory: root.appendingPathComponent("chat")))
        for (id, kind) in [(channel, "channel")] {
            let approval = ChatApproval(id: UUID().uuidString, server: "https://chat.example.com", accountId: "fixture", orgId: "fixture",
                requestId: UUID().uuidString, agentId: "fixture", kind: "initial", params: "{}", paramsHash: "fixture",
                runId: UUID().uuidString, startCommandId: UUID().uuidString, generation: "g1", createdAt: Date())
            try journal.insert(approval)
            let run = ChatRunRecord(runId: approval.runId, requestId: approval.requestId, approvalId: approval.id,
                                    agentId: "fixture", conversationId: id, startedAt: Date(), kind: kind)
            try await journal.queue.write { try run.insert($0) }
        }
    }

    override func tearDown() async throws {
        journal = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func visibility() -> ChannelConversationFilter { .current(journalURL: journal.url) }
    private var projects: URL { root.appendingPathComponent("projects") }

    private func transcript(_ id: String, project: String = "-p", title: String = "fixture question") throws -> URL {
        let folder = projects.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(id).jsonl")
        let bytes = try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": root.path, "message": ["content": title]])
        try (bytes + Data("\n".utf8)).write(to: file)
        return file
    }

    private func record(_ id: String) -> AgentSessionRecord {
        AgentSessionRecord(agentId: AgentTemplate.claudeCodeID, conversationId: id, title: "fixture", cwd: root, lastActivity: Date())
    }

    func testJournalFiltersChannelHistoryAndAllDirectReadersWithoutACache() async throws {
        _ = try transcript(channel)
        let personalFile = try transcript(personal)
        for erased in [false, true] {
            if erased { try await journal.queue.write { try $0.execute(sql: "UPDATE runs SET result_erased = 1, outcome = 'finished'") } }
            let policy = visibility()
            XCTAssertFalse(policy.allows(conversationId: channel.uppercased()))
            XCTAssertTrue(policy.allows(conversationId: personal))
            XCTAssertTrue(policy.allows(agentId: AgentTemplate.codex.id, conversationId: channel))
            let records = AgentSessionScanner.scan(roots: [AgentTemplate.claudeCodeID: projects], visibility: policy)
            XCTAssertEqual(records.map(\.conversationId), [personal])
            XCTAssertNil(AgentSessionScanner.findRecord(agentId: AgentTemplate.claudeCodeID, conversationId: channel, root: projects, visibility: policy))
            XCTAssertEqual(AgentSessionScanner.findRecord(agentId: AgentTemplate.claudeCodeID, conversationId: personal, root: projects, visibility: policy)?.conversationId, personal)
            XCTAssertNil(ExternalSessionSource.transcript(for: channel, under: projects, visibility: policy))
            XCTAssertEqual(ExternalSessionSource.transcript(for: personal, under: projects, visibility: policy)?.resolvingSymlinksInPath().path, personalFile.resolvingSymlinksInPath().path)
            XCTAssertNil(TeamSessionFiles.file(for: channel, root: projects, visibility: policy))
            XCTAssertEqual(TeamSessionFiles.file(for: personal, root: projects, visibility: policy)?.resolvingSymlinksInPath().path, personalFile.resolvingSymlinksInPath().path)
        }
    }

    func testUnreadableJournalFailsClosedButAbsentJournalAndOtherAgentsWork() throws {
        let missing = root.appendingPathComponent("missing.sqlite")
        XCTAssertTrue(ChannelConversationFilter.current(journalURL: missing).allows(conversationId: personal))
        try Data("damaged database".utf8).write(to: missing)
        let policy = ChannelConversationFilter.current(journalURL: missing)
        XCTAssertFalse(policy.allows(conversationId: personal))
        XCTAssertTrue(policy.allows(agentId: AgentTemplate.codex.id, conversationId: personal))
    }

    func testCachedHistoryAndUnifiedListFilterStaleRecordsAndLiveSessions() async throws {
        let history = AgentSessionHistory()
        let stale = [record(channel), record(personal)]
        history.scan = { stale }
        history.visibility = { self.visibility() }
        history.refresh(force: true)
        while history.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(history.records.map(\.conversationId), [personal])
        let external = ExternalAgentSession(pid: 1, sessionId: channel, kind: nil, cwd: root, name: "private", status: .idle, statusSince: nil, startedAt: nil)
        let own = AgentMonitor.Entry(id: UUID(), agent: .claudeCode, state: .idle, tabTitle: "private", directory: root,
                                     remoteHost: nil, tag: nil, conversationId: channel)
        XCTAssertEqual(SessionListModel.items(own: [own], external: [external], history: stale, visibility: visibility()).map(\.title), ["fixture"])
    }

    func testResumeAndOpenSessionRejectAChannelIdBeforeCreatingOrRevealingATab() throws {
        _ = try transcript(personal)
        let store = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() }, optionsProvider: { _ in nil })
        store.conversationVisibility = { self.visibility() }
        store.claudeProjectsRoot = projects
        let before = store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.count
        XCTAssertEqual(WorkspaceStore.resumeRefusal(agentId: AgentTemplate.claudeCodeID, conversationId: channel, options: { _ in nil }, visibility: visibility()), .channelConversation)
        for id in [channel, channel.uppercased()] {
            guard case .failure(let refusal) = store.resumeAgentSession(record(id)) else { return XCTFail("channel resumed") }
            XCTAssertEqual(refusal, .channelConversation)
        }
        XCTAssertEqual(store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.count, before)
        let session = try store.resumeAgentSession(record(personal)).get()
        let monitor = AgentMonitor()
        monitor.storesProvider = { [store] }
        monitor.conversationVisibility = { self.visibility() }
        XCTAssertTrue(monitor.entries.contains { $0.id == session.id })
        session.conversationId = channel // a stale tab from an earlier client
        XCTAssertFalse(monitor.entries.contains { $0.id == session.id })
        XCTAssertNil(store.findOpenConversation(agentId: AgentTemplate.claudeCodeID, conversationId: channel))
        let restored = store.localSpawn(template: .claudeCode, cwd: root, conversationId: channel, forceResume: true).session
        XCTAssertNil(restored.resumedConversationId, "automatic restoration cannot bypass the filter")
    }

    func testExternalMonitorAndMoveHereRejectChannelSessionsBeforeReadingTitlesOrSignalling() async {
        let monitor = ExternalSessionMonitor()
        monitor.conversationVisibility = { self.visibility() }
        let session = ExternalAgentSession(pid: 100, sessionId: channel, kind: "interactive", cwd: root, name: "private",
            status: .idle, statusSince: nil, startedAt: nil, processStart: 42)
        monitor.snapshotProvider = { [session] }
        var probed = false
        monitor.processInfo = { _ in probed = true; return nil }
        await monitor.refresh()
        XCTAssertTrue(monitor.sessions.isEmpty)
        XCTAssertFalse(probed)
        let store = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() }, optionsProvider: { _ in nil })
        guard case .failure(.resumeRefused) = await monitor.takeOver(session, into: store) else { return XCTFail("channel takeover admitted") }
        XCTAssertFalse(probed)
    }

    func testResumeRequiresAnExistingFullIdEvenWithAWorkingDirectory() throws {
        _ = try transcript(personal)
        _ = try transcript(channel)
        let store = makeTestStore(claudeProjectsRoot: projects)
        store.conversationVisibility = { self.visibility() }
        let tabsBefore = store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.map(\.id)
        let activeBefore = store.activeWorkspaceId
        let invalid = ["billing", String(channel.prefix(8)), "", " \(personal)",
                       personal.replacingOccurrences(of: "-", with: "")]
        for id in invalid + [UUID().uuidString, channel.uppercased()] {
            guard case .failure(let refusal) = store.resumeAgentSession(agentId: AgentTemplate.claudeCodeID, conversationId: id, cwd: root)
            else { XCTFail("resumed unverified id: \(id)"); continue }
            XCTAssertFalse(refusal.message(agentId: AgentTemplate.claudeCodeID, conversationId: id).isEmpty)
            if invalid.contains(id) { XCTAssertEqual(refusal, .claudeResume(.fullIdRequired)) }
        }
        XCTAssertEqual(store.workspaces.flatMap { $0.root.allPanes.flatMap(\.tabs) }.map(\.id), tabsBefore)
        XCTAssertEqual(store.activeWorkspaceId, activeBefore)
        let session = try store.resumeAgentSession(agentId: AgentTemplate.claudeCodeID, conversationId: personal.uppercased(), cwd: root).get()
        XCTAssertEqual(session.resumedConversationId, personal)
        XCTAssertEqual((session.engine as? TestEngine)?.startedConfigs.last?.environment["AGENTPAD_AGENT"], "claude --resume \(personal)")
        try FileManager.default.removeItem(at: projects)
        guard case .failure(.claudeResume(.notFound)) = store.resumeAgentSession(record(personal)) else {
            return XCTFail("a stale History row must not resume a deleted session")
        }
        XCTAssertNil(store.findOpenConversation(agentId: AgentTemplate.claudeCodeID, conversationId: personal))
    }

    func testExactResumeWorksBeyondHistoryCapAndKeepsTheVerifiedSpelling() throws {
        let file = try transcript(personal)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        for _ in 0...AgentSessionScanner.perAgentCap { _ = try transcript(UUID().uuidString.lowercased()) }
        XCTAssertFalse(AgentSessionScanner.scan(roots: [AgentTemplate.claudeCodeID: projects], visibility: visibility()).contains { $0.conversationId == personal })
        XCTAssertEqual(try ClaudeSessionResume.resolve(personal.uppercased(), root: projects, visibility: visibility()).get(), personal)
        XCTAssertEqual(AgentSessionScanner.findRecord(agentId: AgentTemplate.claudeCodeID, conversationId: personal.uppercased(), root: projects, visibility: visibility())?.conversationId, personal)
    }

    func testRestorationAndCustomClaudeCannotLaunchSearchOrMissingSessions() throws {
        _ = try transcript(personal)
        _ = try transcript(channel)
        let custom = AgentTemplate.fromCustom(CustomAgentData(id: "custom-claude", baseAgentId: AgentTemplate.claudeCodeID))
        let store = makeTestStore(claudeProjectsRoot: projects)
        store.conversationVisibility = { self.visibility() }
        for template in [AgentTemplate.claudeCode, custom] {
            for (id, refusal) in [("billing", ClaudeSessionResume.Refusal.fullIdRequired), (String(channel.prefix(8)), .fullIdRequired),
                                  (UUID().uuidString, .notFound), (channel, .channelConversation)] {
                let session = store.localSpawn(template: template, cwd: root, conversationId: id, forceResume: true).session
                XCTAssertNil(session.resumedConversationId)
                XCTAssertEqual((session.engine as? TestEngine)?.startedConfigs.last?.environment["AGENTPAD_AGENT"], refusal.shellCommand)
            }
            let config = template.makeSessionConfig(resumeId: personal.uppercased(), claudeProjectsRoot: projects, visibility: visibility())
            XCTAssertEqual(config.environment["AGENTPAD_AGENT"], "claude --resume \(personal)")
        }
    }

    func testTeamRunnerChecksResumeForkSourcesAndNewSessionIds() throws {
        _ = try transcript(personal)
        _ = try transcript(channel)
        let agent = TeamPublishedAgent(name: "fixture", description: "", folder: root.path)
        func request(_ id: String, resume: Bool) -> TeamRunRequest {
            TeamRunRequest(agent: agent, prompt: "fixture", sessionId: id, resume: resume, callerName: "Fixture", callerProject: nil)
        }
        for id in ["billing", String(channel.prefix(8)), UUID().uuidString, channel] {
            XCTAssertThrowsError(try ClaudeCodeRunner.arguments(for: request(id, resume: true), sessionFilesRoot: projects, visibility: visibility()))
            var fork = request(UUID().uuidString, resume: false)
            fork.agent.sessionId = id
            XCTAssertThrowsError(try ClaudeCodeRunner.arguments(for: fork, sessionFilesRoot: projects, visibility: visibility()))
        }
        XCTAssertThrowsError(try ClaudeCodeRunner.arguments(for: request("billing", resume: false), sessionFilesRoot: projects, visibility: visibility()))
        XCTAssertThrowsError(try ClaudeCodeRunner.arguments(for: request(channel, resume: false), sessionFilesRoot: projects, visibility: visibility()))
        let args = try ClaudeCodeRunner.arguments(for: request(personal.uppercased(), resume: true), sessionFilesRoot: projects, visibility: visibility())
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--resume")) + 1], personal)
        var internalChannel = request(channel, resume: true)
        internalChannel.isExecutorConversation = true
        let channelArgs = try ClaudeCodeRunner.arguments(for: internalChannel, sessionFilesRoot: projects, visibility: visibility())
        XCTAssertEqual(channelArgs[try XCTUnwrap(channelArgs.firstIndex(of: "--resume")) + 1], channel)
        internalChannel.agent.sessionId = channel
        let fork = TeamRunRequest(agent: internalChannel.agent, prompt: "fixture", sessionId: UUID().uuidString, resume: false,
                                  callerName: "Fixture", callerProject: nil, isExecutorConversation: true)
        XCTAssertThrowsError(try ClaudeCodeRunner.arguments(for: fork, sessionFilesRoot: projects, visibility: visibility()), "even channel runs cannot fork channel transcripts")
    }

    func testMoveHereRejectsSearchAndUnknownIdBeforeProbingTheProcess() async {
        let monitor = ExternalSessionMonitor()
        monitor.conversationVisibility = { self.visibility() }
        var probed = false
        monitor.processInfo = { _ in probed = true; return nil }
        let store = makeTestStore(claudeProjectsRoot: projects)
        for id in ["billing", String(channel.prefix(8)), UUID().uuidString] {
            let session = ExternalAgentSession(pid: 100, sessionId: id, kind: "interactive", cwd: root, name: "fixture",
                status: .idle, statusSince: nil, startedAt: nil, processStart: 42)
            guard case .failure(.resumeRefused) = await monitor.takeOver(session, into: store) else {
                XCTFail("unverified takeover admitted: \(id)"); continue
            }
        }
        XCTAssertFalse(probed)
    }

    func testTranscriptErasureUsesHistoryLayoutBeyondItsCapAndRejectsTraversalAndSymlinkedProjects() throws {
        let file = try transcript(channel, project: "not-a-derived-cwd")
        let neighbor = try transcript(personal)
        XCTAssertTrue(AgentSessionScanner.isRemovableClaudeTranscript(file, conversationId: channel, root: projects))
        XCTAssertFalse(AgentSessionScanner.isRemovableClaudeTranscript(neighbor, conversationId: channel, root: projects))
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        for _ in 0...AgentSessionScanner.perAgentCap { _ = try transcript(UUID().uuidString) }
        XCTAssertEqual(AgentSessionScanner.claudeTranscript(conversationId: channel, root: projects)?.resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
        AgentSessionScanner.eraseClaudeTranscript(conversationId: "../\(personal)", root: projects)
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.path))
        AgentSessionScanner.eraseClaudeTranscript(conversationId: channel.uppercased(), root: projects)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbor.path))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("\(channel).jsonl")
        try Data("outside".utf8).write(to: target)
        XCTAssertFalse(AgentSessionScanner.isRemovableClaudeTranscript(target, conversationId: channel, root: projects))
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("escape"), withDestinationURL: outside)
        XCTAssertFalse(AgentSessionScanner.isRemovableClaudeTranscript(projects.appendingPathComponent("escape/\(channel).jsonl"), conversationId: channel, root: projects))
        AgentSessionScanner.eraseClaudeTranscript(conversationId: channel, root: projects)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }
}
