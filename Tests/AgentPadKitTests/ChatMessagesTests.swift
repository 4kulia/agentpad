import AppKit
import Foundation
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

/// Messages (DESIGN-F3): the rule of writing, the window and its epoch,
/// single reads, threads' own cursors, sending and its confirmation, the
/// rights' doubt on refusals, the channels followed, drafts, native text.
@MainActor
final class ChatMessagesTests: XCTestCase {
    private var root: URL!
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    private let me = CallJSON.anna
    private let other = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
    private let team = "6a1c9e2b-7d3f-4a5e-8b1c-2d3e4f5a6b7c"
    private let channel = "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f"
    private var services: [ChatService] = []

    private var teamScope: TeamServiceTestScope!

    override func setUp() async throws {
        teamScope = TeamServiceTestScope()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-messages-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        defer { teamScope.close(); teamScope = nil }
        for service in services {
            service.stopFeed()
            for session in service.orgSessions.values { session.sync?.stop() }
        }
        services = []
        try? FileManager.default.removeItem(at: root)
    }

    private var files: ChatFiles { ChatFiles(directory: root.appendingPathComponent("chat")) }
    private var key: ChatOrgKey { ChatOrgKey(server: server, accountId: me, orgId: org) }
    private var channelStream: String { "channel:\(channel)" }

    private func waitUntil(_ what: String = "", _ condition: @MainActor () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out \(what)", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: JSON

    private func message(_ id: String, seq: Int, text: String = "hi", revision: Int = 1, root: String? = nil, deleted: Bool = false,
                         author: String? = nil, mentions: [String] = []) -> String {
        #"{"message_id":"\#(id)","channel_id":"\#(channel)","thread_root_id":\#(root.map { "\"\($0)\"" } ?? "null"),"author_account_id":"\#(author ?? other)","text":"\#(deleted ? "" : text)","mentions":\#(String(decoding: try! JSONEncoder().encode(mentions.map { ["account_id": $0] }), as: UTF8.self)),"revision":\#(revision),"seq":\#(seq),"created_at":"2026-10-05T09:00:00Z","edited_at":null,"deleted_at":\#(deleted ? "\"2026-10-05T10:00:00Z\"" : "null")}"#
    }

    private func wire(_ json: String) -> ChatMessageWire { try! JSONDecoder().decode(ChatMessageWire.self, from: Data(json.utf8)) }

    private func page(_ messages: [String], next: Int?) -> String {
        #"{"messages":[\#(messages.joined(separator: ","))],"next":\#(next.map(String.init) ?? "null"),"head":100}"#
    }

    private func card(_ head: Int, _ messages: [String], before: Int?) -> String {
        #"{"channel_id":"\#(channel)","team_id":"\#(team)","name":"billing","created_by":"\#(me)","created_at":"2026-10-05T09:00:00Z","archived":false,"archived_at":null,"version":1,"head":\#(head),"messages":[\#(messages.joined(separator: ","))],"messages_before":\#(before.map(String.init) ?? "null")}"#
    }

    private func event(_ seq: Int, _ type: String, body: String, message: String?) throws -> ChatEvent {
        let json = #"{"stream":"\#(channelStream)","seq":\#(seq),"id":"e\#(seq)","type":"\#(type)","actor":null,"body":\#(body),"command_id":null,"at":"2026-10-05T09:00:00Z"\#(message.map { ",\"message\":\($0)" } ?? "")}"#
        return try JSONDecoder().decode(ChatEvent.self, from: Data(json.utf8))
    }

    // MARK: The cache alone

    /// A store with the channel's card and a window of `messages`.
    private func store(_ messages: [String] = [], head: Int = 10, before: Int? = nil) throws -> ChatStore {
        let store = try ChatStore.open(files: files, key: key).store
        let cardWire = try JSONDecoder().decode(ChatChannelCard.self, from: Data(card(head, messages, before: before).utf8))
        try store.apply(ChatSnapshot(cursors: ["team:\(team)": 0], orgName: "R", members: [], teams: [.init(teamId: team, name: "T", mine: true)],
                                     teamMembers: [], invitations: nil, channels: [cardWire], channelsComplete: true))
        return store
    }

    private func row(_ store: ChatStore, _ id: String) throws -> ChatMessage? {
        try store.queue.read { db in try Row.fetchOne(db, sql: "\(ChatMessages.select) WHERE m.message_id = ?", arguments: [id]).map(ChatMessage.init(row:)) }
    }

    /// Synchronous reads and writes, for async tests (GRDB's async forms otherwise).
    private func int(_ store: ChatStore, _ sql: String, _ args: [String] = []) throws -> Int? {
        try store.queue.read { db in try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) }
    }
    private func doubt(_ store: ChatStore) throws -> Bool? {
        try store.queue.read { db in try Bool.fetchOne(db, sql: "SELECT rights_in_doubt FROM meta") }
    }
    private func newWindow(_ store: ChatStore, head: Int, _ messages: [ChatMessageWire], before: Int?) throws {
        let channel = channel
        try store.queue.write { db in try ChatMessages.applyWindow(db, channel: channel, head: head, messages: messages, before: before) }
    }
    private func sending(_ store: ChatStore, _ id: String) throws {
        let channel = channel, me = me
        try store.queue.write { db in
            try ChatMessages.insertSending(db, id: id, channel: channel, root: nil, author: me, text: "x", mentions: [], at: "now")
        }
    }

    private func window(_ store: ChatStore) throws -> (epoch: Int, bottom: Int, next: Int?) {
        try store.queue.read { db in
            let r = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM channel_windows WHERE channel_id = ?", arguments: [self.channel]))
            return (r["epoch"], r["bottom_seq"], r["history_next"])
        }
    }

    /// The rule of writing: a newer revision only; a deleted message is not
    /// brought back by an older page (F3 check).
    func testAnOlderPageDoesNotBringBackADeletedText() throws {
        let store = try store([message("m1", seq: 5, text: "secret")])
        try store.queue.write { db in try ChatMessages.write(db, self.wire(self.message("m1", seq: 5, revision: 2, deleted: true))) }
        try store.queue.write { db in try ChatMessages.applyHistory(db, channel: self.channel, page: ChatMessagesPage(messages: [self.wire(self.message("m1", seq: 5, text: "secret"))], next: nil, head: nil)) }
        let kept = try XCTUnwrap(row(store, "m1"))
        XCTAssertTrue(kept.deleted)
        XCTAssertEqual(kept.text, "")
    }

