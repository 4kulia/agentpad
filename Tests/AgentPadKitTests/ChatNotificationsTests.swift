import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

/// Chat notices (DESIGN-F4): one per object, with nothing of what it is about.
@MainActor
final class ChatNotificationsTests: XCTestCase {
    private var root: URL!
    private var posted: [(id: String, title: String)] = []
    private var removed: [([String], String?)] = []
    private let key = ChatOrgKey(server: try! ChatServerAddress(parsing: "https://chat.example.com"),
                                 accountId: "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40", orgId: "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10")
    private var keptPost: (@MainActor (String, String) -> Void)!
    private var keptRemove: (@MainActor ([String], String?) -> Void)!

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-notices-\(UUID().uuidString)")
        posted = []
        removed = []
        keptPost = ChatNotifications.post
        keptRemove = ChatNotifications.remove
        ChatNotifications.post = { [unowned self] id, title in self.posted.append((id, title)) }
        ChatNotifications.remove = { [unowned self] ids, prefix in self.removed.append((ids, prefix)) }
        ChatNotifications.badgeChanged = {}
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        ChatNotifications.post = keptPost
        ChatNotifications.remove = keptRemove
        try? FileManager.default.removeItem(at: root)
    }

    private func service() -> ChatService {
        let service = ChatService(files: ChatFiles(directory: root), tokens: FakeTokenStore())
        _ = service.session(for: key)
        return service
    }

    /// A request waiting for a decision: one notice, however often it is
    /// told — from an event, a snapshot or a start — and no names in it.
    func testADecisionIsToldOnce() throws {
        let service = service()
        XCTAssertNotNil(service.orgSessions[key]?.store)
        ChatNotifications.requestAwaitsDecision(key, requestId: "r1", service: service)
        ChatNotifications.requestAwaitsDecision(key, requestId: "r1", service: service)
        ChatNotifications.requestAwaitsDecision(key, requestId: "r2", service: service)
        XCTAssertEqual(posted.map(\.title), ["A request waits for your decision", "A request waits for your decision"])
        XCTAssertEqual(posted.map(\.id), [ChatNotifications.requestId(key, "r1"), ChatNotifications.requestId(key, "r2")])
    }

    func testRepeatedReadMarksDoNotWakeDatabaseObservers() throws {
        let store = try XCTUnwrap(service().orgSessions[key]?.store)
        let changes = Counter()
        let watch = try DatabaseRegionObservation(tracking: Table("read_marks"), Table("notified"))
            .start(in: store.queue, onError: { XCTFail("\($0)") }) { _ in changes.increment() }
        defer { watch.cancel() }
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, seq) VALUES ('m', 'mention', 'c', 10)")
        }
        XCTAssertEqual(try store.queue.write { try ChatUnread.markRead($0, channel: "c", upTo: 10) }, ["m"])
        let settled = changes.value
        for _ in 0..<100 {
            try store.queue.write { db in
                XCTAssertEqual(try ChatUnread.markRead(db, channel: "c", upTo: 10), [])
                XCTAssertEqual(try ChatUnread.markRead(db, channel: "c", upTo: 9), [])
            }
        }
        XCTAssertEqual(changes.value, settled, "unchanged read marks must not wake F4")
        try store.queue.write { try ChatUnread.markRead($0, channel: "c", upTo: 11) }
        XCTAssertEqual(changes.value, settled + 1, "a new message still advances the mark")
    }
}
