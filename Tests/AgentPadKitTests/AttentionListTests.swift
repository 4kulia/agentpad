import XCTest
import GRDB
@testable import AgentPadKit

@MainActor
final class AttentionListTests: XCTestCase {
    private let scope = AttentionScope(server: "https://chat.example.com", account: "me", organization: "org", generation: "g")
    private func event(_ kind: AttentionKind, time: TimeInterval = 0, source: String = "test") -> AttentionEvent {
        .init(source: source, object: UUID().uuidString, kind: kind, destination: .connect,
              timestamp: Date(timeIntervalSince1970: time))
    }
    func testKindsPriorityAgeAlwaysSettingsAndCollapsedCriticalRows() {
        let included: [AttentionKind] = [.decision, .folder, .confirmation, .publicationReview, .version, .signIn, .input, .failure, .recovery]
        let excluded: [AttentionKind] = [.update, .account, .completion, .publication, .stopped, .reply, .program, .mention, .updateFailure, .updateInstalled]
        let events = (included + excluded).map { event($0) }
        let result = AttentionList.items(ledger: events, current: .init())
        XCTAssertEqual(result.count, included.count)
        XCTAssertEqual(result.map(\.tier), [0, 0, 0, 0, 0, 0, 1, 2, 2])
        XCTAssertEqual(AttentionList.visible(result, expanded: false).count, 7)
        XCTAssertEqual(AttentionList.visible(result, expanded: false, collapsed: true).count, 7)
        XCTAssertEqual(AttentionList.visible(result, expanded: true).count, 9)
        let off = AttentionList.items(ledger: events, current: .init(), settings: .init(approvals: false, mentions: false, dm: false))
        XCTAssertEqual(off.count, 6)
        let older = event(.input, time: 1), newer = event(.input, time: 2)
        XCTAssertEqual(AttentionList.items(ledger: [newer, older], current: .init()).map(\.id), [older.id, newer.id])
        XCTAssertTrue(AttentionList.items(ledger: [event(.failure, source: "link-failure"), event(.failure, source: "post-outcome")], current: .init()).isEmpty)
    }

    func testCurrentTerminalFailureDoesNotEraseHistoryAndExternalWaitIsIndependent() {
        let id = UUID(), episode = "incarnation:turn:3"
        let error = AttentionEvent(source: "terminal", object: id.uuidString, episode: episode, kind: .failure, destination: .terminal(id))
        let ledger = AttentionLedger(); ledger.upsert(error)
        var current = AttentionCurrent(terminals: [id: .init(episode: episode, failed: true)])
        XCTAssertEqual(AttentionList.items(ledger: ledger.events, current: current).count, 1)
        current.terminals[id]?.failed = false
        XCTAssertTrue(AttentionList.items(ledger: ledger.events, current: current).isEmpty)
        current.terminals[id]?.failed = true; current.terminals[id]?.episode = "new:turn:4"
        XCTAssertTrue(AttentionList.items(ledger: ledger.events, current: current).isEmpty)
        current.terminals = [:]
        XCTAssertTrue(AttentionList.items(ledger: ledger.events, current: current).isEmpty)
        XCTAssertEqual(ledger.events, [error])
        let own = AttentionEvent(source: "terminal", object: id.uuidString, kind: .input, destination: .terminal(id))
        let external = AttentionEvent(source: "external", object: "123:same-conversation", kind: .input, destination: .external("123:same-conversation"))
        XCTAssertEqual(AttentionList.items(ledger: [own, external], current: current).count, 2)
    }

    func testBothCallErrorSourcesRequireCurrentRequestAndJournalRun() {
        for source in ["run-outcome", "launch-help"] {
            let old = AttentionEvent(source: source, object: "old-request", episode: "run-1", kind: .failure,
                                     destination: .team(request: "old-request", outgoing: false), scope: scope)
            var current = AttentionCurrent(serverEvents: [old.id], currentRunEvents: [old.id])
            XCTAssertEqual(AttentionList.items(ledger: [old], current: current).count, 1)
            current.currentRunEvents = []
            XCTAssertTrue(AttentionList.items(ledger: [old], current: current).isEmpty)
            XCTAssertEqual(AttentionList.currentRunEventIDs([old], latestApprovals: ["old-request": "run-1"], scope: scope), [old.id])
            XCTAssertTrue(AttentionList.currentRunEventIDs([old], latestApprovals: ["new-request": "run-2"], scope: scope).isEmpty)
            XCTAssertTrue(AttentionList.currentRunEventIDs([old], latestApprovals: ["old-request": "retry"], scope: scope).isEmpty)
        }
    }

