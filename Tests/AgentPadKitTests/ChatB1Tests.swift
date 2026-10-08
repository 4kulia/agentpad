import AppKit
import Foundation
import GRDB
import SwiftUI
import XCTest
@testable import AgentPadKit

@MainActor
final class ChatB1Tests: XCTestCase {
    private var directory: URL!
    private var scope: TeamServiceTestScope!
    private let key = ChatOrgKey(server: try! ChatServerAddress(parsing: "https://b1.example.com"), accountId: "me", orgId: "org")
    override func setUp() async throws {
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("b1-\(UUID())")
    }
    override func tearDown() async throws { scope.close(); try? FileManager.default.removeItem(at: directory) }
    private func store() throws -> ChatStore {
        let s = try ChatStore.open(files: ChatFiles(directory: directory), key: key).store
        try s.apply(.init(cursors: ["channel:c": 10, "member:org:me": 4], members: [], teams: [.init(teamId: "t", name: "Team")],
                          channels: [.init(channelId: "c", teamId: "t", name: "New", archived: false, version: 1, head: 10, messages: [])]), confirmsRights: "session")
        try s.setGeneration("g1")
        return s
    }
    private func read<T>(_ s: ChatStore, _ body: (Database) throws -> T) throws -> T { try s.queue.read(body) }
    private func write<T>(_ s: ChatStore, _ body: (Database) throws -> T) throws -> T { try s.queue.write(body) }
    private func event(_ type: String, seq: Int = 11, id: String = "m", member: Bool = false) -> ChatEvent {
        ChatEvent(stream: member ? "member:org:me" : "channel:c", seq: seq, id: "e\(seq)", type: type, actor: nil,
                  body: member ? .object([:]) : .object(["channel_id": .string("c"), "message_id": .string(id), "revision": .number(2)]), commandId: nil, at: "now")
    }
    private func message(_ id: String = "m", root: String? = nil, me: Bool = true, seq: Int = 1) -> ChatMessageWire {
        let object: [String: Any] = ["message_id": id, "channel_id": "c", "thread_root_id": root as Any? ?? NSNull(),
            "author_account_id": me ? "me" : "other", "text": "Message \(id)", "mentions": [], "revision": 1, "seq": seq, "created_at": "2026-10-06T10:35:00Z"]
        return try! JSONDecoder().decode(ChatMessageWire.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private var meta: ChatB1.Metadata {
        .init(messageId: "m", deleted: false, reactions: [.init(emoji: "👍", count: 3, mine: true)], pin: .init(pinnedBy: "me", pinnedAt: "now"),
              threadSummary: .init(rootId: "m", replyCount: 205, lastReplyAt: "2026-10-06T10:40:00Z", lastReplySeq: 800,
                                  lastParticipants: [.init(authorAccountId: "me", authorAgentId: "bot-1", authorAgentName: "Reviewer"),
                                                     .init(authorAccountId: "me", authorAgentId: "bot-2", authorAgentName: "Builder")]))
    }
    private func seed(_ s: ChatStore, head: Int = 10) throws -> ChatB1.ReadToken {
        try write(s) { db in
            try ChatB1.watch(db, channel: "c", ids: ["m"])
            let token = try XCTUnwrap(ChatB1.readToken(db, channel: "c"))
            XCTAssertTrue(try ChatB1.apply(db, page: .init(asOfSeq: head, items: [meta]), channel: "c", token: token, tickets: ["m": 0]))
            return token
        }
    }

    func testReconnectRefreshKeepsDisplayedDataAndVersionFloorsUntilFreshReplacement() throws {
        let s = try store()
        let socket = ChatSocket(server: key.server, token: "test")
        let b1 = ChatB1Sync(key: key, store: s, api: ChatAPI(server: key.server), token: "test", socket: socket)
        defer { b1.stop() }
        b1.configure(ChatB1.capabilities)
        let oldToken = try seed(s, head: 20)
        let pinned = ChatB1.PinnedMessage(messageId: "m", seq: 1, authorAccountId: "me", excerpt: "Pinned", pinnedBy: "me", pinnedAt: "now")
        let pinsData = try ChatB1.encode([pinned])
        try write(s) { db in
            try db.execute(sql: "INSERT INTO b1_pins (channel_id, data, as_of_seq, dirty) VALUES ('c', ?, 20, 0)", arguments: [pinsData])
            try db.execute(sql: "INSERT INTO my_threads (channel_id, root_id) VALUES ('c', 'm')")
            try db.execute(sql: "UPDATE b1_participation SET head = 8, dirty = 0")
            try ChatB1.invalidate(db, event: event("pin.changed", seq: 25))
        }
        b1.configure(ChatB1.capabilities, reconnect: true)
        try write(s) { db in
            XCTAssertEqual(try ChatB1.metadata(db, id: "m"), meta)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT data FROM b1_pins"), pinsData)
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT root_id FROM my_threads"), ["m"])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT head FROM b1_participation"), 8)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dirty FROM b1_participation"), 1)
            for table in ["b1_metadata", "b1_pins"] {
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT as_of_seq FROM \(table)"), 20)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT invalidated FROM \(table)"), 25)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dirty FROM \(table)"), 1)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT ticket FROM \(table)"), 2)
            }
            let token = try XCTUnwrap(ChatB1.readToken(db, channel: "c"))
            XCTAssertNotEqual(token, oldToken)
            XCTAssertFalse(try ChatB1.apply(db, page: .init(asOfSeq: 99, items: [meta]), channel: "c", token: oldToken, tickets: ["m": 2]))
            XCTAssertFalse(try ChatB1.apply(db, page: .init(asOfSeq: 99, pins: []), channel: "c", token: oldToken, ticket: 2))
            XCTAssertFalse(try ChatB1.apply(db, page: .init(asOfSeq: 24, items: [meta]), channel: "c", token: token, tickets: ["m": 2]))
            XCTAssertFalse(try ChatB1.apply(db, page: .init(asOfSeq: 24, pins: []), channel: "c", token: token, ticket: 2))
            var fresh = meta; fresh.reactions = []; fresh.pin = nil
            XCTAssertTrue(try ChatB1.apply(db, page: .init(asOfSeq: 25, items: [fresh]), channel: "c", token: token, tickets: ["m": 2]))
            XCTAssertTrue(try ChatB1.apply(db, page: .init(asOfSeq: 25, pins: []), channel: "c", token: token, ticket: 2))
            XCTAssertEqual(try ChatB1.metadata(db, id: "m"), fresh)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT data FROM b1_pins"), try ChatB1.encode([ChatB1.PinnedMessage]()))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dirty FROM b1_metadata"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dirty FROM b1_pins"), 0)
        }
    }

    func testReconnectCapabilityChangeStillClearsPrivateProjections() throws {
        let s = try store()
        let socket = ChatSocket(server: key.server, token: "test")
        let b1 = ChatB1Sync(key: key, store: s, api: ChatAPI(server: key.server), token: "test", socket: socket)
        defer { b1.stop() }
        b1.configure(ChatB1.capabilities)
        _ = try seed(s)
        try write(s) { db in
            try db.execute(sql: "INSERT INTO b1_pins (channel_id, data) VALUES ('c', ?)", arguments: [try ChatB1.encode([ChatB1.PinnedMessage]())])
        }
        b1.configure(ChatB1.capabilities.subtracting(["chat.reactions"]), reconnect: true)
        try read(s) { db in
            XCTAssertNil(try ChatB1.metadata(db, id: "m"))
            XCTAssertNil(try Data.fetchOne(db, sql: "SELECT data FROM b1_pins"))
        }
    }

    func testFirstConfigurationWithoutB1CannotKeepCacheFromEarlierCapabilities() throws {
        let s = try store()
        _ = try seed(s)
        try write(s) { db in
            try db.execute(sql: "INSERT INTO b1_pins (channel_id, data) VALUES ('c', ?)", arguments: [try ChatB1.encode([ChatB1.PinnedMessage]())])
        }
        let socket = ChatSocket(server: key.server, token: "test")
        let b1 = ChatB1Sync(key: key, store: s, api: ChatAPI(server: key.server), token: "test", socket: socket)
        defer { b1.stop() }
        b1.configure([])
        try read(s) { db in
            XCTAssertNil(try ChatB1.metadata(db, id: "m"))
            XCTAssertNil(try Data.fetchOne(db, sql: "SELECT data FROM b1_pins"))
        }
    }

    func testB1PointersCommitDurableDebtWithCursorAndDeduplicate() throws {
        let s = try store()
        _ = try seed(s)
        for (n, type) in ["reaction.changed", "pin.changed"].enumerated() {
            XCTAssertEqual(try s.apply(event(type, seq: 11 + n)), .applied)
            XCTAssertEqual(try s.apply(event(type, seq: 11 + n)), .duplicate)
        }
        XCTAssertEqual(try s.apply(event("thread.participation_changed", seq: 5, member: true)), .applied)
        let reopen = try ChatStore.open(files: ChatFiles(directory: directory), key: key).store
        try read(reopen) { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT invalidated FROM b1_metadata WHERE message_id = 'm'"), 12)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dirty FROM b1_metadata WHERE message_id = 'm'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT invalidated FROM b1_participation"), 5)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skipped_events"), 0)
        }
        XCTAssertEqual(try reopen.cursor("channel:c"), 12)
        XCTAssertEqual(try reopen.cursor("member:org:me"), 5)
    }
    func testFutureEventRetainsEntirePayload() throws {
        let s = try store()
        var e = event("future.widget")
        e = ChatEvent(stream: e.stream, seq: e.seq, id: e.id, type: e.type, actor: nil,
                      body: .object(["channel_id": .string("c"), "future": .array([.number(1), .object(["text": .string("retained")])])]), commandId: "cmd", at: "now")
        e.additionalFields = ["future_envelope": .object(["version": .number(2)]), "sig": .string("future-signature"), "enc": .null]
        XCTAssertEqual(try s.apply(e), .passedOver)
        let data = try read(s) { try XCTUnwrap(String.fetchOne($0, sql: "SELECT event_json FROM skipped_events")) }
        XCTAssertEqual(try JSONDecoder().decode(ChatEvent.self, from: Data(data.utf8)), e)
    }
    func testMetadataVersionRejectsOldReadsAndNeverAdvancesEventCursor() throws {
        let s = try store(), token = try seed(s, head: 20)
        XCTAssertEqual(try s.cursor("channel:c"), 10)
        try s.apply(event("reaction.changed", seq: 11))
        XCTAssertEqual(try read(s) { try Int.fetchOne($0, sql: "SELECT dirty FROM b1_metadata") }, 0, "old pointer is already covered")
        try write(s) { db in
            XCTAssertFalse(try ChatB1.apply(db, page: .init(asOfSeq: 19, items: [meta]), channel: "c", token: token, tickets: ["m": 0]))
            try ChatB1.invalidate(db, event: event("pin.changed", seq: 25))
            XCTAssertFalse(try ChatB1.apply(db, page: .init(asOfSeq: 24, items: [meta]), channel: "c", token: token, tickets: ["m": 0]))
            XCTAssertTrue(try ChatB1.apply(db, page: .init(asOfSeq: 25, items: [meta]), channel: "c", token: token, tickets: ["m": 1]))
            XCTAssertEqual(try ChatB1.metadata(db, id: "m")?.threadSummary?.replyCount, 205)
            XCTAssertEqual(try ChatB1.metadata(db, id: "m")?.threadSummary?.lastParticipants.count, 2)
        }
        XCTAssertEqual(try s.cursor("channel:c"), 11)
    }
    func testLateReadsCannotCrossWindowRightsGenerationOrCapabilityEpoch() throws {
        let s = try store()
        var token = try seed(s)
        try write(s) { db in
            try ChatMessages.applyWindow(db, channel: "c", head: 30, messages: [], before: nil)
            XCTAssertFalse(try ChatB1.apply(db, page: .init(asOfSeq: 99, items: [meta]), channel: "c", token: token, tickets: ["m": 0]))
            token = try XCTUnwrap(ChatB1.readToken(db, channel: "c"))
            try db.execute(sql: "UPDATE meta SET rights_in_doubt = 1")
            try db.execute(sql: "UPDATE meta SET rights_in_doubt = 0")
            XCTAssertFalse(try ChatB1.apply(db, page: .init(asOfSeq: 99, items: [meta]), channel: "c", token: token, tickets: ["m": 0]))
            token = try XCTUnwrap(ChatB1.readToken(db, channel: "c"))
            try ChatB1.reset(db)
            XCTAssertFalse(try ChatB1.apply(db, page: .init(asOfSeq: 99, items: [meta]), channel: "c", token: token, tickets: ["m": 0]))
        }
        try s.beginGeneration("g2")
        XCTAssertNil(try read(s) { try ChatB1.readToken($0, channel: "c") })
    }
    func testParticipationReplacesWholeSetAndDisablesLocalTriggersEvenAfterReopen() throws {
        let s = try store()
        try write(s) { db in
            try ChatMessages.write(db, message("old"))
            try ChatB1.setParticipation(db, enabled: true)
            let scope = try XCTUnwrap(ChatB1.readToken(db))
            let ticket = try XCTUnwrap(Int.fetchOne(db, sql: "SELECT ticket FROM b1_participation"))
            XCTAssertTrue(try ChatB1.applyThreads(db, items: [.init(channelId: "c", rootId: "ancient", firstMessageSeq: 2)], head: 8, token: scope, ticket: ticket))
            try ChatMessages.write(db, message("late-page"))
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT root_id FROM my_threads"), ["ancient"])
            try db.execute(sql: "UPDATE meta SET me = NULL")
        }
        let reopen = try ChatStore.open(files: ChatFiles(directory: directory), key: key).store
        XCTAssertEqual(try read(reopen) { try String.fetchAll($0, sql: "SELECT root_id FROM my_threads") }, ["ancient"])
        XCTAssertEqual(try reopen.cursor("member:org:me"), 4)
        try write(reopen) { db in
            let scope = try XCTUnwrap(ChatB1.readToken(db))
            try ChatB1.invalidate(db, event: event("thread.participation_changed", seq: 9, member: true))
            XCTAssertFalse(try ChatB1.applyThreads(db, items: [], head: 8, token: scope, ticket: 1))
            XCTAssertTrue(try ChatB1.applyThreads(db, items: [], head: 9, token: scope, ticket: 1))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dirty FROM b1_participation"), 1, "a newer invalidation retains debt")
            XCTAssertTrue(try String.fetchAll(db, sql: "SELECT root_id FROM my_threads").isEmpty)
            try ChatB1.setParticipation(db, enabled: false)
            XCTAssertEqual(try Set(String.fetchAll(db, sql: "SELECT root_id FROM my_threads")), ["old", "late-page"])
        }
    }
    func testParticipationRemovalRetractsReplyButRetainsMention() throws {
        let s = try store()
        try write(s) { db in
            try ChatB1.setParticipation(db, enabled: true)
            try db.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, thread_root_id, read) VALUES ('reply', 'reply', 'c', 'm', 0), ('mention', 'mention', 'c', 'm', 0)")
            let scope = try XCTUnwrap(ChatB1.readToken(db))
            _ = try ChatB1.applyThreads(db, items: [], head: 5, token: scope, ticket: 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT read FROM notified WHERE object_id = 'reply'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT withdrawn FROM notified WHERE object_id = 'reply'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT read FROM notified WHERE object_id = 'mention'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT withdrawn FROM notified WHERE object_id = 'mention'"), 0)
        }
    }
    func testServerModeReplyNeedsPointEligibilityAndStillChecksReadMuteDeleteAndDedup() throws {
        let s = try store()
        try write(s) { db in
            try ChatB1.setParticipation(db, enabled: true)
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 0, thread_read_seq = 0")
            try ChatMessages.write(db, message("reply", root: "unloaded", me: false, seq: 12))
            try db.execute(sql: "INSERT INTO my_threads (channel_id, root_id, first_message_seq) VALUES ('c', 'unloaded', 1)")
            XCTAssertNil(try ChatUnread.owe(db, messageId: "reply", me: "me"))
            XCTAssertNil(try ChatUnread.owe(db, messageId: "reply", me: "me", eligibleReply: false))
            try ChatUnread.setMuted(db, channel: "c", true)
            XCTAssertNil(try ChatUnread.owe(db, messageId: "reply", me: "me", eligibleReply: true))
            try ChatUnread.setMuted(db, channel: "c", false)
            XCTAssertEqual(try ChatUnread.owe(db, messageId: "reply", me: "me", eligibleReply: true), "reply")
            XCTAssertNil(try ChatUnread.owe(db, messageId: "reply", me: "me", eligibleReply: true))
            try ChatMessages.write(db, message("read", root: "unloaded", me: false, seq: 13))
            _ = try ChatUnread.markRead(db, channel: "c", upTo: 13, thread: "unloaded")
            XCTAssertNil(try ChatUnread.owe(db, messageId: "read", me: "me", eligibleReply: true))
        }
    }
    func testTombstoneClearsMetadataPinsDraftAndPendingCommandButKeepsReply() throws {
        let s = try store()
        _ = try seed(s)
        try write(s) { db in
            try ChatMessages.write(db, message())
            try ChatMessages.write(db, message("reply", root: "m", me: false, seq: 2))
            let draft = ChatChannelModel.Editing(messageId: "m", text: "unsaved", revision: 1,
                message: ChatMessage(row: try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM messages WHERE message_id = 'm'"))))
            try ChatEditDrafts.save(db, draft: draft, channel: "c")
            let record = ChatCommandRecord(commandId: "cmd", sessionId: "session", type: "message.pin.set", bodyBytes: Data(), orderKey: "pin", createdAt: Date(), state: .pending)
            try record.insert(db)
            try db.execute(sql: "INSERT INTO b1_intents VALUES ('cmd', 'c', 'm', 'pin', 1)")
            try db.execute(sql: "INSERT INTO b1_pins (channel_id, data) VALUES ('c', ?)", arguments: [try ChatB1.encode([ChatB1.PinnedMessage(messageId: "m", seq: 1, authorAccountId: "me", excerpt: "text", pinnedBy: "me", pinnedAt: "now")])])
        }
        try s.apply(event("message.delete"))
        try read(s) { db in
            XCTAssertEqual(try ChatB1.metadata(db, id: "m")?.reactions, [])
            XCTAssertNil(try ChatB1.metadata(db, id: "m")?.pin)
            XCTAssertEqual(try ChatB1.metadata(db, id: "m")?.threadSummary?.replyCount, 205)
            XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT data FROM b1_pins"), try ChatB1.encode([ChatB1.PinnedMessage]()))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_drafts"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM b1_intents"), 0)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM outbox"), "dropped")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE message_id = 'reply'"), 1)
        }
    }
    func testEditDraftSurvivesSnapshotGenerationTemporaryChannelLossAndRestart() async throws {
        let s = try store()
        try write(s) { try ChatMessages.write($0, message()) }
        let model = ChatChannelModel(key: key, channel: "c"); model.follow(s)
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("m")), root: nil))
        model.editing?.text = "my unsubmitted text"
        try write(s) { try ChatMessages.applyWindow($0, channel: "c", head: 100, messages: [message("new", seq: 100)], before: 100) }
        try s.beginGeneration("g2")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.editing?.text, "my unsubmitted text")
        let reopened = try ChatStore.open(files: ChatFiles(directory: directory), key: key).store
        let second = ChatChannelModel(key: key, channel: "c"); second.follow(reopened)
        XCTAssertEqual(second.editing?.text, "my unsubmitted text")
        XCTAssertEqual(second.editing?.revision, 1)
        try reopened.apply(.init(cursors: [:], teams: [.init(teamId: "t", name: "Team")],
                                 channels: [.init(channelId: "c", teamId: "t", name: "New", archived: false, version: 1, head: 1, messages: [message()])]), confirmsRights: "session")
        try reopened.finishGeneration("g2")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(second.editing?.text, "my unsubmitted text")
        second.cancelEditing()
        XCTAssertEqual(try read(reopened) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM edit_drafts") }, 0)
    }
    func testConfirmedTeamLossClearsDraftAcrossModels() async throws {
        let s = try store()
        try write(s) { try ChatMessages.write($0, message()) }
        let first = ChatChannelModel(key: key, channel: "c"); first.follow(s)
        XCTAssertTrue(first.beginEditing(try XCTUnwrap(first.message("m")), root: nil))
        first.editing?.text = "private draft"
        let second = ChatChannelModel(key: key, channel: "c"); second.follow(s)
        try write(s) { try ChatStore.leftTeam($0, "t") }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(first.editing); XCTAssertNil(second.editing)
        XCTAssertEqual(try read(s) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM edit_drafts") }, 0)
    }
    func testSharedEditTextPropagatesWithoutObservationCreatingAnotherVersion() async throws {
        let s = try store()
        try write(s) { try ChatMessages.write($0, message()) }
        let first = ChatChannelModel(key: key, channel: "c"); first.follow(s)
        XCTAssertTrue(first.beginEditing(try XCTUnwrap(first.message("m")), root: nil))
        let second = ChatChannelModel(key: key, channel: "c"); second.follow(s)
        second.editing?.text = "shared text from second tab"
        let version = try XCTUnwrap(second.editing?.version)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(first.editing?.text, second.editing?.text)
        XCTAssertEqual(first.editing?.version, version)
        XCTAssertEqual(try read(s) { try ChatEditDrafts.read($0, channel: "c").first?.version }, version)
        first.editing?.text = "next shared text"
        let nextVersion = try XCTUnwrap(first.editing?.version)
        XCTAssertNotEqual(nextVersion, version)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(second.editing?.text, "next shared text")
        XCTAssertEqual(second.editing?.version, nextVersion)
        second.cancelEditing()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(first.editing); XCTAssertNil(second.editing)
    }
    func testB1ReviewMigrationKeepsLegacyDraftAndNotificationReadState() throws {
        let s = try store()
        let draft = try write(s) { db in
            try ChatMessages.write(db, message())
            return ChatChannelModel.Editing(messageId: "m", text: "legacy unsaved text", revision: 1,
                message: ChatMessage(row: try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM messages WHERE message_id = 'm'"))))
        }
        let legacy = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(legacy, upTo: "release-17-b1")
        try legacy.write { db in
            try db.execute(sql: "INSERT INTO edit_drafts (message_id, channel_id, team_id, data, updated_at) VALUES ('m', 'c', 't', ?, 1)", arguments: [try JSONEncoder().encode(draft)])
            try db.execute(sql: "INSERT INTO notified (object_id, kind, read) VALUES ('unread', 'reply', 0), ('read', 'reply', 1)")
        }
        try ChatStoreMigrations.cache.migrate(legacy)
        try legacy.read { db in
            let migrated = try XCTUnwrap(ChatEditDrafts.read(db, channel: "c").first)
            XCTAssertEqual(migrated.text, draft.text)
            XCTAssertEqual(migrated.revision, draft.revision)
            XCTAssertFalse(try XCTUnwrap(migrated.version).isEmpty)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT read FROM notified WHERE object_id = 'unread'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT read FROM notified WHERE object_id = 'read'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT SUM(withdrawn) FROM notified"), 0)
        }
    }
    func testStaleCancelAndCancelAllKeepNewerSharedEditAndDoNotReuseVersions() async throws {
        let s = try store()
        try write(s) { try ChatMessages.write($0, message()) }
        for all in [false, true] {
            let first = ChatChannelModel(key: key, channel: "c"); first.follow(s)
            XCTAssertTrue(first.beginEditing(try XCTUnwrap(first.message("m")), root: nil))
            let second = ChatChannelModel(key: key, channel: "c"); second.follow(s)
            let old = try XCTUnwrap(first.editing)
            second.editing?.text = "newer text before observation"
            let newer = try XCTUnwrap(second.editing)
            // No suspension: first still holds the version before second typed.
            XCTAssertEqual(first.editing?.version, old.version)
            first.cancelEditing(all: all)
            XCTAssertEqual(try read(s) { try ChatEditDrafts.read($0, channel: "c").first?.text }, newer.text)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertEqual(first.editing?.text, newer.text)
            XCTAssertEqual(second.editing?.text, newer.text)
            second.cancelEditing()
            XCTAssertTrue(second.beginEditing(try XCTUnwrap(second.message("m")), root: nil))
            let reopened = try XCTUnwrap(second.editing)
            XCTAssertNotEqual(reopened.version, newer.version)
            try write(s) { db in
                XCTAssertFalse(try ChatEditDrafts.remove(db, message: "m", version: try XCTUnwrap(newer.version)))
            }
            second.cancelEditing()
        }
    }
    func testTypingAfterAnotherTabCancelsKeepsNewWorkButCannotUndoDeletion() async throws {
        let s = try store()
        try write(s) { try ChatMessages.write($0, message()) }
        let first = ChatChannelModel(key: key, channel: "c"); first.follow(s)
        XCTAssertTrue(first.beginEditing(try XCTUnwrap(first.message("m")), root: nil))
        let second = ChatChannelModel(key: key, channel: "c"); second.follow(s)
        let oldVersion = try XCTUnwrap(second.editing?.version)
        first.cancelEditing()
        // A real keystroke arrives before the cancellation observation.
        second.editing?.text = "new input after cancellation"
        XCTAssertNotEqual(second.editing?.version, oldVersion)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(second.editing?.text, "new input after cancellation")
        XCTAssertTrue(first.beginEditing(try XCTUnwrap(first.message("m")), root: nil))
        XCTAssertEqual(first.editing?.text, second.editing?.text)
        try s.apply(event("message.delete"))
        second.editing?.text = "late input after deletion"
        XCTAssertEqual(try read(s) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM edit_drafts") }, 0)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(first.editing); XCTAssertNil(second.editing)
        XCTAssertEqual(try read(s) { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM edit_drafts") }, 0)
    }
    func testEmojiUsesSharedExhaustiveFixtureAndPreservesIdentities() throws {
        XCTAssertGreaterThan(ChatEmoji.aliases.count, 4000)
        for (alias, canonical) in ChatEmoji.aliases { XCTAssertEqual(ChatEmoji.canonical(alias), canonical) }
        XCTAssertEqual(ChatEmoji.canonical("❤"), "❤️")
        for emoji in ["👍🏽", "👩‍💻", "🇳🇱"] { XCTAssertEqual(ChatEmoji.canonical(emoji), emoji) }
        for invalid in ["hello", "👍👍", "🏽", "", "https://image", "👍\u{200D}👍"] { XCTAssertNil(ChatEmoji.canonical(invalid)) }
        for type in ChatB1.commands { XCTAssertTrue(ChatOutbox.neverResent(type)); XCTAssertFalse(ChatOutbox.carriedOver.contains(type)) }
    }

    func testReactionIdentitiesAreUniqueWhenReadingServerAndLegacyCache() throws {
        let data = Data(#"{"message_id":"m","deleted":false,"reactions":[{"emoji":"❤","count":2,"mine":false},{"emoji":"👍🏽","count":1,"mine":false},{"emoji":"❤️","count":3,"mine":true},{"emoji":"❤️","count":3,"mine":true},{"emoji":"👍","count":1,"mine":false}],"pin":null}"#.utf8)
        let expected: [ChatB1.Reaction] = [
            .init(emoji: "❤️", count: 3, mine: true),
            .init(emoji: "👍🏽", count: 1, mine: false),
            .init(emoji: "👍", count: 1, mine: false),
        ]
        let decoded = try JSONDecoder().decode(ChatB1.Metadata.self, from: data)
        XCTAssertEqual(decoded.reactions, expected, "aliases share an identity; duplicate snapshots must not add their counts")
        let s = try store()
        try write(s) { db in
            try ChatB1.watch(db, channel: "c", ids: ["m"])
            // An already persisted 1.1.6 payload must be safe before any refresh.
            try db.execute(sql: "UPDATE b1_metadata SET data = ? WHERE message_id = 'm'", arguments: [data])
        }
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        let panel = ChatB1Channel(key: key, channel: "c", store: s, service: service)
        XCTAssertEqual(panel.state.metadata["m"]?.reactions, expected)
        XCTAssertEqual(try read(s) { try ChatB1.metadata($0, id: "m")?.reactions }, expected)
    }

    func testReactionMetadataDeduplicatesThreadParticipantsWithoutMergingAgents() throws {
        var item = meta
        let participants = try XCTUnwrap(item.threadSummary?.lastParticipants)
        item.threadSummary?.lastParticipants = participants + participants
        let decoded = try JSONDecoder().decode(ChatB1.Metadata.self, from: ChatB1.encode(item))
        XCTAssertEqual(decoded.threadSummary?.lastParticipants, participants)
    }

    func testPinsRejectOldReadAndEvictionPurgesRawUnknownContent() throws {
        let s = try store(), token = try seed(s)
        try s.apply(event("pin.changed"))
        try write(s) { db in
            XCTAssertFalse(try ChatB1.apply(db, page: .init(asOfSeq: 10, pins: []), channel: "c", token: token, ticket: 0))
            XCTAssertTrue(try ChatB1.apply(db, page: .init(asOfSeq: 11, pins: []), channel: "c", token: token, ticket: 1))
            try db.execute(sql: "UPDATE meta SET rights_in_doubt = 1")
            XCTAssertFalse(try ChatB1.apply(db, page: .init(asOfSeq: 99, pins: []), channel: "c", token: token, ticket: 1))
            try db.execute(sql: "UPDATE meta SET rights_in_doubt = 0")
        }
        try s.apply(event("future.pointer", seq: 12))
        try write(s) { db in
            try ChatStore.leftTeam(db, "t")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM skipped_events"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM b1_metadata"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM b1_pins"), 0)
        }
    }

    func testSnapshotMarkersPersistReloadBeforeHeadsAndInvalidateOldParticipationRead() throws {
        let s = try store()
        _ = try seed(s)
        let token = try write(s) { db in
            try ChatB1.setParticipation(db, enabled: true)
            return try XCTUnwrap(ChatB1.readToken(db))
        }
        try s.apply(.init(cursors: ["member:org:me": 80], channels: [.init(channelId: "c", teamId: "t", name: "New", archived: false, version: 1, chatMetadataReload: true)], threadParticipationReload: true))
        try write(s) { db in
            XCTAssertNil(try ChatB1.metadata(db, id: "m"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dirty FROM b1_metadata"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT dirty FROM b1_participation"), 1)
            XCTAssertFalse(try ChatB1.applyThreads(db, items: [.init(channelId: "c", rootId: "old", firstMessageSeq: 1)], head: 90, token: token, ticket: 1))
        }
        XCTAssertEqual(try s.cursor("member:org:me"), 80)
    }

    /// Native AppKit rendering, opt-in destination outside git. Normal tests stay in temp profiles.
    func testNativeB1Snapshots() async throws {
        guard let output = ProcessInfo.processInfo.environment["AGENTPAD_B1_CAPTURE"] else { throw XCTSkip("Native screenshots are opt-in") }
        _ = NSApplication.shared
        let s = try store()
        try write(s) { db in
            try ChatMessages.write(db, message())
            try ChatMessages.write(db, message("answer", root: "m", me: false, seq: 2))
        }
        _ = try seed(s)
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        service.serverCapabilities[key.server] = ChatB1.capabilities
        let model = ChatChannelModel(key: key, channel: "c"); model.service = service; model.follow(s)
        let b1 = try XCTUnwrap(model.b1)
        let members: [ChatOrgView.Member] = [.init(accountId: "me", handle: "andrew", name: "Andrew", role: "member"), .init(accountId: "other", handle: "marina", name: "Marina", role: "member")]
        let shownMessage = try XCTUnwrap(model.message("m"))
        let settings = AgentPadSettingsModel.shared
        let prior = (settings.appearanceMode, settings.lightTerminalThemeSelection, settings.darkTerminalThemeSelection)
        defer { settings.appearanceMode = prior.0; settings.lightTerminalThemeSelection = prior.1; settings.darkTerminalThemeSelection = prior.2 }
        settings.lightTerminalThemeSelection = AgentPadSettingsModel.defaultLightThemeSelection
        settings.darkTerminalThemeSelection = AgentPadSettingsModel.defaultDarkThemeSelection
        for dark in [false, true] {
            settings.appearanceMode = dark ? .dark : .light
            XCTAssertEqual(Theme.resolved.isLight, !dark)
            let content = VStack(alignment: .leading, spacing: 0) {
                HStack { Text("# New").font(Theme.display(16, weight: .semibold)); Spacer(); Image(systemName: "pin"); Image(systemName: "magnifyingglass") }.padding(24)
                Divider()
                ChatMessageRow(model: model, message: shownMessage, members: members, mentionable: [], me: "me", archived: false, replies: 205, selected: true)
                Divider().padding(.vertical, 18)
                ChatReactionPicker(b1: b1, message: "m")
                Spacer()
            }.frame(width: 740, height: 440).background(ChatAppearance.surface).foregroundStyle(Theme.chromeForeground)
                .environment(\.colorScheme, dark ? .dark : .light)
            try await capture(content, name: "\(output)/b1-client-\(dark ? "dark" : "light").png", size: NSSize(width: 740, height: 440), dark: dark)
        }
        try write(s) { db in
            try db.execute(sql: "INSERT INTO b1_pins (channel_id, data) VALUES ('c', ?)", arguments: [try ChatB1.encode([
                ChatB1.PinnedMessage(messageId: "answer", seq: 2, threadRootId: "m", authorAccountId: "other", excerpt: "The pinned reply opens in its thread and keeps your reading position.", pinnedBy: "me", pinnedAt: "2026-10-06T10:40:00Z")])])
        }
        try await Task.sleep(for: .milliseconds(80))
        try await capture(ChatPinnedMessages(b1: b1, model: model, members: members), name: "\(output)/b1-client-pins.png", size: NSSize(width: 392, height: 280), dark: true)
    }
    private func capture(_ content: some View, name: String, size: NSSize, dark: Bool) async throws {
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: name))
    }
}
