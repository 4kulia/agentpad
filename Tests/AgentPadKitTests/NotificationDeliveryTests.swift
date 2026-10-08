import XCTest
@testable import AgentPadKit

private final class CountingNotificationDefaults: UserDefaults, @unchecked Sendable {
    var writes = 0
    override func set(_ value: Any?, forKey key: String) {
        writes += 1
        super.set(value, forKey: key)
    }
}

@MainActor
final class RecordingNotificationCenter: NotificationCenterClient {
    var status: NotificationAuthorization = .authorized
    var authorizationRequests = 0
    var submitted: [NotificationPayload] = []
    var pending: Set<String> = []
    var delivered: Set<String> = []
    var removals: [String] = []
    var suspendAuthorization = false
    var suspendStatus = false
    var statusContinuations: [CheckedContinuation<NotificationAuthorization, Never>] = []
    var suspendAdd = false
    var authorizationContinuation: CheckedContinuation<Bool, Never>?
    var addContinuation: CheckedContinuation<Void, Never>?
    func authorization() async -> NotificationAuthorization {
        if suspendStatus { return await withCheckedContinuation { statusContinuations.append($0) } }
        return status
    }
    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        if suspendAuthorization { return await withCheckedContinuation { authorizationContinuation = $0 } }
        return status != .denied
    }
    func add(_ payload: NotificationPayload) async throws {
        submitted.append(payload); pending.insert(payload.id)
        if suspendAdd { await withCheckedContinuation { addContinuation = $0 } }
        pending.remove(payload.id); delivered.insert(payload.id)
    }
    func remove(_ ids: [String]) {
        removals += ids; pending.subtract(ids); delivered.subtract(ids)
    }
    func identifiers() async -> [String] { Array(pending.union(delivered)) }
}