    func testFailedTurnWhileProcessStillAliveIsCurrentFailure() {
        let session = Session(engine: TestEngine(), currentDirectory: URL(fileURLWithPath: "/tmp"), agent: .claudeCode)
        session.activityState = .attention; session.attentionReason = .failure
        XCTAssertTrue(session.hasCurrentAttentionFailure)
        session.attentionReason = .input
        XCTAssertFalse(session.hasCurrentAttentionFailure)
        session.activityState = .running
        XCTAssertFalse(session.hasCurrentAttentionFailure)
        session.activityState = .idle; session.lastCommandExit = 1
        XCTAssertTrue(session.hasCurrentAttentionFailure)
    }

    func testFinishedSettingDefaultsOnAndOnlyCurrentTerminalTurnAppears() {
        XCTAssertTrue(AttentionListSettings.read([:]).finished)
        let values = AttentionListSettings(finished: false).persisted(over: ["future": "kept"])
        XCTAssertEqual(values["finished"] as? Bool, false)
        XCTAssertEqual(values["future"] as? String, "kept")
        XCTAssertFalse(AttentionListSettings.read(values).finished)
        XCTAssertNil(AttentionListSettings().persisted(over: values)["finished"])

        let id = UUID(), episode = "incarnation:turn:1"
        let finished = AttentionEvent(source: "terminal", object: id.uuidString, episode: episode,
                                      kind: .completion, destination: .terminal(id))
        var current = AttentionCurrent(terminals: [id: .init(episode: episode, failed: false, finished: true)])
        XCTAssertEqual(AttentionList.items(ledger: [finished], current: current).map(\.tier), [1])
        current.terminals[id]?.episode = "incarnation:turn:2"
        XCTAssertTrue(AttentionList.items(ledger: [finished], current: current).isEmpty)
        current.terminals[id]?.episode = episode
        current.terminals[id]?.finished = false
        XCTAssertTrue(AttentionList.items(ledger: [finished], current: current).isEmpty)
        current.terminals = [:]
        XCTAssertTrue(AttentionList.items(ledger: [finished], current: current).isEmpty)
        XCTAssertTrue(AttentionList.items(ledger: [event(.completion, source: "run-outcome")], current: current).isEmpty)
    }

