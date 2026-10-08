import XCTest
@testable import AgentPadKit

@MainActor
final class UpdateNotificationTests: XCTestCase {
    func testNewerBuildReplacesTheUnresolvedOlderReminder() {
        let ledger = AttentionLedger(), updates: UpdateAttention
        updates = UpdateAttention(ledger: ledger)
        updates.available("200", manual: false)
        updates.available("201", manual: false)
        XCTAssertEqual(ledger.pendingCount, 1)
        XCTAssertEqual(ledger.events.first?.destination, .update("201"))
    }
    func testScheduledVersionDeliversOnceAndLaterClosesIt() async {
        let ledger = AttentionLedger(), client = RecordingNotificationCenter()
        let manager = NotificationManager(client: client); ledger.delivery = manager
        let updates = UpdateAttention(ledger: ledger)
        updates.available("200", manual: false); updates.available("200", manual: false)
        await manager.drain()
        XCTAssertEqual(client.submitted.count, 1); XCTAssertEqual(ledger.pendingCount, 1)
        updates.viewed(); XCTAssertEqual(ledger.pendingCount, 1, "viewing alone is not a choice")
        updates.chose(.later); XCTAssertEqual(ledger.pendingCount, 0)
        XCTAssertTrue(client.delivered.isEmpty)
        updates.available("200", manual: false); await manager.drain()
        XCTAssertTrue(ledger.events.isEmpty); XCTAssertEqual(client.submitted.count, 1)
        updates.available("201", manual: false); await manager.drain()
        XCTAssertEqual(client.submitted.count, 2)
    }
    func testManualCheckHasNoSecondBannerAndSkipRetractsAvailable() async {
        let ledger = AttentionLedger(), client = RecordingNotificationCenter()
        let manager = NotificationManager(client: client); ledger.delivery = manager
        let updates = UpdateAttention(ledger: ledger)
        updates.available("200", manual: true); await manager.drain()
        XCTAssertEqual(ledger.pendingCount, 1); XCTAssertTrue(client.submitted.isEmpty)
        updates.chose(.skip); XCTAssertTrue(ledger.events.isEmpty)
    }
    func testInstallFailureIsAnOutcomeNotInstallationSuccess() async {
        let ledger = AttentionLedger(), updates: UpdateAttention
        updates = UpdateAttention(ledger: ledger)
        updates.available("200", manual: true); updates.chose(.install)
        XCTAssertTrue(updates.installing); XCTAssertEqual(ledger.pendingCount, 0)
        updates.failed(); updates.failed()
        XCTAssertEqual(ledger.events.count, 1)
        XCTAssertEqual(ledger.events.first?.kind, .updateFailure)
        let installId = ledger.events[0].id
        updates.beginCheck(); updates.failed()
        XCTAssertEqual(ledger.events.count, 2)
        XCTAssertNotEqual(installId, ledger.events[0].id, "check failure and install failure are different phases")
    }
    func testOnlyRunningNewBundleConfirmsInstall() throws {
        let suite = "updates-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = AttentionLedger(), updates = UpdateAttention(ledger: AttentionLedger(), defaults: defaults)
        updates.available("200", manual: true); updates.chose(.install)
        let next = UpdateAttention(ledger: ledger, defaults: defaults)
        next.launched(version: "199"); XCTAssertTrue(ledger.events.isEmpty)
        next.launched(version: "200"); XCTAssertEqual(ledger.events.first?.kind, .updateInstalled)
        next.launched(version: "200"); XCTAssertEqual(ledger.events.count, 1)
    }
}
