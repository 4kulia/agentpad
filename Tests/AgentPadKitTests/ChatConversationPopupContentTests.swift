import AppKit
import Foundation
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

/// Fictional stores and fake transports cover opening state; quiet mounted
/// timelines verify that delayed geometry cannot acknowledge unseen replies.
@MainActor
final class ChatConversationPopupContentTests: XCTestCase {
    private var directory: URL!
    private var scope: TeamServiceTestScope!
    private var services: [ChatService] = []
    private var sockets: [ChatSocket] = []
    private let key = ChatOrgKey(server: try! ChatServerAddress(parsing: "https://chat.example.com"), accountId: "me", orgId: "org")

    override func setUp() async throws {
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("chat-popup-content-\(UUID())")
    }

    override func tearDown() async throws {
        for service in services {
            service.orgSessions.values.forEach { $0.sync?.stop(); $0.outbox?.hold() }
            service.stopFeed()
        }
        sockets.forEach { $0.stop() }
        services = []; sockets = []
        ChatStubProtocol.reset()
        scope.close(); scope = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func channel(includeReply: Bool = true) throws -> (ChatStore, ChatChannelModel) {
        let files = ChatFiles(directory: directory.appendingPathComponent(UUID().uuidString))
        let store = try ChatStore.open(files: files, key: key).store
        try store.queue.write { db in
            try db.execute(sql: "UPDATE meta SET me = 'me', rights_in_doubt = 0, rights_session = 'fixture-session', channels_served = 1")
            try db.execute(sql: "INSERT INTO teams (team_id, name, mine) VALUES ('team', 'Product', 1)")
            try db.execute(sql: """
                INSERT INTO channels (channel_id, team_id, name, archived, version, stamp, created_by, created_at)
                VALUES ('design', 'team', 'design', 0, 1, 1, 'me', '2026-10-24T10:00:00Z')
                """)
            try db.execute(sql: "INSERT INTO channel_windows (channel_id, epoch, bottom_seq) VALUES ('design', 1, 0)")
            try db.execute(sql: "INSERT INTO read_marks (channel_id, last_read_seq) VALUES ('design', 1)")
            for (id, sequence, root) in [("before", 1, nil), ("unread", 2, nil), ("latest", 3, nil), ("reply", 4, "unread")] as [(String, Int, String?)] {
                if root != nil && !includeReply { continue }
                let body: [String: Any] = ["message_id": id, "channel_id": "design", "thread_root_id": root as Any? ?? NSNull(),
                    "author_account_id": id == "before" ? "me" : "nora", "text": "Fictional copy review \(id)", "mentions": [], "revision": 1,
                    "seq": sequence, "created_at": "2026-10-24T10:00:00Z"]
                let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: body))
                try ChatMessages.write(db, wire)
            }
        }
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        let model = ChatChannelModel(key: key, channel: "design")
        model.service = service; model.follow(store)
        return (store, model)
    }

    private func directMessage(includeCard: Bool = true, includeReply: Bool = true) async throws -> (ChatStore, ChatService) {
        let files = ChatFiles(directory: directory.appendingPathComponent(UUID().uuidString))
        let service = ChatService(files: files, tokens: FakeTokenStore())
        service.followsFeed = false; service.closeRemoteSession = { _, _ in }
        try service.saveSignIn(.init(server: key.server, accountId: key.accountId, sessionId: "fixture-session", deviceName: "Fixture Mac", orgId: key.orgId), token: "fictional-token")
        try await service.start(mode: .server)
        services.append(service)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try store.apply(ChatSnapshot(cursors: [:], members: [
            .init(accountId: "me", handle: "maya", name: "Maya", role: "member"),
            .init(accountId: "nora", handle: "nora", name: "Nora Chen", role: "member")]), confirmsRights: "fixture-session")
        service.orgSessions[key]?.snapshotOwed = false
        let socket = ChatSocket(server: key.server, token: "fictional-token", makeTransport: { FakeSocketTransport() })
        sockets.append(socket)
        let sync = ChatSync(key: key, store: store, api: ChatAPI(server: key.server, protocolClasses: [ChatStubProtocol.self]), socket: socket, outbox: nil, token: "fictional-token")
        service.orgSessions[key]?.sync = sync
        service.serverCapabilities[key.server] = ["chat.dm"]
        sync.dm.sessionId = "fixture-session"; sync.dm.configure(true)
        let card = ChatDMCard(dmId: "fixture-dm", peer: .init(accountId: "nora", name: "Nora Chen", handle: "nora", active: true),
                              state: "active", version: 1, createdAt: "2026-10-24T10:00:00Z")
        let catalog = try JSONEncoder().encode(ChatDMPage(dms: includeCard ? [card] : [], next: nil))
        let messages = try JSONEncoder().encode(ChatDMMessagesPage(messages: [], next: nil, head: nil))
        ChatStubProtocol.reset { request, _ in
            .success(.init(status: 200, body: request.url?.path.hasSuffix("/dms") == true ? catalog : messages))
        }
        try await sync.dm.reloadCatalog(valid: { true })
        if includeCard {
            try store.dmWrite { db in
                try ChatDMStore.liveBaseline(db, "fixture-dm")
                for (id, sequence, root) in [("before", 1, nil), ("unread", 2, nil), ("latest", 3, nil), ("reply", 4, "unread")] as [(String, Int, String?)] {
                    if root != nil && !includeReply { continue }
                    try ChatDMStore.write(db, .init(messageId: id, dmId: "fixture-dm", threadRootId: root, authorAccountId: id == "before" ? "me" : "nora",
                        text: "Fictional copy review \(id)", mentions: [], revision: 1, seq: sequence, createdAt: "2026-10-24T10:00:00Z"))
                }
                try ChatDMStore.markRead(db, "fixture-dm", through: 1)
            }
        }
        return (store, service)
    }

    func testChannelPopupThreadBackRestoresParentPositionAndPerRootDrafts() throws {
        let (_, model) = try channel()
        model.isPopup = true
        model.saveDraft("Parent copy", root: nil, mentionOnly: true, contextIds: ["before"])
        let parentDraft = model.composerDraft(root: nil)
        var parentPosition = ChatScrollPosition()
        _ = parentPosition.update(model.feed.messages, me: "me")
        parentPosition.measured(bottom: false, anchor: "latest")
        model.positions[""] = parentPosition
        model.openThread("unread")
        model.saveDraft("Reply copy", root: "unread")
        let replyDraft = model.composerDraft(root: "unread")
        model.openThread(nil)
        XCTAssertNil(model.threadRoot)
        XCTAssertNil(model.focusedMessageID, "Back must not override the parent anchor by focusing the closed root")
        XCTAssertEqual(model.positions[""], parentPosition)
        XCTAssertEqual(model.readingPositionRestored, 1)
        XCTAssertEqual(model.composerDraft(root: nil), parentDraft)
        XCTAssertEqual(model.composerDraft(root: "unread"), replyDraft)
        XCTAssertTrue(model.hasConversationDraft)
        model.openThread("unread")
        XCTAssertEqual(model.composerDraft(root: "unread"), replyDraft)
    }

    func testChannelOpeningUsesUnreadContextThenRetainedAnchorAndExplicitTarget() throws {
        let (_, model) = try channel()
        model.isPopup = true
        XCTAssertEqual(model.positions[""]?.anchor, "before")
        XCTAssertEqual(model.positions[""]?.atBottom, false)
        var retained = try XCTUnwrap(model.positions[""])
        retained.measured(bottom: false, anchor: "latest")
        model.positions[""] = retained
        model.isPopup = false; model.isPopup = true
        XCTAssertEqual(model.positions[""], retained)
        model.navigate(to: try XCTUnwrap(model.message("unread")))
        XCTAssertEqual(model.revealMessageID, "unread")
        XCTAssertEqual(model.positions[""], retained, "An explicit target leaves the retained return anchor intact")
    }

    func testChannelDelayedThreadRepliesReplaceBootstrapWithUnreadContextBeforeReading() async throws {
        try await checkDelayedChannelThread(lastSequence: 30)
    }

    func testChannelDelayedShortThreadReadsOnlyAfterRepliesFitInViewport() async throws {
        try await checkDelayedChannelThread(lastSequence: 5)
    }

    private func checkDelayedChannelThread(lastSequence: Int) async throws {
        let (store, model) = try channel(includeReply: false)
        try await store.queue.write { db in
            try db.execute(sql: "INSERT INTO cursors (stream, seq) VALUES ('channel:design', 30)")
            _ = try ChatUnread.markRead(db, channel: "design", upTo: 4, thread: "unread")
        }
        model.isPopup = true; model.openThread("unread"); model.beginReading(root: "unread")
        XCTAssertEqual(model.thread.map(\.id), ["unread"])
        // The shared timeline mounts and measures the cached root before the
        // history request returns. This is bootstrap, not a previous visit.
        var bootstrap = ChatScrollPosition()
        XCTAssertTrue(bootstrap.update(model.thread, me: "me"))
        bootstrap.measured(bottom: true, anchor: "unread")
        model.positions["unread"] = bootstrap
        let host = delayedThreadHost(model)
        defer { host.close() }
        try await host.settle()
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        let replies = try (4...lastSequence).map { sequence -> ChatMessageWire in
            let body: [String: Any] = ["message_id": "reply-\(sequence)", "channel_id": "design", "thread_root_id": "unread",
                "author_account_id": "nora", "text": "Fictional reply \(sequence)", "mentions": [], "revision": 1,
                "seq": sequence, "created_at": "2026-10-24T10:00:00Z"]
            return try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: body))
        }
        try await store.queue.write { db in
            try ChatMessages.applyThread(db, channel: "design", root: "unread", epoch: ChatMessages.epoch(db, "design"),
                page: .init(messages: replies, next: nil, head: lastSequence))
        }
        for _ in 0..<300 { if model.thread.count == lastSequence - 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.threadUnreadID, "reply-5")
        if lastSequence == 30 {
            XCTAssertEqual(model.positions["unread"]?.anchor, "reply-4")
            XCTAssertEqual(model.positions["unread"]?.atBottom, false)
        }
        XCTAssertGreaterThan(model.readingPositionRestored, 0, "The already mounted timeline must apply the delayed anchor")
        // An old geometry callback still says bottom until the new position is
        // applied. It must not acknowledge the newly loaded, unseen replies.
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        try await host.settle()
        XCTAssertEqual(model.positions["unread"]?.atBottom, lastSequence == 5, "Read only when the delayed replies actually fit")
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        let mark = try await store.queue.read { try ChatUnread.readSequence($0, channel: "design", thread: "unread") }
        XCTAssertEqual(mark, lastSequence == 5 ? 5 : 4)
        var retained = try XCTUnwrap(model.positions["unread"])
        retained.measured(bottom: false, anchor: lastSequence == 30 ? "reply-12" : "reply-4")
        model.positions["unread"] = retained
        model.openThread(nil); model.openThread("unread")
        XCTAssertEqual(model.positions["unread"], retained)
        if lastSequence == 30 {
            host.close()
            model.navigate(to: try XCTUnwrap(model.message("reply-30")))
            let probe = ChatScrollProbe()
            let targetHost = delayedThreadHost(model, probe: probe)
            defer { targetHost.close() }
            try await targetHost.settle()
            probe.scroll = ChatScrollMounted<ChatScrollFixture>.descendants(targetHost.view, NSScrollView.self).first
            XCTAssertEqual(model.revealMessageID, "reply-30")
            let targetFrame = try XCTUnwrap(probe.frames["reply-30"])
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 620, height: 280).contains(targetFrame), "Explicit target frame: \(targetFrame)")
        }
    }

    func testDMDelayedThreadRepliesReplaceBootstrapWithUnreadContextBeforeReading() async throws {
        try await checkDelayedDMThread(lastSequence: 30)
    }

    func testDMDelayedShortThreadReadsOnlyAfterRepliesFitInViewport() async throws {
        try await checkDelayedDMThread(lastSequence: 5)
    }

    func testDMThreadResponseWaitsForObservationBeforeResolvingUnreadOpening() async throws {
        try await checkDMThreadResponse(cachedReply: false)
    }

    func testDMThreadResponseWithCachedReadReplyStillWaitsForUnreadOpening() async throws {
        try await checkDMThreadResponse(cachedReply: true)
    }

    func testDMThreadResponseWaitsForHydratedRevisionsInObservation() async throws {
        try await checkDMThreadResponse(cachedReply: true, staleReplies: true)
    }

    func testDMPagedThreadKeepsCachedFirstUnreadVisible() async throws {
        try await checkDMPagedThread()
    }

    func testDMPagedThreadKeepsUnreadPositionAfterAccessIsRestored() async throws {
        try await checkDMPagedThread(revalidateBeforeFirstPage: true)
    }

    func testDMEarlierPageTimeoutKeepsUnreadPositionAndResumesFromCursor() async throws {
        try await checkDMPagedThread(earlierPageFailure: .timeout)
    }

    func testDMEarlierPage503KeepsUnreadPositionAndResumesFromCursor() async throws {
        try await checkDMPagedThread(earlierPageFailure: .unavailable)
    }

    private func checkDMPagedThread(revalidateBeforeFirstPage: Bool = false,
                                   earlierPageFailure: PagedThreadFailure? = nil) async throws {
        let (store, service) = try await directMessage(includeReply: false)
        let replies = (5...130).map { sequence in
            ChatDMMessageWire(messageId: "reply-\(sequence)", dmId: "fixture-dm", threadRootId: "unread",
                authorAccountId: "nora", text: "Fictional paged reply \(sequence)", mentions: [],
                revision: 1, seq: sequence, createdAt: "2026-10-24T10:00:00Z")
        }
        try store.dmWrite { db in
            try ChatDMStore.markRead(db, "fixture-dm", root: "unread", through: 4)
            try ChatDMStore.write(db, replies[0])
        }
        let response = try JSONEncoder().encode(ChatDMMessagesPage(messages: replies.filter { $0.seq >= 81 }, next: 81, head: 130))
        let earlier = try JSONEncoder().encode(ChatDMMessagesPage(messages: replies.filter { $0.seq < 81 }, next: nil, head: 130))
        let latest = Gate(), failures = Budget()
        if revalidateBeforeFirstPage { latest.close() }
        if earlierPageFailure != nil { failures.give(1) }
        defer { latest.open() }
        ChatStubProtocol.reset { request, _ in
            let before = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before" }?.value
            if before == nil { latest.pass(); return .success(.init(status: 200, body: response)) }
            if failures.take() {
                return earlierPageFailure == .timeout ? .failure(URLError(.timedOut))
                    : .success(.init(status: 503, body: Data(#"{"error":{"code":"unavailable"}}"#.utf8)))
            }
            return .success(.init(status: 200, body: earlier))
        }
        let model = ChatDMModel(key: key, dm: "fixture-dm", service: service)
        defer { model.stop() }
        model.isPopup = true; model.openThread("unread"); model.beginReading(root: "unread")
        let opening = try XCTUnwrap(model.positions["unread"])
        XCTAssertEqual(opening.anchor, "unread"); XCTAssertFalse(opening.atBottom)
        if revalidateBeforeFirstPage {
            for _ in 0..<300 {
                if ChatStubProtocol.seen.count == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(ChatStubProtocol.seen.count, 1)
            try await store.queue.write { try $0.execute(sql: "UPDATE meta SET rights_in_doubt = 1") }
            XCTAssertFalse(model.readable)
            model.preparePopupOpeningPosition()
            model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
            XCTAssertEqual(try store.dmRead { try ChatDMStore.mark($0, "fixture-dm", root: "unread") }, 4)
            try await store.queue.write { try $0.execute(sql: "UPDATE meta SET rights_in_doubt = 0") }
            XCTAssertTrue(model.readable)
            model.preparePopupOpeningPosition()
            XCTAssertEqual(model.positions["unread"], opening)
            latest.open()
        }
        for _ in 0..<300 {
            if model.conversationMessages(root: "unread").last?.seq == 130 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.conversationMessages(root: "unread").map(\.id), ["unread", "reply-5"] + (81...130).map { "reply-\($0)" })
        XCTAssertEqual(model.threadUnreadID, "reply-5")
        XCTAssertEqual(model.positions["unread"], opening, "DM threads include cached replies without the channel's lower window bound")
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(try store.dmRead { try ChatDMStore.mark($0, "fixture-dm", root: "unread") }, 4)
        XCTAssertTrue(model.threadHasEarlier)
        XCTAssertEqual(ChatStubProtocol.seen.count, 1, "The unread anchor is already present; no earlier page is needed")
        if earlierPageFailure != nil {
            model.earlierReplies()
            for _ in 0..<300 {
                if model.problem != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(failures.peek())
            XCTAssertEqual(model.problem, "The thread could not be loaded. Try again.")
            XCTAssertEqual(model.positions["unread"], opening)
            model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
            XCTAssertEqual(try store.dmRead { try ChatDMStore.mark($0, "fixture-dm", root: "unread") }, 4)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(ChatStubProtocol.seen.count, 2, "No automatic retry loop")
            model.earlierReplies()
            for _ in 0..<300 {
                if !model.threadHasEarlier { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(model.threadHasEarlier)
            XCTAssertEqual(model.conversationMessages(root: "unread").map(\.id), ["unread"] + replies.map(\.messageId))
            XCTAssertEqual(model.positions["unread"], opening)
            XCTAssertEqual(ChatStubProtocol.seen.map { seen in
                URLComponents(url: seen.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before" }?.value
            }, [nil, "81", "81"])
            model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
            XCTAssertEqual(try store.dmRead { try ChatDMStore.mark($0, "fixture-dm", root: "unread") }, 4)
        }
    }

    private func checkDMThreadResponse(cachedReply: Bool, staleReplies: Bool = false) async throws {
        let (store, service) = try await directMessage(includeReply: false)
        try store.dmWrite { try ChatDMStore.markRead($0, "fixture-dm", root: "unread", through: 4) }
        let replies = (4...30).map { sequence in
            ChatDMMessageWire(messageId: "reply-\(sequence)", dmId: "fixture-dm", threadRootId: "unread",
                authorAccountId: "nora", text: "Fictional response reply \(sequence)", mentions: [],
                revision: staleReplies ? 2 : 1, seq: sequence, createdAt: "2026-10-24T10:00:00Z")
        }
        if cachedReply { try store.dmWrite { try ChatDMStore.write($0, replies[0]) } }
        if staleReplies {
            // The state left by dm.message.edit before readOne/page hydrates it.
            try store.dmWrite { db in
                for var reply in replies.dropFirst() {
                    reply.revision = 1
                    try ChatDMStore.write(db, reply)
                }
                try db.execute(sql: "UPDATE dm_messages SET stale = 2 WHERE dm_id = 'fixture-dm' AND root = 'unread' AND seq > 4")
            }
        }
        let delivery = HeldDMObservation()
        let model = ChatDMModel(key: key, dm: "fixture-dm", service: service, scheduling: delivery)
        defer { model.stop() }
        let response = try JSONEncoder().encode(ChatDMMessagesPage(messages: replies, next: nil, head: 30))
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: response)) }
        model.isPopup = true; model.openThread("unread"); model.beginReading(root: "unread")
        var bootstrap = ChatScrollPosition()
        _ = bootstrap.update(model.conversationMessages(root: "unread"), me: "me")
        bootstrap.measured(bottom: true, anchor: "unread")
        model.positions["unread"] = bootstrap

        // The real page request writes its own response. Hold only GRDB delivery,
        // so its completion runs while the timeline still has its cached content.
        for _ in 0..<300 {
            if !delivery.pending.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(delivery.pending.isEmpty)
        XCTAssertEqual(try store.dmRead { try ChatDMStore.messages($0, "fixture-dm").filter { $0.threadRootId == "unread" }.map(\.id) }, replies.map(\.messageId))
        let cachedIDs = staleReplies ? replies.map(\.messageId) : cachedReply ? ["reply-4"] : []
        XCTAssertEqual(model.conversationMessages(root: "unread").map(\.id), ["unread"] + cachedIDs)
        if staleReplies { XCTAssertEqual(model.message("reply-5")?.loading, true) }
        XCTAssertTrue(model.threadHasEarlier, "Response completion alone must not publish a loaded thread")
        XCTAssertEqual(model.positions["unread"], bootstrap)
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(try store.dmRead { try ChatDMStore.mark($0, "fixture-dm", root: "unread") }, 4)

        delivery.deliver()
        XCTAssertFalse(model.threadHasEarlier)
        XCTAssertEqual(model.conversationMessages(root: "unread").map(\.id), ["unread"] + replies.map(\.messageId))
        XCTAssertEqual(model.threadUnreadID, "reply-5")
        var expected = ChatScrollPosition()
        _ = expected.update(model.conversationMessages(root: "unread"), me: "me")
        expected.measured(bottom: false, anchor: "reply-4")
        XCTAssertEqual(model.positions["unread"], expected)
        XCTAssertEqual(model.readingPositionRestored, 1)
        // A stale bottom callback must not acknowledge anything outside the new
        // unread viewport, even after loading is complete.
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(try store.dmRead { try ChatDMStore.mark($0, "fixture-dm", root: "unread") }, 4)
    }

    func testChannelThreadPageWithCachedReadReplyStillWaitsForUnreadOpening() async throws {
        try await checkChannelThreadPage(cachedUnreadBelowWindow: false)
    }

    func testChannelUnreadBannerWaitsForCachedUnreadReplyBelowWindow() async throws {
        try await checkChannelThreadPage(cachedUnreadBelowWindow: true)
    }

    func testChannelUnreadBannerLoadsEarlierPagesUntilCachedUnreadReplyIsVisible() async throws {
        try await checkChannelPagedUnread(mounted: false)
    }

    func testChannelUnreadBannerStopsMountedTimelineFollowingWhileLoadingEarlierPages() async throws {
        try await checkChannelPagedUnread(mounted: true)
    }

    func testChannelUnreadBannerReleasesOpeningWhenEarlierHistoryEndsWithoutAnchor() async throws {
        try await checkChannelPagedUnread(mounted: false, terminal: .exhausted)
    }

    func testChannelUnreadBannerStopsPagingWhenUnreadReplyIsDeleted() async throws {
        try await checkChannelPagedUnread(mounted: false, terminal: .deleted)
    }

    func testChannelUnreadBannerCancelsPagingOnAccessLoss() async throws {
        try await checkChannelPagedUnread(mounted: false, terminal: .accessLost)
    }

    func testChannelUnreadOpeningSurvivesCheckingBeforeFirstPage() async throws {
        try await checkChannelPagedUnread(mounted: false, revalidateBeforeFirstPage: true)
    }

    func testChannelUnreadOpeningSurvivesCheckingBeforeFirstPageInMountedTimeline() async throws {
        try await checkChannelPagedUnread(mounted: true, revalidateBeforeFirstPage: true)
    }

    private enum PagedThreadTerminal { case exhausted, deleted, accessLost }
    private enum PagedThreadFailure { case timeout, unavailable }

    private func checkChannelPagedUnread(mounted: Bool, terminal: PagedThreadTerminal? = nil,
                                        revalidateBeforeFirstPage: Bool = false) async throws {
        let (_, fixture) = try channel(includeReply: false)
        let service = fixture.service
        let session = service.session(for: key)
        let store = try XCTUnwrap(session.store)
        let replies = try (4...130).map { sequence -> ChatMessageWire in
            let body: [String: Any] = ["message_id": "reply-\(sequence)", "channel_id": "design", "thread_root_id": "unread",
                "author_account_id": "nora", "text": "Fictional paged reply \(sequence)", "mentions": [], "revision": 1,
                "seq": sequence, "created_at": "2026-10-24T10:00:00Z"]
            return try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: body))
        }
        try await store.queue.write { db in
            try db.execute(sql: "UPDATE meta SET rights_in_doubt = 0")
            try db.execute(sql: "UPDATE channel_windows SET bottom_seq = 20 WHERE channel_id = 'design'")
            try db.execute(sql: "INSERT INTO cursors (stream, seq) VALUES ('channel:design', 130)")
            _ = try ChatUnread.markRead(db, channel: "design", upTo: 4, thread: "unread")
            try ChatMessages.write(db, replies[1])
        }
        let socket = ChatSocket(server: key.server, token: "fictional-token", makeTransport: { FakeSocketTransport() })
        sockets.append(socket)
        let sync = ChatSync(key: key, store: store, api: ChatAPI(server: key.server, protocolClasses: [ChatStubProtocol.self]),
            socket: socket, outbox: nil, token: "fictional-token")
        session.sync = sync; sync.sessionId = "fixture-session"
        let state = Data(#"""
            {"org":{"org_id":"org","name":"Fictional organization"},
             "members":[{"account_id":"me","handle":"maya","name":"Maya","role":"member"}],
             "teams":[{"team_id":"team","name":"Product","is_general":false,"members":["me"]}],"my_teams":["team"],
             "channels":[{"channel_id":"design","team_id":"team","name":"design","archived":false,"version":1}],
             "streams":{"org:org":0,"team:team":0,"channel:design":130}}
            """#.utf8)
        ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: state)) }
        await sync.snapshotNow()
        XCTAssertFalse(sync.needsSnapshot, "Paging must run through a ready synchronizer")
        let pages = try [
            "latest": ChatMessagesPage(messages: replies.filter { $0.seq >= 81 }, next: 81, head: 130),
            "81": ChatMessagesPage(messages: terminal == .exhausted ? [] : replies.filter { (31...80).contains($0.seq) },
                next: terminal == .exhausted ? nil : 31, head: 130),
            "31": ChatMessagesPage(messages: replies.filter { $0.seq < 31 }, next: nil, head: 130)
        ].mapValues { try JSONEncoder().encode($0) }
        let latest = Gate(), middle = Gate(), earliest = Gate()
        if revalidateBeforeFirstPage { latest.close() }
        middle.close(); earliest.close()
        defer { latest.open(); middle.open(); earliest.open() }
        ChatStubProtocol.reset { request, _ in
            let before = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before" }?.value
            if before == nil { latest.pass() }
            if before == "81" { middle.pass() }
            if before == "31" { earliest.pass() }
            guard let page = pages[before ?? "latest"] else { return .failure(URLError(.badServerResponse)) }
            return .success(.init(status: 200, body: page))
        }
        let conversation = ChatChannelSession()
        conversation.isPopup = true
        let ready = ChannelTabState.ready(.init(channelId: "design", teamId: "team", name: "design", archived: false, version: 1),
                                          team: "Product", offline: false)
        conversation.update(ready, key: key, store: store, service: service)
        let model = try XCTUnwrap(conversation.model)
        // This fixture has no signed-in notification scope. Exercise the read
        // gate itself rather than letting that independent gate hide a failure.
        model.canAutomaticallyRead = { true }
        XCTAssertEqual(model.feed.unloadedUnreadReplyCount, 1)
        XCTAssertEqual(model.message("reply-5")?.seq, 5)
        model.openThread(try XCTUnwrap(model.feed.firstUnloadedUnreadThread))
        model.beginReading(root: "unread")
        var bootstrap = ChatScrollPosition()
        _ = bootstrap.update(model.thread, me: "me")
        bootstrap.measured(bottom: true, anchor: "unread")
        model.positions["unread"] = bootstrap
        let probe = ChatScrollProbe()
        let host = mounted ? delayedThreadHost(model, probe: probe) : nil
        defer { host?.close() }

        if revalidateBeforeFirstPage {
            for _ in 0..<300 {
                if ChatStubProtocol.seen.count == 1 { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(ChatStubProtocol.seen.count, 1)
            conversation.update(.checking, key: key, store: store, service: service)
            latest.open()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.thread.map(\.id), ["unread"], "A cancelled page must not apply during checking")
            XCTAssertEqual(model.positions["unread"], bootstrap)
            XCTAssertEqual(ChatStubProtocol.seen.count, 1, "Checking must not start another request")
            model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
            let mark = try await store.queue.read { try ChatUnread.readSequence($0, channel: "design", thread: "unread") }
            XCTAssertEqual(mark, 4)
            conversation.update(ready, key: key, store: store, service: service)
            model.canAutomaticallyRead = { true }
            XCTAssertTrue(conversation.model === model)
        }

        for _ in 0..<300 {
            if model.threadHasEarlier && model.thread.last?.seq == 130 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.thread.map(\.id), ["unread"] + (81...130).map { "reply-\($0)" })
        XCTAssertEqual(model.threadUnreadID, "reply-5")
        XCTAssertFalse(model.thread.contains { $0.id == "reply-5" })
        XCTAssertEqual(model.positions["unread"]?.atBottom, false, "A partial page must not follow its latest reply")
        if let host {
            try await host.settle()
            let container = try XCTUnwrap(ChatScrollMounted<ChatScrollFixture>.descendants(host.view, NativeChatTimelineContainer.self).first)
            let viewport = container.coordinator.scrollController
            probe.scroll = viewport.scroll
            XCTAssertFalse(viewport.following)
        }
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        var read = try await store.queue.read { try ChatUnread.readSequence($0, channel: "design", thread: "unread") }
        XCTAssertEqual(read, 4)

        if terminal == .deleted {
            try await store.queue.write { db in
                try db.execute(sql: "UPDATE messages SET deleted_at = '2026-10-26T10:00:00Z', text = '' WHERE message_id = 'reply-5'")
            }
            for _ in 0..<300 {
                if model.threadUnreadID == "reply-81" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(model.threadUnreadID, "reply-81")
        } else if terminal == .accessLost {
            conversation.update(.noAccess, key: key, store: store, service: service)
        }
        middle.open()
        if let terminal {
            for _ in 0..<300 {
                let complete = terminal == .accessLost || (terminal == .exhausted ? !model.threadHasEarlier : model.thread.contains { $0.id == "reply-31" })
                if complete { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            // No further page may start after a terminal absence. The access
            // case also verifies that its cancelled page cannot enter the cache.
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.url?.query?.contains("before=31") == true })
            if terminal == .accessLost {
                XCTAssertEqual(model.thread.map(\.id), ["unread"] + (81...130).map { "reply-\($0)" })
            } else if terminal == .exhausted { XCTAssertFalse(model.threadHasEarlier) }
            var bottom = try XCTUnwrap(model.positions["unread"])
            bottom.measured(bottom: true, anchor: "reply-130")
            model.positions["unread"] = bottom
            model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
            read = try await store.queue.read { try ChatUnread.readSequence($0, channel: "design", thread: "unread") }
            XCTAssertEqual(read, terminal == .accessLost ? 4 : 130, "Only a terminal opening can accept a new bottom measurement")
            return
        }
        for _ in 0..<300 {
            if model.thread.contains(where: { $0.id == "reply-31" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.thread.map(\.id), ["unread"] + (31...130).map { "reply-\($0)" })
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        read = try await store.queue.read { try ChatUnread.readSequence($0, channel: "design", thread: "unread") }
        XCTAssertEqual(read, 4)

        earliest.open()
        for _ in 0..<300 {
            if model.positions["unread"]?.anchor == "reply-4" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.thread.map(\.id), ["unread"] + replies.map(\.messageId))
        var expected = ChatScrollPosition()
        _ = expected.update(model.thread, me: "me")
        expected.measured(bottom: false, anchor: "reply-4")
        if let host {
            try await host.settle()
            let frame = try XCTUnwrap(probe.frames["reply-5"])
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 620, height: 280).contains(frame), "First unread frame: \(frame)")
            XCTAssertEqual(model.positions["unread"]?.atBottom, false)
        } else { XCTAssertEqual(model.positions["unread"], expected) }
        XCTAssertGreaterThan(model.readingPositionRestored, 0)
        XCTAssertFalse(model.threadHasEarlier)
        XCTAssertEqual(ChatStubProtocol.seen.map { seen in
            URLComponents(url: seen.request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "before" }?.value
        }, revalidateBeforeFirstPage ? [nil, nil, "81", "31"] : [nil, "81", "31"])
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        read = try await store.queue.read { try ChatUnread.readSequence($0, channel: "design", thread: "unread") }
        XCTAssertEqual(read, 4)
    }

    private func checkChannelThreadPage(cachedUnreadBelowWindow: Bool) async throws {
        let (store, model) = try channel(includeReply: false)
        let replies = try (4...30).map { sequence -> ChatMessageWire in
            let body: [String: Any] = ["message_id": "reply-\(sequence)", "channel_id": "design", "thread_root_id": "unread",
                "author_account_id": "nora", "text": "Fictional reply \(sequence)", "mentions": [], "revision": 1,
                "seq": sequence, "created_at": "2026-10-24T10:00:00Z"]
            return try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: body))
        }
        try await store.queue.write { db in
            try db.execute(sql: "INSERT INTO cursors (stream, seq) VALUES ('channel:design', 30)")
            _ = try ChatUnread.markRead(db, channel: "design", upTo: 4, thread: "unread")
            _ = try ChatMessages.write(db, replies[0])
            if cachedUnreadBelowWindow {
                // Inbox hydrates disjoint messages without expanding the channel
                // window or installing a thread cursor (ChatInboxModel.apply).
                _ = try ChatMessages.write(db, replies[1])
                try db.execute(sql: "UPDATE channel_windows SET bottom_seq = 20 WHERE channel_id = 'design'")
            }
        }
        model.isPopup = true
        if cachedUnreadBelowWindow {
            for _ in 0..<300 {
                if model.feed.firstUnloadedUnreadThread == "unread" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(model.feed.unloadedUnreadReplyCount, 1)
            XCTAssertFalse(model.feed.messages.contains { $0.id == "unread" })
            XCTAssertEqual(model.message("reply-5")?.seq, 5)
            // The unread-replies banner opens the root without a reveal target.
            model.pins.close()
            model.openThread(try XCTUnwrap(model.feed.firstUnloadedUnreadThread))
        } else {
            model.openThread("unread")
        }
        model.beginReading(root: "unread")
        XCTAssertNil(model.revealMessageID)
        XCTAssertEqual(model.thread.map(\.id), cachedUnreadBelowWindow ? ["unread"] : ["unread", "reply-4"])
        XCTAssertEqual(model.threadUnreadID, cachedUnreadBelowWindow ? "reply-5" : nil)
        var bootstrap = ChatScrollPosition()
        _ = bootstrap.update(model.thread, me: "me")
        bootstrap.measured(bottom: true, anchor: cachedUnreadBelowWindow ? "unread" : "reply-4")
        model.positions["unread"] = bootstrap
        model.preparePopupOpeningPosition()
        XCTAssertEqual(model.positions["unread"], bootstrap)
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        let pendingMark = try await store.queue.read { try ChatUnread.readSequence($0, channel: "design", thread: "unread") }
        XCTAssertEqual(pendingMark, 4)
        try await store.queue.write { db in
            try ChatMessages.applyThread(db, channel: "design", root: "unread", epoch: ChatMessages.epoch(db, "design"),
                page: .init(messages: replies, next: nil, head: 30))
        }
        for _ in 0..<300 {
            if model.thread.count == 28 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.thread.map(\.id), ["unread"] + replies.map(\.messageId))
        XCTAssertEqual(model.threadUnreadID, "reply-5")
        var expected = ChatScrollPosition()
        _ = expected.update(model.thread, me: "me")
        expected.measured(bottom: false, anchor: "reply-4")
        XCTAssertEqual(model.positions["unread"], expected)
        XCTAssertEqual(model.readingPositionRestored, 1)
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        let mark = try await store.queue.read { try ChatUnread.readSequence($0, channel: "design", thread: "unread") }
        XCTAssertEqual(mark, 4)
    }

    @MainActor private final class HeldDMObservation: ValueObservationMainActorScheduler {
        var pending: [@MainActor () -> Void] = []
        nonisolated func immediateInitialValue() -> Bool { true }
        nonisolated func scheduleOnMainActor(_ action: @escaping @MainActor () -> Void) {
            DispatchQueue.main.async { self.pending.append(action) }
        }
        func deliver() {
            let callbacks = pending
            pending.removeAll()
            callbacks.forEach { $0() }
        }
    }

    func testDMEmptyThreadResponseCompletesWithoutObservation() async throws {
        let (_, service) = try await directMessage(includeReply: false)
        let delivery = HeldDMObservation()
        let model = ChatDMModel(key: key, dm: "fixture-dm", service: service, scheduling: delivery)
        defer { model.stop() }
        model.isPopup = true; model.openThread("unread")
        var bootstrap = ChatScrollPosition()
        _ = bootstrap.update(model.conversationMessages(root: "unread"), me: "me")
        bootstrap.measured(bottom: true, anchor: "unread")
        model.positions["unread"] = bootstrap
        for _ in 0..<300 {
            if !model.threadHasEarlier { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.threadHasEarlier)
        XCTAssertTrue(delivery.pending.isEmpty, "An empty response does not change the observed database region")
        XCTAssertEqual(model.positions["unread"], bootstrap)
        XCTAssertEqual(model.readingPositionRestored, 0)
    }

    private func checkDelayedDMThread(lastSequence: Int) async throws {
        let (store, service) = try await directMessage(includeReply: false)
        try store.dmWrite { try ChatDMStore.markRead($0, "fixture-dm", root: "unread", through: 4) }
        let model = ChatDMModel(key: key, dm: "fixture-dm", service: service)
        defer { model.stop() }
        ChatStubProtocol.delay = 0.4
        model.isPopup = true; model.openThread("unread"); model.beginReading(root: "unread")
        XCTAssertEqual(model.conversationMessages(root: "unread").map(\.id), ["unread"])
        var bootstrap = ChatScrollPosition()
        XCTAssertTrue(bootstrap.update(model.conversationMessages(root: "unread"), me: "me"))
        bootstrap.measured(bottom: true, anchor: "unread")
        model.positions["unread"] = bootstrap
        let host = delayedThreadHost(model)
        defer { host.close() }
        try await host.settle()
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        try store.dmWrite { db in
            for sequence in 4...lastSequence {
                try ChatDMStore.write(db, .init(messageId: "reply-\(sequence)", dmId: "fixture-dm", threadRootId: "unread",
                    authorAccountId: "nora", text: "Fictional reply \(sequence)", mentions: [], revision: 1,
                    seq: sequence, createdAt: "2026-10-24T10:00:00Z"))
            }
        }
        for _ in 0..<300 { if model.conversationMessages(root: "unread").count == lastSequence - 2 && !model.threadHasEarlier { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.threadUnreadID, "reply-5")
        if lastSequence == 30 {
            XCTAssertEqual(model.positions["unread"]?.anchor, "reply-4")
            XCTAssertEqual(model.positions["unread"]?.atBottom, false)
        }
        XCTAssertGreaterThan(model.readingPositionRestored, 0)
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        try await host.settle()
        XCTAssertEqual(model.positions["unread"]?.atBottom, lastSequence == 5)
        model.readIfLooking(root: "unread", appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(try store.dmRead { try Int.fetchOne($0, sql: "SELECT seq FROM dm_marks WHERE dm_id = 'fixture-dm' AND root = 'unread'") }, lastSequence == 5 ? 5 : 4)
        var retained = try XCTUnwrap(model.positions["unread"])
        retained.measured(bottom: false, anchor: lastSequence == 30 ? "reply-12" : "reply-4")
        model.positions["unread"] = retained
        model.openThread(nil); model.openThread("unread")
        XCTAssertEqual(model.positions["unread"], retained)
        if lastSequence == 30 {
            host.close()
            model.revealSearchMessage(try XCTUnwrap(model.message("reply-30")), in: model.conversationMessages(root: "unread"))
            let probe = ChatScrollProbe()
            let targetHost = delayedThreadHost(model, probe: probe)
            defer { targetHost.close() }
            try await targetHost.settle()
            probe.scroll = ChatScrollMounted<ChatScrollFixture>.descendants(targetHost.view, NSScrollView.self).first
            XCTAssertEqual(model.revealMessageID, "reply-30")
            let targetFrame = try XCTUnwrap(probe.frames["reply-30"])
            XCTAssertTrue(CGRect(x: 0, y: 0, width: 620, height: 280).contains(targetFrame), "Explicit target frame: \(targetFrame)")
        }
    }

    func testThreadBackToTallLatestMessageResumesNativePositionUpdates() async throws {
        let (store, model) = try channel()
        try await store.queue.write { db in
            try db.execute(sql: "UPDATE messages SET text = ? WHERE message_id = 'latest'",
                arguments: [Array(repeating: "Fictional multiline message", count: 30).joined(separator: "\n")])
        }
        model.isPopup = true
        var latest = ChatScrollPosition()
        _ = latest.update(model.feed.messages, me: "me")
        latest.measured(bottom: true, anchor: "latest")
        model.positions[""] = latest
        model.openThread("unread"); model.openThread(nil)
        let host = delayedThreadHost(model, root: nil)
        defer { host.close() }
        try await host.settle()
        let container = try XCTUnwrap(ChatScrollMounted<ChatScrollFixture>.descendants(host.view, NativeChatTimelineContainer.self).first)
        let viewport = container.coordinator.scrollController, scroll = try XCTUnwrap(viewport.scroll)
        XCTAssertTrue(viewport.atBottom)
        XCTAssertGreaterThan(try XCTUnwrap(scroll.documentView).bounds.height, 280)
        viewport.stopFollowing()
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await host.settle()
        XCTAssertFalse(viewport.atBottom)
        XCTAssertEqual(model.positions[""]?.atBottom, false, "A tall final message must not leave restoration permanently pending")
    }

    private func delayedThreadHost(_ model: any ChatConversationPresentation, root: String? = "unread", probe: ChatScrollProbe? = nil) -> ChatQuietHost {
        let host = ChatQuietHost(content: AnyView(ChatTimelineView(model: model, root: root, members: [],
            mentionable: [], me: "me", archived: false, ownerModel: nil)), dark: true, width: 620, height: 280)
        probe?.frameProvider = { [weak view = host.view] in
            guard let view else { return [:] }
            return ChatScrollMounted<ChatScrollFixture>.descendants(view, NativeChatTimelineContainer.self)
                .first?.coordinator.scrollController.bodyFrames ?? [:]
        }
        return host
    }

    func testChannelWithoutUnreadKeepsNormalLatestBootstrap() throws {
        let (store, _) = try channel()
        try store.queue.write { try $0.execute(sql: "UPDATE read_marks SET last_read_seq = 10, thread_read_seq = 10") }
        let model = ChatChannelModel(key: key, channel: "design")
        model.follow(store); model.isPopup = true
        XCTAssertNil(model.feed.unreadID)
        XCTAssertNil(model.positions[""], "Without a target, retained anchor or unread, the shared timeline follows latest")
    }

    func testChannelPopupEscapeAndThreadBackDoNotMarkAnythingRead() throws {
        let (store, model) = try channel()
        let before = try store.queue.read { try Int.fetchOne($0, sql: "SELECT last_read_seq FROM read_marks WHERE channel_id = 'design'") }
        model.isPopup = true; model.openThread("unread")
        XCTAssertFalse(model.dismissTransient())
        XCTAssertEqual(model.threadRoot, "unread")
        model.openThread(nil)
        XCTAssertEqual(try store.queue.read { try Int.fetchOne($0, sql: "SELECT last_read_seq FROM read_marks WHERE channel_id = 'design'") }, before)
        XCTAssertEqual(try store.queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM thread_read_marks") }, 0)
    }

    func testChannelFailedDraftFlushKeepsTextAndContextUntilRetry() throws {
        let (store, model) = try channel()
        model.isPopup = true
        try store.queue.write { try $0.execute(sql: "CREATE TEMP TRIGGER fixture_draft_failure BEFORE INSERT ON drafts BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END") }
        model.saveDraft("Keep this exact draft", root: nil, mentionOnly: true, contextIds: ["before", "latest"])
        XCTAssertEqual(model.composerDraft(root: nil), .init(text: "Keep this exact draft", mentionOnly: true, contextIds: ["before", "latest"]))
        XCTAssertNil(model.draftVersion(root: nil))
        XCTAssertThrowsError(try model.flushConversationDrafts())
        XCTAssertNotNil(model.draftSaveProblem)
        model.openThread("unread")
        XCTAssertNil(model.threadRoot, "A failed draft save must prevent replacing its composer")
        try store.queue.write { try $0.execute(sql: "DROP TRIGGER fixture_draft_failure") }
        model.retryDraftSave()
        let version = try XCTUnwrap(model.draftVersion(root: nil))
        XCTAssertEqual(model.composerDraft(root: nil), .init(text: "Keep this exact draft", version: version, mentionOnly: true, contextIds: ["before", "latest"]))
        XCTAssertNil(model.draftSaveProblem)
        XCTAssertNoThrow(try model.flushConversationDrafts())
    }

    func testDMThreadBackKeepsPerRootDraftsAndParentAnchor() async throws {
        let (_, service) = try await directMessage()
        let model = ChatDMModel(key: key, dm: "fixture-dm", service: service)
        defer { model.stop() }
        model.isPopup = true
        XCTAssertEqual(model.positions[""]?.anchor, "before")
        let parentPosition = model.positions[""]
        let parentVersion = try XCTUnwrap(model.saveDraft("Parent draft", root: nil))
        model.openThread("unread")
        let replyVersion = try XCTUnwrap(model.saveDraft("Thread draft", root: "unread"))
        model.openThread(nil)
        XCTAssertEqual(model.positions[""], parentPosition)
        XCTAssertEqual(model.readingPositionRestored, 1)
        XCTAssertEqual(model.draft(root: nil), .init(text: "Parent draft", version: parentVersion))
        XCTAssertEqual(model.draft(root: "unread"), .init(text: "Thread draft", version: replyVersion))
        XCTAssertFalse(model.dismissTransient())
        XCTAssertTrue(model.hasConversationDraft)
    }

    func testDMSendClearsSentDraftAndKeepsTheSamePopupOpen() async throws {
        let (store, service) = try await directMessage()
        let workspace = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
            drafts: DraftRepository(), engineFactory: { TestEngine() })
        defer { workspace.terminate() }
        let state = TabState(route: .directMessage(ChatDMRef(key, dm: "fixture-dm")))
        let model = ChatDMModel(key: key, dm: "fixture-dm", state: state, service: service)
        state.dmModel = model
        let id = UUID()
        let session = Session(id: id, engine: NativeTabEngine(state: state, tabID: id),
            currentDirectory: directory, agent: .terminal)
        session.content = .tool(state.route)
        XCTAssertTrue(workspace.popups.presentConversation(session))
        XCTAssertTrue(workspace.popups.visibleConversation === session)
        XCTAssertTrue(model.isPopup)

        let text = "The fictional workspace copy is ready."
        let version = try XCTUnwrap(model.saveDraft(text, root: nil))
        XCTAssertTrue(session.hasConversationDraft)
        XCTAssertTrue(model.send(text, root: nil, members: [], version: version))

        let commands = try store.outbox.commands().filter { $0.type == "dm.message.post" }
        XCTAssertEqual(commands.count, 1)
        let command = try XCTUnwrap(commands.first)
        let messageID = try XCTUnwrap(ChatService.args(command)["message_id"]?.string)
        XCTAssertEqual(ChatService.args(command), [
            "dm_id": .string("fixture-dm"), "message_id": .string(messageID),
            "text": .string(text), "mentions": .array([])
        ])
        XCTAssertNil(try store.dmRead { try ChatDMStore.draft($0, "fixture-dm", root: nil) })
        // GRDB delivers changes after the initial snapshot asynchronously on
        // the main actor. Wait for this exact send transaction to reach the
        // model before checking its observed draft state.
        for _ in 0..<300 {
            if model.message(messageID) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.message(messageID)?.text, text)
        XCTAssertNil(model.draft(root: nil))
        XCTAssertFalse(session.hasConversationDraft)
        XCTAssertTrue(workspace.popups.isPresented)
        XCTAssertTrue(workspace.popups.visibleConversation === session)
        XCTAssertTrue(state.dmModel === model)
        XCTAssertTrue(model.isPopup)
        XCTAssertFalse(state.isClosed)
        XCTAssertTrue(workspace.popups.backStack.isEmpty)
        XCTAssertTrue(workspace.allSessions.isEmpty, "Send must not promote or navigate away from the popup")
    }

    func testDMFailedSaveBlocksDepartureAndRetryPreservesBothRoots() async throws {
        let (store, service) = try await directMessage()
        let model = ChatDMModel(key: key, dm: "fixture-dm", service: service)
        defer { model.stop() }
        model.isPopup = true
        let savedVersion = try XCTUnwrap(model.saveDraft("Parent saved", root: nil))
        model.openThread("unread")
        try store.dmWrite { try $0.execute(sql: "CREATE TEMP TRIGGER fixture_dm_draft_failure BEFORE INSERT ON dm_drafts BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END") }
        XCTAssertNil(model.saveDraft("Unsent reply retained", root: "unread"))
        XCTAssertEqual(model.draft(root: "unread")?.text, "Unsent reply retained")
        XCTAssertThrowsError(try model.flushConversationDrafts())
        model.openThread(nil)
        XCTAssertEqual(model.threadRoot, "unread")
        try store.dmWrite { try $0.execute(sql: "DROP TRIGGER fixture_dm_draft_failure") }
        model.retryDraftSave(); model.openThread(nil)
        XCTAssertNil(model.threadRoot)
        XCTAssertNil(model.draftSaveProblem)
        XCTAssertEqual(model.draft(root: nil), .init(text: "Parent saved", version: savedVersion))
        let persisted = try store.dmRead { try ChatDMStore.draft($0, "fixture-dm", root: "unread") }
        XCTAssertEqual(model.draft(root: "unread"), .init(text: "Unsent reply retained", version: try XCTUnwrap(persisted?.version)))
    }

    func testPersonDraftFailureKeepsExactTextUntilRetry() async throws {
        let (store, service) = try await directMessage(includeCard: false)
        let model = try XCTUnwrap(service.dmPeer(key, peer: "nora"))
        defer { model.stop() }
        model.isPopup = true
        try store.dmWrite { try $0.execute(sql: "CREATE TEMP TRIGGER fixture_peer_draft_failure BEFORE INSERT ON dm_drafts BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END") }
        XCTAssertNil(model.saveDraft("A fictional first message", root: nil))
        XCTAssertEqual(model.draft(root: nil)?.text, "A fictional first message")
        XCTAssertTrue(model.hasConversationDraft)
        XCTAssertThrowsError(try model.flushConversationDrafts())
        try store.dmWrite { try $0.execute(sql: "DROP TRIGGER fixture_peer_draft_failure") }
        model.retryDraftSave()
        let persisted = try store.dmRead { try ChatDMStore.draft($0, "peer:nora", root: nil) }
        XCTAssertEqual(model.draft(root: nil), .init(text: "A fictional first message", version: try XCTUnwrap(persisted?.version)))
        XCTAssertNil(model.draftSaveProblem)
    }

    func testChannelEditedMessageDraftSurvivesFailedSaveUntilRetry() throws {
        let (store, model) = try channel()
        model.isPopup = true
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("before")), root: nil))
        try store.queue.write { try $0.execute(sql: "CREATE TEMP TRIGGER fixture_edit_failure BEFORE INSERT ON edit_drafts BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END") }
        model.editing?.text = "Exact edited copy"
        XCTAssertEqual(model.editing?.text, "Exact edited copy")
        XCTAssertThrowsError(try model.flushConversationDrafts())
        model.openThread("unread")
        XCTAssertNil(model.threadRoot)
        try store.queue.write { try $0.execute(sql: "DROP TRIGGER fixture_edit_failure") }
        model.retryDraftSave()
        XCTAssertEqual(model.editing?.text, "Exact edited copy")
        XCTAssertEqual(model.editing, try store.queue.read { try ChatEditDrafts.read($0, channel: "design").first })
        XCTAssertNil(model.draftSaveProblem)
    }

    func testDMEditedMessageDraftSurvivesFailedSaveUntilRetry() async throws {
        let (store, service) = try await directMessage()
        let model = ChatDMModel(key: key, dm: "fixture-dm", service: service)
        defer { model.stop() }
        model.isPopup = true
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("before")), root: nil))
        try store.dmWrite { try $0.execute(sql: "CREATE TEMP TRIGGER fixture_dm_edit_failure BEFORE INSERT ON dm_edits BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END") }
        model.editing?.text = "Exact private edited copy"
        XCTAssertEqual(model.editing?.text, "Exact private edited copy")
        XCTAssertThrowsError(try model.flushConversationDrafts())
        model.openThread("unread")
        XCTAssertNil(model.threadRoot)
        try store.dmWrite { try $0.execute(sql: "DROP TRIGGER fixture_dm_edit_failure") }
        model.retryDraftSave()
        let persisted = try store.dmRead { try Data.fetchOne($0, sql: "SELECT body FROM dm_edits WHERE dm_id = 'fixture-dm' AND message_id = 'before'") }
        XCTAssertEqual(model.editing, try JSONDecoder().decode(ChatChannelModel.Editing.self, from: XCTUnwrap(persisted)))
        XCTAssertEqual(model.editing?.text, "Exact private edited copy")
        XCTAssertNil(model.draftSaveProblem)
    }
}