    /// A frame without its message leaves a placeholder with no changing
    /// part; the full message of the same revision fills it (review F3b-2).
    func testAPlaceholderIsFilledByTheSameRevision() throws {
        let store = try store()
        _ = try store.apply(event(11, "message.post", body: #"{"message_id":"m9","revision":1,"message_seq":11}"#, message: nil))
        let placeholder = try XCTUnwrap(row(store, "m9"))
        XCTAssertFalse(placeholder.hasMutable)
        XCTAssertTrue(placeholder.loading)
        try store.queue.write { db in try ChatMessages.applyOne(db, id: "m9", page: ChatMessagesPage(messages: [self.wire(self.message("m9", seq: 11, text: "full"))], next: nil, head: nil)) }
        let full = try XCTUnwrap(row(store, "m9"))
        XCTAssertEqual(full.text, "full")
        XCTAssertFalse(full.loading)
    }

    /// A new window: a new epoch, older messages gone, the stream's cursor
    /// at its head, threads' cursors void; a message being sent stays.
    func testANewWindowReplacesTheOldOne() throws {
        let store = try store([message("m1", seq: 3), message("m2", seq: 4)], head: 4)
        try store.queue.write { db in
            try ChatMessages.insertSending(db, id: "local", channel: self.channel, root: nil, author: self.me, text: "x", mentions: [], at: "now")
            try ChatMessages.applyThread(db, channel: self.channel, root: "m1", epoch: 1, page: ChatMessagesPage(messages: [], next: 2, head: nil))
        }
        let before = try window(store)
        try store.queue.write { db in
            try ChatMessages.applyWindow(db, channel: self.channel, head: 20, messages: [self.wire(self.message("m3", seq: 19))], before: 19)
        }
        let after = try window(store)
        XCTAssertEqual(after.epoch, before.epoch + 1)
        XCTAssertEqual(after.bottom, 19)
        XCTAssertNil(try row(store, "m1"))
        XCTAssertNotNil(try row(store, "local"))
        XCTAssertEqual(try store.cursor(channelStream), 20)
        XCTAssertEqual(try store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM thread_cursors") }, 0)
    }

    /// A single read writes only its message: the window's bounds stay (review F3-3).
    func testASingleReadLeavesTheWindow() throws {
        let store = try store([message("m5", seq: 900)], head: 900, before: 900)
        let before = try window(store)
        try store.queue.write { db in
            try ChatMessages.applyOne(db, id: "old", page: ChatMessagesPage(
                messages: [self.wire(self.message("old", seq: 100)), self.wire(self.message("older", seq: 99))], next: nil, head: nil))
        }
        let after = try window(store)
        XCTAssertEqual(after.bottom, before.bottom)
        XCTAssertEqual(after.next, before.next)
        XCTAssertNil(try row(store, "older"))
    }

    /// Leaving the team takes the channel's messages, drafts and cursor.
    func testLeavingTheTeamTakesTheChannelsMessages() throws {
        let store = try store([message("m1", seq: 3)], head: 3)
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO drafts (channel_id, thread_root_id, text, updated_at) VALUES (?, '', 'x', 0)", arguments: [self.channel])
        }
        let leave = try JSONDecoder().decode(ChatEvent.self, from: Data(#"{"stream":"team:\#(team)","seq":1,"id":"e","type":"team.remove_member","actor":null,"body":{"team_id":"\#(team)","account_id":"\#(me)"},"command_id":null,"at":"x"}"#.utf8))
        _ = try store.apply(leave)
        XCTAssertNil(try row(store, "m1"))
        XCTAssertEqual(try store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM drafts") }, 0)
        XCTAssertEqual(try store.cursor(channelStream), 0)
    }

    /// A post being sent is confirmed by any source of its message — here
    /// a window — and never shows twice (review F3-2).
    func testSendingIsConfirmedByAnySource() throws {
        let store = try store()
        try store.queue.write { db in
            try ChatMessages.insertSending(db, id: "p1", channel: self.channel, root: nil, author: self.me, text: "mine", mentions: [], at: "now")
            try ChatMessages.applyWindow(db, channel: self.channel, head: 11, messages: [self.wire(self.message("p1", seq: 11, text: "mine", author: self.me))], before: nil)
        }
        let confirmed = try XCTUnwrap(row(store, "p1"))
        XCTAssertNil(confirmed.localState)
        XCTAssertEqual(confirmed.seq, 11)
        XCTAssertEqual(try store.queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") }, 1)
    }

    /// A channel made by an event has its stream from the start, so an open
    /// tab can follow it (found by the live test: no window had come).
    func testAChannelMadeByAnEventCanBeFollowed() throws {
        let store = try store()
        let made = "9d8e7f6a-5b4c-4d3e-8f2a-1b0c9d8e7f6a"
        let create = try JSONDecoder().decode(ChatEvent.self, from: Data(#"{"stream":"team:\#(team)","seq":1,"id":"e","type":"channel.create","actor":null,"body":{"channel_id":"\#(made)","team_id":"\#(team)","name":"new","created_by":"\#(me)","created_at":"x","archived":false,"archived_at":null,"version":1},"command_id":null,"at":"x"}"#.utf8))
        _ = try store.apply(create)
        XCTAssertEqual(try store.queue.read { db in try Int.fetchOne(db, sql: "SELECT seq FROM cursors WHERE stream = ?", arguments: ["channel:\(made)"]) }, 0)
        XCTAssertEqual(try store.queue.read { db in try Int.fetchOne(db, sql: "SELECT bottom_seq FROM channel_windows WHERE channel_id = ?", arguments: [made]) }, 0)
    }

    /// A thread goes on by its own cursor; a lone old reply from an event
    /// does not move it (review F3-4).
    func testAThreadGoesOnByItsOwnCursor() throws {
        let store = try store([message("root", seq: 50)], head: 60)
        try store.queue.write { db in
            try ChatMessages.applyThread(db, channel: self.channel, root: "root", epoch: 1, page: ChatMessagesPage(
                messages: [self.wire(self.message("root", seq: 50)), self.wire(self.message("r9", seq: 59, root: "root"))], next: 59, head: nil))
            try ChatMessages.write(db, self.wire(self.message("r1", seq: 51, root: "root")))
        }
        XCTAssertEqual(try store.queue.read { db in try Int.fetchOne(db, sql: "SELECT next FROM thread_cursors WHERE root_id = 'root'") }, 59)
    }

    /// A new generation empties the server's messages; one being sent stays.
    func testANewGenerationKeepsWhatIsBeingSent() throws {
        let store = try store([message("m1", seq: 3)], head: 3)
        try store.queue.write { db in
            try ChatMessages.insertSending(db, id: "p", channel: self.channel, root: nil, author: self.me, text: "x", mentions: [], at: "now")
        }
        try store.beginGeneration("g2", keeping: [])
        XCTAssertNil(try row(store, "m1"))
        XCTAssertNotNil(try row(store, "p"))
    }

    // MARK: The model

    /// Drafts of the channel and of a thread are apart and outlive a restart.
    func testDraftsAreApartAndKept() throws {
        let store = try store()
        let model = ChatChannelModel(key: key, channel: channel)
        model.follow(store)
        model.saveDraft("channel text", root: nil)
        model.saveDraft("thread text", root: "m1")
        let reopened = ChatChannelModel(key: key, channel: channel)
        reopened.follow(try ChatStore.open(files: files, key: key).store)
        XCTAssertEqual(reopened.draft(root: nil), "channel text")
        XCTAssertEqual(reopened.draft(root: "m1"), "thread text")
    }

    func testMentionsAndTheLimit() {
        let members = [(account: "a1", handle: "anna"), (account: "b1", handle: "boris")]
        XCTAssertEqual(ChatChannelModel.mentions(in: "hi @anna and @borisx, mail a@anna.com", members: members), ["a1"])
        XCTAssertNotNil(ChatChannelModel.textProblem("   "))
        XCTAssertNotNil(ChatChannelModel.textProblem(String(repeating: "я", count: 8193)))
        XCTAssertNil(ChatChannelModel.textProblem(String(repeating: "я", count: 8192)))
    }

    /// The last 50 of 10 000 cached messages read within 200 ms (F3's measure).
    func testOpeningFiftyOfTenThousand() throws {
        let store = try store()
        try store.queue.write { db in
            for n in 1...10_000 { try ChatMessages.write(db, self.wire(self.message("m\(n)", seq: n, root: n % 3 == 0 ? "m1" : nil))) }
        }
        let start = Date()
        let feed = try store.queue.read { db in try ChatChannelModel.readFeed(db, channel: self.channel, shown: 50) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertEqual(feed.messages.count, 50)
        XCTAssertTrue(feed.hasOlder)
    }

    /// Native text links only what passed `chatLink`, over F7's hostile set.
    func testNativeTextLinksOnlyCheckedTargets() {
        let inputs = ["[a](javascript:alert(1))", "[a](file:///etc/passwd)", "![x](https://evil.example/p.png)", "[a](https://ex.com/%E2%80%AEgpj)",
                      "<a href=\"javascript:x\">y</a>", "[ok](https://ex.com/a)", "see https://ex.com/b.", "[m](mailto:x@ex.com)"]
        var links: [URL] = []
        for input in inputs {
            let text = ChatMarkdownText.attributed(input)
            for run in text.runs { if let url = run.link { links.append(url) } }
        }
        XCTAssertEqual(links.map(\.absoluteString), ["https://ex.com/a", "https://ex.com/b", "mailto:x@ex.com"])
        for url in links { XCTAssertNotNil(MarkdownRenderer.chatLinkTarget(url)) }
        var opened: [URL] = []
        _ = ChatMarkdownText.open(URL(string: "file:///etc/passwd")!) { opened.append($0) }
        _ = ChatMarkdownText.open(URL(string: "https://ex.com")!) { opened.append($0) }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://ex.com"])
    }

    // MARK: With a server

    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: (Int, Data)] = [:]
        var gate: Gate?
        var gated: String?
        var freezeBeforeGate = false
        func set(_ path: String, _ body: String, status: Int = 200) { setBytes(path, Data(body.utf8), status: status) }
        func setBytes(_ path: String, _ body: Data, status: Int = 200) { lock.withLock { map[path] = (status, body) } }
        func get(_ path: String) -> (Int, Data)? { lock.withLock { map[path] } }
    }

    private func state(_ messages: [String] = [], head: Int = 10, before: Int? = nil, role: String = "member") -> String {
        #"""
        {"org":{"org_id":"\#(org)","name":"Rabbitshat"},"members":[{"account_id":"\#(me)","handle":"anna","name":"Anna","role":"\#(role)"}],
         "teams":[{"team_id":"\#(team)","name":"Billing","is_general":false,"archived_at":null,"members":["\#(me)"]}],"my_teams":["\#(team)"],
         "admin":null,"agents":[],"requests":[],"requests_next":null,
         "channels":[\#(card(head, messages, before: before))],"channels_next":null,
         "streams":{"org:\#(org)":0,"member:\#(org):\#(me)":4,"team:\#(team)":3}}
        """#
    }

    private func started(_ answers: Answers, channelOpen: Bool = true, alsoOpen: [String] = [], hold: Set<String> = [], b1: Bool = false, role: String = "member") async throws -> (ChatService, FakeSocketTransport) {
        let org = self.org, me = self.me
        answers.set("/v1/me", #"{"account_id":"\#(me)","session_id":"s-anna","orgs":[{"org_id":"\#(org)","org_name":"Rabbitshat","role":"\#(role)","handle":"anna","name":"Anna"}],"streams":{"account:\#(me)":0}}"#)
        answers.set("/v1/server", #"{"name":"s","version":"0.1.0","generation":"g1","api_versions":["v1"],"capabilities":["auth.email_code","events.ws","chat.channels"]}"#)
        if b1 {
            answers.set("/v1/server", #"{"name":"s","version":"0.1.0","generation":"g1","api_versions":["v1"],"capabilities":["auth.email_code","events.ws","chat.channels","chat.reactions","chat.pins","chat.thread_summary","chat.thread_participation"]}"#)
            if answers.get("/v1/orgs/\(org)/my-threads") == nil { answers.set("/v1/orgs/\(org)/my-threads", #"{"member_head":4,"items":[],"next":null}"#) }
        }
        ChatStubProtocol.reset { request, _ in
            let path = request.url?.path ?? ""
            let full = path + (request.url?.query.map { "?\($0)" } ?? "")
            let frozen = answers.freezeBeforeGate ? answers.get(full) ?? answers.get(path) : nil
            if full == answers.gated { answers.gate?.pass() }
            if let (status, body) = frozen ?? answers.get(full) ?? answers.get(path) { return .success(.init(status: status, body: body)) }
            return .success(.init(status: 200, body: Data(#"{"events":[],"result":{}}"#.utf8)))
        }
        let service = ChatService(files: files, tokens: FakeTokenStore())
        services.append(service)
        if channelOpen { service.channelTab(ChannelRef(key, channel: channel), open: true) }
        for other in alsoOpen { service.channelTab(ChannelRef(key, channel: other), open: true) }
        service.makeAPI = { ChatAPI(server: $0, protocolClasses: [ChatStubProtocol.self]) }
        let transports = Transports()
        service.makeSocketTransport = {
            let t = FakeSocketTransport()
            transports.all.append(t)
            return t
        }
        service.followsFeed = true
        service.retryDelay = { _ in 0.05 }
        try service.saveSignIn(ChatConnection(server: server, accountId: me, sessionId: "s-anna", deviceName: "Mac", orgId: org), token: "aps_t")
        try await service.start(mode: .server)
        try await waitUntil("transport") { !transports.all.isEmpty }
        let transport = transports.all[0]
        transport.push(.opened)
        transport.frame(#"{"frame":"hello","generation":"g1","heartbeat_seconds":25,"version":"0.1.0"}"#)
        try await waitUntil("subscribes") { !transport.subscribes.isEmpty }
        var answered = 0
        for _ in 0..<6 {
            for streams in transport.subscribes.dropFirst(answered) {
                for (stream, head) in streams where !hold.contains(stream) { transport.frame(#"{"frame":"subscribed","stream":"\#(stream)","head":\#(head)}"#) }
            }
            answered = transport.subscribes.count
            try await Task.sleep(for: .milliseconds(20))
        }
        return (service, transport)
    }

    private func frame(_ seq: Int, _ type: String, _ id: String, message: String?) -> String {
        #"{"frame":"event","stream":"\#(channelStream)","seq":\#(seq),"id":"e\#(seq)","type":"\#(type)","actor":null,"body":{"message_id":"\#(id)","revision":1,"message_seq":\#(seq)},"command_id":null,"at":"2026-10-05T09:00:00Z","sig":null,"sig_alg":null,"enc":null\#(message.map { ",\"message\":\($0)" } ?? "")}"#
    }

    /// An open tab's channel is followed; its events write messages.
    func testAnOpenChannelIsFollowed() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, transport) = try await started(answers)
        try await waitUntil("channel subscribed") { transport.subscribes.contains { $0.keys.contains(self.channelStream) } }
        transport.frame(frame(11, "message.post", "m1", message: message("m1", seq: 11, text: "live")))
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try await waitUntil("message") { (try? self.row(store, "m1"))?.text == "live" }
    }

    /// Posted here, confirmed once by its event; its repeat delivery adds nothing.
    func testAPostIsConfirmedOnce() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, transport) = try await started(answers)
        try await waitUntil("channel subscribed") { transport.subscribes.contains { $0.keys.contains(self.channelStream) } }
        let id = try service.post(key, channel: channel, root: nil, text: "mine", mentions: [])
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        XCTAssertEqual(try row(store, id)?.localState, .sending)
        transport.frame(frame(11, "message.post", id, message: message(id, seq: 11, text: "mine", author: me)))
        transport.frame(frame(11, "message.post", id, message: message(id, seq: 11, text: "mine", author: me)))
        try await waitUntil("confirmed") { (try? self.row(store, id))?.localState == nil }
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM messages WHERE message_id = ?", [id]), 1)
    }

    /// A post refused `403`: "not sent" with why, and the rights in doubt (review F3-1).
    func testARefusedPostIsNotSentAndPutsRightsInDoubt() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        answers.set("/v1/commands", #"{"error":"forbidden"}"#, status: 403)
        let snapshots = sync.snapshots
        let id = try service.post(key, channel: channel, root: nil, text: "x", mentions: [])
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try await waitUntil("failed") { (try? self.row(store, id))?.localState == .failed }
        XCTAssertEqual(try row(store, id)?.localError, "forbidden")
        XCTAssertEqual(ChatChannelModel.reason("forbidden"), "You can't post here any more")
        // In doubt, so a snapshot decides (the stub's answers at once, which ends it).
        try await waitUntil("a snapshot after the refusal") { sync.snapshots > snapshots }
    }

    func testReview1FileCommandRefusalClosesCachedPreviewsAndViewerBeforeWebSocketRevoke() async throws {
        let testRoot = root!
        defer { root = testRoot }
        for type in ["message.post_with_attachments", "request.create_in_channel_with_attachments", "attachment.prepare", "attachment.complete", "attachment.cancel"] {
            root = testRoot.appendingPathComponent(UUID().uuidString)
            let answers = Answers()
            answers.set("/v1/orgs/\(org)/state", state())
            let (service, _) = try await started(answers)
            let sync = try XCTUnwrap(service.orgSessions[key]?.sync), store = try XCTUnwrap(service.orgSessions[key]?.store)
            try await waitUntil("snapshot") { !sync.needsSnapshot }
            service.serverCapabilities[server, default: []].formUnion(["chat.attachments", "chat.attachments_context"])
            let limits = try JSONDecoder().decode(ChatAttachmentLimits.self, from: Data(ChatAttachmentsTests.limitsJSON.utf8))
            service.serverAttachmentLimits[server] = limits
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 64, bitsPerPixel: 32))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            var file = try ChatAttachmentStorage.descriptor(data: png, name: "private.png", limits: limits); file.hasPreview = true
            let id = UUID().uuidString.lowercased(), channel = channel
            let descriptor = file
            let posted = wire(self.message(id, seq: 1))
            try await store.queue.write { db in
                _ = try ChatMessages.write(db, posted)
                try ChatAttachments.write(db, id: id, files: [descriptor], only: false)
            }
            let message = try XCTUnwrap(row(store, id)), manager = try XCTUnwrap(service.attachments(key))
            answers.setBytes("/v1/orgs/\(org)/attachments/\(file.id)/preview", png)
            answers.setBytes("/v1/orgs/\(org)/attachments/\(file.id)/original", png)
            _ = try await manager.load(message, file: file, preview: true)
            try await manager.open(message, file: file)
            XCTAssertNotNil(manager.image(message, file: file)); XCTAssertNotNil(manager.viewer)
            // A failed rights refresh must leave the gate closed; no WS event is
            // delivered. This exercises the actual feed/outbox HTTP callback.
            answers.set("/v1/orgs/\(org)/state", "{}", status: 503)
            answers.set("/v1/me", "{}", status: 503)
            answers.set("/v1/commands", #"{"error":"not_found"}"#, status: 404)
            let stateReads = ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/orgs/\(org)/state" }.count
            let prepared = try service.prepareCommand(key, type: type, args: .object(["message_id": .string(id), "channel_id": .string(channel), "attachment_ids": .array([.string(file.id)])]))
            let command = prepared.record
            try await store.queue.write { db in
                _ = try prepared.table.insert(db, command, seq: command.seq)
                if type == "request.create_in_channel_with_attachments" {
                    try db.execute(sql: "INSERT INTO channel_call_intents (request_id, message_id, agent_id, command_id) VALUES (?, ?, 'agent', ?)", arguments: [UUID().uuidString, id, command.commandId])
                }
            }
            prepared.sent()
            try await waitUntil("HTTP refusal") { try store.outbox.commands().contains { $0.commandId == command.commandId && $0.state == .failed } }
            XCTAssertEqual(try doubt(store), true, type)
            XCTAssertNil(manager.image(message, file: file), type)
            XCTAssertNil(manager.viewer, type)
            XCTAssertNil(manager.stamp(channel: channel), type)
            XCTAssertTrue(sync.needsSnapshot)
            try await waitUntil("rights recheck") { ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/orgs/\(self.org)/state" }.count > stateReads }
            service.stopFeed()
        }
    }

    /// A repeat answered `200` with no event: the message is read alone and confirms the post.
    func testAnAnswerWithoutAnEventConfirms() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        let id = "0192a3b4-5c6d-7e8f-9a0b-1c2d3e4f5b77"
        answers.set("/v1/commands", #"{"events":[],"result":{"message_id":"\#(id)","revision":1,"seq":11}}"#)
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=12", page([message(id, seq: 11, text: "mine", author: me)], next: 11))
        _ = try service.post(key, channel: channel, root: nil, text: "mine", mentions: [], messageId: id)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try await waitUntil("confirmed by the single read") { (try? self.row(store, id))?.localState == nil }
        XCTAssertEqual(try window(store).bottom, 10 + 1, "the window stays")
        XCTAssertNil(try window(store).next, "no history way on from a single read")
    }

    /// At start, a post left "sending" with no command goes again with its id (review F3b-3).
    func testAPostLeftSendingGoesAgainWithItsId() async throws {
        let store = try ChatStore.open(files: files, key: key).store
        try sending(store, "left")
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, _) = try await started(answers)
        let posted = { ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/commands" && String(decoding: $0.body, as: UTF8.self).contains("\"left\"") } }
        try await waitUntil("sent again") { !posted().isEmpty }
        XCTAssertEqual(try service.orgSessions[key]?.store?.outbox.commands().filter { $0.type == "message.post" }.count, 1)
    }

    func testInboxHydratesAnUnopenedChannelThroughTheExistingMessagesAPI() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([], head: 12, before: 12))
        let path = "/v1/orgs/\(org)/channels/\(channel)/messages"
        answers.set(path, page([message("new", seq: 12, mentions: [me]), message("reply", seq: 11, root: "old-root", mentions: [me])], next: 11))
        answers.set(path + "?before=11", page([message("read-root", seq: 8), message("unseen-reply", seq: 4, root: "unseen-thread", mentions: [me]), message("baseline", seq: 3)], next: 3))
        let (service, _) = try await started(answers, channelOpen: false)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil { !sync.needsSnapshot }
        let s = try XCTUnwrap(service.orgSessions[key]?.store)
        let channel = channel
        try await s.queue.write { db in
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 8, thread_read_seq = 3 WHERE channel_id = ?", arguments: [channel])
            try db.execute(sql: "INSERT INTO messages (message_id, channel_id, seq) VALUES ('new', ?, 12)", arguments: [channel])
        }
        let orgModel = try XCTUnwrap(ChatOrgModel.current(service))
        XCTAssertEqual(orgModel.unread(channel)?.count, 1)
        let followed = service.orgSessions[key]?.followedChannels
        let model = ChatInboxModel(ref: ChatInboxRef(key, kind: .mentions))
        defer { model.stop() }
        XCTAssertTrue(model.entries(orgModel).isEmpty)
        model.follow(s, org: orgModel) { try await sync.readInboxPage($0, before: $1) }
        try await waitUntil { !model.loading && model.entries(orgModel).count == 3 }
        XCTAssertEqual(Set(model.entries(orgModel).map(\.id)), ["new", "reply", "unseen-reply"])
        XCTAssertNil(model.problem)
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path == path }.map { $0.request.url?.query }, [nil, "before=11"])
        XCTAssertEqual(try int(s, "SELECT seq FROM cursors WHERE stream = ?", [channelStream]), 12, "HTTP heads must not skip socket events")
        XCTAssertEqual(try int(s, "SELECT last_read_seq FROM read_marks WHERE channel_id = ?", [channel]), 8)
        XCTAssertEqual(try window(s).next, 12, "the feed's pagination is independent")
        XCTAssertEqual(service.orgSessions[key]?.followedChannels, followed, "inbox reads do not change subscriptions")
    }

    func testInboxHTTPRejectsLateSessionChangesAndHandlesAccessRefusal() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m5", seq: 5)], head: 5, before: 5))
        let (service, _) = try await started(answers, channelOpen: false)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil { !sync.needsSnapshot }
        let s = try XCTUnwrap(service.orgSessions[key]?.store)
        let target = ChatInboxLoading.Key(channel: channel, epoch: try window(s).epoch, head: 5, channelRead: 0, threadRead: 0)
        let path = "/v1/orgs/\(org)/channels/\(channel)/messages"
        let gate = Gate(); gate.close()
        defer { gate.open() }
        answers.gate = gate; answers.gated = path
        answers.set(path, page([message("late", seq: 4)], next: nil))
        let pending = Task { try await sync.readInboxPage(target, before: nil) }
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path == path } }
        let session = sync.sessionId
        sync.sessionId = "replacement"
        gate.open()
        do { _ = try await pending.value; XCTFail("a late page from another session must be discarded") }
        catch is CancellationError { }
        sync.sessionId = session
        answers.set(path, #"{"error":"not_found"}"#, status: 404)
        let revocations = sync.revocations
        var membershipChecks = 0
        sync.onMembershipInDoubt = { membershipChecks += 1 }
        do { _ = try await sync.readInboxPage(target, before: nil); XCTFail("refused read must fail") }
        catch ChatInboxLoadError.unavailable { }
        XCTAssertGreaterThan(sync.revocations, revocations)
        XCTAssertEqual(membershipChecks, 1)
        XCTAssertNil(try row(s, "late"))
    }

    /// A history read asked before a new window is not applied (the epoch).
    func testAHistoryReadBeforeANewWindowIsVoid() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m5", seq: 5)], head: 5, before: 5))
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        let gate = Gate()
        gate.close()
        defer { gate.open() }
        answers.gate = gate
        answers.gated = "/v1/orgs/\(org)/channels/\(channel)/messages?before=5"
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=5", page([message("old", seq: 4, text: "stale")], next: nil))
        let read = Task { await sync.readChannel(channel, .history) }
        try await waitUntil("asked") { ChatStubProtocol.seen.contains { $0.request.url?.query == "before=5" } }
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try newWindow(store, head: 9, [wire(message("m9", seq: 9))], before: 9)
        gate.open()
        await read.value
        XCTAssertNil(try row(store, "old"))
    }

    /// A history read refused `404`: the rights in doubt (review F3-1).
    func testARefusedReadPutsRightsInDoubt() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m5", seq: 5)], head: 5, before: 5))
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages", #"{"error":"not_found"}"#, status: 404)
        let snapshots = sync.snapshots
        await sync.readChannel(channel, .history)
        try await waitUntil("a snapshot after the refusal") { sync.snapshots > snapshots }
    }

    /// Over the socket's budget a channel is not followed, it shows paused,
    /// and the organization is ready all the same (review F3-5).
    func testOverTheBudgetAChannelWaitsAndTheOrganizationIsReady() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, transport) = try await started(answers, channelOpen: false)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("ready") { sync.state == .ready }
        // No room left beside the organization's streams.
        ChatSync.socketStreams = 0
        defer { ChatSync.socketStreams = 500 }
        service.channelTab(ChannelRef(key, channel: channel), open: true)
        XCTAssertFalse(sync.followedChannels.contains(channelStream))
        XCTAssertEqual(service.orgSessions[key]?.pausedChannels, [channel])
        XCTAssertEqual(sync.state, .ready)
        // Room again: followed.
        ChatSync.socketStreams = 500
        service.channelTab(ChannelRef(key, channel: channel), open: true)
        XCTAssertTrue(sync.followedChannels.contains(channelStream))
        XCTAssertTrue(transport.subscribes.contains { $0.keys.contains(self.channelStream) })
        XCTAssertEqual(service.orgSessions[key]?.pausedChannels, [])
    }

    /// A revision conflict: the current version read, the user's text kept.
    func testARevisionConflictKeepsTheUsersText() async throws {
        let answers = Answers()
        let mine = "0192a3b4-5c6d-7e8f-9a0b-1c2d3e4f5b55"
        answers.set("/v1/orgs/\(org)/state", state([message(mine, seq: 7, text: "first", author: me)], head: 7))
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        answers.set("/v1/commands", #"{"error":"revision_conflict"}"#, status: 409)
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=8", page([message(mine, seq: 7, text: "theirs", revision: 2, author: me)], next: nil))
        try service.change(key, messageId: mine, text: "my edit", expectedRevision: 1)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try await waitUntil("conflict") { (try? self.row(store, mine))?.localEdit?.error == "revision_conflict" }
        try await waitUntil("current version") { (try? self.row(store, mine))?.text == "theirs" }
        XCTAssertEqual(try row(store, mine)?.localEdit?.text, "my edit")
        XCTAssertEqual(try row(store, mine)?.localEdit?.state, "failed")
    }

    // MARK: Review F3, round 1

    /// A deletion leaves no copy of the text: an edit asked or in conflict goes (review F3-p1-2).
    func testATombstoneTakesEveryCopy() throws {
        let store = try store([message("m1", seq: 5, text: "secret", author: me)])
        try store.queue.write { db in
            try db.execute(sql: """
                INSERT INTO local_edits (message_id, channel_id, kind, text, command_id, state, error)
                VALUES ('m1', ?, 'edit', 'secret, edited', 'c1', 'failed', 'revision_conflict')
                """, arguments: [self.channel])
        }
        try store.queue.write { db in try ChatMessages.write(db, self.wire(self.message("m1", seq: 5, revision: 3, deleted: true, author: self.me))) }
        let gone = try XCTUnwrap(row(store, "m1"))
        XCTAssertEqual(gone.text, "")
        XCTAssertNil(gone.localEdit)
    }

    /// A draft saved late — the card gone, or the rights in doubt — writes nothing (review F3-p1-3).
    func testALateDraftWritesNothing() throws {
        let store = try store()
        let model = ChatChannelModel(key: key, channel: channel)
        model.follow(store)
        try store.putRightsInDoubt()
        model.saveDraft("in doubt", root: nil)
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM drafts"), 0)
        try store.queue.write { db in
            try db.execute(sql: "UPDATE meta SET rights_in_doubt = 0")
            try db.execute(sql: "DELETE FROM channels")
        }
        model.saveDraft("card gone", root: nil)
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM drafts"), 0)
    }

    /// An edit too long is not queued: the editor keeps the text with why (review F3-p2-2).
    func testAnEditRefusedHereSaysWhy() throws {
        let model = ChatChannelModel(key: key, channel: channel)
        let message = try XCTUnwrap(try store([message("m1", seq: 5, author: me)]).queue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM messages").map(ChatMessage.init(row:))
        })
        XCTAssertNotNil(model.edit(message, to: String(repeating: "x", count: ChatChannelModel.maxBytes + 1), revision: 1, members: []))
    }

    /// Mentions only of the channel's team (review F3-p2-4).
    func testOnlyTheTeamIsMentionable() {
        let members = [ChatOrgView.Member(accountId: "a1", handle: "anna", name: "A", role: "member"),
                       ChatOrgView.Member(accountId: "b1", handle: "boris", name: "B", role: "member")]
        let able = ChatChannelModel.mentionable(members, team: ["a1"])
        XCTAssertEqual(ChatChannelModel.mentions(in: "@anna @boris", members: able), ["a1"])
    }

    /// An edit goes with the revision its editor was opened on: a newer one
    /// since is the server's conflict, not overwritten (review F3-p1-1).
    func testAnEditExpectsTheRevisionItWasOpenedOn() async throws {
        let answers = Answers()
        let mine = "0192a3b4-5c6d-7e8f-9a0b-1c2d3e4f5b66"
        answers.set("/v1/orgs/\(org)/state", state([message(mine, seq: 7, text: "now", revision: 2, author: me)], head: 7))
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let model = ChatChannelModel(key: key, channel: channel)
        model.service = service
        let shown = try XCTUnwrap(try row(store, mine))
        XCTAssertNil(model.edit(shown, to: "mine", revision: 1, members: []))
        try await waitUntil("sent") {
            ChatStubProtocol.seen.contains { $0.request.url?.path == "/v1/commands" && String(decoding: $0.body, as: UTF8.self).contains("message.edit") }
        }
        let body = String(decoding: try XCTUnwrap(ChatStubProtocol.seen.last { $0.request.url?.path == "/v1/commands" }).body, as: UTF8.self)
        XCTAssertTrue(body.contains("\"expected_revision\":1"), body)
    }

    func testResumedEditSavesOriginalRevisionAndFinishesOnlyAfterQueueing() async throws {
        let answers = Answers(), mine = "0192a3b4-5c6d-7e8f-9a0b-1c2d3e4f5b66"
        answers.set("/v1/orgs/\(org)/state", state([message("root", seq: 1),
            message(mine, seq: 7, text: "original", revision: 2, root: "root", author: me)], head: 7))
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        sync.stop()
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let model = ChatChannelModel(key: key, channel: channel); model.service = service; model.follow(store)
        model.openThread("root")
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message(mine)), root: "root"))
        model.editing?.text = " "
        XCTAssertFalse(model.saveEditing(members: []))
        XCTAssertNotNil(model.editing?.problem)
        model.openThread(nil)
        let newer = wire(message(mine, seq: 7, text: "changed elsewhere", revision: 3, root: "root", author: me))
        try await store.queue.write { _ = try ChatMessages.write($0, newer) }
        model.openThread("root")
        try await waitUntil { model.editing?.message.revision == 3 }
        XCTAssertEqual(model.editing?.text, " "); XCTAssertEqual(model.editing?.revision, 2)
        XCTAssertNotNil(model.editing?.problem)
        model.editing?.text = "resumed edit"
        XCTAssertTrue(model.saveEditing(members: []))
        XCTAssertNil(model.editing)
        model.openThread(nil); model.openThread("root"); XCTAssertNil(model.editing)
        let commands = try store.outbox.commands()
        let command = try XCTUnwrap(commands.first { $0.type == "message.edit" })
        let body = try JSONDecoder().decode(ChatCommandEnvelope.self, from: command.bodyBytes)
        XCTAssertEqual(body.args["expected_revision"]?.int, 2)
        XCTAssertEqual(body.args["text"]?.string, "resumed edit")
    }

    /// A message read alone again once a newer revision is known — not once
    /// per life (review F3-p1-4).
    func testAMessageIsReadAgainForANewerRevision() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m7", seq: 7, text: "one")], head: 7))
        let (service, transport) = try await started(answers)
        try await waitUntil("channel subscribed") { transport.subscribes.contains { $0.keys.contains(self.channelStream) } }
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let model = ChatChannelModel(key: key, channel: channel)
        model.service = service
        model.follow(store)
        let reads = { ChatStubProtocol.seen.filter { $0.request.url?.query == "before=8" }.count }
        func edit(_ seq: Int, _ revision: Int) -> String {
            #"{"frame":"event","stream":"\#(channelStream)","seq":\#(seq),"id":"e\#(seq)","type":"message.edit","actor":null,"body":{"message_id":"m7","revision":\#(revision),"message_seq":7},"command_id":null,"at":"x","sig":null,"sig_alg":null,"enc":null}"#
        }
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=8", page([message("m7", seq: 7, text: "two", revision: 2)], next: nil))
        transport.frame(edit(8, 2))
        try await waitUntil("read for revision 2") { (try? self.row(store, "m7"))?.text == "two" }
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=8", page([message("m7", seq: 7, text: "three", revision: 3)], next: nil))
        transport.frame(edit(9, 3))
        try await waitUntil("read for revision 3") { (try? self.row(store, "m7"))?.text == "three" }
        XCTAssertEqual(reads(), 2)
    }

    /// At start, a post whose command waits for the user after a new
    /// generation is not sent again; one whose session ended is "not sent" (review F3-p1-5).
    func testResendLeavesUnconfirmedAndDropped() async throws {
        let store = try ChatStore.open(files: files, key: key).store
        try sending(store, "waits")
        try sending(store, "ended")
        for (id, state) in [("waits", ChatCommandRecord.State.unconfirmed), ("ended", .dropped)] {
            let args = ChatService.postArgs(id, channel, nil, "x", [])
            let bytes = try ChatCommandEnvelope(commandId: "c-\(id)", org: org, type: "message.post", args: args).encoded()
            _ = try store.outbox.enqueue(ChatCommandRecord(commandId: "c-\(id)", sessionId: "s-anna", type: "message.post", bodyBytes: bytes,
                                                           orderKey: org, dependsOn: nil, createdAt: Date(), state: state))
        }
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, _) = try await started(answers)
        let live = try XCTUnwrap(service.orgSessions[key]?.store)
        try await waitUntil("ended: not sent") { (try? self.row(live, "ended"))?.localState == .failed }
        XCTAssertEqual(try row(live, "waits")?.localState, .sending)
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.url?.path == "/v1/commands" && String(decoding: $0.body, as: UTF8.self).contains("\"waits\"") })
    }

    // MARK: Review F3, round 2

    /// The model costs at most three times the same 1000 upserts, under the same load.
    func testADraftWriteAtEveryChangeIsCheap() throws {
        let store = try store()
        let model = ChatChannelModel(key: key, channel: channel)
        model.follow(store)
        let text = String(repeating: "word ", count: 400)
        let baselineStart = ContinuousClock.now
        for n in 0..<1000 {
            try store.queue.write { db in
                try db.execute(sql: """
                    INSERT INTO drafts (channel_id, thread_root_id, text, updated_at) VALUES (?, '', ?, ?)
                    ON CONFLICT(channel_id, thread_root_id) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at
                    """, arguments: [channel, text + "\(n)", Date().timeIntervalSince1970])
            }
        }
        let baseline = ContinuousClock.now - baselineStart
        let start = ContinuousClock.now
        for n in 0..<1000 { model.saveDraft(text + "\(n)", root: nil) }
        XCTAssertLessThanOrEqual(ContinuousClock.now - start, baseline * 3)
        XCTAssertEqual(model.draft(root: nil), text + "999")
    }

    /// A channel no longer kept takes every message of it, those being sent too (review F3b-p1-3).
    func testAChannelGoneTakesItsUnsentMessages() throws {
        let store = try store()
        try sending(store, "unsent")
        try store.queue.write { db in
            try db.execute(sql: "UPDATE messages SET local_state = 'failed' WHERE message_id = 'unsent'")
            try db.execute(sql: "DELETE FROM channels")
            try ChatMessages.dropOrphans(db)
        }
        XCTAssertNil(try row(store, "unsent"))
    }

    /// One change at a time; an answer settles only its own command's marks (review F3b-p1-1).
    func testAnAnswerSettlesOnlyItsOwnChange() async throws {
        let answers = Answers()
        let mine = "0192a3b4-5c6d-7e8f-9a0b-1c2d3e4f5b88"
        answers.set("/v1/orgs/\(org)/state", state([message(mine, seq: 7, text: "now", author: me)], head: 7))
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        let gate = Gate()
        gate.close()
        defer { gate.open() }
        answers.gate = gate
        answers.gated = "/v1/commands"
        answers.set("/v1/commands", #"{"events":[],"result":{"message_id":"\#(mine)","revision":2}}"#)
        try service.change(key, messageId: mine, text: "first", expectedRevision: 1)
        XCTAssertThrowsError(try service.change(key, messageId: mine, text: "second", expectedRevision: 1), "one at a time")
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        // Another change took its place meanwhile (as after a conflict): the first answer leaves it.
        try await store.queue.write { db in try db.execute(sql: "UPDATE local_edits SET text = 'second', command_id = 'other' WHERE message_id = ?", arguments: [mine]) }
        gate.open()
        try await waitUntil("answered") { (try? store.outbox.commands().first { $0.type == "message.edit" }?.state) == .sent }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try row(store, mine)?.localEdit?.text, "second")
    }

    /// A single read that failed is asked again after a pause; none is
    /// left marked as asked (review F3b-4).
    func testAFailedSingleReadIsAskedAgain() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m7", seq: 7, text: "one")], head: 7))
        let (service, transport) = try await started(answers)
        try await waitUntil("channel subscribed") { transport.subscribes.contains { $0.keys.contains(self.channelStream) } }
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let model = ChatChannelModel(key: key, channel: channel)
        model.service = service
        try XCTUnwrap(service.orgSessions[key]?.sync).oneRetryDelay = { _ in 0.05 }
        model.follow(store)
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=8", #"{"error":"internal"}"#, status: 500)
        transport.frame(#"{"frame":"event","stream":"\#(channelStream)","seq":8,"id":"e8","type":"message.edit","actor":null,"body":{"message_id":"m7","revision":2,"message_seq":7},"command_id":null,"at":"x","sig":null,"sig_alg":null,"enc":null}"#)
        try await waitUntil("a failed read") { ChatStubProtocol.seen.contains { $0.request.url?.query == "before=8" } }
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=8", page([message("m7", seq: 7, text: "two", revision: 2)], next: nil))
        try await waitUntil("read again") { (try? self.row(store, "m7"))?.text == "two" }
    }

    func testSingleReadRetryCannotBeWokenIntoABusyLoop() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m7", seq: 7, text: "one")], head: 7))
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        sync.oneRetryDelay = { _ in 1 }
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=8", #"{"error":"internal"}"#, status: 500)
        sync.readOne(channel, id: "m7", seq: 7, atLeast: 2)
        try await waitUntil("first read") { ChatStubProtocol.seen.contains { $0.request.url?.query == "before=8" } }
        for _ in 0..<100 { sync.readOne(channel, id: "m7", seq: 7, atLeast: 2) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.query == "before=8" }.count, 1)
        sync.stop()
    }

    /// A channel that came on a later channels page is followed once the pages are in (review F3b-p1-5).
    func testAChannelOfALaterPageIsFollowed() async throws {
        let answers = Answers()
        let later = "4d5e6f7a-8b9c-4d0e-9f1a-2b3c4d5e6f7a"
        let laterCard = #"{"channel_id":"\#(later)","team_id":"\#(team)","name":"later","created_by":"\#(me)","created_at":"x","archived":false,"archived_at":null,"version":1,"head":3,"messages":[],"messages_before":null}"#
        answers.set("/v1/orgs/\(org)/state", state().replacingOccurrences(of: #""channels_next":null"#, with: #""channels_next":"p1""#))
        answers.set("/v1/orgs/\(org)/channels?after=p1", #"{"channels":[\#(laterCard)],"next":null}"#)
        // Open before the read: nothing after it would make it followed but the read itself.
        let service = try await started(answers, channelOpen: false, alsoOpen: [later]).0
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("followed") { sync.followedChannels.contains("channel:\(later)") }
    }

    // MARK: Review F3, round 3: local edits apart, one way of single reads

    /// A new window leaves the user's unsettled edit alone (review F3c-1).
    func testANewWindowLeavesALocalEdit() throws {
        let store = try store([message("m1", seq: 3, author: me)], head: 3)
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO local_edits (message_id, channel_id, kind, text, command_id, state, error) VALUES ('m1', ?, 'edit', 'mine', 'c1', 'failed', 'forbidden')",
                           arguments: [self.channel])
        }
        try newWindow(store, head: 30, [wire(message("m30", seq: 30))], before: 30)
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM local_edits"), 1)
    }

    /// An edit whose command the queue dropped (a session ended) is not
    /// "saving": shown failed with its text, and a new edit may go (review F3c-1).
    func testAnEditOfADroppedCommandIsFailedAndFree() throws {
        let store = try store([message("m1", seq: 3, author: me)], head: 3)
        let bytes = try ChatCommandEnvelope(commandId: "c1", org: org, type: "message.edit", args: .object([:])).encoded()
        _ = try store.outbox.enqueue(ChatCommandRecord(commandId: "c1", sessionId: "s", type: "message.edit", bodyBytes: bytes,
                                                       orderKey: org, dependsOn: nil, createdAt: Date(), state: .dropped))
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO local_edits (message_id, channel_id, kind, text, command_id, state) VALUES ('m1', ?, 'edit', 'mine', 'c1', 'saving')",
                           arguments: [self.channel])
        }
        let shown = try XCTUnwrap(try row(store, "m1"))
        XCTAssertEqual(shown.localEdit?.state, "failed")
        XCTAssertEqual(shown.localEdit?.text, "mine")
        XCTAssertFalse(shown.changing)
    }

    /// Any refusal of an edit keeps its text for "Edit again" (review F3c-1).
    func testAnyRefusedEditKeepsItsText() async throws {
        let answers = Answers()
        let mine = "0192a3b4-5c6d-7e8f-9a0b-1c2d3e4f5b99"
        answers.set("/v1/orgs/\(org)/state", state([message(mine, seq: 7, text: "now", author: me)], head: 7))
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        answers.set("/v1/commands", #"{"error":"too_large"}"#, status: 413)
        try service.change(key, messageId: mine, text: "too much", expectedRevision: 1)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try await waitUntil("failed") { (try? self.row(store, mine))?.localEdit?.error == "too_large" }
        XCTAssertEqual(try row(store, mine)?.localEdit?.text, "too much")
    }

    /// The read that confirms a post retries too — the one way of single reads (review F3c-2).
    func testThePostsConfirmingReadRetries() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        sync.oneRetryDelay = { _ in 0.05 }
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        let id = "0192a3b4-5c6d-7e8f-9a0b-1c2d3e4f5baa"
        answers.set("/v1/commands", #"{"events":[],"result":{"message_id":"\#(id)","revision":1,"seq":11}}"#)
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=12", #"{"error":"internal"}"#, status: 500)
        _ = try service.post(key, channel: channel, root: nil, text: "mine", mentions: [], messageId: id)
        try await waitUntil("a failed read") { ChatStubProtocol.seen.contains { $0.request.url?.query == "before=12" } }
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=12", page([message(id, seq: 11, text: "mine", author: me)], next: 11))
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try await waitUntil("confirmed after a retry") { (try? self.row(store, id))?.localState == nil }
    }

    /// A frame without its message tells a post of this Mac its place: the
    /// model then reads it, and the post is confirmed (review F3c-2).
    func testAFrameTellsASendingPostItsPlace() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, transport) = try await started(answers)
        try await waitUntil("channel subscribed") { transport.subscribes.contains { $0.keys.contains(self.channelStream) } }
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let id = "0192a3b4-5c6d-7e8f-9a0b-1c2d3e4f5bbb"
        try sending(store, id)
        let model = ChatChannelModel(key: key, channel: channel)
        model.service = service
        model.follow(store)
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=12", page([message(id, seq: 11, text: "x", author: me)], next: 11))
        transport.frame(frame(11, "message.post", id, message: nil))
        try await waitUntil("confirmed") { (try? self.row(store, id))?.localState == nil }
    }

    // MARK: Review F3, the last look

    /// A row pushed out by a window, then its tombstone: the user's edit goes all the same (review F3d-1).
    func testATombstoneOfAPushedOutMessageTakesItsEdit() throws {
        let store = try store([message("m1", seq: 3, author: me)], head: 3)
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO local_edits (message_id, channel_id, kind, text, command_id, state, error) VALUES ('m1', ?, 'edit', 'secret', 'c1', 'failed', 'forbidden')",
                           arguments: [self.channel])
        }
        try newWindow(store, head: 30, [wire(message("m30", seq: 30))], before: 30)
        XCTAssertNil(try row(store, "m1"), "pushed out")
        try store.queue.write { db in try ChatMessages.applyOne(db, id: "m1", page: ChatMessagesPage(messages: [self.wire(self.message("m1", seq: 3, revision: 2, deleted: true, author: self.me))], next: nil, head: nil)) }
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM local_edits"), 0)
        // A tombstone again (row there now): still nothing.
        try store.queue.write { db in try ChatMessages.write(db, self.wire(self.message("m1", seq: 3, revision: 2, deleted: true, author: self.me))) }
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM local_edits"), 0)
    }

    func testANewGenerationTakesUnsettledEdits() throws {
        let store = try store([message("m1", seq: 3, author: me)], head: 3)
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO local_edits (message_id, channel_id, kind, text, command_id, state) VALUES ('m1', ?, 'edit', 'x', 'c1', 'saving')",
                           arguments: [self.channel])
        }
        try store.beginGeneration("g2", keeping: [])
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM local_edits"), 0)
    }

    /// A newer revision asked while a read is on its way is not lost: the
    /// read goes again until the cache has it (review F3d-2).
    func testANewerRevisionAskedMeanwhileIsRead() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m7", seq: 7, text: "one")], head: 7))
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        sync.oneRetryDelay = { _ in 0.05 }
        try await waitUntil("snapshot") { !sync.needsSnapshot }
        let gate = Gate()
        gate.close()
        defer { gate.open() }
        answers.gate = gate
        answers.gated = "/v1/orgs/\(org)/channels/\(channel)/messages?before=8"
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=8", page([message("m7", seq: 7, text: "two", revision: 2)], next: nil))
        sync.readOne(channel, id: "m7", seq: 7, atLeast: 2)
        try await waitUntil("asked") { ChatStubProtocol.seen.contains { $0.request.url?.query == "before=8" } }
        // Revision 3 is known now; the read on its way brings 2.
        sync.readOne(channel, id: "m7", seq: 7, atLeast: 3)
        answers.gated = nil
        gate.open()
        try await Task.sleep(for: .milliseconds(30))
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=8", page([message("m7", seq: 7, text: "three", revision: 3)], next: nil))
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try await waitUntil("revision 3") { (try? self.row(store, "m7"))?.text == "three" }
    }

    /// A deletion's frame without its message takes the user's edit at once (review F3e).
    func testADeletionFrameWithoutTheMessageTakesTheEdit() throws {
        let store = try store([message("m1", seq: 3, author: me)], head: 3)
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO local_edits (message_id, channel_id, kind, text, command_id, state, error) VALUES ('m1', ?, 'edit', 'secret', 'c1', 'failed', 'forbidden')",
                           arguments: [self.channel])
        }
        _ = try store.apply(event(4, "message.delete", body: #"{"message_id":"m1","revision":2,"message_seq":3}"#, message: nil))
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM local_edits"), 0)
    }

    // MARK: F4: unread and notices

    private var notices: [(id: String, title: String)] = []
    private var takenBack: [([String], String?)] = []
    private var shown: Set<String> = []

    /// Notices go to `notices`; the channel is seen and the app in front unless a test says otherwise.
    private func noticesHere(visible: Bool = true, active: Bool = false) {
        notices = []
        takenBack = []
        shown = []
        // The system's notices, as a set: posted ones show until taken back.
        ChatNotifications.post = { [unowned self] id, title in self.notices.append((id, title)); self.shown.insert(id) }
        ChatNotifications.remove = { [unowned self] ids, prefix in self.takenBack.append((ids, prefix)); self.shown.subtract(ids) }
        ChatNotifications.listIds = { [unowned self] in Array(self.shown) }
        ChatNotifications.badgeChanged = {}
        ChatNotifications.visible = { _, _, _ in visible }
        ChatNotifications.appActive = { active }
        ChatNotifications.places = [:]
    }

    private func post(_ seq: Int, _ id: String, author: String? = nil, root: String? = nil, mentions: [String] = [], text: String = "hi") -> String {
        let m = #"{"message_id":"\#(id)","channel_id":"\#(channel)","thread_root_id":\#(root.map { "\"\($0)\"" } ?? "null"),"author_account_id":"\#(author ?? other)","text":"\#(text)","mentions":[\#(mentions.map { "{\"account_id\":\"\($0)\"}" }.joined(separator: ","))],"revision":1,"seq":\#(seq),"created_at":"2026-10-05T09:00:00Z","edited_at":null,"deleted_at":null}"#
        return frame(seq, "message.post", id, message: m)
    }

    private func unread(_ store: ChatStore) throws -> ChatUnread.Count {
        let channel = channel, me = me
        return try store.queue.read { db in try ChatUnread.count(db, channel: channel, me: me) }
    }

    /// A live mention: one notice, with nothing of what it is about; its
    /// repeat and a snapshot give none; a new channel starts read (F4).
    func testALiveMentionIsToldOnceAndNamesNothing() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, transport) = try await started(answers)
        try await waitUntil("channel subscribed") { transport.subscribes.contains { $0.keys.contains(self.channelStream) } }
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        XCTAssertEqual(try unread(store).count, 0, "first seen: read up to its head")
        transport.frame(post(11, "m11", mentions: [me], text: "secret plan"))
        transport.frame(post(11, "m11", mentions: [me], text: "secret plan"))
        try await waitUntil("noticed") { !self.notices.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(notices.map(\.title), ["New mention in AgentPad"])
        XCTAssertFalse(notices[0].title.contains("secret") || notices[0].title.contains("billing") || notices[0].title.contains("Rabbitshat"))
        XCTAssertEqual(try unread(store).count, 1)
        // A snapshot brings it again: no notice.
        answers.set("/v1/orgs/\(org)/state", state([message("m11", seq: 11)], head: 11))
        try XCTUnwrap(service.orgSessions[key]?.sync).requestSnapshot()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(notices.count, 1)
    }

    /// A catch-up (the stream syncing) counts but tells nothing; once live, it tells (NT-2).
    func testACatchUpCountsButTellsNothing() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, transport) = try await started(answers, hold: [channelStream])
        try await waitUntil("channel asked") { transport.subscribes.contains { $0.keys.contains(self.channelStream) } }
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        for n in 11..<511 { transport.frame(post(n, "c\(n)", mentions: [me])) }
        try await waitUntil("caught up") { (try? self.unread(store).count) == 500 }
        XCTAssertTrue(notices.isEmpty)
        transport.frame(#"{"frame":"subscribed","stream":"\#(channelStream)","head":510}"#)
        transport.frame(post(511, "live", mentions: [me]))
        try await waitUntil("live told") { self.notices.count == 1 }
    }

    /// Edits, deletions and my own posts change no count; a reply in my
    /// thread tells once, a mention in it too but as one; muted: replies
    /// quiet, mentions not (F4, review F4-4).
    func testWhatCountsAndWhatTells() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("mine", seq: 10, author: me)], head: 10))
        let (service, transport) = try await started(answers)
        try await waitUntil("channel subscribed") { transport.subscribes.contains { $0.keys.contains(self.channelStream) } }
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        transport.frame(post(11, "own", author: me))
        transport.frame(post(12, "r1", root: "mine"))
        transport.frame(post(13, "r2", root: "mine", mentions: [me]))
        try await waitUntil("two notices") { self.notices.count == 2 }
        XCTAssertEqual(notices.map(\.title), ["New reply in a thread", "New mention in AgentPad"])
        XCTAssertEqual(try unread(store).count, 0, "replies and my own are not root unread")
        transport.frame(post(14, "root2", mentions: [me]))
        try await waitUntil("counted") { (try? self.unread(store).count) == 1 && self.notices.count == 3 }
        transport.frame(#"{"frame":"event","stream":"\#(channelStream)","seq":15,"id":"e15","type":"message.delete","actor":null,"body":{"message_id":"root2","revision":2,"message_seq":14},"command_id":null,"at":"x","sig":null,"sig_alg":null,"enc":null,"message":\#(message("root2", seq: 14, revision: 2, deleted: true))}"#)
        // The deleted mention's notice is taken back, and it leaves the Dock's count (review F4-C).
        let gone = ChatNotifications.messageId(key, channel: channel, message: "root2")
        try await waitUntil("taken back") { !self.shown.contains(gone) }
        XCTAssertEqual(try unread(store).count, 1, "a deletion changes no count")
        XCTAssertEqual(try int(store, "SELECT read FROM notified WHERE object_id = 'root2'"), 1)
        let channel = channel
        try await store.queue.write { db in try ChatUnread.setMuted(db, channel: channel, true) }
        transport.frame(post(16, "r3", root: "mine"))
        transport.frame(post(17, "r4", root: "mine", mentions: [me]))
        try await waitUntil("muted: the mention only") { self.notices.count == 4 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(notices.last?.title, "New mention in AgentPad")
    }

    /// The thread is mine though my message was pushed out by a window (review F4-2).
    func testMyThreadOutlivesTheWindow() throws {
        let store = try store([message("mine", seq: 3, author: me)], head: 3)
        try newWindow(store, head: 40, [wire(message("x", seq: 40))], before: 40)
        XCTAssertNil(try row(store, "mine"))
        try store.queue.write { db in try ChatMessages.write(db, self.wire(self.message("r", seq: 41, root: "mine"))) }
        let kind = try store.queue.write { db in try ChatUnread.owe(db, messageId: "r", me: self.me) }
        XCTAssertEqual(kind, "reply")
    }

    /// Not seen (rights in doubt, …): no notice. An open thread's panel quiets
    /// its replies; a channel tab without it does not (review F4b-2).
    func testWhatIsSeenAndWhatIsLookedAt() async throws {
        noticesHere(visible: false, active: true)
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("mine", seq: 10, author: me)], head: 10))
        let (service, transport) = try await started(answers)
        try await waitUntil("channel subscribed") { transport.subscribes.contains { $0.keys.contains(self.channelStream) } }
        transport.frame(post(11, "a", mentions: [me]))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(notices.isEmpty, "not seen: nothing")
        ChatNotifications.visible = { _, _, _ in true }
        ChatNotifications.places = ["c:\(channel)": [UUID(): { true }]]
        transport.frame(post(12, "b", root: "mine"))
        try await waitUntil("a reply while only the feed shows") { self.notices.count == 1 }
        ChatNotifications.places = ["t:mine": [UUID(): { true }]]
        transport.frame(post(13, "c", root: "mine"))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(notices.count, 1, "the thread's panel is open: quiet")
        _ = service
    }

    /// A live post without its text: told once read; not read — nothing (review F4b-3).
    func testALivePostWithoutItsTextIsToldOnceRead() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, transport) = try await started(answers)
        try XCTUnwrap(service.orgSessions[key]?.sync).oneRetryDelay = { _ in 0.02 }
        try await waitUntil("channel subscribed") { transport.subscribes.contains { $0.keys.contains(self.channelStream) } }
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=12", page([#"{"message_id":"bare","channel_id":"\#(channel)","thread_root_id":null,"author_account_id":"\#(other)","text":"x","mentions":[{"account_id":"\#(me)"}],"revision":1,"seq":11,"created_at":"x","edited_at":null,"deleted_at":null}"#], next: nil))
        transport.frame(frame(11, "message.post", "bare", message: nil))
        try await waitUntil("told after the read") { self.notices.count == 1 }
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=13", #"{"error":"not_found"}"#, status: 404)
        transport.frame(frame(12, "message.post", "lost", message: nil))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(notices.count, 1, "not read: not told")
    }

    /// A new generation: everything read again, notices of messages gone (review F4-5).
    func testANewGenerationReadsAll() throws {
        let store = try store([message("m1", seq: 3)], head: 3)
        try store.queue.write { db in
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 0")
            try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, seq) VALUES ('m1', 'mention', ?, 3)", arguments: [self.channel])
        }
        XCTAssertEqual(try unread(store).count, 1)
        try store.beginGeneration("g2", keeping: [])
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM notified"), 0)
        try store.apply(ChatSnapshot(cursors: ["team:\(team)": 0], orgName: "R", members: [], teams: [.init(teamId: team, name: "T", mine: true)],
                                     teamMembers: [], invitations: nil,
                                     channels: [try JSONDecoder().decode(ChatChannelCard.self, from: Data(card(90, [message("n1", seq: 90)], before: 90).utf8))],
                                     channelsComplete: true))
        XCTAssertEqual(try unread(store).count, 0)
    }

    /// One notice per message, whatever brings it again (review F4-4).
    func testANoticeIsOwedOncePerMessage() throws {
        let store = try store([message("mine", seq: 3, author: me)], head: 3)
        let body = #"{"message_id":"r","channel_id":"\#(channel)","thread_root_id":"mine","author_account_id":"\#(other)","text":"x","mentions":[{"account_id":"\#(me)"}],"revision":1,"seq":4,"created_at":"x","edited_at":null,"deleted_at":null}"#
        try store.queue.write { db in try ChatMessages.write(db, self.wire(body)) }
        let first = try store.queue.write { db in try ChatUnread.owe(db, messageId: "r", me: self.me) }
        let again = try store.queue.write { db in try ChatUnread.owe(db, messageId: "r", me: self.me) }
        XCTAssertEqual(first, "mention", "a mention in my thread: one notice, of the mention")
        XCTAssertNil(again)
    }

    // MARK: Review F4, round 1

    /// The gate lives with the connection, not the windows: no UI model here
    /// at all (review F4-A).
    func testTheServicesGate() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot && service.orgSessions[self.key]?.snapshotOwed == false }
        XCTAssertTrue(ChatNotifications.allowed(service, key, channel: channel))
        XCTAssertFalse(ChatNotifications.allowed(service, key, channel: "elsewhere"))
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try store.putRightsInDoubt()
        XCTAssertFalse(ChatNotifications.allowed(service, key, channel: channel), "rights in doubt")
    }

    /// Reconcile takes back what no longer applies, whatever the way it
    /// stopped applying; it keeps the rest (review F4-A).
    func testReconcileTakesBackWhatNoLongerApplies() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("ok", seq: 5), message("read", seq: 6), message("del", seq: 7, deleted: true)], head: 7))
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot && service.orgSessions[self.key]?.snapshotOwed == false }
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let channel = channel
        try await store.queue.write { db in
            for (id, read) in [("ok", 0), ("read", 1), ("del", 0)] {
                try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, seq, read) VALUES (?, 'mention', ?, 1, ?)", arguments: [id, channel, read])
            }
        }
        ChatNotifications.visible = { service, key, channel in ChatNotifications.allowed(service, key, channel: channel) }
        let id = { (message: String) in ChatNotifications.messageId(self.key, channel: channel, message: message) }
        shown = [id("ok"), id("read"), id("del"), "chat:other-org:\(channel):x", ChatNotifications.messageId(key, channel: "gone", message: "y")]
        ChatNotifications.reconcile(service)
        try await waitUntil("reconciled") { self.shown == [id("ok")] }
        // Rights in doubt: everything of messages goes.
        try store.putRightsInDoubt()
        ChatNotifications.reconcile(service)
        try await waitUntil("all gone") { self.shown.isEmpty }
    }

    /// Looking = the app in front and that place shown in a key window (review F4-B).
    func testLookingIsTheKeyWindowsPlace() {
        noticesHere(active: true)
        var key = false
        ChatNotifications.show("c:x", view: UUID()) { key }
        XCTAssertFalse(ChatNotifications.isLooking("c:x"), "another window is key")
        key = true
        XCTAssertTrue(ChatNotifications.isLooking("c:x"))
        ChatNotifications.appActive = { false }
        XCTAssertFalse(ChatNotifications.isLooking("c:x"), "the app in the background")
        XCTAssertFalse(ChatNotifications.isLooking("t:y"), "not shown at all")
    }

    /// A cache from before F4 learns the threads its user wrote in (review F4-C).
    func testAnOlderCacheLearnsMyThreads() throws {
        let store = try store([message("old", seq: 3, author: me)], head: 3)
        try store.queue.write { db in
            try db.execute(sql: "DELETE FROM my_threads")
            try db.execute(sql: "UPDATE meta SET me = NULL")
        }
        let reopened = try ChatStore.open(files: files, key: key).store
        XCTAssertEqual(try int(reopened, "SELECT COUNT(*) FROM my_threads WHERE root_id = 'old'"), 1)
    }

    /// "•" only for a channel not followed (review F4-C).
    func testTheDotIsForChannelsNotFollowed() {
        let model = ChatOrgModel(me: me) { _, _ in "c" }
        model.key = key
        var view = ChatOrgView(orgName: "R", members: [], teams: [.init(teamId: team, name: "T", isGeneral: false, archived: false, mine: true, members: [me])],
                               channels: [ChatChannelCard(channelId: channel, teamId: team, name: "c", archived: false, version: 1)],
                               channelsServed: true)
        view.unread = [channel: ChatUnread.Count(count: 0, more: false, something: true, muted: false)]
        model.set(view)
        model.isFollowed = { _ in false }
        XCTAssertEqual(model.unread(channel)?.something, true)
        model.isFollowed = { _ in true }
        XCTAssertEqual(model.unread(channel)?.something, false)
    }

    // MARK: Review F4, round 2

    /// A view hidden (its tab not selected) is not looked at; two views of a
    /// place each take back only their own entry (review F4b-1, F4b-5).
    func testLookingIsPerViewAndHiddenIsNot() {
        noticesHere(active: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(view)
        let box = WindowBox()
        box.view = view
        view.isHidden = true
        XCTAssertFalse(box.shown, "hidden: not shown, whatever its window")
        let a = UUID(), b = UUID()
        ChatNotifications.show("t:r", view: a) { true }
        ChatNotifications.show("t:r", view: b) { false }
        ChatNotifications.hide("t:r", view: b)
        XCTAssertTrue(ChatNotifications.isLooking("t:r"), "the other view's entry stays")
    }

    /// A placeholder counts as unread until read; a window above the mark
    /// keeps at least "•"; a message read already owes no notice (review F4b-2, -3, -4).
    func testPlaceholdersGapsAndReadMessages() throws {
        let store = try store([message("m3", seq: 3)], head: 3)
        _ = try store.apply(event(4, "message.post", body: #"{"message_id":"ph","revision":1,"message_seq":4}"#, message: nil))
        XCTAssertEqual(try unread(store).count, 1, "a placeholder counts")
        try newWindow(store, head: 40, [wire(message("own", seq: 40, author: me))], before: 40)
        let gap = try unread(store)
        XCTAssertEqual(gap.count, 0)
        XCTAssertFalse(gap.more, "my post reads through the gap before it")
        try newWindow(store, head: 80, [wire(message("foreign", seq: 80))], before: 80)
        XCTAssertTrue(try unread(store).more, "a foreign post does not read the gap below the window")
        try store.queue.write { db in
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 50")
            try ChatMessages.write(db, self.wire(#"{"message_id":"late","channel_id":"\#(self.channel)","thread_root_id":null,"author_account_id":"\#(self.other)","text":"x","mentions":[{"account_id":"\#(self.me)"}],"revision":1,"seq":45,"created_at":"x","edited_at":null,"deleted_at":null}"#))
        }
        let owed = try store.queue.write { db in try ChatUnread.owe(db, messageId: "late", me: self.me) }
        XCTAssertNil(owed, "read already: no notice")
        XCTAssertEqual(try int(store, "SELECT read FROM notified WHERE object_id = 'late'"), 1)
    }

    /// A catch-up's post without its text is read too, so the count learns its author (review F4b-2).
    func testACatchUpPlaceholderIsRead() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, transport) = try await started(answers, hold: [channelStream])
        try await waitUntil("channel asked") { transport.subscribes.contains { $0.keys.contains(self.channelStream) } }
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=12", page([message("mine11", seq: 11, author: me)], next: nil))
        transport.frame(frame(11, "message.post", "mine11", message: nil))
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try await waitUntil("read: mine, not unread") { (try? self.row(store, "mine11"))?.hasFixed == true }
        XCTAssertEqual(try unread(store).count, 0)
        XCTAssertTrue(notices.isEmpty)
    }

    /// Any write that changes what notices stand for reconciles them — one
    /// point, whatever wrote it (review F4b-5).
    func testAnyWriteReconciles() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("ok", seq: 5)], head: 5))
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        try await waitUntil("snapshot") { !sync.needsSnapshot && service.orgSessions[self.key]?.snapshotOwed == false }
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let channel = channel
        try await store.queue.write { db in
            try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, seq) VALUES ('ok', 'mention', ?, 5)", arguments: [channel])
        }
        ChatNotifications.visible = { service, key, channel in ChatNotifications.allowed(service, key, channel: channel) }
        shown = [ChatNotifications.messageId(key, channel: channel, message: "ok")]
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(shown.isEmpty, "still due")
        // A write elsewhere — no call of reconcile by hand.
        try await store.queue.write { db in try db.execute(sql: "DELETE FROM channels") }
        try await waitUntil("reconciled by the write") { self.shown.isEmpty }
    }

    // MARK: Review F4, round 3

    /// Read up to the last wholly known message, never past a placeholder (review F4c-1).
    func testReadingStopsBeforeAPlaceholder() throws {
        let store = try store([message("m3", seq: 3)], head: 3)
        try store.queue.write { db in try db.execute(sql: "UPDATE read_marks SET last_read_seq = 0") }
        _ = try store.apply(event(4, "message.post", body: #"{"message_id":"ph","revision":1,"message_seq":4}"#, message: nil))
        try store.queue.write { db in try ChatMessages.write(db, self.wire(self.message("m5", seq: 5))) }
        let model = ChatChannelModel(key: key, channel: channel)
        model.follow(store)
        model.markRead(clearingBoundary: false)
        XCTAssertEqual(try int(store, "SELECT last_read_seq FROM read_marks WHERE channel_id = ?", [channel]), 3)
    }

    /// Mentions for the Dock come from the messages — one a snapshot brought
    /// counts — not from banners shown; one read in its thread does not (review F4c-2).
    func testMentionsCountFromMessages() throws {
        let mention = #"{"message_id":"mm","channel_id":"\#(channel)","thread_root_id":null,"author_account_id":"\#(other)","text":"x","mentions":[{"account_id":"\#(me)"}],"revision":1,"seq":9,"created_at":"x","edited_at":null,"deleted_at":null}"#
        let store = try store([], head: 3)
        try store.queue.write { db in
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 3")
            try ChatMessages.write(db, self.wire(mention))
        }
        XCTAssertEqual(try store.queue.read { db in try ChatUnread.unreadMentions(db) }, 1, "no banner was shown; it counts")
        try store.queue.write { db in try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, seq, read) VALUES ('mm', 'mention', ?, 9, 1)", arguments: [self.channel]) }
        XCTAssertEqual(try store.queue.read { db in try ChatUnread.unreadMentions(db) }, 0, "read in its thread")
    }

    /// A deletion without its message marks the row deleted: no text, no notice (review F4c-3).
    func testADeletionFrameMarksTheRowDeleted() throws {
        let store = try store()
        let mention = #"{"message_id":"d1","channel_id":"\#(channel)","thread_root_id":null,"author_account_id":"\#(other)","text":"secret","mentions":[{"account_id":"\#(me)"}],"revision":1,"seq":11,"created_at":"x","edited_at":null,"deleted_at":null}"#
        try store.queue.write { db in try ChatMessages.write(db, self.wire(mention)) }
        _ = try store.apply(event(11, "message.delete", body: #"{"message_id":"d1","revision":2,"message_seq":11}"#, message: nil))
        let row = try XCTUnwrap(row(store, "d1"))
        XCTAssertTrue(row.deleted)
        XCTAssertEqual(row.text, "")
        XCTAssertNil(try store.queue.write { db in try ChatUnread.owe(db, messageId: "d1", me: self.me) })
    }

    /// A decision's notice names its account: another account takes it back (review F4c-4).
    func testADecisionNoticeIsTheAccounts() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, _) = try await started(answers)
        let other = ChatOrgKey(server: server, accountId: self.other, orgId: org)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try await store.queue.write { [me] db in
            var body = CallJSON.request("r1", state: "awaiting_decision", version: 1, onThisDevice: true, owner: me)
            body["deliver_by"] = ChatCallStore.timestamp(Date().addingTimeInterval(3600))
            try ChatCallStore.apply(db, CallJSON.wire(body), onThisDevice: true)
        }
        XCTAssertTrue(ChatNotifications.stillDue(ChatNotifications.requestId(key, "r1"), service))
        XCTAssertFalse(ChatNotifications.stillDue(ChatNotifications.requestId(other, "r1"), service))
    }
}

// Release 1.1.2: hover and keyboard editing share one model-owned editor.
extension ChatMessagesTests {
    func testEditLastSelectsOwnMessageInTheCurrentConversation() throws {
        let agent = message("agent", seq: 40, author: me).replacingOccurrences(of: "\"mentions\":[]", with: "\"author_agent_id\":\"bot\",\"mentions\":[]")
        let signature = message("signature", seq: 45, author: me).replacingOccurrences(of: "\"mentions\":[]", with: "\"author_session_name\":\"Claude tab\",\"mentions\":[]")
        let store = try store([
            message("root", seq: 1, author: me), message("mine", seq: 10, author: me),
            message("other", seq: 20), message("reply", seq: 30, root: "root", author: me),
            agent, signature, message("deleted", seq: 50, deleted: true, author: me),
            message("other-thread", seq: 60, root: "mine", author: me)
        ], head: 60)
        let model = ChatChannelModel(key: key, channel: channel)
        model.follow(store)
        XCTAssertEqual(model.lastEditableMessage(root: nil)?.messageId, "mine")
        XCTAssertNil(model.lastEditableMessage(root: "root"), "a closed thread is not the current conversation")
        model.openThread("root")
        XCTAssertEqual(model.lastEditableMessage(root: "root")?.messageId, "reply")
        XCTAssertFalse(model.editLastMessage(root: nil, composerText: " "))
        XCTAssertFalse(model.editLastMessage(root: nil, composerText: "draft"))
        XCTAssertTrue(model.editLastMessage(root: "root", composerText: ""))
        XCTAssertEqual(model.editing?.messageId, "reply")
        XCTAssertFalse(model.editLastMessage(root: nil, composerText: ""), "one editor across feed and thread")
        XCTAssertFalse(model.beginEditing(try XCTUnwrap(model.message("root")), root: nil))
        model.openThread(nil)
        XCTAssertNil(model.editing, "closing the thread releases its editor")
        XCTAssertTrue(model.editLastMessage(root: nil, composerText: ""))
        XCTAssertEqual(model.editing?.messageId, "mine")
    }

    func testEditLastSkipsIncompleteLocalAndChangingMessages() throws {
        let store = try store((1...8).map { message("m\($0)", seq: $0, author: me) }, head: 8)
        let bytes = try ChatCommandEnvelope(commandId: "cmd", org: org, type: "message.edit", args: .object([:])).encoded()
        _ = try store.outbox.enqueue(ChatCommandRecord(commandId: "cmd", sessionId: "s", type: "message.edit", bodyBytes: bytes,
                                                       orderKey: org, dependsOn: nil, createdAt: Date(), state: .pending))
        try store.queue.write { db in
            try db.execute(sql: "UPDATE messages SET has_fixed = 0 WHERE message_id = 'm3'")
            try db.execute(sql: "UPDATE messages SET has_mutable = 0 WHERE message_id = 'm4'")
            try db.execute(sql: "UPDATE messages SET stale = 2 WHERE message_id = 'm5'")
            try db.execute(sql: "UPDATE messages SET local_state = 'sending' WHERE message_id = 'm6'")
            try db.execute(sql: "UPDATE messages SET local_state = 'failed' WHERE message_id = 'm7'")
            try db.execute(sql: "INSERT INTO local_edits (message_id, channel_id, kind, text, command_id, state) VALUES ('m8', ?, 'edit', 'pending', 'cmd', 'saving')", arguments: [self.channel])
        }
        let model = ChatChannelModel(key: key, channel: channel)
        model.follow(store)
        XCTAssertEqual(model.lastEditableMessage(root: nil)?.messageId, "m2")
        var candidate = try XCTUnwrap(model.message("m2"))
        candidate.channelId = "elsewhere"
        XCTAssertFalse(model.canEdit(candidate))
    }

    func testEditLastDoesNothingWithoutOwnMessagesOrInArchive() async throws {
        let store = try store([message("other", seq: 1)])
        let model = ChatChannelModel(key: key, channel: channel)
        model.follow(store)
        XCTAssertFalse(model.editLastMessage(root: nil, composerText: ""))
        let incoming = wire(message("mine", seq: 2, author: me)), channel = channel
        try await store.queue.write { db in
            try ChatMessages.write(db, incoming)
            try db.execute(sql: "UPDATE channels SET archived = 1 WHERE channel_id = ?", arguments: [channel])
        }
        try await waitUntil { model.feed.archived }
        XCTAssertFalse(model.editLastMessage(root: nil, composerText: ""))
        XCTAssertFalse(model.beginEditing(try XCTUnwrap(model.message("mine")), root: nil))
    }

    func testEditorKeepsOpeningRevisionAndClearsOnDeletion() async throws {
        let store = try store([message("mine", seq: 1, author: me)])
        let model = ChatChannelModel(key: key, channel: channel)
        model.follow(store)
        let old = try XCTUnwrap(model.message("mine"))
        let second = wire(message("mine", seq: 1, text: "second", revision: 2, author: me))
        try await store.queue.write { db in try ChatMessages.write(db, second) }
        XCTAssertTrue(model.beginEditing(old, root: nil))
        XCTAssertEqual(model.editing?.revision, 2, "snapshot at opening, not when the row was rendered")
        model.editing?.text = "my draft"
        let third = wire(message("mine", seq: 1, text: "third", revision: 3, author: me))
        try await store.queue.write { db in try ChatMessages.write(db, third) }
        try await waitUntil { model.feed.messages.first?.revision == 3 }
        XCTAssertEqual(model.editing?.revision, 2)
        XCTAssertEqual(model.editing?.text, "my draft")
        let deleted = wire(message("mine", seq: 1, revision: 4, deleted: true, author: me))
        try await store.queue.write { db in try ChatMessages.write(db, deleted) }
        try await waitUntil { model.editing == nil }
    }
}

// UX2 A4 / B1 compatibility: real synchronizer, cache window and tab draft.
extension ChatMessagesTests {
    func testUnknownChannelEventsReadOnlyTheirChannel() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("old", seq: 1, author: me)], before: 1))
        let (service, transport) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let snapshots = sync.snapshots, originalWindow = try window(store)
        let mark = try int(store, "SELECT last_read_seq FROM read_marks")
        for (index, type) in ["reaction.add", "pin.remove", "thread.participation", "future.channel.feature"].enumerated() {
            let revision = index + 2
            answers.set("/v1/orgs/\(org)/channels/\(channel)/messages", page([message("old", seq: 1, text: "refreshed", revision: revision, author: me)], next: nil))
            let input = frame(11 + index, type, "old", message: nil)
                .replacingOccurrences(of: "\"body\":{", with: "\"body\":{\"channel_id\":\"\(channel)\",")
            transport.frame(input)
            try await waitUntil("channel pointer read") { try self.row(store, "old")?.revision == revision }
            XCTAssertEqual(sync.snapshots, snapshots, type)
            XCTAssertFalse(sync.needsSnapshot)
            XCTAssertEqual(try store.cursor(channelStream), 11 + index)
        }
        XCTAssertEqual(try window(store).epoch, originalWindow.epoch)
        XCTAssertEqual(try window(store).bottom, originalWindow.bottom)
        XCTAssertEqual(try window(store).next, originalWindow.next)
        XCTAssertEqual(try int(store, "SELECT last_read_seq FROM read_marks"), mark)
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM skipped_events"), 4)
    }

    func testChannelPointersCoalesceAndKeepAnInvalidationDuringRead() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        let path = "/v1/orgs/\(org)/channels/\(channel)/messages"
        answers.set(path, page([], next: nil))
        let gate = Gate(); gate.close(); defer { gate.open() }
        answers.gate = gate; answers.gated = path
        let reads = { ChatStubProtocol.seen.filter { $0.request.url?.path == path }.count }
        let body = #"{"channel_id":"\#(channel)"}"#
        XCTAssertTrue(sync.apply(try event(11, "reaction.add", body: body, message: nil)))
        XCTAssertTrue(sync.apply(try event(12, "pin.add", body: body, message: nil)))
        try await waitUntil("first read") { reads() == 1 }
        XCTAssertTrue(sync.apply(try event(13, "thread.participation", body: body, message: nil)))
        XCTAssertTrue(sync.apply(try event(14, "future.type", body: body, message: nil)))
        gate.open()
        try await waitUntil("read owed during first request") { reads() == 2 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reads(), 2)
        XCTAssertFalse(sync.needsSnapshot)
    }

    func testChannelPointerRetryAndRevokedChannelRead() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let (service, _) = try await started(answers)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        sync.oneRetryDelay = { _ in 0.02 }
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let path = "/v1/orgs/\(org)/channels/\(channel)/messages"
        answers.set(path, #"{"error":"unavailable"}"#, status: 503)
        XCTAssertTrue(sync.apply(try event(11, "pin.add", body: #"{"channel_id":"\#(channel)"}"#, message: nil)))
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path == path } }
        answers.set(path, page([message("read", seq: 10)], next: nil))
        try await waitUntil { try self.row(store, "read") != nil }
        let gate = Gate(); gate.close(); defer { gate.open() }
        answers.gate = gate; answers.gated = path
        answers.set(path, page([message("revoked", seq: 12)], next: nil))
        let count = ChatStubProtocol.seen.count
        let task = Task { await sync.readChannel(channel, .latest) }
        try await waitUntil { ChatStubProtocol.seen.count > count }
        try await store.queue.write { db in try db.execute(sql: "DELETE FROM channels") }
        gate.open()
        let outcome = await task.value
        XCTAssertEqual(outcome, .void)
        XCTAssertNil(try row(store, "revoked"))
    }

    func testOnlyUnknownAddressedEventsUseChannelPointers() throws {
        XCTAssertEqual(ChatEvents.channelPointer(try event(11, "future.type", body: #"{"channel_id":"c"}"#, message: nil)), "c")
        for type in ["message.edit", "channel.rename", "run.finished", "member.set_role"] {
            XCTAssertNil(ChatEvents.channelPointer(try event(11, type, body: #"{"channel_id":"c"}"#, message: nil)))
        }
        for body in ["{}", #"{"channel_id":null}"#, #"{"channel_id":42}"#, #"{"channel_id":" "}"#] {
            XCTAssertNil(ChatEvents.channelPointer(try event(11, "future.type", body: body, message: nil)))
        }
    }

    func testSnapshotEvictionKeepsAndReloadsFeedEditDraft() async throws { try await checkEvictedEdit(root: nil) }
    func testSnapshotEvictionKeepsAndReloadsThreadEditDraft() async throws { try await checkEvictedEdit(root: "root") }

    func testOpenThreadReloadsAfterSnapshotOnlyWhenReadyAndPreservesEdit() async throws {
        let answers = Answers()
        let rootMessage = message("root", seq: 1)
        let mine = message("mine", seq: 3, root: "root", author: me)
        let path = "/v1/orgs/\(org)/channels/\(channel)/threads/root"
        answers.set("/v1/orgs/\(org)/state", state([rootMessage, mine]))
        answers.set(path, page([rootMessage, mine], next: 3))
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=4", page([mine], next: nil))
        let (service, _) = try await started(answers)
        let store = try XCTUnwrap(service.orgSessions[key]?.store), sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        let session = ChatChannelSession()
        let card = try JSONDecoder().decode(ChatChannelCard.self, from: Data(self.card(10, [], before: nil).utf8))
        let ready = ChannelTabState.ready(card, team: "Billing", offline: false)
        session.update(ready, key: key, store: store, service: service)
        let model = try XCTUnwrap(session.model)
        model.openThread("root")
        try await waitUntil("first thread page") { model.threadHasEarlier }
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("mine")), root: "root"))
        model.editing?.text = "unsaved thread edit"
        let reads = { ChatStubProtocol.seen.filter { $0.request.url?.path == path }.count }
        XCTAssertEqual(reads(), 1)
        let snapshots = sync.snapshots
        session.update(.checking, key: key, store: store, service: service)
        answers.set("/v1/orgs/\(org)/state", state([message("new", seq: 100)], head: 100, before: 100))
        sync.requestSnapshot()
        try await waitUntil("snapshot evicts the open thread") { sync.snapshots > snapshots && !sync.needsSnapshot && !model.threadHasEarlier }
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(reads(), 1, "checking cannot start a thread read")
        XCTAssertEqual(model.threadRoot, "root")
        XCTAssertEqual(model.editing?.text, "unsaved thread edit")
        session.update(ready, key: key, store: store, service: service)
        session.update(ready, key: key, store: store, service: service)
        try await waitUntil("open thread restored") { model.threadHasEarlier && model.thread.contains { $0.id == "root" } }
        XCTAssertEqual(reads(), 2, "repeated ready notifications share one read")
        XCTAssertTrue(session.model === model)
        XCTAssertEqual(model.editing?.text, "unsaved thread edit")
        XCTAssertEqual(model.editing?.revision, 1)
        XCTAssertEqual(try window(store).bottom, 100)
        // Loss of a cursor also needs a read without any F2 state transition.
        try await store.queue.write { try $0.execute(sql: "DELETE FROM thread_cursors") }
        try await waitUntil("missing cursor restored") { reads() == 3 && model.threadHasEarlier }
        // An obsolete cursor cannot be mistaken for one from the new epoch.
        try await store.queue.write { try $0.execute(sql: "UPDATE channel_windows SET epoch = epoch + 1") }
        try await waitUntil("obsolete cursor replaced") {
            try self.int(store, "SELECT epoch FROM thread_cursors WHERE root_id = 'root'") == self.window(store).epoch
        }
        XCTAssertEqual(reads(), 4)
        XCTAssertEqual(model.editing?.text, "unsaved thread edit")
        session.update(.noAccess, key: key, store: store, service: service)
    }

    func testOpenThreadReplacesInFlightPageOnEpochChangeAndCancelsOnNoAccess() async throws {
        let answers = Answers(), gate = Gate()
        answers.set("/v1/orgs/\(org)/state", state([message("root", seq: 1)]))
        let path = "/v1/orgs/\(org)/channels/\(channel)/threads/root"
        answers.set(path, page([message("root", seq: 1), message("reply", seq: 2, root: "root")], next: 2))
        let (service, _) = try await started(answers)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let session = ChatChannelSession()
        let card = try JSONDecoder().decode(ChatChannelCard.self, from: Data(self.card(10, [], before: nil).utf8))
        session.update(.ready(card, team: "Billing", offline: false), key: key, store: store, service: service)
        let model = try XCTUnwrap(session.model)
        gate.close(); defer { gate.open() }
        answers.gate = gate; answers.gated = path
        let reads = { ChatStubProtocol.seen.filter { $0.request.url?.path == path }.count }
        model.openThread("root")
        try await waitUntil("first page in flight") { reads() == 1 }
        try newWindow(store, head: 100, [wire(message("new", seq: 100))], before: 100)
        try await waitUntil("new epoch asks its own first page") { reads() == 2 }
        gate.open()
        try await waitUntil("current epoch page applied") { model.threadHasEarlier }
        XCTAssertEqual(try int(store, "SELECT epoch FROM thread_cursors WHERE root_id = 'root'"), try window(store).epoch)
        gate.close()
        try newWindow(store, head: 200, [wire(message("newer", seq: 200))], before: 200)
        try await waitUntil("another page in flight") { reads() == 3 }
        session.update(.noAccess, key: key, store: store, service: service)
        gate.open()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(session.model === model)
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM thread_cursors"), 0, "a cancelled read cannot repopulate the cache")
        XCTAssertNil(try row(store, "reply"))
    }

    private func checkEvictedEdit(root: String?) async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("root", seq: 1), message("mine", seq: 2, root: root, author: me)]))
        answers.set("/v1/orgs/\(org)/channels/\(channel)/threads/root", page([message("mine", seq: 2, root: root, author: me)], next: nil))
        let (service, _) = try await started(answers)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        let session = ChatChannelSession()
        let card = try JSONDecoder().decode(ChatChannelCard.self, from: Data(self.card(10, [], before: nil).utf8))
        let ready = ChannelTabState.ready(card, team: "Billing", offline: false)
        session.update(ready, key: key, store: store, service: service)
        let model = try XCTUnwrap(session.model)
        if let root { model.openThread(root) }
        model.saveDraft("composer draft", root: root)
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("mine")), root: root))
        model.editing?.text = "unsaved edit 🐇"
        model.positions[root ?? ""] = ChatScrollPosition()
        let gate = Gate(); gate.close(); defer { gate.open() }
        let path = "/v1/orgs/\(org)/channels/\(channel)/messages?before=3"
        answers.gate = gate; answers.gated = path
        answers.set(path, page([message("mine", seq: 2, text: "changed elsewhere", revision: 2, root: root, author: me)], next: nil))
        answers.set("/v1/orgs/\(org)/state", state([message("new", seq: 100)], head: 100, before: 100))
        session.update(.checking, key: key, store: store, service: service)
        sync.requestSnapshot()
        try await waitUntil("evicted editor requests its message") { ChatStubProtocol.seen.contains { $0.request.url?.query == "before=3" } }
        XCTAssertTrue(session.model === model)
        XCTAssertEqual(model.editing?.text, "unsaved edit 🐇")
        XCTAssertEqual(model.editing?.revision, 1)
        let reloading = try XCTUnwrap(model.conversationMessages(root: root).first { $0.id == "mine" })
        XCTAssertTrue(reloading.loading)
        XCTAssertFalse(model.canEdit(reloading), "Save waits for the current server row")
        XCTAssertEqual(model.draft(root: root), "composer draft")
        gate.open()
        try await waitUntil("edit source loaded") { model.editing?.message.revision == 2 }
        session.update(ready, key: key, store: store, service: service)
        XCTAssertTrue(session.model === model)
        XCTAssertEqual(model.editing?.text, "unsaved edit 🐇")
        XCTAssertEqual(model.editing?.revision, 1, "the conflict check keeps the opening revision")
        XCTAssertTrue(model.canEdit(try XCTUnwrap(model.conversationMessages(root: root).first { $0.id == "mine" })))
        XCTAssertEqual(try window(store).bottom, 100, "reloading an edit does not pretend to load continuous history")
        session.update(.noAccess, key: key, store: store, service: service)
        XCTAssertTrue(session.model === model)
        XCTAssertEqual(model.editing?.text, "unsaved edit 🐇")
        let team = team
        try await store.queue.write { try ChatStore.leftTeam($0, team) }
        try await waitUntil("confirmed revoke clears draft") { model.editing == nil }
    }

    func testEscapeDismissesEditSearchThenThreadAndPreservesComposerDrafts() throws {
        let store = try store([message("root", seq: 1, author: me), message("reply", seq: 2, root: "root", author: me)])
        let model = ChatChannelModel(key: key, channel: channel); model.follow(store)
        model.openThread("root"); model.saveDraft("reply draft", root: "root")
        model.setSearching(true)
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("reply")), root: "root"))
        XCTAssertTrue(model.dismissTransient()); XCTAssertNil(model.editing)
        XCTAssertEqual(model.focusRequest?.area, .thread)
        XCTAssertTrue(model.searching); XCTAssertEqual(model.threadRoot, "root")
        XCTAssertTrue(model.dismissTransient()); XCTAssertFalse(model.searching)
        XCTAssertEqual(model.threadRoot, "root")
        XCTAssertTrue(model.dismissTransient()); XCTAssertNil(model.threadRoot)
        XCTAssertEqual(model.focusedMessageID, "root")
        XCTAssertEqual(model.draft(root: "root"), "reply draft")
        XCTAssertFalse(model.dismissTransient())
    }
}

// B1: the real API, synchronizer, outbox and notification path with a deterministic server.
extension ChatMessagesTests {
    private enum B1Read { case metadata, pins, reactors, threads, participation }
    private func readDB<T>(_ store: ChatStore, _ body: (Database) throws -> T) throws -> T { try store.queue.read(body) }

    private func assertB1Refusal(_ read: B1Read, status: Int, holdCapabilities: Bool = false, failedCapabilities: Bool = false,
                                file: StaticString = #filePath, line: UInt = #line) async throws {
        let answers = Answers(), channel = channel
        let base = "/v1/orgs/\(org)", statePath = "/v1/orgs/\(org)/state"
        let metadata = "\(base)/channels/\(channel)/message-metadata", pins = "\(base)/channels/\(channel)/pins"
        let reactors = "\(base)/channels/\(channel)/messages/m/reactions", threads = "\(base)/my-threads"
        let participation = "\(base)/channels/\(channel)/threads/m/participation"
        answers.set(statePath, state([message("m", seq: 1), message("second", seq: 2)]))
        answers.set(metadata, #"{"as_of_seq":10,"items":[{"message_id":"m","deleted":false,"reactions":[{"emoji":"👍","count":2,"mine":false}],"pin":null},{"message_id":"second","deleted":false,"reactions":[],"pin":null}]}"#)
        answers.set(pins, #"{"as_of_seq":10,"pins":[{"message_id":"m","seq":1,"author_account_id":"someone","excerpt":"private excerpt","pinned_by":"someone","pinned_at":"now"}]}"#)
        answers.set(reactors, #"{"as_of_seq":10,"account_ids":["private-account"],"next":"more"}"#)
        let (service, _) = try await started(answers, b1: true)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync), store = try XCTUnwrap(service.orgSessions[key]?.store)
        let first = ChatB1Channel(key: key, channel: channel, store: store, service: service)
        let second = ChatB1Channel(key: key, channel: channel, store: store, service: service)
        first.show(["m", "second"]); first.showPins(true)
        try await waitUntil("B1 projections loaded") { first.state.metadata["m"]?.reactions.count == 1 && first.state.pins?.count == 1 }
        let list = ChatReactionAccounts(b1: first, message: "m", emoji: "👍")
        await list.load(restart: true)
        XCTAssertEqual(list.accounts, ["private-account"], file: file, line: line)
        let revocations = sync.revocations
        let snapshots = ChatStubProtocol.seen.filter { $0.request.url?.path == statePath }.count
        let infoReads = ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/server" }.count
        // The common gate must hide all windows before rights can be confirmed,
        // with no websocket revocation event and no completed snapshot.
        let gate = Gate(); gate.close()
        answers.gate = gate; answers.gated = statePath
        let infoGate = Gate(); infoGate.close()
        if holdCapabilities { answers.gate = infoGate; answers.gated = "/v1/server" }
        if failedCapabilities { answers.set("/v1/server", #"{"error":"unavailable"}"#, status: 503) }
        defer { service.stopFeed(); sync.stop(); gate.open(); infoGate.open() }
        let path: String
        switch read {
        case .metadata: path = metadata
        case .pins: path = pins
        case .reactors: path = reactors
        case .threads: path = threads
        case .participation: path = participation
        }
        answers.set(path, status == 403 ? #"{"error":"forbidden"}"# : #"{"error":"not_found"}"#, status: status)
        switch read {
        case .metadata, .pins:
            first.retryReads()
        case .reactors:
            await list.load(restart: false)
        case .threads:
            try await store.queue.write { try $0.execute(sql: "UPDATE b1_participation SET dirty = 1, ticket = ticket + 1") }
        case .participation:
            sync.b1.checkReply(channel: channel, id: "reply", root: "m")
        }
        if holdCapabilities {
            try await waitUntil("capability check started") { ChatStubProtocol.seen.filter { $0.request.url?.path == "/v1/server" }.count > infoReads }
            try await waitUntil("B1 hidden while compatibility is unresolved") {
                first.state.metadata.isEmpty && first.state.pins == nil && list.accounts.isEmpty
                    && second.state.metadata.isEmpty && second.state.pins == nil
            }
            answers.gate = gate; answers.gated = statePath
            infoGate.open()
        }
        try await waitUntil("shared access gate", { sync.revocations > revocations }, file: file, line: line)
        XCTAssertTrue(sync.needsSnapshot, file: file, line: line)
        XCTAssertEqual(try int(store, "SELECT rights_in_doubt FROM meta"), 1, file: file, line: line)
        XCTAssertFalse(ChatNotifications.allowed(service, key, channel: channel), file: file, line: line)
        for panel in [first, second] {
            XCTAssertFalse(panel.state.accessible, file: file, line: line)
            XCTAssertTrue(panel.state.metadata.isEmpty, file: file, line: line)
            XCTAssertNil(panel.state.pins, file: file, line: line)
        }
        XCTAssertTrue(list.accounts.isEmpty, file: file, line: line)
        try await waitUntil("rights reread", { ChatStubProtocol.seen.filter { $0.request.url?.path == statePath }.count > snapshots }, file: file, line: line)
        if read == .metadata {
            XCTAssertEqual(try int(store, "SELECT dirty FROM b1_metadata WHERE message_id = 'm'"), 1, file: file, line: line)
            XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.url?.path == metadata && $0.request.url?.query == "ids=m" }, file: file, line: line)
        }
    }
    func testB1Metadata403ClosesSharedAccessGate() async throws { try await assertB1Refusal(.metadata, status: 403) }
    func testB1Metadata404ClosesSharedAccessGate() async throws { try await assertB1Refusal(.metadata, status: 404) }
    func testB1Pins403ClosesSharedAccessGate() async throws { try await assertB1Refusal(.pins, status: 403) }
    func testB1Pins404ClosesSharedAccessGate() async throws { try await assertB1Refusal(.pins, status: 404) }
    func testB1Reactors403ClosesSharedAccessGate() async throws { try await assertB1Refusal(.reactors, status: 403) }
    func testB1Reactors404ClosesSharedAccessGate() async throws { try await assertB1Refusal(.reactors, status: 404) }
    func testB1Threads403ClosesSharedAccessGate() async throws { try await assertB1Refusal(.threads, status: 403) }
    func testB1Threads404ClosesSharedAccessGate() async throws { try await assertB1Refusal(.threads, status: 404) }
    func testB1Participation403ClosesSharedAccessGate() async throws { try await assertB1Refusal(.participation, status: 403) }
    func testB1Participation404ClosesSharedAccessGate() async throws { try await assertB1Refusal(.participation, status: 404) }
    func testB1Slow404CapabilityCheckHidesContentBeforeItCompletes() async throws { try await assertB1Refusal(.pins, status: 404, holdCapabilities: true) }
    func testB1Failed404CapabilityCheckClosesSharedAccessGate() async throws { try await assertB1Refusal(.pins, status: 404, failedCapabilities: true) }

    func testB1MissingPinsCapabilityOn404DoesNotRevokeAccessToSupportedReactions() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m", seq: 1)]))
        let (service, _) = try await started(answers, b1: true)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync), store = try XCTUnwrap(service.orgSessions[key]?.store)
        let revocations = sync.revocations, snapshots = sync.snapshots
        answers.set("/v1/server", #"{"name":"s","version":"0.1.0","generation":"g1","api_versions":["v1"],"capabilities":["auth.email_code","events.ws","chat.channels","chat.reactions"]}"#)
        answers.set("/v1/orgs/\(org)/channels/\(channel)/pins", "", status: 404)
        sync.b1.showPins(UUID(), channel: channel, shown: true)
        try await waitUntil { !sync.b1.capabilities.contains("chat.pins") }
        XCTAssertTrue(sync.b1.capabilities.contains("chat.reactions"))
        XCTAssertEqual(sync.revocations, revocations)
        XCTAssertEqual(sync.snapshots, snapshots)
        XCTAssertEqual(try int(store, "SELECT rights_in_doubt FROM meta"), 0)
        XCTAssertTrue(ChatNotifications.allowed(service, key, channel: channel))
    }

    func testB1UnsupportedReactorsRefreshesCapabilitiesWithoutRevokingRights() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m", seq: 1)]))
        let path = "/v1/orgs/\(org)/channels/\(channel)/messages/m/reactions"
        answers.set(path, #"{"as_of_seq":10,"account_ids":["one"],"next":"more"}"#)
        let (service, _) = try await started(answers, b1: true)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync), store = try XCTUnwrap(service.orgSessions[key]?.store)
        let panel = ChatB1Channel(key: key, channel: channel, store: store, service: service)
        let list = ChatReactionAccounts(b1: panel, message: "m", emoji: "👍")
        await list.load(restart: true)
        XCTAssertEqual(list.accounts, ["one"])
        let revocations = sync.revocations
        answers.set(path, #"{"error":"unsupported"}"#, status: 403)
        answers.set("/v1/server", #"{"name":"s","version":"0.1.0","generation":"g1","api_versions":["v1"],"capabilities":["auth.email_code","events.ws","chat.channels","chat.pins"]}"#)
        await list.load(restart: false)
        XCTAssertTrue(list.accounts.isEmpty)
        XCTAssertFalse(service.supports("chat.reactions", key: key))
        XCTAssertEqual(sync.revocations, revocations)
        XCTAssertEqual(try int(store, "SELECT rights_in_doubt FROM meta"), 0)
        XCTAssertTrue(ChatNotifications.allowed(service, key, channel: channel))
    }

    func testStaleSaveKeepsNewerSharedEditInBothTabsAndOnReopen() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m", seq: 1, author: me)]))
        let (service, _) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let first = ChatChannelModel(key: key, channel: channel); first.service = service; first.follow(store)
        XCTAssertTrue(first.beginEditing(try XCTUnwrap(first.message("m")), root: nil))
        first.editing?.text = "text captured by save"
        let second = ChatChannelModel(key: key, channel: channel); second.service = service; second.follow(store)
        second.editing?.text = "newer unsaved text"
        let version = try XCTUnwrap(second.editing?.version)
        // Save before the database observation has updated first's version.
        XCTAssertEqual(first.editing?.text, "text captured by save")
        XCTAssertTrue(first.saveEditing(members: []))
        try await waitUntil { first.editing?.text == "newer unsaved text" && second.editing?.text == "newer unsaved text" }
        XCTAssertEqual(first.editing?.version, version)
        XCTAssertEqual(second.editing?.version, version)
        let reopened = ChatChannelModel(key: key, channel: channel)
        reopened.follow(try ChatStore.open(files: files, key: key).store)
        XCTAssertEqual(reopened.editing?.text, "newer unsaved text")
        XCTAssertEqual(reopened.editing?.version, version)
        let command = try XCTUnwrap(store.commands().first { $0.type == "message.edit" })
        XCTAssertEqual(ChatService.args(command)["text"]?.string, "text captured by save")
    }

    func testB1ParticipationWithdrawalRemovesNoticeWithoutReadingReply() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let threads = "/v1/orgs/\(org)/my-threads"
        answers.set(threads, #"{"member_head":4,"items":[{"channel_id":"\#(channel)","root_id":"ancient","first_message_seq":1}],"next":null}"#)
        answers.set("/v1/orgs/\(org)/channels/\(channel)/threads/ancient/participation", #"{"as_of_seq":100,"participating":true,"eligible_for_reply":true}"#)
        let (service, transport) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store), channel = channel, me = me
        transport.frame(post(11, "reply", root: "ancient"))
        transport.frame(post(12, "mention", root: "ancient", mentions: [me]))
        try await waitUntil { self.notices.count == 2 }
        let replyNotice = ChatNotifications.messageId(key, channel: channel, message: "reply")
        let mentionNotice = ChatNotifications.messageId(key, channel: channel, message: "mention")
        XCTAssertTrue(shown.contains(replyNotice)); XCTAssertTrue(shown.contains(mentionNotice))
        let marks = try readDB(store) { db in (try Row.fetchAll(db, sql: "SELECT * FROM read_marks"), try Row.fetchAll(db, sql: "SELECT * FROM thread_read_marks")) }
        answers.set(threads, #"{"member_head":5,"items":[],"next":null}"#)
        transport.frame(#"{"frame":"event","stream":"member:\#(org):\#(me)","seq":5,"id":"p5","type":"thread.participation_changed","body":{},"actor":null,"command_id":null,"at":"now"}"#)
        try await waitUntil { try self.int(store, "SELECT head FROM b1_participation") == 5 && !self.shown.contains(replyNotice) }
        XCTAssertTrue(shown.contains(mentionNotice))
        XCTAssertFalse(ChatNotifications.stillDue(replyNotice, service))
        XCTAssertTrue(ChatNotifications.stillDue(mentionNotice, service))
        try readDB(store) { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT read FROM notified WHERE object_id = 'reply'"), 0)
            XCTAssertEqual(try ChatUnread.unreadRepliesByChannel(db)[channel], 2)
            XCTAssertEqual(try ChatInbox.read(db, kind: .unread, account: me, session: "s-anna").map(\.id), ["reply", "mention"])
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM read_marks"), marks.0)
            XCTAssertEqual(try Row.fetchAll(db, sql: "SELECT * FROM thread_read_marks"), marks.1)
        }
        // Rejoining and a duplicate live delivery cannot resurrect a withdrawn banner.
        try await store.queue.write { db in
            try db.execute(sql: "INSERT INTO my_threads (channel_id, root_id, first_message_seq) VALUES (?, 'ancient', 1)", arguments: [channel])
            XCTAssertNil(try ChatUnread.owe(db, messageId: "reply", me: me, eligibleReply: true))
        }
        XCTAssertFalse(ChatNotifications.stillDue(replyNotice, service))
        XCTAssertEqual(notices.count, 2)
        try await store.queue.write { try ChatUnread.markRead($0, channel: channel, upTo: 12, thread: "ancient") }
        XCTAssertEqual(try int(store, "SELECT read FROM notified WHERE object_id = 'reply'"), 1)
    }

    func testB1SignalsNeverSnapshotAndReadHeadsNeverMoveCursors() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m", seq: 1)]))
        let metadataPath = "/v1/orgs/\(org)/channels/\(channel)/message-metadata"
        answers.set(metadataPath, #"{"as_of_seq":50,"items":[{"message_id":"m","deleted":false,"reactions":[{"emoji":"❤️","count":7,"mine":true}],"pin":null,"thread_summary":{"root_id":"m","reply_count":300,"last_reply_at":null,"last_reply_seq":null,"last_participants":[]}}]}"#)
        let (service, transport) = try await started(answers, b1: true)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync), store = try XCTUnwrap(service.orgSessions[key]?.store)
        let snapshots = sync.snapshots
        sync.b1.show(UUID(), channel: channel, ids: ["m"])
        try await waitUntil { try self.int(store, "SELECT as_of_seq FROM b1_metadata WHERE message_id = 'm'") == 50 }
        transport.frame(frame(11, "reaction.changed", "m", message: nil))
        transport.frame(frame(12, "pin.changed", "m", message: nil))
        answers.set("/v1/orgs/\(org)/my-threads", #"{"member_head":8,"items":[],"next":null}"#)
        transport.frame(#"{"frame":"event","stream":"member:\#(org):\#(me)","seq":5,"id":"p5","type":"thread.participation_changed","body":{},"actor":null,"command_id":null,"at":"now"}"#)
        try await waitUntil { try store.cursor("member:\(self.org):\(self.me)") == 5 && store.cursor(self.channelStream) == 12 }
        try await waitUntil { try self.int(store, "SELECT head FROM b1_participation") == 8 }
        XCTAssertEqual(sync.snapshots, snapshots)
        XCTAssertFalse(sync.needsSnapshot)
        XCTAssertEqual(try store.cursor(channelStream), 12)
        XCTAssertEqual(try store.cursor("member:\(org):\(me)"), 5)
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM skipped_events"), 0)
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.url?.query?.contains("supports=") == true })
        transport.frame(#"{"frame":"event","stream":"member:\#(org):\#(me)","seq":6,"id":"p6","type":"thread.participation_future","body":{"future":[1,2]},"actor":null,"command_id":null,"at":"now","future_envelope":true}"#)
        try await waitUntil { try store.cursor("member:\(self.org):\(self.me)") == 6 }
        XCTAssertEqual(sync.snapshots, snapshots)
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM skipped_events WHERE event_json LIKE '%future_envelope%'"), 1)
    }

    func testB1PointCheckNotifiesSecondMacWithoutLocalParticipationAndMentionWins() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let point = "/v1/orgs/\(org)/channels/\(channel)/threads/ancient/participation"
        answers.set(point, #"{"as_of_seq":100,"participating":true,"eligible_for_reply":true}"#)
        let (service, transport) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM my_threads"), 0)
        transport.frame(post(11, "reply", root: "ancient"))
        try await waitUntil { self.notices.count == 1 }
        XCTAssertEqual(notices[0].title, "New reply in a thread")
        transport.frame(post(11, "reply", root: "ancient"))
        transport.frame(post(12, "mention", root: "ancient", mentions: [me]))
        try await waitUntil { self.notices.count == 2 }
        XCTAssertEqual(notices[1].title, "New mention in AgentPad")
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path == point }.count, 1)
        answers.set(point, #"{"as_of_seq":100,"participating":true,"eligible_for_reply":false}"#)
        transport.frame(post(13, "before-my-contribution", root: "ancient"))
        try await waitUntil { ChatStubProtocol.seen.filter { $0.request.url?.path == point }.count == 2 }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(notices.count, 2)
    }

    func testB1LatePointAnswerRechecksDeletionReadMuteAndLooking() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let point = "/v1/orgs/\(org)/channels/\(channel)/threads/ancient/participation"
        answers.set(point, #"{"as_of_seq":100,"participating":true,"eligible_for_reply":true}"#)
        let (service, transport) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let gate = Gate(); gate.close(); defer { gate.open() }
        answers.gate = gate; answers.gated = point + "?reply_id=doomed"
        transport.frame(post(11, "doomed", root: "ancient"))
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path == point } }
        transport.frame(frame(12, "message.delete", "doomed", message: message("doomed", seq: 11, revision: 2, root: "ancient", deleted: true)))
        try await waitUntil { try self.row(store, "doomed")?.deleted == true }
        gate.open()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(notices.isEmpty)
        let channel = channel
        try await store.queue.write { try ChatUnread.setMuted($0, channel: channel, true) }
        transport.frame(post(13, "muted", root: "ancient"))
        try await waitUntil { try self.row(store, "muted") != nil }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(notices.isEmpty)
        try await store.queue.write { try ChatUnread.setMuted($0, channel: channel, false) }
        ChatNotifications.appActive = { true }
        let view = UUID(); ChatNotifications.show("t:ancient", view: view) { true }
        transport.frame(post(14, "viewed", root: "ancient"))
        try await waitUntil { try self.int(store, "SELECT COUNT(*) FROM notified WHERE object_id = 'viewed'") == 1 }
        XCTAssertTrue(notices.isEmpty)
        ChatNotifications.hide("t:ancient", view: view)
    }

    func testB1ParticipationPaginationRestartsAndReplacesOnlyWhenComplete() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let path = "/v1/orgs/\(org)/my-threads"
        let cursor = "\(channel):old"
        answers.set(path, #"{"member_head":4,"items":[{"channel_id":"\#(channel)","root_id":"old","first_message_seq":1}],"next":"\#(cursor)"}"#)
        answers.set(path + "?after=\(cursor)&at=4&limit=200", #"{"error":"snapshot_changed"}"#, status: 409)
        let (service, _) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.query?.contains("at=4") == true } }
        answers.set(path, #"{"member_head":5,"items":[{"channel_id":"\#(channel)","root_id":"new","first_message_seq":3}],"next":null}"#)
        try await waitUntil { try self.int(store, "SELECT COUNT(*) FROM my_threads WHERE root_id = 'new'") == 1 }
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM my_threads"), 1)
        XCTAssertEqual(try store.cursor("member:\(org):\(me)"), 4)
    }

    func testB1SinglePendingIntentSharedAcrossWindowsAndAckDoesNotRestoreOldState() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m", seq: 1)]))
        let metadataPath = "/v1/orgs/\(org)/channels/\(channel)/message-metadata"
        answers.set(metadataPath, #"{"as_of_seq":10,"items":[{"message_id":"m","deleted":false,"reactions":[],"pin":null}]}"#)
        let (service, _) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store), sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        let first = ChatB1Channel(key: key, channel: channel, store: store, service: service)
        let second = ChatB1Channel(key: key, channel: channel, store: store, service: service)
        first.show(["m"]); second.show(["m"])
        try await waitUntil { first.state.metadata["m"] != nil && second.state.metadata["m"] != nil }
        let gate = Gate(); gate.close(); defer { gate.open() }
        answers.gate = gate; answers.gated = "/v1/commands"
        try service.setB1(key, channel: channel, message: "m", choice: "❤", present: true)
        XCTAssertThrowsError(try service.setB1(key, channel: channel, message: "m", choice: "❤️", present: false))
        try await waitUntil { second.pending("m", choice: "❤️") }
        let command = try XCTUnwrap(store.commands().first { $0.type == "message.reaction.set" })
        XCTAssertEqual(ChatService.args(command)["emoji"], .string("❤️"))
        XCTAssertEqual(ChatService.args(command)["present"], .bool(true))
        answers.set(metadataPath, #"{"as_of_seq":20,"items":[{"message_id":"m","deleted":false,"reactions":[],"pin":null}]}"#)
        XCTAssertTrue(sync.apply(try event(11, "reaction.changed", body: #"{"channel_id":"\#(channel)","message_id":"m"}"#, message: nil)))
        try await waitUntil { try self.int(store, "SELECT as_of_seq FROM b1_metadata WHERE message_id = 'm'") == 20 }
        gate.open()
        try await waitUntil { !first.pending("m", choice: "❤️") && !second.pending("m", choice: "❤️") }
        XCTAssertEqual(first.state.metadata["m"]?.reactions, [])
        XCTAssertEqual(second.state.metadata["m"]?.reactions, [])
        let channel = channel
        try await store.queue.write { try $0.execute(sql: "UPDATE channels SET archived = 1 WHERE channel_id = ?", arguments: [channel]) }
        XCTAssertThrowsError(try service.setB1(key, channel: channel, message: "m", choice: "pin", present: true))
        try await store.queue.write { try $0.execute(sql: "UPDATE channels SET archived = 0 WHERE channel_id = ?", arguments: [channel]) }
        service.serverCapabilities[key.server] = ["chat.channels"]
        XCTAssertFalse(first.supports("chat.reactions")); XCTAssertFalse(first.supports("chat.pins"))
        XCTAssertThrowsError(try service.setB1(key, channel: channel, message: "m", choice: "👍", present: true))
    }
}

extension ChatMessagesTests {
    func testB1MemberReactionsHandleMissingDeletedAndThreadMessages() async throws {
        try await checkB1ReactionEvents(role: "member")
    }

    func testB1OwnerReactionsHandleMissingDeletedAndThreadMessages() async throws {
        try await checkB1ReactionEvents(role: "owner")
    }

    private func checkB1ReactionEvents(role: String) async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([
            message("m", seq: 1), message("reply", seq: 2, root: "m"), message("deleted", seq: 3, deleted: true),
        ], role: role))
        let (service, transport) = try await started(answers, b1: true, role: role)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let panel = ChatB1Channel(key: key, channel: channel, store: store, service: service)
        XCTAssertTrue(panel.canChange)
        let gate = Gate(); gate.close(); defer { gate.open() }
        answers.gate = gate; answers.gated = "/v1/commands"
        for id in ["m", "reply"] {
            try service.setB1(key, channel: channel, message: id, choice: "👍", present: true)
        }
        for id in ["unloaded", "deleted"] {
            XCTAssertThrowsError(try service.setB1(key, channel: channel, message: id, choice: "👍", present: true))
        }
        XCTAssertEqual(try store.commands().count, 2)
        transport.frame(frame(11, "reaction.changed", "unloaded", message: nil))
        transport.frame(frame(12, "reaction.changed", "deleted", message: nil))
        transport.frame(frame(13, "reaction.changed", "reply", message: nil))
        transport.frame(frame(14, "message.delete", "m", message: nil))
        transport.frame(frame(15, "reaction.changed", "m", message: nil))
        try await waitUntil { try store.cursor(self.channelStream) == 15 }
        XCTAssertNil(try row(store, "unloaded"), "a reaction pointer must not invent a message or hydrate its body")
        XCTAssertEqual(try row(store, "deleted")?.deleted, true)
        XCTAssertEqual(try row(store, "m")?.deleted, true)
        XCTAssertEqual(try row(store, "reply")?.threadRootId, "m")
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM b1_intents WHERE message_id = 'm'"), 0)
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM skipped_events"), 0)
        XCTAssertEqual(try int(store, "SELECT invalidated FROM b1_metadata WHERE message_id = 'unloaded'"), 14)
    }

    func testB1ReactionAccountsDeduplicateWithinAndAcrossPages() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m", seq: 1)]))
        let path = "/v1/orgs/\(org)/channels/\(channel)/messages/m/reactions"
        answers.set(path, #"{"as_of_seq":10,"account_ids":["one","one","two","two"],"next":"two"}"#)
        let (service, _) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let panel = ChatB1Channel(key: key, channel: channel, store: store, service: service)
        let list = ChatReactionAccounts(b1: panel, message: "m", emoji: "👍")
        await list.load(restart: true)
        XCTAssertEqual(list.accounts, ["one", "two"])
        answers.set(path, #"{"as_of_seq":10,"account_ids":["two","three","three","one"],"next":null}"#)
        await list.load(restart: false)
        XCTAssertEqual(list.accounts, ["one", "two", "three"])
        XCTAssertNil(list.next)
        answers.set(path, #"{"as_of_seq":11,"account_ids":["three","three"],"next":null}"#)
        await list.load(restart: true)
        XCTAssertEqual(list.accounts, ["three"])
    }

    func testB1NativeReactionPickerAndStripThroughPendingAndServerUpdates() async throws {
        _ = NSApplication.shared
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m", seq: 1), message("reply", seq: 2, root: "m")]))
        let path = "/v1/orgs/\(org)/channels/\(channel)/message-metadata"
        answers.set(path, #"{"as_of_seq":10,"items":[{"message_id":"m","deleted":false,"reactions":[],"pin":null},{"message_id":"reply","deleted":false,"reactions":[],"pin":null}]}"#)
        let (service, transport) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let model = ChatChannelModel(key: key, channel: channel)
        model.service = service; model.follow(store)
        let panel = try XCTUnwrap(model.b1)
        panel.show(["m", "reply"])
        try await waitUntil { panel.state.metadata.count == 2 }
        XCTAssertTrue(panel.canChange, "a regular member can react to another member's message")

        let shown = try XCTUnwrap(model.message("m")), reply = try XCTUnwrap(row(store, "reply"))
        let host = NSHostingView(rootView: AnyView(VStack {
            ChatMessageRow(model: model, message: shown, members: [], mentionable: [], me: me, archived: false, replies: 1, selected: true)
            ChatMessageRow(model: model, message: reply, members: [], mentionable: [], me: me, archived: false, replies: 0, inThread: true)
        }.frame(width: 400, height: 260)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: ChatReactionPicker(b1: panel, message: "m"))
        defer { popover.close(); window.contentView = nil; window.close() }
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        popover.show(relativeTo: host.bounds, of: host, preferredEdge: .maxY)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(popover.isShown)

        let gate = Gate(); gate.close(); defer { gate.open() }
        answers.gate = gate; answers.gated = "/v1/commands"
        // Invoke the picker's action while its native popover and message rows
        // are alive; no external accessibility permission is required.
        panel.toggle("m", emoji: "❤")
        panel.toggle("reply", emoji: "👍🏽")
        try await waitUntil { panel.pending("m", choice: "❤️") && panel.pending("reply", choice: "👍🏽") }
        host.layoutSubtreeIfNeeded()
        let commands = try store.commands().filter { $0.type == "message.reaction.set" }
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.allSatisfy { ChatService.args($0)["present"] == .bool(true) })

        answers.set(path, #"{"as_of_seq":12,"items":[{"message_id":"m","deleted":false,"reactions":[{"emoji":"❤️","count":1,"mine":true}],"pin":null},{"message_id":"reply","deleted":false,"reactions":[{"emoji":"👍🏽","count":1,"mine":true}],"pin":null}]}"#)
        transport.frame(frame(11, "reaction.changed", "m", message: nil))
        transport.frame(frame(12, "reaction.changed", "reply", message: nil))
        gate.open()
        try await waitUntil { panel.state.metadata["m"]?.reactions.first?.mine == true && panel.state.metadata["reply"]?.reactions.first?.mine == true && !panel.pending("m", choice: "❤️") }
        host.layoutSubtreeIfNeeded()
        panel.toggle("m", emoji: "❤️")
        let removal = try XCTUnwrap(store.commands().last { $0.type == "message.reaction.set" })
        XCTAssertEqual(ChatService.args(removal)["present"], .bool(false))
        popover.close()
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
    }

    func testB1MetadataBatchKeepsHiddenAndPinDebtAndHonorsLimit() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("good", seq: 1), message("missing", seq: 2), message("hidden", seq: 3)]))
        let path = "/v1/orgs/\(org)/channels/\(channel)/message-metadata"
        answers.set(path, #"{"as_of_seq":10,"items":[{"message_id":"good","deleted":false,"reactions":[],"pin":null},{"message_id":"missing","deleted":true,"reactions":[],"pin":null}]}"#)
        let (service, _) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store), b1 = try XCTUnwrap(service.orgSessions[key]?.sync?.b1)
        let channel = channel
        try await store.queue.write { db in
            try ChatB1.watch(db, channel: channel, ids: ["hidden"])
            try db.execute(sql: "INSERT OR IGNORE INTO b1_pins (channel_id) VALUES (?)", arguments: [channel])
        }
        let owner = UUID()
        b1.show(owner, channel: channel, ids: ["good", "missing"])
        try await waitUntil { try self.int(store, "SELECT as_of_seq FROM b1_metadata WHERE message_id = 'good'") == 10 && self.int(store, "SELECT dirty FROM b1_metadata WHERE message_id = 'missing'") == 0 }
        XCTAssertEqual(try int(store, "SELECT dirty FROM b1_metadata WHERE message_id = 'hidden'"), 1)
        XCTAssertEqual(try int(store, "SELECT dirty FROM b1_pins"), 1)
        XCTAssertFalse(ChatStubProtocol.seen.contains { $0.request.url?.query?.contains("hidden") == true })
        var limits = ChatB1.Limits(); limits.metadataIds = 1
        b1.configure(ChatB1.capabilities, limits: limits)
        answers.set(path + "?ids=hidden", #"{"as_of_seq":10,"items":[{"message_id":"hidden","deleted":false,"reactions":[],"pin":null}]}"#)
        b1.show(owner, channel: channel, ids: ["hidden", "another"])
        try await waitUntil { try self.int(store, "SELECT as_of_seq FROM b1_metadata WHERE message_id = 'hidden'") == 10 }
        XCTAssertTrue(ChatStubProtocol.seen.filter { $0.request.url?.query?.contains("hidden") == true }.allSatisfy { $0.request.url?.query == "ids=hidden" })
    }

    func testB1ReactionPanelRestartsAndDiscardsAnInvalidatedPage() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m", seq: 1)]))
        let path = "/v1/orgs/\(org)/channels/\(channel)/messages/m/reactions"
        answers.set(path, #"{"as_of_seq":10,"account_ids":["one"],"next":"one"}"#)
        let (service, _) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let b1 = ChatB1Channel(key: key, channel: channel, store: store, service: service)
        let list = ChatReactionAccounts(b1: b1, message: "m", emoji: "👍")
        await list.load(restart: true)
        XCTAssertEqual(list.accounts, ["one"])
        var components = URLComponents(); components.queryItems = [URLQueryItem(name: "emoji", value: "👍"), URLQueryItem(name: "after", value: "one"), URLQueryItem(name: "at", value: "10"), URLQueryItem(name: "limit", value: "100")]
        let more = path + "?" + (components.percentEncodedQuery ?? "")
        answers.set(more, #"{"error":"snapshot_changed"}"#, status: 409)
        answers.set(path, #"{"as_of_seq":11,"account_ids":["new"],"next":null}"#)
        await list.load(restart: false)
        XCTAssertEqual(list.accounts, ["new"])
        XCTAssertNil(list.error)
        let gate = Gate(); gate.close(); defer { gate.open() }
        let query = try XCTUnwrap(ChatStubProtocol.seen.first { $0.request.url?.path == path }?.request.url?.query)
        answers.gate = gate; answers.gated = path + "?" + query
        let count = ChatStubProtocol.seen.filter { $0.request.url?.path == path }.count
        let late = Task { await list.load(restart: true) }
        try await waitUntil { ChatStubProtocol.seen.filter { $0.request.url?.path == path }.count > count }
        list.clear()
        gate.open(); await late.value
        XCTAssertTrue(list.accounts.isEmpty, "closing/invalidation cannot be undone by a late page")
        let channel = channel
        try await store.queue.write { try ChatB1.watch($0, channel: channel, ids: ["m"]) }
        try await waitUntil { b1.state.versions["m"] != nil }
        let version = b1.state.versions["m"]
        _ = try store.apply(event(11, "reaction.changed", body: #"{"message_id":"m"}"#, message: nil))
        try await waitUntil { b1.state.versions["m"] != version }
        let invalidatedVersion = b1.state.versions["m"]
        try await store.queue.write { db in
            let token = try XCTUnwrap(ChatB1.readToken(db, channel: channel))
            try ChatB1.apply(db, page: .init(asOfSeq: 12, items: [.init(messageId: "m", deleted: false, reactions: [], pin: nil)]),
                             channel: channel, token: token, tickets: ["m": 1])
        }
        try await waitUntil { b1.state.versions["m"] != invalidatedVersion }
        do {
            _ = try await b1.reactors(message: "m", emoji: "👍", after: nil, at: nil)
            XCTFail("a reactor page older than accepted metadata is stale even before its event arrives")
        } catch { }
    }

    func testB1DefinitiveOrganizationLossClearsDraftsHeldByOpenModels() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m", seq: 1, author: me)]))
        let (service, _) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let model = ChatChannelModel(key: key, channel: channel); model.follow(store)
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("m")), root: nil))
        model.editing?.text = "unfinished private work"
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM edit_drafts"), 1)
        service.membershipLost(key)
        try await waitUntil { model.editing == nil && model.b1?.state.accessible == false }
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.cacheURL(key).path))
    }

    func testB1StaleEligibilityRetriesAfterNewThreadEvent() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let point = "/v1/orgs/\(org)/channels/\(channel)/threads/ancient/participation"
        answers.set(point, #"{"as_of_seq":10,"participating":true,"eligible_for_reply":true}"#)
        let (service, transport) = try await started(answers, b1: true)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        sync.b1.retryDelay = { _ in 0.1 }
        transport.frame(post(11, "new-reply", root: "ancient"))
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path == point } }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(notices.isEmpty, "an eligibility read older than the reply is not evidence")
        answers.set(point, #"{"as_of_seq":11,"participating":true,"eligible_for_reply":false}"#)
        try await waitUntil { ChatStubProtocol.seen.filter { $0.request.url?.path == point }.count >= 2 }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(notices.isEmpty)
    }

    func testB1DelayedEligibilityRetriesEvenWhenMetadataAlreadyIncludesDeletion() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("mine", seq: 1, root: "ancient", author: me)]))
        let point = "/v1/orgs/\(org)/channels/\(channel)/threads/ancient/participation"
        answers.set(point, #"{"as_of_seq":11,"participating":true,"eligible_for_reply":true}"#)
        let (service, transport) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store), sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        sync.b1.retryDelay = { _ in 0.01 }
        let gate = Gate(); gate.close(); defer { gate.open() }
        answers.gate = gate; answers.gated = point + "?reply_id=reply"; answers.freezeBeforeGate = true
        let scope = try readDB(store) { try ChatB1.readToken($0, channel: self.channel) }
        transport.frame(post(11, "reply", root: "ancient"))
        try await waitUntil { ChatStubProtocol.seen.contains { $0.request.url?.path == point } }
        // Hydration wins the race: every watched row is already at deletion head 12.
        let channel = channel
        let deletion = try event(12, "message.delete", body: #"{"message_id":"mine","revision":2}"#, message: nil)
        try await store.queue.write { db in
            try ChatB1.watch(db, channel: channel, ids: ["mine"])
            let rows = try Row.fetchAll(db, sql: "SELECT message_id, ticket FROM b1_metadata")
            let tickets = Dictionary(uniqueKeysWithValues: rows.map { ($0["message_id"] as String, $0["ticket"] as Int) })
            let items = tickets.keys.map { ChatB1.Metadata(messageId: $0, deleted: $0 == "mine", reactions: [], pin: nil, threadSummary: nil) }
            _ = try ChatB1.apply(db, page: .init(asOfSeq: 12, items: items), channel: channel,
                                 token: XCTUnwrap(ChatB1.readToken(db, channel: channel)), tickets: tickets)
            // Isolate B1's freshness from the content cache's separate rights
            // epoch: its own event invalidation must reject the delayed answer.
            try ChatB1.invalidate(db, event: deletion)
        }
        XCTAssertEqual(try readDB(store) { try ChatB1.readToken($0, channel: channel) }, scope)
        XCTAssertEqual(try int(store, "SELECT MAX(seq) FROM b1_reply_heads"), 12)
        XCTAssertEqual(try int(store, "SELECT MAX(invalidated) FROM b1_metadata"), 11)
        answers.set(point, #"{"as_of_seq":12,"participating":false,"eligible_for_reply":false}"#)
        gate.open()
        try await waitUntil { ChatStubProtocol.seen.filter { $0.request.url?.path == point }.count >= 2 || !self.notices.isEmpty }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(notices.isEmpty, "removing the last contribution invalidates the delayed eligible answer")
        XCTAssertEqual(ChatStubProtocol.seen.filter { $0.request.url?.path == point }.count, 2)
        XCTAssertEqual(try int(store, "SELECT COUNT(*) FROM notified WHERE object_id = 'reply'"), 0)
    }

    func testB1OldParticipationPassCannotWithdrawNewlyConfirmedReply() async throws {
        noticesHere()
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state())
        let threads = "/v1/orgs/\(org)/my-threads"
        let point = "/v1/orgs/\(org)/channels/\(channel)/threads/ancient/participation"
        answers.set(point, #"{"as_of_seq":12,"participating":true,"eligible_for_reply":true}"#)
        let (service, transport) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        try await waitUntil { try self.int(store, "SELECT dirty FROM b1_participation") == 0 }
        let before = ChatStubProtocol.seen.filter { $0.request.url?.path == threads }.count
        let gate = Gate(); gate.close(); defer { gate.open() }
        answers.gate = gate; answers.gated = threads + "?limit=200"; answers.freezeBeforeGate = true
        try await store.queue.write { try $0.execute(sql: "UPDATE b1_participation SET dirty = 1, ticket = ticket + 1") }
        try await waitUntil { ChatStubProtocol.seen.filter { $0.request.url?.path == threads }.count > before }
        transport.frame(post(11, "mine", author: me, root: "ancient"))
        transport.frame(post(12, "reply", root: "ancient"))
        try await waitUntil { self.notices.count == 1 }
        let notice = ChatNotifications.messageId(key, channel: channel, message: "reply")
        // The member signal has not arrived. Only a fresh pass can see this membership.
        answers.set(threads, #"{"member_head":5,"items":[{"channel_id":"\#(channel)","root_id":"ancient","first_message_seq":11}],"next":null}"#)
        gate.open()
        try await waitUntil { try self.int(store, "SELECT dirty FROM b1_participation") == 0 }
        XCTAssertGreaterThanOrEqual(ChatStubProtocol.seen.filter { $0.request.url?.path == threads }.count, before + 2)
        XCTAssertEqual(try int(store, "SELECT head FROM b1_participation"), 5)
        XCTAssertEqual(try int(store, "SELECT withdrawn FROM notified WHERE object_id = 'reply'"), 0)
        XCTAssertTrue(ChatNotifications.stillDue(notice, service))
        XCTAssertTrue(shown.contains(notice))
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(try store.cursor("member:\(org):\(me)"), 4)
    }

    func testB1ReactorsEncodeEmojiPaginateAndRejectLateRevokedPage() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m", seq: 1)]))
        let path = "/v1/orgs/\(org)/channels/\(channel)/messages/m/reactions"
        answers.set(path, #"{"as_of_seq":10,"account_ids":["one"],"next":"one"}"#)
        let (service, _) = try await started(answers, b1: true)
        let b1 = try XCTUnwrap(service.orgSessions[key]?.sync?.b1), store = try XCTUnwrap(service.orgSessions[key]?.store)
        let first = try await b1.reactors(channel: channel, message: "m", emoji: "❤️", after: nil, at: nil)
        XCTAssertEqual(first.accountIds, ["one"])
        answers.set(path, #"{"as_of_seq":10,"account_ids":["two"],"next":null}"#)
        let second = try await b1.reactors(channel: channel, message: "m", emoji: "❤️", after: first.next, at: first.asOfSeq)
        XCTAssertEqual(second.accountIds, ["two"])
        let requests = ChatStubProtocol.seen.filter { $0.request.url?.path == path }
        let query = URLComponents(url: try XCTUnwrap(requests.last?.request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "emoji" }?.value, "❤️")
        XCTAssertEqual(query.first { $0.name == "after" }?.value, "one")
        XCTAssertEqual(query.first { $0.name == "at" }?.value, "10")
        let gate = Gate(); gate.close(); defer { gate.open() }
        let full = try XCTUnwrap(requests.first?.request.url?.query)
        answers.gate = gate; answers.gated = path + "?" + full
        let channel = channel
        let late = Task { try await b1.reactors(channel: channel, message: "m", emoji: "❤️", after: nil, at: nil) }
        try await waitUntil { ChatStubProtocol.seen.filter { $0.request.url?.path == path }.count == 3 }
        try await store.queue.write { try $0.execute(sql: "UPDATE meta SET rights_in_doubt = 1") }
        gate.open()
        do { _ = try await late.value; XCTFail("revoked reactor names were returned") } catch { }
    }
}

extension ChatMessagesTests {
    func testR115PinsLoadFullBodiesWithoutMovingConversationAndUnpinWithoutMetadata() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("latest", seq: 10)], before: 10))
        let pinsPath = "/v1/orgs/\(org)/channels/\(channel)/pins"
        answers.set(pinsPath, #"{"as_of_seq":10,"pins":[{"message_id":"old","seq":1,"author_account_id":"someone","excerpt":"short preview","pinned_by":"someone","pinned_at":"now"}]}"#)
        let full = "## Complete message\n\n" + String(repeating: "Long Markdown paragraph. ", count: 20) + "\n\nFinal searchable detail"
        var old = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(message("old", seq: 1).utf8)) as? [String: Any])
        old["text"] = full
        let fullMessage = String(decoding: try JSONSerialization.data(withJSONObject: old), as: UTF8.self)
        answers.set("/v1/orgs/\(org)/channels/\(channel)/messages?before=2", page([fullMessage], next: nil))
        let (service, _) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let model = ChatChannelModel(key: key, channel: channel); model.service = service; model.follow(store)
        let b1 = try XCTUnwrap(model.b1)
        let before = try int(store, "SELECT last_read_seq FROM read_marks LIMIT 1")
        b1.showPins(true)
        try await waitUntil { b1.state.pins?.count == 1 }
        b1.loadPinBodies()
        try await waitUntil { b1.state.pinMessages["old"]?.text == full }
        XCTAssertNil(model.revealMessageID)
        XCTAssertNil(model.threadRoot)
        XCTAssertEqual(try int(store, "SELECT last_read_seq FROM read_marks LIMIT 1"), before)
        XCTAssertNil(b1.state.metadata["old"], "the unpin action must not require pin metadata")
        let gate = Gate(); gate.close(); defer { gate.open() }
        answers.gated = "/v1/commands"; answers.gate = gate
        b1.unpin("old")
        try await waitUntil { b1.pending("old", choice: "pin") }
        let command = try XCTUnwrap(store.commands().first { $0.type == "message.pin.set" })
        XCTAssertEqual(ChatService.args(command)["message_id"], .string("old"))
        XCTAssertEqual(ChatService.args(command)["present"], .bool(false))
        // The cached full message must disappear through the same gate as its excerpt.
        try await store.queue.write { try $0.execute(sql: "UPDATE meta SET rights_in_doubt = 1") }
        try await waitUntil { !b1.state.accessible }
        XCTAssertNil(b1.state.pins)
        XCTAssertTrue(b1.state.pinMessages.isEmpty)
    }

    func testR115PinSubscriptionSurvivesHiddenTimeline() async throws {
        let answers = Answers()
        answers.set("/v1/orgs/\(org)/state", state([message("m", seq: 1)]))
        let path = "/v1/orgs/\(org)/channels/\(channel)/pins"
        answers.set(path, #"{"as_of_seq":10,"pins":[]}"#)
        let (service, _) = try await started(answers, b1: true)
        let store = try XCTUnwrap(service.orgSessions[key]?.store)
        let b1 = ChatB1Channel(key: key, channel: channel, store: store, service: service)
        b1.showPins(true)
        try await waitUntil { b1.state.pins == [] }
        b1.hideMetadata()
        answers.set(path, #"{"as_of_seq":11,"pins":[{"message_id":"m","seq":1,"author_account_id":"someone","excerpt":"new pin","pinned_by":"someone","pinned_at":"now"}]}"#)
        let sync = try XCTUnwrap(service.orgSessions[key]?.sync)
        XCTAssertTrue(sync.apply(try event(11, "pin.changed", body: #"{"channel_id":"\#(channel)","message_id":"m"}"#, message: nil)))
        try await waitUntil { b1.state.pins?.first?.id == "m" }
    }
}
