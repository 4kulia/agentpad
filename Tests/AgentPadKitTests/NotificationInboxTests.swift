import XCTest
@testable import AgentPadKit

@MainActor
final class NotificationInboxTests: XCTestCase {
    private func add(_ inbox: NotificationInbox, _ kind: SessionAlertKind, tab: String = "t") {
        inbox.add(kind: kind, sessionId: UUID(), agent: .claudeCode, tab: tab, workspace: "w")
    }

    func testAddInsertsNewestFirst() {
        let inbox = NotificationInbox()
        add(inbox, .attention, tab: "first")
        add(inbox, .failure, tab: "second")
        XCTAssertEqual(inbox.events.count, 2)
        XCTAssertEqual(inbox.events.first?.tabTitle, "second", "newest event is at index 0")
    }

    func testCapDropsOldest() {
        let inbox = NotificationInbox()
        for i in 0..<120 { add(inbox, .completed, tab: "\(i)") }
        XCTAssertEqual(inbox.events.count, 100, "capped at 100")
        XCTAssertEqual(inbox.events.first?.tabTitle, "119", "newest kept")
        XCTAssertFalse(inbox.events.contains { $0.tabTitle == "0" }, "oldest dropped")
    }

    func testUnreadFlag() {
        let inbox = NotificationInbox()
        add(inbox, .attention)
        add(inbox, .completed)
        XCTAssertTrue(inbox.hasUnread)
        XCTAssertEqual(inbox.events.filter { !$0.isRead }.count, 2)
    }

    func testMarkReadClearsOne() {
        let inbox = NotificationInbox()
        add(inbox, .attention)
        add(inbox, .failure)
        let id = inbox.events.first!.id
        inbox.markRead(id)
        XCTAssertTrue(inbox.hasUnread, "one still unread")
        XCTAssertEqual(inbox.events.filter { !$0.isRead }.count, 1)
    }

    func testMarkAllReadClearsFlag() {
        let inbox = NotificationInbox()
        for _ in 0..<3 { add(inbox, .attention) }
        inbox.markAllRead()
        XCTAssertFalse(inbox.hasUnread)
        XCTAssertTrue(inbox.events.allSatisfy { $0.isRead })
    }

    func testMarkReadForSessionClearsOnlyThatSession() {
        let inbox = NotificationInbox()
        let a = UUID(), b = UUID()
        inbox.add(kind: .attention, sessionId: a, agent: .claudeCode, tab: "a", workspace: "w")
        inbox.add(kind: .failure, sessionId: b, agent: .claudeCode, tab: "b", workspace: "w")
        inbox.add(kind: .completed, sessionId: a, agent: .claudeCode, tab: "a", workspace: "w")
        inbox.markRead(forSession: a)
        XCTAssertTrue(inbox.events.filter { $0.sessionId == a }.allSatisfy { $0.isRead })
        XCTAssertTrue(inbox.hasUnread, "session b's event is still unread")
        XCTAssertEqual(inbox.events.filter { !$0.isRead }.count, 1)
    }

    func testAddReadDoesNotLightUnread() {
        let inbox = NotificationInbox()
        inbox.add(kind: .attention, sessionId: UUID(), agent: .claudeCode, tab: "a", workspace: "w", isRead: true)
        XCTAssertFalse(inbox.hasUnread, "an event added as read must not flag unread")
    }

    func testRelativeTimeUsesTheSelectedLanguageBundle() {
        let now = Date()
        let bundle = AgentPadAppLanguage.simplifiedChinese.previewBundle
        XCTAssertEqual(
            InboxTime.relative(from: now.addingTimeInterval(-5), now: now, bundle: bundle),
            "刚刚"
        )
        XCTAssertEqual(
            InboxTime.relative(from: now.addingTimeInterval(-120), now: now, bundle: bundle),
            "2m前"
        )
    }

    func testClearAllRetainsLiveDecisions() {
        let inbox = NotificationInbox()
        add(inbox, .attention)
        add(inbox, .failure)
        inbox.clearAll()
        XCTAssertEqual(inbox.events.count, 1)
        XCTAssertEqual(inbox.events.first?.notice.kind, .input)
        XCTAssertTrue(inbox.hasUnread)
    }
}