    func testAggregateKeysOrderGateMuteAndPreferences() {
        let older = AttentionConversation(scope: scope, id: "one", title: "#one", count: 2, time: Date(timeIntervalSince1970: 1), firstMessage: "first", firstSequence: 1)
        var newer = older; newer.id = "two"; newer.time = Date(timeIntervalSince1970: 2)
        let current = AttentionCurrent(aggregateScope: scope)
        let rows = AttentionList.items(ledger: [], current: current, mentions: [older, newer], dms: [older])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first?.title, "#one")
        XCTAssertEqual(rows.first?.action, .mention(scope, channel: "two", message: "first", sequence: 1))
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        newer.muted = true
        XCTAssertTrue(AttentionList.items(ledger: [], current: current, dms: [newer]).isEmpty)
        XCTAssertTrue(AttentionList.items(ledger: [], current: .init(), mentions: [older], dms: [older]).isEmpty)
        XCTAssertTrue(AttentionList.items(ledger: [], current: current, mentions: [older], dms: [older], settings: .init(mentions: false, dm: false)).isEmpty)
        XCTAssertEqual(AttentionListSettings.read([:]), .init())
        XCTAssertTrue(AttentionListSettings().persisted().isEmpty)
        XCTAssertEqual(AttentionListSettings.read(AttentionListSettings(approvals: false).persisted()), .init(approvals: false))
    }

    func testDismissIsDurableAndDoesNotChangeBannerPolicy() throws {
        let suite = "attention-test-\(UUID())", error = event(.failure)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        NotificationDeliveryStore(defaults: defaults).update(error.id) { $0.hidden = true }
        let reopened = NotificationDeliveryStore(defaults: defaults)
        let hidden = Set(reopened.markers.filter { $0.value.hidden }.keys)
        XCTAssertTrue(AttentionList.items(ledger: [error], current: .init(), dismissed: hidden).isEmpty)
        XCTAssertTrue(AttentionPolicy.shouldDeliver(error, preferences: .init(), focused: false))
    }

    func testLatestLocalRequestUsesCreationThenIDNeverUpdateTime() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE requests (request_id TEXT, agent_id TEXT, owner_account_id TEXT, on_this_device INTEGER, created_at TEXT, updated_at TEXT)")
            try db.execute(sql: """
                INSERT INTO requests VALUES
                ('old', 'agent', 'me', 1, '2026-10-01', '2026-10-09'),
                ('new-a', 'agent', 'me', 1, '2026-10-08', '2026-10-08'),
                ('new-b', 'agent', 'me', 1, '2026-10-08', '2026-10-08'),
                ('other-device', 'agent', 'me', 0, '2026-10-10', '2026-10-10')
                """)
            XCTAssertEqual(try ChatAttention.latestLocalRequestIDs(db, account: "me"), ["new-b"])
        }
    }

    func testGateOpeningWithoutIdentityChangeStartsObservationAndClearsOnRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let key = ChatAttention.key(scope)!
        let store = try ChatStore.open(files: ChatFiles(directory: root), key: key).store
        try await store.queue.write { db in
            try db.execute(sql: "UPDATE meta SET me = 'me', generation = 'g', rights_in_doubt = 0, rights_session = 's', channels_served = 1")
            try db.execute(sql: "INSERT INTO teams (team_id, name, mine) VALUES ('t', 'Team', 1)")
            try db.execute(sql: "INSERT INTO channels (channel_id, team_id, name, archived, version, stamp) VALUES ('c', 't', 'General', 0, 1, 1)")
            try db.execute(sql: """
                INSERT INTO messages (message_id, channel_id, author_account_id, seq, created_at, has_fixed, has_mutable, mentions)
                VALUES ('first', 'c', 'other', 1, '2026-10-08T12:00:00Z', 1, 1, '["me"]'),
                       ('second', 'c', 'other', 2, '2026-10-08T13:00:00Z', 1, 1, '["me"]')
                """)
        }
        let model = AttentionAggregates()
        var gate = AttentionAggregates.Gate(scope: scope, session: "s", allowed: false)
        var opens = 0
        model.update(gate) { opens += 1; return store }
        XCTAssertEqual(opens, 0)
        gate.allowed = true
        model.update(gate) { opens += 1; return store }
        for _ in 0..<100 where model.mentions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(model.mentions.first?.count, 2)
        XCTAssertEqual(model.mentions.first?.firstMessage, "first")
        XCTAssertEqual(model.mentions.first?.time, ChatStore.date("2026-10-08T13:00:00Z"))
        XCTAssertEqual(model.mentions.first?.subjectID, "other")
        XCTAssertEqual(model.mentions.first?.subjectIsAgent, false)
        try await store.queue.write { db in
            try db.execute(sql: "UPDATE messages SET author_session_name = 'Legacy agent' WHERE message_id = 'first'")
        }
        for _ in 0..<100 where model.mentions.first?.subjectIsAgent != true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.mentions.first?.subjectID, "other")
        XCTAssertEqual(model.mentions.first?.subjectName, "Legacy agent")
        XCTAssertEqual(model.mentions.first?.subjectIsAgent, true)
        gate.allowed = false
        model.update(gate) { XCTFail("A closed gate must not access the database"); return store }
        XCTAssertTrue(model.mentions.isEmpty)
        gate.scope.generation = "next"
        model.update(gate) { XCTFail("Generation change with a closed gate"); return store }
        XCTAssertTrue(model.mentions.isEmpty)
    }
}
