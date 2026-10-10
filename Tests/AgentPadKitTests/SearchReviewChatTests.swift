import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

@MainActor
final class SearchReviewChatTests: XCTestCase {
    private var root: URL!
    private var service: ChatService!
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private var key: ChatOrgKey { .init(server: server, accountId: "account", orgId: "org") }
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("search-chat-review-\(UUID())")
        service = ChatService(files: ChatFiles(directory: root), tokens: FakeTokenStore())
        service.followsFeed = false; service.closeRemoteSession = { _, _ in }
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
    }
    override func tearDown() async throws {
        await service.disconnect(); service = nil; ChatStubProtocol.reset()
        try? FileManager.default.removeItem(at: root)
    }
    private func connect() async throws -> ChatStore {
        try service.saveSignIn(.init(server: server, accountId: key.accountId, sessionId: "session", deviceName: "test", orgId: key.orgId), token: "fixture")
        try await service.start(mode: .server)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try store.finishGeneration("generation")
        try store.apply(ChatSnapshot(cursors: [:], members: [.init(accountId: key.accountId, handle: "me", name: "Me", role: "member")],
            teams: [.init(teamId: "team", name: "Team", mine: true)], teamMembers: [.init(teamId: "team", accountId: key.accountId)],
            channels: [.init(channelId: "channel", teamId: "team", name: "Channel", archived: false, version: 1)], channelsComplete: true, agentChannels: []), confirmsRights: "session")
        try store.endChannelsRead(since: 0, seen: ["channel"])
        service.orgSessions[key]?.snapshotOwed = false
        service.serverCapabilities[server] = ["chat.search", "chat.dm"]
        return store
    }
    private func hit(_ id: String) -> ChatSearchHit {
        .init(kind: .channel, targetID: "channel", messageID: id, messageSeq: id == "one" ? 1 : 2, revision: 2,
              authorAccountID: "account", createdAt: "2026-10-09T12:00:00Z", snippet: "searchword")
    }
    private func serve() throws {
        let first = try JSONEncoder().encode(ChatSearchPage(hits: [hit("one")], next: "page2"))
        let second = try JSONEncoder().encode(ChatSearchPage(hits: [hit("two")], next: "page3"))
        ChatStubProtocol.reset { _, body in
            let more = (try? JSONDecoder().decode(ChatSearchRequest.self, from: body).cursor) != nil
            return .success(.init(status: 200, body: more ? second : first))
        }
    }
    private func settle(_ model: ChatSearchModel) async throws {
        for _ in 0..<200 { if !model.loading { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("Search did not settle")
    }
    func testReconnectBindsObservationToReplacementStoreAndRevokesVisibleHitsImmediately() async throws {
        let first = try await connect(); try serve()
        let model = ChatSearchModel(service: service)
        model.search(.init(query: "searchword"), debounce: false); try await settle(model)
        XCTAssertEqual(model.hits.count, 1)
        await service.disconnect(); model.invalidate()
        let second = try await connect(); XCTAssertFalse(first === second); try serve()
        try await Task.sleep(for: .milliseconds(50))
        model.search(.init(query: "searchword"), debounce: false); try await settle(model)
        XCTAssertEqual(model.hits.count, 1)
        var invalidations = 0; model.onInvalidation = { invalidations += 1 }
        try SearchCache.write(second.queue) { try $0.execute(sql: "UPDATE teams SET mine=0 WHERE team_id='team'") }
        XCTAssertTrue(model.hits.isEmpty, "Access must be checked even before the UI observer runs")
        for _ in 0..<100 { if invalidations > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(invalidations, 0, "The replacement ChatStore must be observed")
    }
    func testNavigationCacheWritePreservesAllLoadedPagesAndCursor() async throws {
        let store = try await connect(); try serve()
        let model = ChatSearchModel(service: service), request = ChatSearchRequest(query: "searchword")
        model.onInvalidation = { model.search(request, debounce: false) }
        model.search(request, debounce: false); try await settle(model)
        model.search(request, more: true, debounce: false); try await settle(model)
        XCTAssertEqual(model.hits.map(\.messageID), ["one", "two"])
        let wire = try JSONDecoder().decode(ChatMessageWire.self, from: Data(#"{"message_id":"two","channel_id":"channel","author_account_id":"account","seq":2,"revision":2,"text":"searchword","created_at":"2026-10-09T12:00:00Z"}"#.utf8))
        try SearchCache.write(store.queue) { _ = try ChatMessages.write($0, wire) }
        XCTAssertEqual(model.hits.map(\.messageID), ["one", "two"])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.hits.map(\.messageID), ["one", "two"]); XCTAssertEqual(model.next, "page3")
        XCTAssertEqual(ChatStubProtocol.seen.count, 2, "Navigation must not refetch the first page")
        model.onInvalidation = nil
        try SearchCache.write(store.queue) { try $0.execute(sql: "UPDATE messages SET revision=3, text='changed' WHERE message_id='two'") }
        XCTAssertFalse(model.hits.contains { $0.messageID == "two" }, "A newer cached revision must hide the obsolete snippet")
    }

    func testMessageResultsReuseLocalAndDetachedTabsAndRevealRootsAndReplies() async throws {
        let isolation = TeamServiceTestScope()
        defer { isolation.close() }
        let cache = try await connect()
        let service = try XCTUnwrap(self.service)
        try SearchCache.write(cache.queue) {
            try $0.execute(sql: "INSERT INTO channel_windows (channel_id, epoch, bottom_seq) VALUES ('channel', 1, 100)")
        }
        var stores: [WorkspaceStore] = []
        let origin = WorkspaceStore(persistence: InMemoryPersistence(), engineFactory: { TestEngine() }, peerStores: { stores })
        let detached = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true,
                                      engineFactory: { TestEngine() }, peerStores: { stores })
        stores = [origin, detached]
        let previous = AgentMonitor.shared.storesProvider
        AgentMonitor.shared.storesProvider = { stores }
        defer { AgentMonitor.shared.storesProvider = previous; stores.forEach { $0.terminate() }; stores = [] }
        let tab = origin.openChannelTab(ChannelRef(key, channel: "channel"), in: try XCTUnwrap(origin.active))
        let projection = AttentionSidebarModel(ledger: AttentionLedger(), service: service)
        let router = TabRouter()
        router.stores = { stores }
        router.prepareDestinations = { projection.updateProjection() }
        router.destinations = { projection.projection.tabs }
        router.channelScope = { [service, key] ref in
            ref.belongs(to: key) && ChatNotifications.allowed(service, key, channel: ref.channel)
                ? ChatAttention.scope(key, service) : nil
        }
        var revealedWindow: UUID?
        router.revealWindow = { revealedWindow = $0.windowID }
        let index = ConversationIndex(directory: root.appendingPathComponent("index"), roots: [:], visibility: { .init(channelIds: []) })
        let model = EverywhereSearchModel(messages: ChatSearchModel(service: service), indexing: .init(index: index),
            catalog: .init(scan: { _ in .init(records: [], scanned: 0, total: 0, skipped: 0) }),
            names: SessionNames(url: root.appendingPathComponent("names.sqlite")), visibility: { .init(channelIds: []) })
        let channel = ChatChannelModel(key: key, channel: "channel")
        channel.service = service; channel.canAutomaticallyRead = { false }; channel.follow(cache)
        let count = stores.flatMap(\.allSessions).count
        for owner in stores {
            if owner === detached {
                // The same live-session transfer used when detaching a tab.
                let workspace = try XCTUnwrap(detached.active), pane = try XCTUnwrap(workspace.activePane)
                XCTAssertTrue(detached.handleTabDrop(droppedId: tab.id, to: pane, at: 0, in: workspace))
                XCTAssertNil(origin.channelTab(ChannelRef(key, channel: "channel")))
            }
            _ = owner.addEmptyWorkspace() // The resolver must also select the hidden workspace.
            for id in ["one", "two"] {
                var result = hit(id)
                result.threadRootID = id == "two" ? "one" : nil
                let wire = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: [
                    "message_id": id, "channel_id": "channel", "thread_root_id": result.threadRootID as Any? ?? NSNull(),
                    "author_account_id": "account", "seq": result.messageSeq, "revision": 3,
                    "text": "Current server message", "created_at": result.createdAt
                ]))
                let page = try JSONEncoder().encode(ChatMessagesPage(messages: [wire], next: nil, head: 100))
                ChatStubProtocol.reset { _, _ in .success(.init(status: 200, body: page)) }
                await SearchNavigation.open(result, model: model, from: origin, service: service, router: router)
                XCTAssertNil(model.navigationError)
                XCTAssertTrue(model.returnAvailable)
                XCTAssertEqual(revealedWindow, owner.windowID)
                XCTAssertTrue(owner.active?.activeSession === tab)
                XCTAssertEqual(stores.flatMap(\.allSessions).count, count, "Message results must not duplicate a channel tab")
                let wrongHost = try XCTUnwrap(origin.allSessions.first { $0 !== tab }?.engine.view)
                XCTAssertNil(ChatMessageNavigation.take(key: key, channel: "channel", from: wrongHost))
                let link = try XCTUnwrap(ChatMessageNavigation.take(key: key, channel: "channel", from: tab.engine.view))
                XCTAssertEqual(link.message, id); XCTAssertEqual(link.sequence, result.messageSeq)
                channel.navigate(to: link)
                XCTAssertEqual(channel.revealMessageID, id, "The reused tab receives the scroll and highlight target")
                XCTAssertEqual(channel.threadRoot, result.threadRootID)
                let messages = id == "one" ? channel.feed.messages : channel.thread
                XCTAssertEqual(messages.first { $0.id == id }?.text, "Current server message")
                channel.finishNavigation()
            }
        }
        XCTAssertEqual(try SearchCache.read(cache.queue) { try ChatUnread.readSequence($0, channel: "channel") }, 0)
    }

    func testDMNavigationCacheWriteIncludingActivityPreservesPages() async throws {
        let store = try await connect()
        let card = ChatDMCard(dmId: "dm", peer: .init(accountId: "peer", name: "Peer", handle: "peer", active: true), state: "active",
            version: 1, createdAt: "2026-10-09T12:00:00Z")
        try store.dmWrite { try ChatDMStore.writeCard($0, card) }
        let context = ChatSearchContext(key: key, session: "session", generation: "generation", revision: 0)
        var one = hit("one"), two = hit("two"); one.kind = .dm; one.targetID = "dm"; two.kind = .dm; two.targetID = "dm"
        var calls = 0
        let model = ChatSearchModel(context: { context }, availability: { .ready }, fetch: { _, request in
            calls += 1
            return request.cursor == nil ? .init(hits: [one], next: "page2") : .init(hits: [two], next: "page3")
        })
        model.useLoadedHistory([], key: key, store: store, allowed: { true }) // Attach the same production cache observation.
        let request = ChatSearchRequest(query: "searchword")
        model.onInvalidation = { model.search(request, debounce: false) }
        model.search(request, debounce: false); try await settle(model)
        model.search(request, more: true, debounce: false); try await settle(model)
        let wire = ChatDMMessageWire(messageId: "two", dmId: "dm", authorAccountId: "peer", text: "searchword", mentions: [], revision: 2, seq: 2, createdAt: "2026-10-09T12:01:00Z")
        try store.dmWrite { try ChatDMStore.write($0, wire) }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(model.hits.map(\.messageID), ["one", "two"]); XCTAssertEqual(model.next, "page3"); XCTAssertEqual(calls, 2)
    }
}
