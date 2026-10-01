import XCTest
@testable import KookyKit

/// AgentPad: the unified sessions list (own tabs + other terminals + recent)
/// and the "next session needing you" cycle.
@MainActor
final class UnifiedSessionsTests: XCTestCase {
    private func own(_ title: String, _ state: AgentMonitor.State, dir: String = "/p/a", conversation: String? = nil) -> AgentMonitor.Entry {
        AgentMonitor.Entry(
            id: UUID(), agent: .claudeCode, state: state, tabTitle: title,
            directory: URL(fileURLWithPath: dir), remoteHost: nil, tag: nil, conversationId: conversation
        )
    }

    private func external(_ id: String, _ status: ExternalAgentSession.Status, dir: String = "/p/b", since: TimeInterval = 0) -> ExternalAgentSession {
        ExternalAgentSession(
            pid: 1, sessionId: id, kind: "interactive", cwd: URL(fileURLWithPath: dir), name: id, status: status,
            statusSince: Date(timeIntervalSince1970: since), startedAt: nil
        )
    }

    private func record(_ id: String, title: String, dir: String = "/p/c", at: TimeInterval) -> AgentSessionRecord {
        AgentSessionRecord(
            agentId: AgentTemplate.claudeCodeID, conversationId: id, title: title,
            cwd: URL(fileURLWithPath: dir), lastActivity: Date(timeIntervalSince1970: at)
        )
    }

    func testLiveConversationsAreNotRepeatedUnderRecent() {
        let items = SessionListModel.items(
            own: [own("mine", .idle, conversation: "c-own")],
            external: [external("c-ext", .idle)],
            history: [record("c-own", title: "x", at: 1), record("c-ext", title: "y", at: 2), record("c-old", title: "z", at: 3)]
        )
        XCTAssertEqual(items.map(\.id).filter { $0.hasPrefix("rec:") }, ["rec:claude-code:c-old"])
    }

    func testStatusSectionsInOrderAndOwnBeforeExternal() {
        let items = SessionListModel.items(
            own: [own("own-wait", .attention), own("own-fail", .failed), own("own-run", .running)],
            external: [external("ext-wait", .waiting(reason: nil)), external("ext-idle", .idle)],
            history: [record("r", title: "old", at: 1)]
        )
        let sections = SessionListModel.byStatus(items)
        XCTAssertEqual(sections.map(\.title), ["Needs you", "Running", "Idle", "Recent"])
        XCTAssertEqual(sections[0].items.map(\.title), ["own-wait", "own-fail", "ext-wait"])
    }

    func testFilterKeepsAllLiveAndCapsRecentByDate() {
        let history = (0..<5).map { record("r\($0)", title: "t\($0)", at: TimeInterval($0)) }
        let items = SessionListModel.items(own: [own("live", .idle)], external: [], history: history)
        let shown = SessionListModel.filter(items, query: "", recentLimit: 2, searchLimit: 10)
        XCTAssertEqual(shown.map(\.title), ["live", "t4", "t3"])
    }

    func testSearchMatchesEveryWordInTitleOrPathIgnoringCaseAndAccents() {
        let items = SessionListModel.items(
            own: [],
            external: [external("a", .idle, dir: "/Users/x/billing")],
            history: [
                record("r1", title: "Отчёт за неделю", dir: "/Users/x/csm", at: 2),
                record("r2", title: "Login bug", dir: "/Users/x/billing", at: 1),
            ]
        )
        func titles(_ q: String) -> [String] {
            SessionListModel.filter(items, query: q, recentLimit: 0, searchLimit: 10).map(\.title)
        }
        XCTAssertEqual(titles("BILLING"), ["a", "Login bug"])
        XCTAssertEqual(titles("login billing"), ["Login bug"])
        XCTAssertEqual(titles("отчет"), ["Отчёт за неделю"])
        XCTAssertEqual(titles("nothing"), [])
    }