@MainActor
final class NotificationDeliveryTests: XCTestCase {
    func testNewestFirstHistoryKeepsNewestDeliveryAndDoesNotRewriteEvictedOutcomes() async throws {
        let suite = "notify-history-\(UUID())"
        let defaults = try XCTUnwrap(CountingNotificationDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = AttentionLedger(metadata: NotificationDeliveryStore(defaults: defaults))
        let client = RecordingNotificationCenter()
        // Hold delivery until all 500 newest-first entries have been reconciled.
        let delivery = NotificationManager(client: client)
        ledger.delivery = delivery
        let history = (0..<500).reversed().map { index in
            AttentionEvent(source: "run-outcome", object: "run-\(index)", kind: .completion,
                           destination: .team(request: "run-\(index)", outgoing: false),
                           timestamp: Date(timeIntervalSince1970: Double(index)))
        }
        let wait = event("still-pending")
        ledger.upsert(wait)
        for notice in history { ledger.upsert(notice) }
        await delivery.drain()
        XCTAssertEqual(ledger.events.filter { !$0.kind.needsDecision }.map(\.id), Array(history.prefix(100)).map(\.id))
        XCTAssertTrue(client.delivered.contains(history[0].id), "newest outcome survives asynchronous isCurrent")
        XCTAssertEqual(ledger.pendingCount, 1)
        let writes = defaults.writes
        for _ in 0..<3 { for notice in history { ledger.upsert(notice) } }
        await delivery.drain()
        XCTAssertEqual(defaults.writes, writes, "old history must not be inserted, consumed and persisted every refresh")
        XCTAssertEqual(client.submitted.count, 101)
    }

    func testRestartReconcilesPersistedWaitsAbsentFromCurrentSources() async throws {
        let suite = "notify-resolved-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = AttentionLedger(metadata: NotificationDeliveryStore(defaults: defaults))
        let client = RecordingNotificationCenter(), manager = NotificationManager(client: client)
        old.delivery = manager
        let resolved = AttentionEvent(source: "block", object: "configuration", kind: .recovery, destination: .recovery(nil))
        let active = AttentionEvent(source: "block", object: "journal", kind: .recovery, destination: .recovery(nil))
        let outcome = event("history", kind: .failure)
        for notice in [resolved, active, outcome] { old.upsert(notice) }
        await manager.drain()
        client.pending.insert(resolved.id)
        let restored = AttentionLedger(metadata: NotificationDeliveryStore(defaults: defaults))
        restored.delivery = manager
        XCTAssertTrue(restored.events.isEmpty, "startup has only durable locators")
        restored.reconcile(source: "block", keeping: [active.id])
        restored.upsert(active)
        await manager.drain()
        XCTAssertFalse(client.pending.contains(resolved.id))
        XCTAssertFalse(client.delivered.contains(resolved.id))
        XCTAssertNil(restored.event(resolved.id))
        XCTAssertNil(NotificationDeliveryStore(defaults: defaults).markers[resolved.id]?.locator)
        XCTAssertTrue(client.delivered.contains(active.id))
        XCTAssertTrue(client.delivered.contains(outcome.id))
        XCTAssertEqual(client.submitted.count, 3, "an unchanged active wait is neither revoked nor delivered twice")
        restored.reconcile(source: "block", keeping: [])
        XCTAssertNil(restored.event(active.id))
        XCTAssertFalse(client.delivered.contains(active.id))
    }

    func event(_ episode: String = "1", kind: AttentionKind = .decision) -> AttentionEvent {
        AttentionEvent(source: "test", object: "request", episode: episode, kind: kind, destination: .team(request: "request", outgoing: false))
    }
    func setup() -> (AttentionLedger, NotificationManager, RecordingNotificationCenter) {
        let ledger = AttentionLedger(), client = RecordingNotificationCenter(), manager: NotificationManager
        manager = NotificationManager(client: client); ledger.delivery = manager
        return (ledger, manager, client)
    }
    func until(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1000 { if condition() { return }; await Task.yield() }
        XCTFail("notification continuation did not start")
    }
    func testEventSnapshotAndReconcileDeliverOneBannerAndNewEpisodeDeliversAnother() async {
        let (ledger, manager, client) = setup()
        for _ in 0..<5 { ledger.upsert(event()) }
        await manager.drain()
        ledger.upsert(event()); await manager.drain()
        XCTAssertEqual(client.submitted.count, 1)
        ledger.resolve(event().id); ledger.upsert(event("2")); await manager.drain()
        XCTAssertEqual(client.submitted.count, 2)
        XCTAssertEqual(client.delivered, [event("2").id])
    }
    func testResolutionDuringAuthorizationCannotResurrectNotification() async {
        let (ledger, manager, client) = setup()
        client.status = .unknown; client.suspendAuthorization = true
        let notice = event(); ledger.upsert(notice)
        await until { client.authorizationContinuation != nil }
        ledger.resolve(notice.id)
        client.authorizationContinuation?.resume(returning: true)
        await manager.drain()
        XCTAssertTrue(client.submitted.isEmpty)
        XCTAssertTrue(client.delivered.isEmpty)
        XCTAssertEqual(client.authorizationRequests, 1)
    }
    func testSimultaneousEventsShareTheStatusQueryAndPermissionPrompt() async {
        let (ledger, manager, client) = setup()
        client.status = .unknown; client.suspendStatus = true; client.suspendAuthorization = true
        for index in 1...3 { ledger.upsert(event(String(index))) }
        await until { !client.statusContinuations.isEmpty }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(client.statusContinuations.count, 1)
        client.suspendStatus = false
        for continuation in client.statusContinuations { continuation.resume(returning: .unknown) }
        await until { client.authorizationContinuation != nil }
        client.authorizationContinuation?.resume(returning: true)
        await manager.drain()
        XCTAssertEqual(client.authorizationRequests, 1)
        XCTAssertEqual(client.submitted.count, 3)
    }
    func testResolutionDuringAddRemovesBothPendingAndLateDelivered() async {
        let (ledger, manager, client) = setup()
        client.suspendAdd = true
        let notice = event(); ledger.upsert(notice)
        await until { client.addContinuation != nil }
        XCTAssertEqual(client.pending, [notice.id])
        ledger.resolve(notice.id)
        XCTAssertTrue(client.pending.isEmpty)
        client.addContinuation?.resume()
        await manager.drain()
        XCTAssertTrue(client.delivered.isEmpty)
        XCTAssertNil(ledger.metadata.markers[notice.id]?.delivered == true ? true : nil)
    }
    func testReplacementWaitsForRevokedAddBeforeSubmitting() async {
        let (ledger, manager, client) = setup()
        client.suspendAdd = true; let notice = event()
        ledger.upsert(notice); await until { client.addContinuation != nil }
        ledger.resolve(notice.id); ledger.upsert(notice)
        client.suspendAdd = false; client.addContinuation?.resume()
        await manager.drain()
        XCTAssertEqual(client.submitted.count, 2)
        XCTAssertEqual(client.delivered, [notice.id], "the late old callback cannot remove the new banner")
    }
    func testDeniedPermissionKeepsDecisionInInboxAndDoesNotPromptAgain() async {
        let (ledger, manager, client) = setup(); client.status = .denied
        ledger.upsert(event()); ledger.upsert(event("2")); await manager.drain()
        XCTAssertEqual(ledger.pendingCount, 2)
        XCTAssertTrue(client.submitted.isEmpty); XCTAssertEqual(client.authorizationRequests, 0)
        XCTAssertEqual(manager.status, .denied)
    }
    func testSettingsCanDeliverSuppressedLiveDecisionButNeverReplayOutcome() async {
        let (ledger, manager, client) = setup()
        var preferences = AttentionPreferences(enabled: false)
        ledger.preferences = { preferences }
        ledger.upsert(event()); ledger.upsert(event("outcome", kind: .completion)); await manager.drain()
        preferences.enabled = true; preferences.sound = false
        ledger.settingsChanged(); await manager.drain()
        XCTAssertEqual(client.submitted.map(\.id), [event().id])
        XCTAssertEqual(client.submitted.first?.sound, false)
        ledger.upsert(event("outcome", kind: .completion)); await manager.drain()
        XCTAssertEqual(client.submitted.count, 1)
    }
    func testReadDecisionSurvivesAndReadOutcomeIsRetracted() async {
        let (ledger, manager, client) = setup()
        ledger.upsert(event()); ledger.upsert(event("outcome", kind: .failure)); await manager.drain()
        ledger.markAllRead(); ledger.clearHistory()
        XCTAssertEqual(ledger.events.map(\.id), [event().id])
        XCTAssertEqual(ledger.pendingCount, 1); XCTAssertEqual(ledger.unreadCount, 0)
        XCTAssertEqual(client.delivered, [event().id])
    }
    func testLegacyDeliveredIDsAreRemovedAtStartup() async {
        let (_, manager, client) = setup()
        client.pending = ["chat:org:request:x", "old-team"]
        client.delivered = ["old-uuid", event().id]
        await manager.reconcile(keeping: [event().id])
        XCTAssertTrue(client.pending.isEmpty); XCTAssertEqual(client.delivered, [event().id])
    }
    func testMessagePublicationAndMentionShareOneBannerInEitherOrder() async {
        for kinds: [AttentionKind] in [[.publication, .mention], [.mention, .publication], [.reply, .mention]] {
            let (ledger, manager, client) = setup()
            for kind in kinds { ledger.upsert(event("message", kind: kind)); await manager.drain() }
            XCTAssertEqual(client.submitted.count, 1)
            XCTAssertEqual(ledger.events.first?.kind, .mention)
        }
    }
    func testRestartPreservesDedupeAndLocatorsWithoutContent() async throws {
        let suite = "notify-tests-\(UUID())", defaults: UserDefaults
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = RecordingNotificationCenter(), manager = NotificationManager(client: RecordingNotificationCenter())
        let first = AttentionLedger(metadata: NotificationDeliveryStore(defaults: defaults)); first.delivery = manager
        var notice = event(); notice.localTitle = "PRIVATE TITLE"; notice.localBody = "PRIVATE PATH"
        first.upsert(notice); await manager.drain()
        let restored = AttentionLedger(metadata: NotificationDeliveryStore(defaults: defaults))
        let nextManager = NotificationManager(client: client); restored.delivery = nextManager
        restored.upsert(notice); await nextManager.drain()
        XCTAssertTrue(client.submitted.isEmpty)
        let stored = try XCTUnwrap(defaults.data(forKey: "AgentPad.notificationMetadata.v1"))
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("PRIVATE"))
        XCTAssertEqual(restored.event(notice.id)?.destination, notice.destination)
    }
    func testAllChannelPayloadFieldsAreContentFree() async throws {
        let (ledger, manager, client) = setup()
        for kind: AttentionKind in [.decision, .folder, .publicationReview, .completion, .failure, .publication, .mention, .reply] {
            var notice = AttentionEvent(source: "channel", object: kind.rawValue, kind: kind,
                destination: .channel("secret-channel", request: "secret-request"),
                scope: .init(server: "https://secret-server", account: "secret-account", organization: "secret-org", generation: "secret-generation"))
            notice.localTitle = "secret name"; notice.localBody = "secret prompt and /private/folder"
            ledger.upsert(notice)
        }
        await manager.drain()
        XCTAssertEqual(client.submitted.count, 8)
        for payload in client.submitted {
            XCTAssertFalse(payload.title.contains("secret")); XCTAssertEqual(payload.body, "")
            XCTAssertFalse(payload.id.contains("secret")); XCTAssertEqual(payload.category, "attention.open")
            XCTAssertEqual(payload.userInfo, ["locator": payload.id])
        }
    }
}
