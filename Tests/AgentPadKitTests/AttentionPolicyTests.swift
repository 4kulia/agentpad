import XCTest
@testable import AgentPadKit

@MainActor
final class AttentionPolicyTests: XCTestCase {
    private func event(_ kind: AttentionKind) -> AttentionEvent {
        AttentionEvent(source: "policy", object: "one", kind: kind, destination: .terminal(UUID()))
    }
    func testEveryDecisionDeliversInFocusAndEveryOutcomeOnlyOutsideIt() {
        let decisions: [AttentionKind] = [.decision, .version, .folder, .publicationReview, .input, .recovery, .signIn, .confirmation, .update]
        let outcomes: [AttentionKind] = [.completion, .failure, .stopped, .publication, .mention, .reply, .account, .program, .updateFailure, .updateInstalled]
        for kind in decisions {
            XCTAssertTrue(AttentionPolicy.shouldDeliver(event(kind), preferences: .init(), focused: true), kind.rawValue)
        }
        for kind in outcomes {
            XCTAssertFalse(AttentionPolicy.shouldDeliver(event(kind), preferences: .init(), focused: true), kind.rawValue)
            XCTAssertTrue(AttentionPolicy.shouldDeliver(event(kind), preferences: .init(), focused: false), kind.rawValue)
            XCTAssertFalse(AttentionPolicy.shouldDeliver(event(kind), preferences: .init(), focused: false, live: false))
        }
    }
    func testEveryCategoryAndMasterDisableSystemDelivery() {
        for kind: AttentionKind in [.decision, .input, .completion, .failure, .publication, .mention, .reply, .account, .update, .program] {
            XCTAssertFalse(AttentionPolicy.shouldDeliver(event(kind), preferences: .init(enabled: false), focused: false))
            XCTAssertFalse(AttentionPolicy.shouldDeliver(event(kind), preferences: .init(disabled: [kind.category]), focused: false))
        }
        var notice = event(.decision); notice.actionInFlight = true
        XCTAssertFalse(AttentionPolicy.shouldDeliver(notice, preferences: .init(), focused: false))
    }
    func testFocusChangeRemovesOutcomeButDoesNotResolveDecision() {
        let ledger = AttentionLedger(); var focus = false
        ledger.isFocused = { _ in focus }
        ledger.upsert(event(.input)); ledger.upsert(AttentionEvent(source: "outcome", object: "two", kind: .completion, destination: .terminal(UUID())))
        focus = true; ledger.validateAll()
        XCTAssertEqual(ledger.pendingCount, 1); XCTAssertEqual(ledger.unreadCount, 0)
    }
    func testScopeAndEpisodeArePartOfStableIdentity() {
        let original = AttentionScope(server: "server-a", account: "account-a", organization: "org-a", generation: "g-a")
        let scopes = [original, .init(server: "server-b", account: "account-a", organization: "org-a", generation: "g-a"),
                      .init(server: "server-a", account: "account-b", organization: "org-a", generation: "g-a"),
                      .init(server: "server-a", account: "account-a", organization: "org-b", generation: "g-a"),
                      .init(server: "server-a", account: "account-a", organization: "org-a", generation: "g-b")]
        let ids = scopes.map { AttentionEvent(source: "request", object: "same", kind: .decision, destination: .connect, scope: $0).id }
        XCTAssertEqual(Set(ids).count, 5)
        XCTAssertNotEqual(AttentionEvent.identifier(["a:b", "c"]), AttentionEvent.identifier(["a", "b:c"]))
    }
    func testCatchupOutcomesAreHistoryAndActiveDecisionsStillCount() {
        let ledger = AttentionLedger()
        ledger.upsert(event(.completion), live: false)
        XCTAssertEqual(ledger.unreadCount, 0)
        ledger.upsert(AttentionEvent(source: "decision", object: "new", kind: .decision, destination: .connect), live: false)
        XCTAssertEqual(ledger.pendingCount, 1)
        ledger.clearHistory(); XCTAssertEqual(ledger.events.count, 1)
    }
    func testY2IdentityIncludesSelectedPathFileProfileVersionAndConfiguration() {
        let file = ClaudeExecutable.File(resolvedPath: "/bin/claude", device: 1, inode: 2, size: 3, modifiedSeconds: 4, modifiedNanoseconds: 5)
        func pending(path: String = "/selected", profile: TeamAccessProfile = .read, version: String = "2.1.1", configuration: String = "one") -> ClaudeVersionApprovals.Pending {
            .init(id: UUID(), executable: .init(selectedPath: path, file: file),
                  grant: .init(version: version, file: file, profile: profile, configuration: configuration), agentName: "name", callId: "request")
        }
        XCTAssertEqual(pending().attentionKey, pending().attentionKey, "separate runs share one approval")
        XCTAssertNotEqual(pending().attentionKey, pending(path: "/different").attentionKey)
        XCTAssertNotEqual(pending().attentionKey, pending(version: "2.2.0").attentionKey)
        XCTAssertNotEqual(pending().attentionKey, pending(configuration: "two").attentionKey)
    }
}


extension AttentionPolicyTests {
    func testNewWaitAfterResolutionIsANewEpisodeButSnapshotIsNot() {
        let episodes = AttentionEpisodes()
        XCTAssertEqual(episodes.begin("fingerprint"), "1")
        XCTAssertEqual(episodes.begin("fingerprint"), "1")
        episodes.reconcile(keeping: ["fingerprint"])
        XCTAssertEqual(episodes.begin("fingerprint"), "1")
        episodes.reconcile(keeping: [])
        XCTAssertEqual(episodes.begin("fingerprint"), "2")
    }
}


extension AttentionPolicyTests {
    func testLaunchDiagnosticsHaveOneActionableCategoryWithoutRawOutput() {
        XCTAssertEqual(ChatAttention.launchHelp(ClaudeLaunchDiagnostic(version: nil, exitCode: 1, output: "not authenticated SECRET", fallback: .spawn).failure), .signIn)
        XCTAssertEqual(ChatAttention.launchHelp(ClaudeLaunchDiagnostic(version: nil, exitCode: 1, output: "permission denied /secret", fallback: .spawn).failure), .recovery)
        XCTAssertNil(ChatAttention.launchHelp(.network))
        XCTAssertNil(ChatAttention.launchHelp(nil))
    }
}