    func testProjectSectionsPutTheNeediestProjectFirst() {
        let items = SessionListModel.items(
            own: [own("calm", .idle, dir: "/p/calm")],
            external: [external("urgent", .waiting(reason: nil), dir: "/p/hot")],
            history: [record("r", title: "older", dir: "/p/hot", at: 1)]
        )
        let sections = SessionListModel.byProject(items)
        XCTAssertEqual(sections.map(\.title), ["/p/hot", "/p/calm"])
        XCTAssertEqual(sections[0].items.map(\.title), ["urgent", "older"])
    }

    func testWaitingTargetsAndCycling() {
        let mine = own("mine", .attention)
        let targets = AttentionCoordinator.waitingTargets(
            own: [mine, own("busy", .running)],
            external: [external("e1", .waiting(reason: nil)), external("e2", .idle)]
        )
        XCTAssertEqual(targets, [.own(mine.id), .external("1:e1")])
        XCTAssertEqual(AttentionCoordinator.next(after: nil, in: targets), .own(mine.id))
        XCTAssertEqual(AttentionCoordinator.next(after: targets[0].key, in: targets), .external("1:e1"))
        XCTAssertEqual(AttentionCoordinator.next(after: targets[1].key, in: targets), .own(mine.id))
        XCTAssertEqual(AttentionCoordinator.next(after: "ext:gone", in: targets), .own(mine.id))
        XCTAssertNil(AttentionCoordinator.next(after: nil, in: []))
    }

    func testTwoProcessesOnOneConversationCycleSeparately() {
        func ext(_ pid: pid_t) -> ExternalAgentSession {
            ExternalAgentSession(
                pid: pid, sessionId: "same", kind: "interactive", cwd: URL(fileURLWithPath: "/p"), name: nil,
                status: .waiting(reason: nil), statusSince: nil, startedAt: nil
            )
        }
        let targets = AttentionCoordinator.waitingTargets(own: [], external: [ext(1), ext(2)])
        XCTAssertEqual(targets.count, 2)
        XCTAssertEqual(AttentionCoordinator.next(after: targets[0].key, in: targets), targets[1])
        XCTAssertEqual(AttentionCoordinator.next(after: targets[1].key, in: targets), targets[0])
    }

    func testEpisodeKeyChangesOnlyWithANewWait() {
        var a = ExternalAgentSession(
            pid: 1, sessionId: "s", kind: "interactive", cwd: URL(fileURLWithPath: "/p"), name: nil,
            status: .waiting(reason: nil), statusSince: Date(timeIntervalSince1970: 10), startedAt: nil
        )
        let first = AttentionCoordinator.episodeKey(a)
        a.title = "renamed"
        XCTAssertEqual(AttentionCoordinator.episodeKey(a), first)
        a = ExternalAgentSession(
            pid: 1, sessionId: "s", kind: "interactive", cwd: URL(fileURLWithPath: "/p"), name: nil,
            status: .waiting(reason: nil), statusSince: Date(timeIntervalSince1970: 99), startedAt: nil
        )
        XCTAssertNotEqual(AttentionCoordinator.episodeKey(a), first)
    }

    func testExternalTreeRootRetiresWhenTheActiveWorkspaceChanges() async throws {
        let store = makeTestStore()
        let a = store.addWorkspace(workingDirectory: URL(fileURLWithPath: "/tmp/a"))
        let b = store.addWorkspace(workingDirectory: URL(fileURLWithPath: "/tmp/a"))
        store.activateWorkspace(a)
        let root = ExternalTreeRoot.for(store)
        root.show(external("x", .idle, dir: "/p/ext"))
        XCTAssertEqual(root.url?.path, "/p/ext")
        // Nothing reads `url` while we switch away and back (sidebar hidden).
        store.activateWorkspace(b)
        try await Task.sleep(for: .milliseconds(50))
        store.activateWorkspace(a)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(root.url, "coming back must not resurrect the external folder")
    }
}
