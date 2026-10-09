import Foundation
import AppKit
import SwiftUI
import GRDB
import XCTest
@testable import AgentPadKit

private final class DMQueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []
    func append(_ event: Database.TraceEvent) {
        if case .statement(let statement) = event {
            lock.lock(); defer { lock.unlock() }
            statements.append(statement.sql.lowercased())
        }
    }
    var selects: [String] {
        lock.lock(); defer { lock.unlock() }
        return statements.filter { $0.hasPrefix("select") }
    }
    func reset() { lock.lock(); defer { lock.unlock() }; statements = [] }
}

@MainActor
final class ChatDMTests: XCTestCase {
    private var root: URL!
    private var scope: TeamServiceTestScope!
    private var service: ChatService!
    private var store: ChatStore!
    private var sync: ChatDMSync!
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private let me = "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40"
    private let peer = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    private let dm = "2c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f"
    private let org = "0d6f8e2a-4b1c-4a8d-9e7f-3a2b1c0d9e8f"
    private var key: ChatOrgKey { .init(server: server, accountId: me, orgId: org) }
    private var gate: Gate?
    private let routes = ChannelRoutes()
    private var socket: ChatSocket!
    private var transport: FakeSocketTransport!
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/dm/\(name).json"))
    }
    private func decode<T: Decodable>(_ name: String, as type: T.Type) throws -> T { try JSONDecoder().decode(type, from: fixture(name)) }
    private func write(_ body: (Database) throws -> Void) throws { try store.dmWrite(body) }
    private func read<T>(_ body: (Database) throws -> T) throws -> T { try store.dmRead(body) }
    override func setUp() async throws {
        scope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dm-tests-\(UUID())")
        service = ChatService(files: ChatFiles(directory: root), tokens: FakeTokenStore())
        service.followsFeed = false
        service.closeRemoteSession = { _, _ in }
        try service.saveSignIn(.init(server: server, accountId: me, sessionId: "s-me", deviceName: "Mac", orgId: org), token: "test-only")
        try await service.start(mode: .server)
        store = try XCTUnwrap(service.orgSessions[key]?.store)
        try store.apply(ChatSnapshot(cursors: [:], members: [.init(accountId: me, handle: "me", name: "Me", role: "member"),
            .init(accountId: peer, handle: "boris", name: "Boris", role: "member")]), confirmsRights: "s-me")
        service.orgSessions[key]?.snapshotOwed = false
        let api = ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self])
        let transport = FakeSocketTransport(); self.transport = transport
        socket = ChatSocket(server: server, token: "test-only", makeTransport: { transport })
        let owner = ChatSync(key: key, store: store, api: api, socket: socket, outbox: nil, token: "test-only")
        service.orgSessions[key]?.sync = owner; sync = owner.dm
        sync.sessionId = "s-me"
        service.serverCapabilities[server] = ["chat.dm"]
        sync.configure(true)
        let routes = routes
        ChatStubProtocol.reset { request, _ in
            let path = request.url!.path + (request.url!.query.map { "?" + $0 } ?? "")
            if routes.gated == path { routes.gate?.pass() }
            let answer = routes.answer(path) ?? routes.answer(request.url!.path)
            return .success(.init(status: answer?.0 ?? 404, body: answer?.1 ?? Data(#"{"error":"not_found"}"#.utf8)))
        }
        routes.set("/v1/orgs/\(org)/dms", String(decoding: try fixture("dms_response"), as: UTF8.self))
        routes.set("/v1/orgs/\(org)/dms/\(dm)", String(decoding: try fixture("dm_response"), as: UTF8.self))
        routes.set("/v1/orgs/\(org)/dms/\(dm)/messages", String(decoding: try fixture("dm_messages_response"), as: UTF8.self))
    }
    override func tearDown() async throws {
        gate?.open(); service?.orgSessions.values.forEach { $0.sync?.stop(); $0.outbox?.hold() }; sync?.stop(); service?.stopFeed(); socket?.stop(); service = nil; store = nil; sync = nil; socket = nil; transport = nil
        try? FileManager.default.removeItem(at: root)
        scope.close(); scope = nil
    }
    private func ready() async throws { try await sync.reloadCatalog(valid: { true }) }
    func testSearchNavigationRevealsExactSavedMessageWithoutWritingReadMarks() async throws {
        try await ready()
        let page = try decode("dm_messages_response", as: ChatDMMessagesPage.self)
        try write { db in for message in page.messages { try ChatDMStore.write(db, message) } }
        let target = try XCTUnwrap(page.messages.last)
        let before = try read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dm_marks") }
        let model = ChatDMModel(key: key, dm: dm, service: service)
        model.navigateToSearchMessage(target.messageId)
        XCTAssertEqual(model.revealMessageID, target.messageId)
        XCTAssertEqual(model.threadRoot, target.threadRootId)
        XCTAssertEqual(try read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dm_marks") }, before)
        model.stop()
    }
    func testSearchServiceRequiresCapabilitiesAndInvalidatesOnlyChangedCachedMessages() async throws {
        try await ready(); try store.setGeneration("search-generation")
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        let model = ChatSearchModel(service: service)
        let request = ChatSearchRequest(query: "release")
        model.search(request, debounce: false)
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.url?.path.hasSuffix("/chat/search") == true })
        service.serverCapabilities[server] = ["chat.dm", "chat.search"]
        let target = try decode("dm_messages_response", as: ChatDMMessagesPage.self).messages[0]
        let hit = ChatSearchHit(kind: .dm, targetID: dm, messageID: target.messageId, messageSeq: target.seq, revision: target.revision,
                                authorAccountID: target.authorAccountId, createdAt: target.createdAt, snippet: "release")
        routes.set("/v1/orgs/\(org)/chat/search", String(decoding: try JSONEncoder().encode(ChatSearchPage(hits: [hit], next: nil)), as: UTF8.self))
        model.search(request, debounce: false)
        try await wait { !model.loading }
        XCTAssertEqual(model.hits.count, 1)
        try write { try ChatDMStore.write($0, target) }
        XCTAssertEqual(model.hits, [hit], "An unchanged cache fill must preserve search results")
        var edited = target; edited.revision += 1; edited.text = "changed"
        try write { try ChatDMStore.write($0, edited) }
        XCTAssertTrue(model.hits.isEmpty, "A newer message revision fences the stale snippet before the UI callback")
        model.invalidate()
        service.serverCapabilities[server] = ["chat.search"]
        XCTAssertEqual(service.searchAvailability, .unsupported)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("DM work did not settle")
    }

    // Review regressions: sending belongs to the durable queue, and observers
    // must not make typing or closed tabs read unrelated history.
    func testFirstSendIsArchivedBeforeOpenReturns() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        routes.set("/v1/commands", #"{"events":[],"result":{"dm_id":"\#(dm)"}}"#)
        try await ready()
        let beforeDisconnect = try sendingQueue()
        let gate = Gate(); self.gate = gate; routes.gate = gate
        routes.gated = "/v1/commands"; gate.close()
        let model = try XCTUnwrap(service.dmPeer(key, peer: peer))
        let version = try XCTUnwrap(model.saveDraft("durable first hello", root: nil))
        _ = model.send("durable first hello", root: nil, members: [], version: version)
        let commands = try store.outbox.commands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(ChatService.args(try XCTUnwrap(commands.first))["text"]?.string, "durable first hello")
        XCTAssertNil(try read { try ChatDMStore.draft($0, "peer:\(peer)", root: nil) })
        beforeDisconnect.allow(connection: 1, generation: "g1")
        try await wait { ChatStubProtocol.seen.contains { $0.request.url?.path == "/v1/commands" } }
        let outcome = await service.disconnect(expecting: service.connection)
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(service.disconnectedDMCount, 1)
        let archive = try XCTUnwrap(service.files.savedDMOutbox(key))
        XCTAssertEqual(archive.count, 1)
        let original = try XCTUnwrap(archive.commands.first)
        XCTAssertEqual(ChatService.args(original)["peer_account_id"]?.string, peer)
        XCTAssertEqual(ChatService.args(original)["text"]?.string, "durable first hello")
        XCTAssertNotNil(ChatService.args(original)["message_id"]?.string)
        gate.open()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(try service.files.savedDMOutbox(key)?.commands.first?.bodyBytes, original.bodyBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.files.cacheURL(key).path), "The late open must not recreate the disconnected cache")
        let restored = ChatOrgSession(key: key, files: service.files)
        let record = try XCTUnwrap(restored.store?.outbox.commands().first)
        XCTAssertEqual(record.bodyBytes, original.bodyBytes)
        XCTAssertEqual(record.state, .unconfirmed)
        restored.startSending(api: ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self]), token: "new-token", sessionId: "s-new", journal: nil, onUnauthorized: {})
        let queue = try XCTUnwrap(restored.outbox)
        defer { queue.hold() }
        queue.allow(connection: 2, generation: "g1")
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }.count, 1)
        let repeated = try queue.resendUnconfirmed()
        XCTAssertEqual(repeated.count, 1)
        queue.pump()
        try await wait { (try? restored.store?.outbox.commands().last?.state) == .sent }
        let sent = try ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }
            .map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body) }
        XCTAssertEqual(sent.map(\.type), ["dm.open", "dm.open", "dm.message.post"])
        XCTAssertEqual(sent.first?.commandId, sent.dropFirst().first?.commandId)
        XCTAssertEqual(sent.last?.args["message_id"], ChatService.args(original)["message_id"])
        XCTAssertNil(sent.last?.args["peer_account_id"])
        XCTAssertNil(sent.last?.args["open_command_id"])
    }

    func testFirstSendRestoresResolvedAddressWithoutOpeningAgain() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        routes.set("/v1/commands", #"{"events":[],"result":{"dm_id":"\#(dm)"}}"#)
        try await ready()
        let queue = try sendingQueue()
        queue.onDMOpened = { [weak queue] _ in queue?.hold() }
        let model = try XCTUnwrap(service.dmPeer(key, peer: peer))
        let version = try XCTUnwrap(model.saveDraft("resume after open", root: nil))
        XCTAssertTrue(model.send("resume after open", root: nil, members: [], version: version))
        let original = try XCTUnwrap(store.outbox.commands().first)
        queue.allow(connection: 1, generation: "g1")
        try await wait { (try? self.store.outbox.commands().first.map { ChatService.args($0)["dm_id"]?.string }) == self.dm }
        XCTAssertNil(try read { try ChatDMStore.card($0, dm) })
        let outcome = await service.disconnect(expecting: service.connection)
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(service.disconnectedDMCount, 1)
        let restored = ChatOrgSession(key: key, files: service.files)
        restored.startSending(api: ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self]), token: "new-token", sessionId: "s-new", journal: nil, onUnauthorized: {})
        let resumed = try XCTUnwrap(restored.outbox), cache = try XCTUnwrap(restored.store)
        defer { resumed.hold() }
        XCTAssertEqual(try resumed.resendUnconfirmed().count, 1)
        try service.files.saveDMOutbox(key, store: cache)
        XCTAssertEqual(try service.files.savedDMOutbox(key)?.count, 1)
        resumed.allow(connection: 2, generation: "g1")
        try await wait { (try? cache.outbox.commands().last?.state) == .sent }
        let sent = try ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }
            .map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body) }
        XCTAssertEqual(sent.map(\.type), ["dm.open", "dm.message.post"])
        XCTAssertEqual(sent.last?.args["message_id"], ChatService.args(original)["message_id"])
        try service.files.saveDMOutbox(key, store: cache)
        XCTAssertEqual(try service.files.savedDMOutbox(key)?.count, 0)
    }

    func testFirstSendRetriesBothStepsWithIdenticalWireIDsAndOneMessage() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        var card = try decode("dm_response", as: ChatDMCard.self); card.messages = []; card.head = 0
        routes.set("/v1/orgs/\(org)/dms/\(dm)", String(decoding: try JSONEncoder().encode(card), as: UTF8.self))
        routes.set("dm.open", #"{"error":"temporary"}"#, status: 503)
        routes.set("dm.message.post", #"{"error":"temporary"}"#, status: 503)
        let routes = routes
        ChatStubProtocol.reset { request, body in
            let type = (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: body))?.type
            let response = routes.answer(type ?? request.url!.path)
            return .success(.init(status: response?.0 ?? 404, body: response?.1 ?? Data()))
        }
        let queue = try sendingQueue()
        let model = try XCTUnwrap(service.dmPeer(key, peer: peer))
        let version = try XCTUnwrap(model.saveDraft("retry exactly once", root: nil))
        XCTAssertTrue(model.send("retry exactly once", root: nil, members: [], version: version))
        let original = try XCTUnwrap(store.outbox.commands().first)
        queue.allow(connection: 1, generation: "g1")
        try await wait { (try? self.store.outbox.commands().first?.attempts) == 1 }
        routes.set("dm.open", #"{"events":[],"result":{"dm_id":"\#(dm)"}}"#)
        try write { try $0.execute(sql: "UPDATE outbox SET next_attempt_at = NULL") }; queue.pump()
        try await wait {
            guard let row = try? self.store.outbox.commands().first else { return false }
            return ChatService.args(row)["dm_id"]?.string == self.dm && row.attempts == 1
        }
        routes.set("dm.message.post", #"{"events":[],"result":{"dm_id":"\#(dm)"}}"#)
        try write { try $0.execute(sql: "UPDATE outbox SET next_attempt_at = NULL") }; queue.pump()
        try await wait { (try? self.store.outbox.commands().first?.state) == .sent }
        let bodies = ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }.map(\.body)
        XCTAssertEqual(bodies.count, 4)
        guard bodies.count == 4 else { return }
        XCTAssertEqual(bodies[0], bodies[1]); XCTAssertEqual(bodies[2], bodies[3])
        let post = try JSONDecoder().decode(ChatCommandEnvelope.self, from: bodies[3])
        XCTAssertEqual(post.commandId, original.commandId)
        XCTAssertEqual(post.args["message_id"], ChatService.args(original)["message_id"])
        XCTAssertEqual(try store.outbox.commands().count, 1)
        XCTAssertEqual(try read { try ChatDMStore.messages($0, dm).count }, 1)
    }

    func testFirstSendSurvivesDMEpochAndSnapshot() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        routes.set("/v1/commands", #"{"events":[],"result":{"dm_id":"\#(dm)"}}"#)
        try await ready()
        let outbox = try sendingQueue()
        let model = try XCTUnwrap(service.dmPeer(key, peer: peer))
        let version = try XCTUnwrap(model.saveDraft("send across snapshot", root: nil))
        _ = model.send("send across snapshot", root: nil, members: [], version: version)
        let messageID = try store.outbox.commands().first.flatMap { ChatService.args($0)["message_id"]?.string }
        let gate = Gate(); self.gate = gate; routes.gate = gate
        routes.gated = "/v1/commands"; gate.close()
        outbox.allow(connection: 1, generation: "g1")
        try await wait { ChatStubProtocol.seen.contains { $0.request.url?.path == "/v1/commands" } }
        sync.invalidate() // requestSnapshot's DM fence after team.add_member.
        try store.apply(ChatSnapshot(cursors: [:], members: [
            .init(accountId: me, handle: "me", name: "Me", role: "member"),
            .init(accountId: peer, handle: "boris", name: "Boris", role: "member")]), confirmsRights: "s-me")
        try await ready()
        gate.open()
        try await wait { (try? self.store.outbox.commands().contains { $0.type == "dm.message.post" && $0.state == .sent }) == true }
        let sent = try ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }
            .map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body) }
        XCTAssertEqual(sent.map(\.type), ["dm.open", "dm.message.post"])
        XCTAssertEqual(sent.last?.args["text"]?.string, "send across snapshot")
        XCTAssertEqual(sent.last?.args["message_id"]?.string, messageID)
    }

    func testDMListUsesStoredActivityWithoutReadingDrafts() async throws {
        try await ready()
        let activity = "2020-01-01T00:00:00Z"
        try write { try $0.execute(sql: "UPDATE dm_cards SET last_activity = ?", arguments: [activity]) }
        let list = try XCTUnwrap(service.dmList(key))
        XCTAssertEqual(list.entries.first?.lastUsed, ChatFeedLayout.date(activity))
        let queries = DMQueryLog()
        try write { db in db.trace { queries.append($0) } }
        defer { try? write { $0.trace(nil) } }
        _ = try store.dmWrite { try ChatDMStore.saveDraft($0, dm, root: nil, text: "typing") }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(queries.selects.contains { $0.contains("dm_messages") }, "Saving a draft must not refetch list history: \(queries.selects)")
    }

    func testPeerObservationReadsOnlyMembershipAndOwnDM() async throws {
        try await ready()
        let queries = DMQueryLog()
        try write { db in db.trace { queries.append($0) } }
        defer { try? write { $0.trace(nil) } }
        let model = ChatDMPeerModel(key: key, peer: peer, service: service)
        defer { model.stop() }
        XCTAssertEqual(model.person?.name, "Boris")
        for table in ["teams", "team_members", "channels", "messages", "agents", "channel_agents"] {
            XCTAssertFalse(queries.selects.contains { $0.contains("from \(table)") || $0.contains("join \(table)") }, "Peer observation read \(table)")
        }
        XCTAssertFalse(queries.selects.contains { $0.contains("order by last_activity") })
        queries.reset()
        try write { try $0.execute(sql: "UPDATE meta SET channels_served = 1") }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(queries.selects.isEmpty, "Channel metadata must not wake the peer observation")
        let plan = try read { try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN SELECT dm_id FROM dm_cards WHERE json_extract(CAST(body AS TEXT), '$.peer.account_id') = ? LIMIT 1", arguments: [peer]) }
        XCTAssertTrue(plan.contains { ($0["detail"] as String).contains("dm_card_peer") })
    }

    func testClosedPeerModelIsReleased() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        let state = TabState(route: .directMessageDraft(OrgKey(key), peer: peer))
        var model = service.dmPeer(key, peer: peer)
        weak var released = model
        XCTAssertNotNil(released)
        state.close()
        model = nil
        XCTAssertNil(released, "The organization must not retain a closed peer composer")
    }
    func testProductionFixturesDecodeAndChannelDecoderRejectsDM() throws {
        let card = try decode("dm_response", as: ChatDMCard.self)
        XCTAssertTrue(card.writable)
        XCTAssertEqual(try decode("dms_response", as: ChatDMPage.self).dms, [card])
        for name in ["dm_messages_response", "dm_thread_response"] { XCTAssertEqual(try decode(name, as: ChatDMMessagesPage.self).messages.first?.dmId, dm) }
        XCTAssertThrowsError(try decode("dm_message", as: ChatMessageWire.self))
        for name in ["dm_open", "dm_message_post", "dm_message_edit", "dm_message_delete"] {
            XCTAssertTrue(ChatDMStore.commands.contains(try decode(name + "_request", as: ChatCommandEnvelope.self).type))
            XCTAssertEqual(try decode(name + "_response", as: ChatCommandAnswer.self).result["dm_id"]?.string, dm)
        }
        for name in ["created", "closed", "reopened", "member_signal", "message_post", "message_delete"] {
            XCTAssertTrue(ChatDMStore.events.contains(try decode("event_dm_" + name, as: ChatEvent.self).type))
        }
        XCTAssertEqual(try decode("error_dm_read_only", as: ChatErrorBody.self).error, "dm_read_only")
    }
    func testCatalogBaselineAndIsolationFromChannels() async throws {
        try await ready()
        XCTAssertTrue(sync.readable(dm)); XCTAssertTrue(service.dmAllowed(key, dm))
        XCTAssertEqual(try read { try ChatDMStore.mark($0, dm) }, 2)
        XCTAssertEqual(try read { try ChatDMStore.messages($0, dm).count }, 1)
        XCTAssertTrue(try store.channels().isEmpty)
        XCTAssertEqual(try read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM messages") }, 0)
        XCTAssertFalse(try String(decoding: JSONEncoder().encode(ChatDMRef(key, dm: dm)), as: UTF8.self).contains("Boris"))
    }
    func testLiveDiscoveryStartsAtZeroAndDuplicateSignalsStayOneMessage() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        var event = try decode("event_dm_member_signal", as: ChatEvent.self)
        event = .init(stream: "member:\(org):\(me)", seq: 1, id: event.id, type: event.type, actor: event.actor, body: event.body, commandId: nil, at: event.at)
        XCTAssertEqual(try store.apply(event), .applied)
        sync.receive(event, live: true)
        try await wait { (try? self.store.dmRead { try ChatDMStore.messages($0, self.dm).count }) == 1 }
        XCTAssertEqual(try read { try ChatDMStore.mark($0, dm) }, 0)
        sync.receive(event, live: true)
        XCTAssertEqual(try read { try ChatDMStore.messages($0, dm).count }, 1)
    }
    func testCloseReopenAndLateCardNeverRegressState() async throws {
        try await ready()
        let old = try decode("dm_response", as: ChatDMCard.self)
        let closed = try decode("event_dm_closed", as: ChatEvent.self)
        try write { XCTAssertTrue(try ChatDMStore.apply($0, closed)); try ChatDMStore.writeCard($0, old) }
        XCTAssertFalse(try XCTUnwrap(read { try ChatDMStore.card($0, dm) }).writable)
        let reopened = try decode("event_dm_reopened", as: ChatEvent.self)
        try write { XCTAssertTrue(try ChatDMStore.apply($0, reopened)); XCTAssertTrue(try ChatDMStore.apply($0, closed)) }
        XCTAssertTrue(try XCTUnwrap(read { try ChatDMStore.card($0, dm) }).writable)
    }
    func testTombstoneWinsAcrossWindowReplacementAndOldHydration() async throws {
        try await ready()
        let event = try decode("event_dm_message_delete", as: ChatEvent.self)
        let old = try decode("dm_message", as: ChatDMMessageWire.self)
        try write { XCTAssertTrue(try ChatDMStore.apply($0, event)); try ChatDMStore.write($0, old) }
        let deleted = try XCTUnwrap(read { try ChatDMStore.messages($0, dm).first })
        XCTAssertTrue(deleted.deleted); XCTAssertEqual(deleted.text, "")
        var newWindow = try decode("dm_response", as: ChatDMCard.self); newWindow.head = 8; newWindow.messages = []
        try write { try ChatDMStore.writeCard($0, newWindow); try ChatDMStore.write($0, old) }
        XCTAssertTrue(try read { try ChatDMStore.messages($0, dm).isEmpty })
    }
    func testMissingOnOnePageDoesNotRevokeButEndOfCatalogDoes() async throws {
        try await ready()
        let stamp = try read { try ChatDMStore.stamp($0) }
        var fresh = try decode("dm_response", as: ChatDMCard.self); fresh.dmId = "new"; fresh.messages = []
        try write { try ChatDMStore.writeCard($0, fresh) }
        XCTAssertNotNil(try read { try ChatDMStore.card($0, dm) })
        try write { try ChatDMStore.endRead($0, since: stamp, seen: []) }
        XCTAssertNil(try read { try ChatDMStore.card($0, dm) })
        XCTAssertNotNil(try read { try ChatDMStore.card($0, "new") })
    }
    func testLateHistoryAfterInvalidationCannotRestoreText() async throws {
        try await ready()
        let gate = Gate(); self.gate = gate; routes.gate = gate
        routes.gated = "/v1/orgs/\(org)/dms/\(dm)/messages?before=2"
        gate.close()
        let task = Task { try await sync.page(dm, before: 2) }
        try await wait { ChatStubProtocol.seen.contains { $0.request.url?.query == "before=2" } }
        sync.invalidate()
        try write { try ChatDMStore.remove($0, dm) }
        gate.open()
        do { _ = try await task.value; XCTFail("A late page was accepted") } catch {}
        XCTAssertTrue(try read { try ChatDMStore.messages($0, dm).isEmpty })
        XCTAssertFalse(sync.readable(dm))
    }
    func testNoCapabilityAndDisconnectedUseNoDMNetwork() async throws {
        try await ready()
        sync.setOpen([dm])
        XCTAssertEqual(sync.followed, ["dm:\(dm)"])
        sync.configure(false)
        XCTAssertTrue(sync.followed.isEmpty)
        XCTAssertFalse(sync.ready)
        XCTAssertEqual(try read { try ChatDMStore.cards($0).map(\.dmId) }, [dm])
        let before = ChatStubProtocol.seen.count
        try await sync.reloadCatalog(valid: { true })
        XCTAssertThrowsError(try service.postDMToPeer(key, peer: peer, text: "private", mentions: [], draftVersion: "offline"))
        XCTAssertThrowsError(try service.postDM(key, dm: dm, root: nil, text: "private", mentions: []))
        XCTAssertEqual(ChatStubProtocol.seen.count, before)
        XCTAssertFalse(sync.readable())
    }

    func testDraftSurvivesLossAndReturnOfDMCapability() async throws {
        try await ready()
        let version = try store.dmWrite { try ChatDMStore.saveDraft($0, dm, root: nil, text: "private draft") }
        sync.configure(false)
        XCTAssertFalse(sync.readable(dm))
        XCTAssertEqual(try read { try ChatDMStore.draft($0, dm, root: nil)?.text }, "private draft")
        sync.configure(true)
        try await ready()
        XCTAssertTrue(sync.readable(dm))
        let draft = try XCTUnwrap(read { try ChatDMStore.draft($0, dm, root: nil) })
        XCTAssertEqual(draft.text, "private draft")
        XCTAssertEqual(draft.version, version)
    }

    func testDMResyncResubscribesFromSnapshotAndLeavesSyncing() async throws {
        try await ready()
        socket.start()
        try await wait { self.transport.request != nil }
        transport.push(.opened)
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await wait { self.socket.state == .connected }
        let stream = "dm:\(dm)"
        sync.setOpen([dm])
        let firstSub = try XCTUnwrap(transport.lastSub(of: stream))
        XCTAssertTrue(socket.syncing.contains(stream))

        var card = try decode("dm_response", as: ChatDMCard.self)
        card.head = 6002
        routes.set("/v1/orgs/\(org)/dms/\(dm)", String(decoding: try JSONEncoder().encode(card), as: UTF8.self))
        transport.frame(#"{"frame":"resync_required","stream":"\#(stream)"}"#)
        try await wait { self.sync.cursor(stream) == 6002 }
        XCTAssertEqual(transport.subscribes.filter { $0[stream] != nil }, [[stream: 2], [stream: 6002]])
        guard transport.lastSub(of: stream) != firstSub else { return XCTFail("The snapshot must be followed by a new subscription") }

        transport.frame(#"{"frame":"subscribed","stream":"\#(stream)","head":6002,"sub":\#(firstSub)}"#)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(socket.syncing.contains(stream), "The old subscription cannot confirm the new snapshot")
        transport.frame(#"{"frame":"subscribed","stream":"\#(stream)","head":6002}"#)
        try await wait { !self.socket.syncing.contains(stream) }
        XCTAssertTrue(socket.stuck.isEmpty)
        XCTAssertTrue(sync.readable(dm))
    }
    func testPostAndDraftAreAtomicAndReadOnlyRejectsEveryMutation() async throws {
        try await ready()
        let version = try store.dmWrite { try ChatDMStore.saveDraft($0, dm, root: nil, text: "private") }
        let id = try service.postDM(key, dm: dm, root: nil, text: "private", mentions: [peer, "third"], draftVersion: version)
        XCTAssertEqual(try service.postDM(key, dm: dm, root: nil, text: "private", mentions: [], draftVersion: version), id)
        XCTAssertNil(try read { try ChatDMStore.draft($0, dm, root: nil) })
        let command = try XCTUnwrap(store.outbox.commands().first { $0.type == "dm.message.post" })
        XCTAssertEqual(ChatService.args(command)["mentions"], .array([.object(["account_id": .string(peer)])]))
        XCTAssertNil(ChatService.args(command)["channel_id"])
        let closed = try decode("event_dm_closed", as: ChatEvent.self)
        try write { _ = try ChatDMStore.apply($0, closed) }
        XCTAssertThrowsError(try service.postDM(key, dm: dm, root: nil, text: "blocked", mentions: []))
        XCTAssertThrowsError(try service.changeDM(key, dm: dm, message: id, text: nil, revision: 1))
        XCTAssertThrowsError(try service.changeDM(key, dm: dm, message: id, text: "blocked", revision: 1))
        XCTAssertEqual(try store.outbox.commands().count, 1)
        // Losing access removes every presentation value, while the user's command stays.
        try write { try ChatDMStore.remove($0, dm) }
        XCTAssertEqual(try store.outbox.commands().count, 1)
        XCTAssertTrue(try read { try ChatDMStore.messages($0, dm).isEmpty })
    }

    private func sendingQueue() throws -> ChatOutbox {
        let session = try XCTUnwrap(service.orgSessions[key])
        session.startSending(api: ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self]),
            token: "test-only", sessionId: "s-me", journal: nil, onUnauthorized: {})
        let outbox = try XCTUnwrap(session.outbox), service = self.service!, key = self.key
        outbox.onSent = { [weak service] record, answer in service?.commandAnswered(key, record, .taken(answer)) }
        outbox.onPermanentFailure = { [weak service] record, code in service?.commandAnswered(key, record, .refused(code)) }
        outbox.retryDelay = { _ in 60 }
        return outbox
    }

    func testDontSendCancelsWaitingAndPreparedDMWithoutNetworkOrRestore() async throws {
        try await ready()
        let outbox = try sendingQueue()
        routes.set("/v1/commands", #"{"events":[],"result":{}}"#)
        let model = ChatDMModel(key: key, dm: dm, service: service); defer { model.stop() }
        for alreadyPrepared in [false, true] {
            let id = try service.postDM(key, dm: dm, root: nil, text: "do not send", mentions: [])
            let message = try XCTUnwrap(read { try ChatDMStore.messages($0, dm).first { $0.id == id } })
            XCTAssertEqual(message.localState, .sending)
            if alreadyPrepared { outbox.allow(connection: 1, generation: "g1") }
            model.discard(message)
            let cancelled = try XCTUnwrap(store.outbox.commands().first { ChatService.args($0)["message_id"]?.string == id })
            XCTAssertEqual(cancelled.state, .dropped)
            XCTAssertEqual(cancelled.error, "dismissed")
            try write { try ChatDMStore.restoreOutgoing($0, dm: dm, me: me) }
            XCTAssertFalse(try read { try ChatDMStore.messages($0, dm).contains { $0.id == id } })

            outbox.allow(connection: 1, generation: "g1")
            let next = try outbox.enqueue(org: org, type: "member.set_name", args: .object(["name": .string("Me")]))
            try await wait { (try? self.store.outbox.commands().first { $0.commandId == next.commandId }?.state) == .sent }
            outbox.hold()
        }
        let sent = try ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }
            .map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).type }
        XCTAssertEqual(sent, ["member.set_name", "member.set_name"])
        try service.files.saveDMOutbox(key, store: store)
        XCTAssertEqual(try service.files.savedDMOutbox(key)?.count, 0)
    }

    func testDontSendRacingAcceptedHTTPKeepsExactlyOneServerMessage() async throws {
        try await ready()
        let outbox = try sendingQueue()
        let id = try service.postDM(key, dm: dm, root: nil, text: "accepted during cancellation", mentions: [])
        var message = try decode("dm_message", as: ChatDMMessageWire.self)
        message.messageId = id; message.seq = 3; message.text = "accepted during cancellation"
        routes.set("/v1/commands", #"{"events":[],"result":{"seq":3,"revision":1}}"#)
        routes.set("/v1/orgs/\(org)/dms/\(dm)/messages", String(decoding: try JSONEncoder().encode(ChatDMMessagesPage(messages: [message], next: nil, head: 3)), as: UTF8.self))
        let gate = Gate(); self.gate = gate; routes.gate = gate; routes.gated = "/v1/commands"; gate.close()
        outbox.allow(connection: 1, generation: "g1")
        try await wait { ChatStubProtocol.seen.contains { $0.request.url?.path == "/v1/commands" } }

        try service.discardDM(key, dm: dm, message: id)
        XCTAssertFalse(try read { try ChatDMStore.messages($0, dm).contains { $0.id == id } })
        XCTAssertEqual(try store.outbox.commands().first?.state, .dropped)
        gate.open()
        try await wait { (try? self.store.outbox.commands().first?.state) == .sent }
        try await wait { (try? self.store.dmRead { try ChatDMStore.messages($0, self.dm).first { $0.id == id }?.seq }) == 3 }
        let event = ChatEvent(stream: "dm:\(dm)", seq: 3, id: "accepted", type: "dm.message.post", actor: nil,
            body: .object(["dm_id": .string(dm), "message_id": .string(id), "message_seq": .number(3), "revision": .number(1)]),
            commandId: nil, at: message.createdAt, message: try JSONDecoder().decode(ChatJSON.self, from: JSONEncoder().encode(message)))
        XCTAssertEqual(try store.apply(event), .applied)
        // A stale Don't send action after the feed's acceptance cannot erase it.
        try service.discardDM(key, dm: dm, message: id)
        let accepted = try read { try ChatDMStore.messages($0, dm).filter { $0.id == id } }
        XCTAssertEqual(accepted.count, 1)
        XCTAssertNil(accepted.first?.localState)
        XCTAssertEqual(accepted.first?.text, message.text)
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }.count, 1)
    }

    func testDontSendRacingFailedHTTPDoesNotRetry() async throws {
        try await ready()
        let outbox = try sendingQueue()
        let id = try service.postDM(key, dm: dm, root: nil, text: "cancel in flight", mentions: [])
        let gate = Gate(); self.gate = gate; gate.close()
        ChatStubProtocol.reset { _, body in
            if (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: body).type) == "dm.message.post" {
                gate.pass()
                return .success(.init(status: 503, body: Data(#"{"error":"internal"}"#.utf8)))
            }
            return .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
        }
        outbox.allow(connection: 1, generation: "g1")
        try await wait { ChatStubProtocol.seen.contains { $0.request.url?.path == "/v1/commands" } }
        try service.discardDM(key, dm: dm, message: id)
        gate.open()
        // The next command in this order can finish only after the failed
        // send settles; cancellation must prevent its automatic retry.
        let next = try outbox.enqueue(org: org, type: "member.set_name", args: .object(["name": .string("Me")]))
        try await wait { (try? self.store.outbox.commands().first { $0.commandId == next.commandId }?.state) == .sent }
        let cancelled = try XCTUnwrap(store.outbox.commands().first)
        XCTAssertEqual(cancelled.state, .dropped)
        XCTAssertEqual(cancelled.error, "dismissed")
        XCTAssertNil(cancelled.nextAttemptAt)
        XCTAssertFalse(try read { try ChatDMStore.messages($0, dm).contains { $0.id == id } })
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }.count, 2)
    }

    func testDontSendAfterHTTPAcceptanceKeepsMessageWhileHydrating() async throws {
        try await ready()
        let outbox = try sendingQueue()
        let id = try service.postDM(key, dm: dm, root: nil, text: "already accepted", mentions: [])
        var message = try decode("dm_message", as: ChatDMMessageWire.self)
        message.messageId = id; message.seq = 3; message.text = "already accepted"
        routes.set("/v1/commands", #"{"events":[],"result":{"seq":3,"revision":1}}"#)
        routes.set("/v1/orgs/\(org)/dms/\(dm)/messages", String(decoding: try JSONEncoder().encode(ChatDMMessagesPage(messages: [message], next: nil, head: 3)), as: UTF8.self))
        let gate = Gate(); self.gate = gate; routes.gate = gate
        routes.gated = "/v1/orgs/\(org)/dms/\(dm)/messages?before=4"; gate.close()
        outbox.allow(connection: 1, generation: "g1")
        try await wait { ChatStubProtocol.seen.contains { $0.request.url?.query == "before=4" } }
        XCTAssertEqual(try store.outbox.commands().first?.state, .sent)
        XCTAssertEqual(try read { try ChatDMStore.messages($0, dm).first { $0.id == id }?.localState }, .sending)
        try service.discardDM(key, dm: dm, message: id)
        XCTAssertTrue(try read { try ChatDMStore.messages($0, dm).contains { $0.id == id } })
        gate.open()
        try await wait { (try? self.store.dmRead { try ChatDMStore.messages($0, self.dm).first { $0.id == id }?.seq }) == 3 }
        XCTAssertEqual(try read { try ChatDMStore.messages($0, dm).filter { $0.id == id }.count }, 1)
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }.count, 1)
    }
    func testSameUUIDInChannelAndDMNeverSharesMessages() async throws {
        try await ready()
        var json = try JSONSerialization.jsonObject(with: fixture("dm_message")) as! [String: Any]
        json.removeValue(forKey: "dm_id"); json["channel_id"] = dm; json["text"] = "channel text"
        let channelMessage = try JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: json))
        try write { try ChatMessages.write($0, channelMessage) }
        XCTAssertEqual(try read { try String.fetchOne($0, sql: "SELECT text FROM messages WHERE message_id = ?", arguments: [channelMessage.messageId]) }, "channel text")
        let direct = try XCTUnwrap(read { try ChatDMStore.messages($0, dm).first })
        XCTAssertEqual(direct.text, "Hello privately."); XCTAssertEqual(direct.dmId, dm); XCTAssertEqual(direct.channelId, "")
        let deletion = try decode("event_dm_message_delete", as: ChatEvent.self)
        try write { _ = try ChatDMStore.apply($0, deletion) }
        XCTAssertEqual(try read { try String.fetchOne($0, sql: "SELECT text FROM messages WHERE message_id = ?", arguments: [channelMessage.messageId]) }, "channel text")
    }
    func testGenerationClearsPrivateCacheAndHoldsUnsentCommands() async throws {
        try await ready()
        _ = try service.postDM(key, dm: dm, root: nil, text: "unsent", mentions: [])
        try store.setGeneration("old")
        try store.beginGeneration("new")
        XCTAssertTrue(try read { try ChatDMStore.cards($0).isEmpty })
        XCTAssertTrue(try read { try ChatDMStore.messages($0, dm).isEmpty })
        XCTAssertFalse(sync.readable())
        XCTAssertEqual(try store.outbox.commands().first?.state, .unconfirmed)
    }
    func testDoubtWriteFailureClosesServiceGateAndUnknownClosedCardStaysReadOnly() async throws {
        try await ready()
        service.orgSessions[key]?.doubtNotWritten = true
        XCTAssertFalse(service.dmAllowed(key, dm))
        XCTAssertThrowsError(try service.postDM(key, dm: dm, root: nil, text: "blocked", mentions: []))
        service.orgSessions[key]?.doubtNotWritten = false
        let old = try decode("dm_response", as: ChatDMCard.self), closed = try decode("event_dm_closed", as: ChatEvent.self)
        try write { try ChatDMStore.remove($0, dm); _ = try ChatDMStore.apply($0, closed); try ChatDMStore.writeCard($0, old) }
        XCTAssertFalse(try XCTUnwrap(read { try ChatDMStore.card($0, dm) }).writable)
    }

    func testAllMembersSortByConversationActivityThenNameAndKeepUnreadVisible() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        let original = try decode("dm_response", as: ChatDMCard.self)
        try write { db in
            try db.execute(sql: "DELETE FROM members WHERE account_id != ?", arguments: [me])
            for number in 0..<18 {
                let id = "person-\(number)", name = String(format: "Person %02d", number)
                try db.execute(sql: "INSERT INTO members (account_id, name, handle, role) VALUES (?, ?, ?, 'member')", arguments: [id, name, id])
                guard number < 10 || number == 12 else { continue }
                var card = original; card.dmId = "dm-\(number)"; card.peer.accountId = id; card.messages = []; card.head = 0
                card.createdAt = String(format: "2026-10-01T00:00:%02dZ", number)
                if number < 10 {
                    var message = original.messages![0]; message.dmId = card.dmId; message.createdAt = card.createdAt
                    message.authorAccountId = id; card.messages = [message]; card.head = message.seq
                }
                try ChatDMStore.writeCard(db, card)
            }
            var former = original; former.dmId = "former-dm"; former.peer.accountId = "former"; former.peer.name = "Former"
            former.peer.active = false; former.state = "closed"; former.messages = []; former.head = 0
            try ChatDMStore.writeCard(db, former)
            try db.execute(sql: "UPDATE dm_marks SET seq = 0 WHERE dm_id = 'dm-0'")
            try db.execute(sql: "INSERT INTO dm_preferences (dm_id, muted, opened) VALUES ('dm-12', 0, '2026-10-09T12:00:00Z'), ('dm-0', 1, NULL)")
        }
        let before = ChatStubProtocol.seen.count
        let list = try XCTUnwrap(service.dmList(key)), entries = list.people
        XCTAssertEqual(entries.prefix(10).map(\.id), (0..<10).reversed().map { "person-\($0)" })
        XCTAssertEqual(entries.dropFirst(10).map(\.id), ["former"] + (10..<18).map { "person-\($0)" })
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.id == "person-12" }).hasMessages)
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.id == "former" }).writable)
        XCTAssertFalse(entries.contains { $0.id == me || $0.id == peer })
        let compact = ChatDMPerson.visible(entries, limit: 8)
        XCTAssertTrue(compact.contains { $0.id == "person-0" && $0.roots.count == 1 && $0.roots.muted })
        XCTAssertEqual(compact.count, 9)
        XCTAssertEqual(ChatDMPerson.visible(entries, limit: 24).count, 19)
        XCTAssertEqual(ChatDMPerson.visible(entries, limit: 8).map(\.id), compact.map(\.id))
        XCTAssertEqual(ChatDMPerson.visible(entries, limit: 8, expanded: false).map(\.id), ["person-0"])
        for kind in 0..<3 {
            var unread = entries
            unread[0].conversation?.roots = .init(count: 0, more: kind == 0, something: kind == 1, muted: true)
            unread[0].conversation?.replies = kind == 2 ? 1 : 0
            XCTAssertTrue(ChatDMPerson.visible(unread, limit: 0, expanded: false).contains { $0.id == unread[0].id })
        }
        try write { try $0.execute(sql: "DELETE FROM members WHERE account_id = 'person-17'") }
        try await wait { !list.people.contains { $0.id == "person-17" } }
        try write { try $0.execute(sql: "UPDATE members SET name = 'Aaron' WHERE account_id = 'person-16'") }
        try await wait { list.people.dropFirst(10).first?.id == "person-16" }
        _ = try service.postDM(key, dm: "dm-12", root: nil, text: "new activity", mentions: [])
        try await wait { list.people.first?.id == "person-12" }
        XCTAssertEqual(ChatStubProtocol.seen.count, before)
    }
    func testSharedTimelineUsesIndependentThreadReadsAndSharedDrafts() async throws {
        try await ready()
        var root = try decode("dm_message", as: ChatDMMessageWire.self)
        root.messageId = "root"; root.authorAccountId = peer; root.seq = 3
        var reply = root; reply.messageId = "reply"; reply.threadRootId = "root"; reply.seq = 4
        try write { try ChatDMStore.write($0, root); try ChatDMStore.write($0, reply) }
        routes.set("/v1/orgs/\(org)/dms/\(dm)/threads/root", String(decoding: try JSONEncoder().encode(ChatDMMessagesPage(messages: [root, reply], next: nil, head: 4)), as: UTF8.self))
        let first = ChatDMModel(key: key, dm: dm, service: service), second = ChatDMModel(key: key, dm: dm, service: service)
        defer { first.stop(); second.stop() }
        XCTAssertTrue(first.isDM); XCTAssertNil(first.b1); XCTAssertTrue(first.threadRequests.isEmpty)
        let draft = first.saveDraft("shared draft", root: nil)
        try await wait { second.draft(root: nil)?.version == draft }
        XCTAssertEqual(second.draft(root: nil)?.text, "shared draft")
        first.beginReading(root: nil)
        first.readIfLooking(root: nil, appActive: true, shown: false, atBottom: true)
        XCTAssertEqual(try read { try ChatDMStore.mark($0, dm) }, 2)
        first.readIfLooking(root: nil, appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(try read { try ChatDMStore.mark($0, dm) }, 3)
        XCTAssertEqual(try read { try ChatDMStore.mark($0, dm, root: "root") }, 2)
        first.openThread("root")
        try await wait { !first.threadHasEarlier }
        first.beginReading(root: "root")
        first.readIfLooking(root: "root", appActive: true, shown: true, atBottom: true)
        XCTAssertEqual(try read { try ChatDMStore.mark($0, dm, root: "root") }, 4)
        XCTAssertNil(second.threadRoot)
        XCTAssertEqual(first.notificationPlace(root: nil), ChatDMRef(key, dm: dm).place)
    }
    func testDMModelGatesDraftEditCopyAndLateActions() async throws {
        try await ready()
        let state = TabState(route: .directMessage(ChatDMRef(key, dm: dm)))
        let model = ChatDMModel(key: key, dm: dm, state: state, service: service); state.dmModel = model
        let message = try XCTUnwrap(model.feed.messages.first)
        XCTAssertTrue(model.beginEditing(message, root: nil))
        _ = model.saveDraft("private draft", root: nil)
        XCTAssertNotNil(model.editing)
        sync.invalidate()
        XCTAssertFalse(model.readable); XCTAssertTrue(model.feed.messages.isEmpty); XCTAssertNil(model.editing)
        XCTAssertNil(model.draft(root: nil)); XCTAssertNil(model.copyText(message))
        XCTAssertFalse(model.canDelete(message)); XCTAssertFalse(model.send("late", root: nil, members: [], version: "old"))
        state.close()
        XCTAssertNil(state.dmModel)
        XCTAssertNil(ChatMessageLink(key: key, message: message).url)
    }
    func testNewDMPickerFiltersPeopleWithoutOpeningOnServer() async throws {
        try await ready()
        let other = ChatOrgView.Member(accountId: "new-peer", handle: "vera", name: "Вера", role: "member")
        XCTAssertEqual(ChatDMNewModel.filter([.init(accountId: me, handle: "me", name: "Me", role: "member"), other], me: me, query: "ВЕ"), [other])
        try write { try $0.execute(sql: "INSERT INTO members (account_id, name, handle, role) VALUES (?, ?, ?, ?)", arguments: [other.accountId, other.name, other.handle, other.role]) }
        let state = TabState(route: .newDM(OrgKey(key))), model = ChatDMNewModel(key: key, state: nil, service: service)
        model.state = state; state.newDMModel = model
        let before = ChatStubProtocol.seen.count
        model.choose(other.accountId)
        XCTAssertEqual(model.result, .directMessageDraft(OrgKey(key), peer: other.accountId))
        XCTAssertTrue(try store.outbox.commands().isEmpty)
        model.choose(peer)
        XCTAssertEqual(model.result, .directMessage(ChatDMRef(key, dm: dm)))
        state.close()
        model.choose(other.accountId)
        XCTAssertNil(model.result); XCTAssertFalse(model.readable)
        XCTAssertNil(state.newDMModel)
        XCTAssertEqual(ChatStubProtocol.seen.count, before)
    }

    func testPersonClickOpensOnePrivateLocalTabWithoutCommandsOrSubscriptions() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        let host = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, engineFactory: {
            XCTFail("A DM created a terminal"); return TestEngine()
        })
        defer { host.terminate() }
        let router = TabRouter(); router.stores = { [host] }; router.ensureHost = { host }
        let navigation = SupportTabNavigation(router: router); navigation.finishStartup()
        let before = ChatStubProtocol.seen.count
        let tab = try XCTUnwrap(ChatDMTabs.open(key, peer: peer, from: host, service: service, navigation: navigation))
        XCTAssertEqual(tab.toolRoute, .directMessageDraft(OrgKey(key), peer: peer))
        XCTAssertTrue(tab.isDirectMessageTab)
        XCTAssertTrue(ChatDMTabs.open(key, peer: peer, from: host, service: service, navigation: navigation) === tab)
        let model = try XCTUnwrap(service.dmPeer(key, peer: peer))
        XCTAssertTrue(model.readable); XCTAssertTrue(model.writable)
        XCTAssertTrue(model.conversationMessages(root: nil).isEmpty)
        XCTAssertEqual(model.person?.name, "Boris")
        _ = model.saveDraft("private draft", root: nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(try store.outbox.commands().isEmpty)
        XCTAssertTrue(sync.openIDs.isEmpty); XCTAssertTrue(sync.followed.isEmpty)
        XCTAssertEqual(ChatStubProtocol.seen.count, before)
        let encoded = String(decoding: try JSONEncoder().encode(tab.toolRoute), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Boris")); XCTAssertFalse(encoded.contains("private draft"))

        let card = try decode("dm_response", as: ChatDMCard.self)
        try write { try ChatDMStore.writeCard($0, card) }
        try await wait { model.result == self.dm && self.service.dmList(self.key)?.people.first?.conversation != nil }
        XCTAssertEqual(try read { try ChatDMStore.draft($0, dm, root: nil)?.text }, "private draft")
        XCTAssertEqual(ChatDMTabs.open(key, peer: peer, from: host, service: service, navigation: navigation)?.toolRoute, .directMessage(ChatDMRef(key, dm: dm)))
        XCTAssertTrue(try store.outbox.commands().isEmpty)
        ChatConversationTabs.close(key, stores: [host])
        XCTAssertTrue(host.allSessions.isEmpty)
    }

    func testFirstSendCreatesOneDMAndOneMessageAcrossWindowsAndFeedRace() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        let outbox = try sendingQueue()
        routes.set("/v1/commands", #"{"events":[],"result":{"dm_id":"\#(dm)"}}"#)
        let first = try XCTUnwrap(service.dmPeer(key, peer: peer))
        // Also exercise independent observers, as can happen during tab restoration.
        let second = ChatDMPeerModel(key: key, peer: peer, service: service); defer { second.stop() }
        let version = try XCTUnwrap(first.saveDraft("first hello @boris", root: nil))
        try await wait { second.draft(root: nil)?.version == version }
        for model in [first, first, second] {
            XCTAssertTrue(model.send("first hello @boris", root: nil, members: [(peer, "boris")], version: version))
        }
        XCTAssertEqual(try store.outbox.commands().map(\.type), ["dm.message.post"])
        var card = try decode("dm_response", as: ChatDMCard.self); card.messages = []; card.head = 0
        routes.set("/v1/orgs/\(org)/dms/\(dm)", String(decoding: try JSONEncoder().encode(card), as: UTF8.self))
        // The member feed discovers the DM before the open response returns.
        try write { try ChatDMStore.writeCard($0, card) }
        try await wait { first.result == self.dm && second.result == self.dm }
        for model in [first, second] {
            XCTAssertTrue(model.send("first hello @boris", root: nil, members: [(peer, "boris")], version: version))
        }
        outbox.allow(connection: 1, generation: "g1")
        try await wait { (try? self.store.outbox.commands().first?.state) == .sent }
        let commands = try store.outbox.commands()
        XCTAssertEqual(commands.map(\.type), ["dm.message.post"])
        let post = try XCTUnwrap(commands.last)
        XCTAssertEqual(ChatService.args(post)["dm_id"]?.string, dm)
        XCTAssertEqual(ChatService.args(post)["text"]?.string, "first hello @boris")
        XCTAssertEqual(try read { try ChatDMStore.messages($0, dm).count }, 1)
        XCTAssertNil(try read { try ChatDMStore.draft($0, "peer:\(peer)", root: nil) })
        XCTAssertEqual(try read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dm_sends") }, 1)
    }

    func testFirstSendDoesNotWaitForCardAndSurvivesClosingTab() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        routes.set("/v1/commands", #"{"events":[],"result":{"dm_id":"\#(dm)"}}"#)
        try await ready()
        let outbox = try sendingQueue()
        let state = TabState(route: .directMessageDraft(OrgKey(key), peer: peer))
        state.dmPeerModel = try XCTUnwrap(service.dmPeer(key, peer: peer))
        let version = try XCTUnwrap(state.dmPeerModel?.saveDraft("send after close", root: nil))
        XCTAssertTrue(state.dmPeerModel?.send("send after close", root: nil, members: [], version: version) == true)
        state.close()
        XCTAssertNil(state.dmPeerModel)
        let gate = Gate(); self.gate = gate; routes.gate = gate
        routes.gated = "/v1/orgs/\(org)/dms/\(dm)"; gate.close()
        outbox.allow(connection: 1, generation: "g1")
        try await wait { (try? self.store.outbox.commands().first?.state) == .sent }
        XCTAssertNil(try read { try ChatDMStore.card($0, dm) })
        XCTAssertEqual(try store.outbox.commands().count, 1)
        gate.open()
        try await wait { self.sync.readable(self.dm) }
    }

    func testFirstSendRejectsStaleDraftAndCanRetryOpenFailure() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        let model = try XCTUnwrap(service.dmPeer(key, peer: peer))
        let old = try XCTUnwrap(model.saveDraft("old", root: nil))
        let version = try XCTUnwrap(model.saveDraft("current", root: nil))
        XCTAssertFalse(model.send("old", root: nil, members: [], version: old))
        XCTAssertTrue(try store.outbox.commands().isEmpty)
        XCTAssertTrue(model.send("current", root: nil, members: [], version: version))
        let command = try XCTUnwrap(store.outbox.commands().first)
        try write { try $0.execute(sql: "UPDATE outbox SET state = 'failed', error = 'temporary' WHERE command_id = ?", arguments: [command.commandId]) }
        try await wait { model.outgoing.first?.state == .failed }
        XCTAssertNil(model.draft(root: nil))
        XCTAssertEqual(ChatService.args(try XCTUnwrap(model.outgoing.first))["text"]?.string, "current")
        model.retry(command.commandId)
        let retry = try XCTUnwrap(store.outbox.commands().last)
        XCTAssertEqual(retry.state, .pending)
        XCTAssertNotEqual(retry.commandId, command.commandId)
        XCTAssertEqual(ChatService.args(retry)["message_id"], ChatService.args(command)["message_id"])
    }

    func testFirstSendReusesDMDiscoveredBeforeSendAndMovedDraftVersion() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        let model = try XCTUnwrap(service.dmPeer(key, peer: peer))
        let version = try XCTUnwrap(model.saveDraft("send during discovery", root: nil))
        let card = try decode("dm_response", as: ChatDMCard.self)
        try write { try ChatDMStore.writeCard($0, card) }
        try await wait { model.result == self.dm }
        XCTAssertTrue(model.send("send during discovery", root: nil, members: [], version: version))
        XCTAssertTrue(model.send("send during discovery", root: nil, members: [], version: version))
        XCTAssertEqual(try store.outbox.commands().map(\.type), ["dm.message.post"])
        XCTAssertNil(try read { try ChatDMStore.draft($0, dm, root: nil) })
    }

    func testFirstSendPostsEvenWhenCardHydrationFails() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        let outbox = try sendingQueue()
        routes.set("/v1/commands", #"{"events":[],"result":{"dm_id":"\#(dm)"}}"#)
        routes.set("/v1/orgs/\(org)/dms/\(dm)", #"{"error":"temporary"}"#, status: 503)
        let model = try XCTUnwrap(service.dmPeer(key, peer: peer))
        let version = try XCTUnwrap(model.saveDraft("retry hydration", root: nil))
        XCTAssertTrue(model.send("retry hydration", root: nil, members: [], version: version))
        outbox.allow(connection: 1, generation: "g1")
        try await wait { (try? self.store.outbox.commands().first?.state) == .sent }
        XCTAssertNil(model.draft(root: nil))
        routes.set("/v1/orgs/\(org)/dms/\(dm)", String(decoding: try fixture("dm_response"), as: UTF8.self))
        try await wait { model.result == self.dm }
        let sent = try ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" }
            .map { try JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.body).type }
        XCTAssertEqual(sent, ["dm.open", "dm.message.post"])
    }

    func testRemovedMemberAndRevokedAccessCannotSendPendingFirstMessage() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        let list = try XCTUnwrap(service.dmList(key)), model = try XCTUnwrap(service.dmPeer(key, peer: peer))
        let version = try XCTUnwrap(model.saveDraft("must not send", root: nil))
        try write { try $0.execute(sql: "DELETE FROM members WHERE account_id = ?", arguments: [peer]) }
        XCTAssertFalse(model.send("must not send", root: nil, members: [], version: version))
        try await wait { list.people.isEmpty && !model.readable }
        XCTAssertNil(ChatDMTabs.route(key, peer: peer, service: service))
        XCTAssertTrue(try store.outbox.commands().isEmpty)
        try write { try $0.execute(sql: "INSERT INTO members (account_id, name, handle, role) VALUES (?, 'Boris', 'boris', 'member')", arguments: [peer]) }
        try await wait { model.readable }
        XCTAssertTrue(model.send("must not send", root: nil, members: [], version: version))
        sync.invalidate()
        let card = try decode("dm_response", as: ChatDMCard.self)
        try write { try ChatDMStore.writeCard($0, card) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.readable); XCTAssertNil(model.person); XCTAssertNil(model.draft(root: nil))
        XCTAssertTrue(list.people.isEmpty)
        XCTAssertEqual(try store.outbox.commands().map(\.type), ["dm.message.post"])
    }


    func testRenderedMemberSidebarAndEmptyConversationUsePrivateComposerWithoutNetwork() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        try write { db in
            for number in 0..<12 {
                try db.execute(sql: "INSERT INTO members (account_id, name, handle, role) VALUES (?, ?, ?, 'member')",
                               arguments: ["person-\(number)", String(format: "Person %02d", number), "person\(number)"])
            }
        }
        _ = NSApplication.shared
        let workspace = WorkspaceStore(persistence: InMemoryPersistence(), initiallyEmpty: true, engineFactory: { TestEngine() })
        defer { workspace.terminate() }
        let state = TabState(route: .directMessageDraft(OrgKey(key), peer: peer))
        let before = ChatStubProtocol.seen.count
        let host = NSHostingView(rootView: AnyView(HStack(spacing: 0) {
            VStack { ChatDMSidebarSection(store: workspace, key: key, service: service); Spacer() }
                .frame(width: 230).foregroundStyle(Theme.chromeForeground).background(Theme.chromeBackground)
            Divider()
            ChatDMPeerTab(state: state, scope: OrgKey(key), peer: peer, service: service)
        }.frame(width: 960, height: 700)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        func editors(_ view: NSView) -> [ChatMentionEditor.Editor] {
            (view as? ChatMentionEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        let editor = try XCTUnwrap(editors(host).first)
        XCTAssertEqual(editors(host).count, 1)
        XCTAssertEqual(editor.placeholder, "Message Boris")
        XCTAssertNil(editor.navigationTarget)
        XCTAssertTrue(try store.outbox.commands().isEmpty)
        XCTAssertTrue(sync.followed.isEmpty)
        XCTAssertEqual(ChatStubProtocol.seen.count, before)
        if let directory = ProcessInfo.processInfo.environment["AGENTPAD_DM_RENDER"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("dm-members.png"))
        }
        let model = try XCTUnwrap(state.dmPeerModel)
        _ = model.saveDraft("late return after close", root: nil)
        try await wait { editor.string == "late return after close" }
        state.close()
        XCTAssertNil(state.dmPeerModel)
        XCTAssertFalse(model.readable)
        XCTAssertTrue(editor.consume?(36, []) == true)
        XCTAssertTrue(try store.outbox.commands().isEmpty)
        XCTAssertEqual(ChatStubProtocol.seen.count, before)
    }

    func testRenderedDMFeedAndThreadKeepSeparateHumanComposers() async throws {
        try await ready()
        _ = NSApplication.shared
        let wire = try decode("dm_message", as: ChatDMMessageWire.self)
        routes.set("/v1/orgs/\(org)/dms/\(dm)/threads/\(wire.messageId)", String(decoding: try fixture("dm_thread_response"), as: UTF8.self))
        let model = ChatDMModel(key: key, dm: dm, service: service)
        defer { model.stop() }
        model.openThread(wire.messageId)
        try await wait { !model.threadHasEarlier }
        let card = try XCTUnwrap(model.card)
        for width: CGFloat in [1000, 680] {
            let host = NSHostingView(rootView: AnyView(ChatDMView(model: model, card: card).frame(width: width, height: 720)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            func editors(_ view: NSView) -> [ChatMentionEditor.Editor] {
                (view as? ChatMentionEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
            }
            let native = editors(host)
            XCTAssertEqual(native.count, width > 784 ? 2 : 1)
            XCTAssertTrue(native.allSatisfy { $0.navigationTarget == nil }, "DM editors cannot address channel or agent actions")
            XCTAssertTrue(native.allSatisfy { $0.consume?(36, []) == true }, "DM Return sends; Shift-Return remains a newline")
            XCTAssertTrue(native.allSatisfy { $0.consume?(36, [.shift]) == false })
            if let directory = ProcessInfo.processInfo.environment["AGENTPAD_DM_RENDER"],
               let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("dm-\(Int(width)).png"))
            }
        }
    }

    func testLiveDMNoticesArePrivateDeduplicatedAndNeverProducedByReplay() async throws {
        try await ready()
        let oldEmit = ChatNotifications.emit, oldPost = ChatNotifications.post
        defer { ChatNotifications.emit = oldEmit; ChatNotifications.post = oldPost }
        var notices: [AttentionEvent] = [], banners: [String] = []
        ChatNotifications.emit = { notices.append($0) }; ChatNotifications.post = { _, title in banners.append(title) }
        sync.onLiveMessage = { [self] dm, id in ChatDMNotices.live(service, key, dm: dm, id: id) }
        var m = try decode("dm_message", as: ChatDMMessageWire.self)
        m.authorAccountId = peer; m.seq = 3; m.messageId = UUID().uuidString.lowercased(); m.text = "private incoming secret"
        func point(_ message: ChatDMMessageWire, type: String = "dm.message.post") -> ChatEvent {
            .init(stream: "member:\(org):\(me)", seq: message.seq, id: UUID().uuidString, type: type, actor: nil,
                  body: .object(["dm_id": .string(dm), "message_id": .string(message.messageId), "message_seq": .number(Double(message.seq)), "revision": .number(Double(message.revision))]), commandId: nil, at: ChatService.now())
        }
        func route(_ message: ChatDMMessageWire) throws {
            routes.set("/v1/orgs/\(org)/dms/\(dm)/messages", String(decoding: try JSONEncoder().encode(ChatDMMessagesPage(messages: [message], next: nil, head: message.seq)), as: UTF8.self))
        }
        try route(m); sync.receive(point(m), live: false)
        try await wait { (try? self.read { try ChatDMStore.messages($0, self.dm).contains { $0.id == m.messageId } }) == true }
        XCTAssertTrue(banners.isEmpty)
        m.seq = 4; m.messageId = UUID().uuidString.lowercased(); try route(m)
        let live = point(m); sync.receive(live, live: true); sync.receive(live, live: true)
        try await wait { banners.count == 1 }
        sync.receive(live, live: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(banners, ["New direct message in AgentPad"])
        let notice = try XCTUnwrap(notices.first)
        XCTAssertEqual(notice.body, ""); XCTAssertFalse(notice.kind.needsDecision)
        let encoded = String(decoding: try JSONEncoder().encode(notice), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Boris")); XCTAssertFalse(encoded.contains(m.text))
        XCTAssertTrue(ChatDMNotices.valid(notice, service: service))
        m.revision += 1; m.text = "edited"; try route(m); sync.receive(point(m, type: "dm.message.edit"), live: true)
        try await Task.sleep(for: .milliseconds(50)); XCTAssertEqual(banners.count, 1)
        try write { try ChatDMStore.markAllRead($0, dm) }
        XCTAssertFalse(ChatDMNotices.valid(notice, service: service)); XCTAssertTrue(ChatDMNotices.events(service, key).isEmpty)
    }

    func testDMNoticeTransactionMuteFocusAndScopeRetraction() async throws {
        try await ready()
        let oldEmit = ChatNotifications.emit, oldActive = ChatNotifications.appActive, oldPlaces = ChatNotifications.places
        defer { ChatNotifications.emit = oldEmit; ChatNotifications.appActive = oldActive; ChatNotifications.places = oldPlaces }
        var notices: [AttentionEvent] = []; ChatNotifications.emit = { notices.append($0) }
        var m = try decode("dm_message", as: ChatDMMessageWire.self)
        m.authorAccountId = peer; m.seq = 3; m.messageId = "incoming-root"
        enum Abort: Error { case rollback }
        XCTAssertThrowsError(try store.dmWrite { db in
            try ChatDMStore.write(db, m); _ = try ChatDMStore.owe(db, dm: dm, message: m.messageId, me: me); throw Abort.rollback
        })
        XCTAssertEqual(try read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM dm_notified") }, 0)
        func incoming() throws {
            try write { db in
                try ChatDMStore.write(db, m)
                XCTAssertTrue(try ChatDMStore.owe(db, dm: dm, message: m.messageId, me: me))
                XCTAssertFalse(try ChatDMStore.owe(db, dm: dm, message: m.messageId, me: me))
            }
            ChatDMNotices.live(service, key, dm: dm, id: m.messageId)
        }
        try write { try $0.execute(sql: "INSERT INTO dm_preferences (dm_id, muted) VALUES (?, 1)", arguments: [dm]) }
        try incoming(); XCTAssertTrue(notices.isEmpty)
        try write { try $0.execute(sql: "UPDATE dm_preferences SET muted = 0") }
        ChatDMNotices.live(service, key, dm: dm, id: m.messageId)
        // No delayed banner after unmute: live delivery must consume suppression.
        XCTAssertTrue(notices.isEmpty)
        m.seq = 4; m.messageId = "visible-root"
        let view = UUID(); ChatNotifications.appActive = { true }
        ChatNotifications.show(ChatDMRef(key, dm: dm).place, view: view) { true }
        try incoming(); XCTAssertTrue(notices.isEmpty)
        m.seq = 5; m.messageId = "reply"; m.threadRootId = "visible-root"
        try incoming(); XCTAssertEqual(notices.count, 1, "Looking at roots does not suppress a reply")
        let notice = try XCTUnwrap(notices.first)
        service.orgSessions[key]?.doubtNotWritten = true
        XCTAssertFalse(ChatDMNotices.valid(notice, service: service))
        service.orgSessions[key]?.doubtNotWritten = false
        var deletion = m; deletion.revision = 2; deletion.deletedAt = ChatService.now(); deletion.text = ""
        try write { try ChatDMStore.write($0, deletion) }
        XCTAssertFalse(ChatDMNotices.valid(notice, service: service))
        try store.setGeneration("different")
        XCTAssertFalse(ChatDMNotices.valid(notice, service: service))
    }

    func testDMAttentionSourceMuteReadAndClosedGate() async throws {
        try await ready()
        var m = try decode("dm_message", as: ChatDMMessageWire.self)
        m.authorAccountId = peer; m.seq = 3; m.messageId = "unread"
        try write { try ChatDMStore.write($0, m) }
        let source = ChatDMAttentionSource(service: service), scope = ChatAttention.scope(key, service)
        var rows: [AttentionConversation] = []
        source.start(scope: scope) { rows = $0 }; defer { source.stop() }
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.subjectID, peer)
        let items = AttentionList.items(ledger: [], current: .init(aggregateScope: scope), dms: rows)
        XCTAssertEqual(items.count, 1); XCTAssertTrue(items[0].subtitle.contains("roots"))
        let model = ChatDMModel(key: key, dm: dm, service: service); defer { model.stop() }
        model.setMuted(true); try await wait { rows.isEmpty }
        XCTAssertTrue(try XCTUnwrap(read { try ChatDMEntry.read($0, me: me).first }).unread)
        model.setMuted(false); try await wait { rows.count == 1 }
        service.orgSessions[key]?.doubtNotWritten = true; source.refresh(); XCTAssertTrue(rows.isEmpty)
        service.orgSessions[key]?.doubtNotWritten = false; source.refresh(); XCTAssertEqual(rows.count, 1)
        source.markRead(dm, scope: scope); try await wait { rows.isEmpty }
        XCTAssertFalse(try XCTUnwrap(read { try ChatDMEntry.read($0, me: me).first }).unread)
    }

    func testDisconnectPreservesOnlyOwnCommandsAndReconnectRequiresExplicitRetry() async throws {
        try await ready()
        let id = try service.postDM(key, dm: dm, root: nil, text: "own unsent text", mentions: [peer])
        let original = try XCTUnwrap(store.outbox.commands().first)
        try write { _ = try ChatDMStore.saveDraft($0, dm, root: nil, text: "draft must disappear") }
        var closed = false; service.onCloseConversations = { _ in closed = true }
        let outcome = await service.disconnect(expecting: service.connection)
        XCTAssertEqual(outcome, .done)
        XCTAssertTrue(closed); XCTAssertEqual(service.disconnectedDMCount, 1)
        XCTAssertFalse(service.dmAllowed(key)); XCTAssertFalse(FileManager.default.fileExists(atPath: service.files.cacheURL(key).path))
        let files = service.files
        let archive = try XCTUnwrap(files.savedDMOutbox(key))
        XCTAssertEqual(archive.commands.first?.bodyBytes, original.bodyBytes)
        XCTAssertEqual(archive.count, 1)
        let json = String(decoding: try Data(contentsOf: files.dmOutboxURL(key)), as: UTF8.self)
        XCTAssertFalse(json.contains("Boris")); XCTAssertFalse(json.contains("draft must disappear")); XCTAssertFalse(json.contains("Hello privately."))
        XCTAssertEqual(ChatService(files: files, tokens: FakeTokenStore()).disconnectedDMCount, 1)
        sync = nil; store = nil
        let restored = ChatOrgSession(key: key, files: files)
        let cache = try XCTUnwrap(restored.store), command = try XCTUnwrap(cache.outbox.commands().first)
        XCTAssertEqual(command.state, .unconfirmed); XCTAssertEqual(command.commandId, original.commandId); XCTAssertEqual(command.bodyBytes, original.bodyBytes)
        XCTAssertTrue(try cache.dmRead { try ChatDMStore.cards($0).isEmpty })
        let card = try decode("dm_response", as: ChatDMCard.self)
        try cache.dmWrite { db in
            try ChatDMStore.writeCard(db, card); try ChatDMStore.restoreOutgoing(db, dm: dm, me: me)
        }
        let outgoing = try XCTUnwrap(cache.dmRead { try ChatDMStore.messages($0, dm).first { $0.id == id } })
        XCTAssertEqual(outgoing.localState, .failed); XCTAssertEqual(outgoing.text, "own unsent text")
        XCTAssertNil(try files.savedDMOutbox(key))
    }

    func testOfflineDMNavigationAndAttentionCreateNoNetworkOrPrivateState() async throws {
        let files = ChatFiles(directory: root.appendingPathComponent("offline")), offline = ChatService(files: files, tokens: FakeTokenStore())
        var apiCalls = 0; offline.makeAPI = { server in apiCalls += 1; return ChatAPI(server: server) }
        try await offline.start(mode: .off)
        let before = ChatStubProtocol.seen.count
        let picker = ChatDMNewModel(key: key, state: nil, service: offline)
        let conversation = ChatDMModel(key: key, dm: dm, service: offline)
        let person = ChatDMPeerModel(key: key, peer: peer, service: offline)
        let source = ChatDMAttentionSource(service: offline)
        source.start(scope: ChatAttention.scope(key, offline)) { XCTAssertTrue($0.isEmpty) }
        picker.choose(peer); conversation.loadOlder(); conversation.openThread("root")
        XCTAssertTrue(picker.people.isEmpty); XCTAssertNil(offline.dmList(key)); XCTAssertNil(ChatDMTabs.open(ChatDMRef(key, dm: dm), service: offline))
        XCTAssertNil(offline.dmPeer(key, peer: peer)); XCTAssertNil(ChatDMTabs.open(key, peer: peer, service: offline))
        XCTAssertFalse(person.readable); XCTAssertNil(person.person); XCTAssertNil(person.saveDraft("offline", root: nil))
        XCTAssertFalse(person.send("offline", root: nil, members: [], version: "offline"))
        XCTAssertEqual(apiCalls, 0); XCTAssertEqual(ChatStubProtocol.seen.count, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.directory.path))
        picker.stop(); conversation.stop(); person.stop(); source.stop()
    }

    func testSessionToolsRejectDMArgumentsAndCannotReadDMAsChannel() async throws {
        try await ready()
        service.serverCapabilities[server] = ["chat.dm", "chat.session_tools"]
        service.isServerKnown = { _, _ in true }
        try write { try $0.execute(sql: "UPDATE meta SET channels_served = 1") }
        let before = ChatStubProtocol.seen.count
        let caller = ChatLocalCaller(surface: UUID().uuidString, claudePID: 100, claudeStart: 1000, signature: "test")
        let attempts: [[String: ChatJSON]] = [
            ["tool": .string("chat_read"), "dm_id": .string(dm)],
            ["tool": .string("chat_read"), "kind": .string("dm"), "channel_id": .string(dm)],
            ["tool": .string("chat_post"), "channel_id": .string(dm), "text": .string("no")],
            ["tool": .string("chat_read"), "channel_id": .string(dm)],
            ["tool": .string("chat_dms")]
        ]
        for args in attempts {
            do {
                _ = try await ChatSessionTools.call(.object(args), caller: caller, service: service, revalidate: { true })
                XCTFail("Session tool reached a DM")
            } catch {}
        }
        XCTAssertEqual(ChatStubProtocol.seen.count, before)
        XCTAssertTrue(try store.outbox.commands().isEmpty)
    }
    func testUnsentDMArchiveFailureKeepsQueueAndGateClosed() async throws {
        try await ready()
        _ = try service.postDM(key, dm: dm, root: nil, text: "must survive", mentions: [])
        try FileManager.default.createDirectory(at: service.files.dmOutboxURL(key), withIntermediateDirectories: true)
        let outcome = await service.disconnect(expecting: service.connection)
        guard case .notFinished = outcome else { return XCTFail("Failed archive must not finish disconnect") }
        XCTAssertFalse(service.dmAllowed(key)); XCTAssertEqual(try store.outbox.commands().count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.files.cacheURL(key).path))
        try FileManager.default.removeItem(at: service.files.dmOutboxURL(key))
        let retry = await service.disconnect(expecting: service.connection)
        XCTAssertEqual(retry, .done); XCTAssertEqual(service.disconnectedDMCount, 1)
        let mode = try FileManager.default.attributesOfItem(atPath: service.files.dmOutboxURL(key).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    private func restartWithRevokedSession() async throws {
        let files = service.files
        service.sessionEnded("Session revoked")
        service.orgSessions.values.forEach { $0.sync?.stop() }
        try store.queue.close()
        sync = nil; store = nil
        service = ChatService(files: files, tokens: FakeTokenStore())
        service.followsFeed = false
        try await service.start(mode: .server)
        XCTAssertTrue(service.orgSessions.isEmpty, "Revoked sessions never open their cache")
    }

    func testDisconnectAfterRevokedRestartArchivesUnopenedDMQueue() async throws {
        try await ready()
        _ = try service.postDM(key, dm: dm, root: nil, text: "survive revoked restart", mentions: [])
        let original = try XCTUnwrap(store.outbox.commands().first)
        try await restartWithRevokedSession()

        let outcome = await service.disconnect(expecting: service.connection)
        XCTAssertEqual(outcome, .done)
        let archive = try XCTUnwrap(service.files.savedDMOutbox(key))
        XCTAssertEqual(archive.commands.map(\.bodyBytes), [original.bodyBytes])
        XCTAssertEqual(service.disconnectedDMCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: service.files.cacheURL(key).path))
    }

    func testDisconnectAfterRevokedRestartKeepsUnopenedCacheIfArchiveFails() async throws {
        try await ready()
        _ = try service.postDM(key, dm: dm, root: nil, text: "keep unopened queue", mentions: [])
        try await restartWithRevokedSession()
        try FileManager.default.createDirectory(at: service.files.dmOutboxURL(key), withIntermediateDirectories: true)

        let outcome = await service.disconnect(expecting: service.connection)
        guard case .notFinished = outcome else { return XCTFail("An unopened queue must be archived before deletion") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.files.cacheURL(key).path))
        XCTAssertEqual(try service.files.loadConnections().count, 1)
        try FileManager.default.removeItem(at: service.files.dmOutboxURL(key))
        let retry = await service.disconnect(expecting: service.connection)
        XCTAssertEqual(retry, .done)
        XCTAssertEqual(try service.files.savedDMOutbox(key)?.count, 1)
    }

    func testFirstLivePeerDMNotifiesAndReadOneRetriesAReplacedWindow() async throws {
        routes.set("/v1/orgs/\(org)/dms", #"{"dms":[],"next":null}"#)
        try await ready()
        var card = try decode("dm_response", as: ChatDMCard.self)
        var message = try XCTUnwrap(card.messages?.first); message.authorAccountId = peer
        card.messages = [message]
        routes.set("/v1/orgs/\(org)/dms/\(dm)", String(decoding: try JSONEncoder().encode(card), as: UTF8.self))
        routes.set("/v1/orgs/\(org)/dms/\(dm)/messages", String(decoding: try JSONEncoder().encode(ChatDMMessagesPage(messages: [message], next: nil, head: card.head)), as: UTF8.self))
        let gate = Gate(); self.gate = gate; routes.gate = gate
        routes.gated = "/v1/orgs/\(org)/dms/\(dm)/messages?before=\(message.seq + 1)"; gate.close()
        let oldEmit = ChatNotifications.emit; defer { ChatNotifications.emit = oldEmit }
        var emitted = 0; ChatNotifications.emit = { _ in emitted += 1 }
        sync.onLiveMessage = { [self] dm, id in ChatDMNotices.live(service, key, dm: dm, id: id) }
        let event = try decode("event_dm_member_signal", as: ChatEvent.self)
        sync.receive(event, live: true)
        try await wait { ChatStubProtocol.seen.contains { $0.request.url?.query == "before=\(message.seq + 1)" } }
        try write { try ChatDMStore.writeCard($0, card) }
        gate.open()
        try await wait { emitted == 1 }
        XCTAssertEqual(try read { try ChatDMStore.mark($0, dm) }, 0)
        XCTAssertEqual(emitted, 1)
    }


    func testPickerTracksMembershipAndRejectedCardClosesGate() async throws {
        try await ready()
        let picker = ChatDMNewModel(key: key, state: nil, service: service)
        defer { picker.stop() }
        XCTAssertEqual(picker.people.count, 1)
        try write { try $0.execute(sql: "DELETE FROM members WHERE account_id = ?", arguments: [peer]) }
        try await wait { picker.people.isEmpty }
        let model = ChatDMModel(key: key, dm: dm, service: service); defer { model.stop() }
        model.saveDraft("private draft", root: nil)
        routes.set("/v1/orgs/\(org)/dms/\(dm)", #"{"error":"not_found"}"#, status: 404)
        do { _ = try await sync.refresh(dm); XCTFail("A revoked card was accepted") } catch {}
        XCTAssertFalse(service.dmAllowed(key)); XCTAssertFalse(picker.readable)
        XCTAssertNil(model.card); XCTAssertNil(model.draft(root: nil))
        XCTAssertTrue(try read { try ChatDMStore.messages($0, dm).isEmpty })
    }

    func testZeroUnsentDisconnectStillOffersReconnectAfterRestart() async throws {
        XCTAssertNil(ChatService(files: ChatFiles(directory: root.appendingPathComponent("never")), tokens: FakeTokenStore()).disconnectedDMCount)
        let result = await service.disconnect(expecting: service.connection)
        XCTAssertEqual(result, .done); XCTAssertEqual(service.disconnectedDMCount, 0)
        XCTAssertEqual(ChatService(files: service.files, tokens: FakeTokenStore()).disconnectedDMCount, 0)
    }

    func testSignedDMFixturesUseCanonicalTextAndSessionAttributionAcrossHTTPAndEvents() async throws {
        try await ready()
        let wire: ChatDMMessageWire = try decode("dm_signed_message", as: ChatDMMessageWire.self)
        let page = ChatDMMessagesPage(messages: [wire], next: nil, head: wire.seq)
        routes.set("/v1/orgs/\(org)/dms/\(dm)/messages", String(decoding: try JSONEncoder().encode(page), as: UTF8.self))
        _ = try await sync.page(dm, before: nil)
        let message = try XCTUnwrap(try read { try ChatDMStore.messages($0, dm).first { $0.id == wire.messageId } })
        XCTAssertEqual(message.text, "Hello privately.")
        XCTAssertEqual(message.authorSessionName, "Review [private]")
        XCTAssertNil(message.authorAgentId)
        let attribution = ChatMessageAttribution(message, ownerName: "Anna", ownerHandle: "anna")
        XCTAssertEqual(attribution.title, "Review [private] (Anna's agent)")
        XCTAssertNil(attribution.publishedAgentId)
        XCTAssertTrue(ChatAuthorIdentity(message).isBot)
        let event = try decode("event_dm_signed_post", as: ChatEvent.self)
        try write { _ = try ChatDMStore.apply($0, event) }
        XCTAssertEqual(try read { try ChatDMStore.messages($0, dm).first { $0.id == wire.messageId }?.text }, message.text)
        let legacy = try decode("dm_message", as: ChatDMMessageWire.self)
        XCTAssertNil(legacy.authorSessionName); XCTAssertNil(legacy.canonicalText)
        XCTAssertEqual(ChatMessage(dm: legacy).text, legacy.text)
    }

    func testSignedDMEditUsesCanonicalContractAndRollbackPausesOnlySignedChanges() async throws {
        try await ready()
        service.serverCapabilities[server] = ["chat.dm", "chat.dm.session_signature"]
        let wire = try decode("dm_signed_message", as: ChatDMMessageWire.self)
        try write { try ChatDMStore.write($0, wire) }
        let model = ChatDMModel(key: key, dm: dm, service: service); defer { model.stop() }
        let message = try XCTUnwrap(model.feed.messages.first { $0.id == wire.messageId })
        XCTAssertTrue(model.beginEditing(message, root: nil))
        XCTAssertEqual(model.editing?.text, wire.canonicalText)
        try service.changeDM(key, dm: dm, message: wire.messageId, text: "Edited privately.", revision: wire.revision)
        let edit = try XCTUnwrap(store.outbox.commands().last)
        let expected: ChatCommandEnvelope = try decode("dm_signed_edit_request", as: ChatCommandEnvelope.self)
        XCTAssertEqual(ChatService.args(edit)["text_format"], expected.args["text_format"])
        XCTAssertEqual(ChatService.args(edit)["text"]?.string, "Edited privately.")
        XCTAssertNil(ChatService.args(edit)["author_session_name"])
        let outbox = ChatOutbox(queues: [store.outbox], api: ChatAPI(server: server), token: "test-only", sessionId: "s-me", held: true)
        service.configureCommandCapabilities(outbox, key: key)
        XCTAssertFalse(outbox.isSuspended(edit))
        service.serverCapabilities[server] = ["chat.dm"]
        XCTAssertTrue(outbox.isSuspended(edit)); XCTAssertFalse(outbox.maySendCommand(edit))
        XCTAssertFalse(model.canEdit(message)); XCTAssertTrue(model.canDelete(message))
        try write { try $0.execute(sql: "DELETE FROM dm_changes") }
        try service.changeDM(key, dm: dm, message: wire.messageId, text: nil, revision: wire.revision)
        let deletion = try XCTUnwrap(store.outbox.commands().last)
        XCTAssertFalse(outbox.isSuspended(deletion))
        XCTAssertNil(ChatService.args(deletion)["text_format"])
    }

    func testSignedPendingProjectionAndTombstoneRetainSignatureButEraseBothBodies() async throws {
        try await ready()
        let id = UUID().uuidString.lowercased()
        let prepared = try service.prepareCommand(key, type: "dm.message.post", args: .object([
            "dm_id": .string(dm), "message_id": .string(id), "text": .string("pending canonical"),
            "author_session_name": .string("Original tab"), "_mcp": .object([:])]))
        var record = prepared.record; record.state = .unconfirmed
        try write { db in
            _ = try store.outbox.insert(db, record)
            try ChatDMStore.restoreOutgoing(db, dm: dm, me: me)
        }
        let pending = try XCTUnwrap(try read { try ChatDMStore.messages($0, dm).first { $0.id == id } })
        XCTAssertEqual(pending.text, "pending canonical"); XCTAssertEqual(pending.authorSessionName, "Original tab")
        XCTAssertEqual(ChatMessageAttribution(pending, ownerName: "Me", ownerHandle: nil).title, "Original tab (Me's agent)")
        let peerModel = ChatDMPeerModel(key: key, peer: peer, service: service)
        defer { peerModel.stop() }
        XCTAssertEqual(peerModel.attribution(record)?.title, "Original tab (Me's agent)")
        let wire = try decode("dm_signed_message", as: ChatDMMessageWire.self)
        try write { try ChatDMStore.write($0, wire) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture("event_dm_signed_post")) as? [String: Any])
        object["message"] = nil; object["type"] = "dm.message.delete"
        var body = object["body"] as! [String: Any]; body["revision"] = 2; object["body"] = body
        let deletion = try JSONDecoder().decode(ChatEvent.self, from: JSONSerialization.data(withJSONObject: object))
        try write { _ = try ChatDMStore.apply($0, deletion) }
        let bytes = try XCTUnwrap(try read { try Data.fetchOne($0, sql: "SELECT body FROM dm_messages WHERE message_id = ?", arguments: [wire.messageId]) })
        let erased = try JSONDecoder().decode(ChatDMMessageWire.self, from: bytes)
        XCTAssertEqual(erased.text, ""); XCTAssertEqual(erased.canonicalText, "")
        XCTAssertEqual(erased.authorSessionName, wire.authorSessionName)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Hello privately"))
    }

    func testUnreadableDMQueueCannotBeDeletedByDisconnect() async throws {
        try await ready()
        _ = try service.postDM(key, dm: dm, root: nil, text: "keep this command", mentions: [])
        try store.queue.close()
        let outcome = await service.disconnect(expecting: service.connection)
        guard case .notFinished = outcome else { return XCTFail("An unreadable own-message queue must be retained") }
        XCTAssertFalse(service.dmAllowed(key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.files.cacheURL(key).path))
        let recovered = ChatOrgSession(key: key, files: service.files)
        let own = try XCTUnwrap(recovered.store?.outbox.commands().first)
        XCTAssertEqual(ChatService.args(own)["text"]?.string, "keep this command")
    }
}
