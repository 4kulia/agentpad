import AppKit
import GRDB
import XCTest
import SwiftUI
@testable import AgentPadKit

@MainActor
final class ChatUX2Tests: XCTestCase {
    private let channel = "3c4d5e6f-7a8b-4c9d-8e0f-1a2b3c4d5e6f"
    private let team = "6a1c9e2b-7d3f-4a5e-8b1c-2d3e4f5a6b7c"
    private let me = "8c2b3b55-6b1e-4f5e-9a39-0e3c1f7a2d40"
    private var directory: URL!
    private var scope: TeamServiceTestScope!
    private var key: ChatOrgKey {
        ChatOrgKey(server: try! ChatServerAddress(parsing: "https://chat.example.com"), accountId: me,
                   orgId: "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10")
    }
    override func setUp() async throws {
        scope = TeamServiceTestScope()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ux2-\(UUID())")
    }
    override func tearDown() async throws {
        scope.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func message(_ id: String, seq: Int = 1, author: String = "person", at: String = "2026-10-06T10:00:00Z",
                         root: String? = nil, agent: String? = nil, session: String? = nil) -> ChatMessage {
        ChatMessage(row: Row(["message_id": id, "channel_id": channel, "thread_root_id": root, "author_account_id": author,
            "seq": seq, "created_at": at, "has_fixed": true, "has_mutable": true, "text": "Message \(id)", "mentions": "[]", "revision": 1,
            "author_agent_id": agent, "author_session_name": session]))
    }
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!; return calendar
    }

    func testGroupingUsesActualAuthorConversationAndFiveMinuteWindow() {
        let a = message("a", seq: 1)
        let b = message("b", seq: 2, at: "2026-10-06T10:05:00Z")
        let c = message("c", seq: 3, at: "2026-10-06T10:10:01Z")
        XCTAssertEqual(ChatFeedLayout.rows([c, a, b], calendar: utc).map(\.startsGroup), [true, false, true])
        let identities = [message("human", seq: 1), message("agent1", seq: 2, agent: "a"),
                          message("agent2", seq: 3, agent: "b"), message("session1", seq: 4, session: "A"),
                          message("session2", seq: 5, session: "B"), message("other", seq: 6, author: "someone")]
        XCTAssertTrue(ChatFeedLayout.rows(identities, calendar: utc).allSatisfy(\.startsGroup))
        XCTAssertTrue(ChatFeedLayout.rows([a, message("reply", seq: 2, root: "root")], calendar: utc)[1].startsGroup)
    }

    func testDayUnreadAndDeletedRowsBreakGroupsWithoutChangingOrder() {
        let a = message("a", seq: 1, at: "2026-10-06T23:59:00Z")
        let b = message("b", seq: 2, at: "2026-10-07T00:01:00Z")
        let dated = ChatFeedLayout.rows([b, a], calendar: utc)
        XCTAssertEqual(dated.map(\.id), ["a", "b"])
        XCTAssertTrue(dated.allSatisfy { $0.date != nil && $0.startsGroup })
        var amsterdam = utc; amsterdam.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        XCTAssertFalse(ChatFeedLayout.rows([a, b], calendar: amsterdam)[1].startsGroup)
        let unread = ChatFeedLayout.rows([message("a"), message("b", seq: 2), message("c", seq: 3)], unreadID: "b", calendar: utc)
        XCTAssertEqual(unread.map(\.startsUnread), [false, true, false])
        XCTAssertEqual(unread.map(\.startsGroup), [true, true, false])
        var deleted = message("d", seq: 2); deleted.deletedAt = "now"; deleted.text = ""
        XCTAssertTrue(ChatFeedLayout.rows([message("a"), deleted, message("c", seq: 3)], calendar: utc).allSatisfy(\.startsGroup))
        var placeholder = deleted; placeholder.deletedAt = nil; placeholder.hasFixed = false
        XCTAssertTrue(ChatFeedLayout.rows([message("a"), placeholder, message("c", seq: 3)], calendar: utc).allSatisfy(\.startsGroup))
    }

    func testBotAndAvatarComeFromAttributionNotText() {
        var human = message("a"); human.text = "@bot BOT"; human.authorAgentName = "misleading name"
        XCTAssertFalse(ChatAuthorIdentity(human).isBot)
        XCTAssertTrue(ChatAuthorIdentity(message("b", session: "Terminal")).isBot)
        XCTAssertTrue(ChatAuthorIdentity(message("c", agent: "agent")).isBot)
        XCTAssertEqual(ChatAuthorIdentity.initials(" Марина  Иванова "), "МИ")
        XCTAssertEqual(ChatAuthorIdentity.initials("🐇 Rabbit"), "🐇R")
        let identity = ChatAuthorIdentity(human)
        human.text = "edited"; human.authorAgentName = "renamed"
        XCTAssertEqual(identity.colorIndex, ChatAuthorIdentity(human).colorIndex)
    }

    func testReplySummaryCountsOnlyKnownPostsAndDistinctIdentities() {
        var pending = message("pending"); pending.seq = nil; pending.localState = .sending
        var placeholder = message("unknown", seq: 5); placeholder.hasFixed = false
        let summary = ChatReplySummary(messages: [message("a", seq: 1, root: "r"), message("b", seq: 2, root: "r"),
            message("c", seq: 3, root: "r", agent: "one"), message("d", seq: 4, root: "r", agent: "two"), placeholder, pending], complete: true)
        XCTAssertEqual(summary.label, "5+ replies")
        XCTAssertEqual(summary.participants.map(\.id), ["a", "c", "d"])
        XCTAssertEqual(summary.latest?.id, "d")
        XCTAssertEqual(ChatReplySummary(messages: [message("a")], complete: true).label, "1 reply")
    }

    func testScrollingDoesNotFollowWhileReadingOrCountPrependedHistoryAsNew() {
        var position = ChatScrollPosition()
        XCTAssertTrue(position.update([message("a", seq: 10)]))
        position.measured(bottom: false, anchor: "a")
        XCTAssertFalse(position.update([message("older", seq: 1), message("a", seq: 10)]))
        XCTAssertTrue(position.unseen.isEmpty)
        XCTAssertFalse(position.update([message("older", seq: 1), message("a", seq: 10), message("new", seq: 11)]))
        XCTAssertEqual(position.unseen, ["new"])
        XCTAssertEqual(position.anchor, "a")
        position.measured(bottom: true, anchor: "new")
        XCTAssertTrue(position.unseen.isEmpty)
        XCTAssertTrue(position.update([message("new", seq: 11), message("next", seq: 12)]))
    }

    func testOnlyActiveVisibleBottomCanAdvanceReading() {
        for active in [true, false] { for shown in [true, false] { for bottom in [true, false] { for search in [true, false] {
            XCTAssertEqual(ChatScrollPosition.canMarkRead(appActive: active, shown: shown, atBottom: bottom, searching: search),
                           active && shown && bottom && !search)
        } } } }
    }

    func testNativeViewportHandlesBothCoordinateDirectionsAndReflow() {
        let document = CGRect(x: 0, y: 0, width: 400, height: 1000)
        let top = CGRect(x: 0, y: 0, width: 400, height: 400)
        let bottom = CGRect(x: 0, y: 600, width: 400, height: 400)
        XCTAssertTrue(ChatScrollGeometry.isAtBottom(document: document, visible: bottom, flipped: true))
        XCTAssertFalse(ChatScrollGeometry.isAtBottom(document: document, visible: top, flipped: true))
        XCTAssertTrue(ChatScrollGeometry.isAtBottom(document: document, visible: top, flipped: false))
        XCTAssertFalse(ChatScrollGeometry.isAtBottom(document: document, visible: bottom, flipped: false))
        XCTAssertFalse(ChatScrollGeometry.isAtBottom(document: CGRect(x: 0, y: 0, width: 400, height: 1200), visible: bottom, flipped: true))
        XCTAssertTrue(ChatScrollGeometry.isAtBottom(document: CGRect(x: 0, y: 0, width: 400, height: 100), visible: top, flipped: true))
    }

    func testKeyboardPreservesNewlinesIMEAndMentionPriority() {
        func action(_ key: UInt16, _ flags: NSEvent.ModifierFlags = [], text: String = "", menu: Bool = false, ime: Bool = false) -> ChatComposerKey {
            .action(code: key, modifiers: flags, markedText: ime, hasCandidates: menu, text: text, inThread: true)
        }
        XCTAssertEqual(action(36), .native)
        XCTAssertEqual(action(36, .command), .send)
        XCTAssertEqual(action(36, .command, menu: true), .send)
        XCTAssertEqual(action(36, .command, ime: true), .native)
        XCTAssertEqual(action(126), .editLast)
        XCTAssertEqual(action(126, text: " "), .native)
        XCTAssertEqual(action(126, menu: true), .previousCandidate)
        XCTAssertEqual(action(125, menu: true), .nextCandidate)
        XCTAssertEqual(action(48, menu: true), .chooseCandidate)
        XCTAssertEqual(action(36, menu: true), .chooseCandidate)
        XCTAssertEqual(action(53, menu: true), .dismissCandidates)
        XCTAssertEqual(action(53), .closeThread)
        XCTAssertEqual(action(126, .option), .native)
    }

    func testMessageKeyboardNavigationHasOneEntryAndStaysAtEdges() {
        XCTAssertNil(ChatFeedLayout.selection(moving: 1, in: [], from: nil))
        XCTAssertEqual(ChatFeedLayout.selection(moving: 1, in: ["a", "b"], from: nil), "a")
        XCTAssertEqual(ChatFeedLayout.selection(moving: -1, in: ["a", "b"], from: nil), "b")
        XCTAssertEqual(ChatFeedLayout.selection(moving: 1, in: ["a", "b"], from: "a"), "b")
        XCTAssertEqual(ChatFeedLayout.selection(moving: 1, in: ["a", "b"], from: "b"), "b")
        XCTAssertEqual(ChatFeedLayout.selection(moving: -1, in: ["a", "b"], from: "a"), "a")
    }

    func testMarkdownInsertionUsesUTF16SelectionAndParagraphs() {
        let text = "Hi 👩🏽‍💻 world"
        let selection = (text as NSString).range(of: "👩🏽‍💻")
        let edit = ChatMarkdownInsertion.bold.edit(text: text, selection: selection)
        XCTAssertEqual((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), "Hi **👩🏽‍💻** world")
        XCTAssertEqual(edit.selection.length, selection.length)
        let link = ChatMarkdownInsertion.link.edit(text: "site", selection: NSRange(location: 0, length: 4))
        XCTAssertEqual(link.replacement, "[site](https://)")
        XCTAssertEqual((link.replacement as NSString).substring(with: link.selection), "https://")
        let list = ChatMarkdownInsertion.list.edit(text: "one\ntwo\n", selection: NSRange(location: 0, length: 8))
        XCTAssertEqual(list.replacement, "- one\n- two\n")
        let code = ChatMarkdownInsertion.code.edit(text: "a\nb", selection: NSRange(location: 0, length: 3))
        XCTAssertEqual(code.replacement, "```\na\nb\n```")
    }

    func testAgentCardDistinguishesExecutionPublicationAndAllowedActions() {
        var status = ChatSourceStatus(id: "request", source: "source", agent: "Bot", state: "running", initiator: "person", owner: me)
        XCTAssertEqual(ChatSourcePresentation(status, me: me, connected: true).action, .stop)
        XCTAssertEqual(ChatSourcePresentation(status, me: "colleague", connected: true).action, .none)
        XCTAssertFalse(ChatSourcePresentation(status, me: me, connected: false).showsActivity)
        status.state = "finished"; status.publication = "awaiting_publish"
        XCTAssertFalse(ChatSourcePresentation(status, me: me, connected: true).answered)
        XCTAssertEqual(status.word, "finished · awaiting publication")
        status.publication = "published"
        XCTAssertTrue(ChatSourcePresentation(status, me: me, connected: true).answered)
        status.state = "awaiting_decision"; status.initiator = me
        XCTAssertEqual(ChatSourcePresentation(status, me: me, connected: true).action, .cancel)
        status.state = "failed"; status.error = "lost"
        XCTAssertEqual(ChatSourcePresentation(status, me: me, connected: true).tone, .failure)
        XCTAssertTrue(status.word.contains("lost"))
    }

    private func store() throws -> ChatStore {
        let store = try ChatStore.open(files: ChatFiles(directory: directory), key: key).store
        try store.queue.write { db in
            try db.execute(sql: "INSERT INTO teams (team_id, name, mine) VALUES (?, 'Team', 1)", arguments: [team])
            try db.execute(sql: "INSERT INTO channels (channel_id, team_id, name, archived, version, stamp, created_by, created_at) VALUES (?, ?, 'New', 0, 1, 1, ?, 'now')", arguments: [channel, team, me])
            try db.execute(sql: "INSERT INTO channel_windows (channel_id, epoch, bottom_seq, history_next) VALUES (?, 1, 0, NULL)", arguments: [channel])
            try db.execute(sql: "INSERT INTO read_marks (channel_id, last_read_seq) VALUES (?, 0)", arguments: [channel])
            try db.execute(sql: "UPDATE meta SET me = ?, rights_in_doubt = 0", arguments: [me])
        }
        return store
    }
    private func insert(_ message: ChatMessage, store: ChatStore, mention: Bool = false) throws {
        try store.queue.write { db in
            try db.execute(sql: """
                INSERT INTO messages (message_id, channel_id, thread_root_id, author_account_id, seq, created_at, has_fixed, has_mutable, text, mentions, revision)
                VALUES (?, ?, ?, ?, ?, ?, 1, 1, ?, ?, 1)
                """, arguments: [message.id, channel, message.threadRootId, message.authorAccountId, message.seq, message.createdAt,
                                  message.text, mention ? "[\"\(me)\"]" : "[]"])
        }
    }

    func testUnreadBoundaryIsFrozenAtEntryAndReportsEarlierUnloadedMessages() throws {
        let store = try store()
        for seq in 1...4 { try insert(message("m\(seq)", seq: seq), store: store) }
        try store.queue.write { try $0.execute(sql: "UPDATE read_marks SET last_read_seq = 2") }
        let model = ChatChannelModel(key: key, channel: channel); model.follow(store)
        XCTAssertEqual(model.feed.unreadID, "m3")
        model.markRead()
        XCTAssertEqual(model.entryReadSequence, 2)
        XCTAssertEqual(try store.queue.read { try ChatChannelModel.readFeed($0, channel: channel, shown: 50, unreadAfter: model.entryReadSequence).unreadID }, "m3")
        let limited = try store.queue.read { try ChatChannelModel.readFeed($0, channel: channel, shown: 1, unreadAfter: 2) }
        XCTAssertTrue(limited.earlierUnread); XCTAssertNil(limited.unreadID)
    }

    func testReadingChannelDoesNotReadHiddenThreadsAndThreadStopsAtVisibleSequence() throws {
        let store = try store()
        try insert(message("root", seq: 1), store: store)
        try insert(message("reply", seq: 2, root: "root"), store: store, mention: true)
        try insert(message("later", seq: 3, root: "root"), store: store, mention: true)
        try insert(message("tail", seq: 4), store: store)
        try store.queue.write { db in
            _ = try ChatUnread.owe(db, messageId: "reply", me: me)
            try ChatUnread.markRead(db, channel: channel, upTo: 4)
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 2)
            XCTAssertEqual(try ChatUnread.markRead(db, channel: channel, upTo: 2, thread: "root"), ["reply"])
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 1)
            try ChatUnread.markRead(db, channel: channel, upTo: 3, thread: "root")
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 0, "snapshot-only replies also become read")
        }
    }

    func testInitialThreadBaselineSurvivesRootReadsAndResetsWithGeneration() throws {
        let store = try store()
        try store.queue.write { db in
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = -1 WHERE channel_id = ?", arguments: [channel])
            try db.execute(sql: "UPDATE read_marks SET last_read_seq = 10 WHERE channel_id = ?", arguments: [channel])
        }
        try insert(message("old", seq: 5, root: "root"), store: store, mention: true)
        try insert(message("new", seq: 11, root: "root"), store: store, mention: true)
        try store.queue.write { db in
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 1)
            try ChatUnread.markRead(db, channel: channel, upTo: 20)
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 1)
            XCTAssertNil(try ChatUnread.owe(db, messageId: "old", me: me))
            XCTAssertEqual(try ChatUnread.owe(db, messageId: "new", me: me), "mention")
        }
    }

    func testChannelReadDoesNotReadAnEvictedThreadMention() throws {
        let store = try store()
        let reply = message("reply", seq: 2, root: "root")
        try insert(reply, store: store, mention: true)
        try store.queue.write { db in
            XCTAssertEqual(try ChatUnread.owe(db, messageId: "reply", me: me), "mention")
            try db.execute(sql: "DELETE FROM messages WHERE message_id = 'reply'")
            try ChatUnread.markRead(db, channel: channel, upTo: 10)
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT read FROM notified WHERE object_id = 'reply'"), false)
        }
        try insert(reply, store: store, mention: true)
        try store.queue.write { db in
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 1)
            XCTAssertEqual(try ChatUnread.markRead(db, channel: channel, upTo: 2, thread: "root"), ["reply"])
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 0)
        }
    }

    func testDraftsRemainSeparatedByThreadAndKeepVersionForSameText() throws {
        let store = try store()
        let model = ChatChannelModel(key: key, channel: channel); model.follow(store)
        model.saveDraft("channel draft", root: nil); let version = model.draftVersion(root: nil)
        model.saveDraft("reply draft", root: "root")
        model.saveDraft("channel draft", root: nil)
        XCTAssertEqual(model.draftVersion(root: nil), version)
        XCTAssertEqual(model.draft(root: nil), "channel draft")
        XCTAssertEqual(model.draft(root: "root"), "reply draft")
        model.saveDraft("edited draft", root: nil)
        XCTAssertNotEqual(model.draftVersion(root: nil), version)
        let reopened = ChatChannelModel(key: key, channel: channel)
        reopened.follow(try ChatStore.open(files: ChatFiles(directory: directory), key: key).store)
        XCTAssertEqual(reopened.draft(root: nil), "edited draft", "a release migration must never reset the user's cache")
        XCTAssertEqual(reopened.draft(root: "root"), "reply draft")
    }

    func testUpgradePreservesExistingReadBaseline() throws {
        let db = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(db, upTo: "release-13-ux1-review")
        try db.write {
            try $0.execute(sql: "INSERT INTO read_marks (channel_id, last_read_seq) VALUES ('c', 42)")
            try $0.execute(sql: "INSERT INTO messages (message_id, channel_id, thread_root_id, seq) VALUES ('reply', 'c', 'root', 43)")
            try $0.execute(sql: "INSERT INTO notified (object_id, kind, channel_id, seq) VALUES ('reply', 'mention', 'c', 43)")
        }
        try ChatStoreMigrations.cache.migrate(db)
        try db.read {
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT last_read_seq FROM read_marks WHERE channel_id = 'c'"), 42)
            XCTAssertEqual(try Int.fetchOne($0, sql: "SELECT thread_read_seq FROM read_marks WHERE channel_id = 'c'"), 42)
            XCTAssertEqual(try String.fetchOne($0, sql: "SELECT thread_root_id FROM notified WHERE object_id = 'reply'"), "root")
            XCTAssertEqual(try Bool.fetchOne($0, sql: "SELECT read FROM notified WHERE object_id = 'reply'"), false)
        }
    }

    func testDraftOptionsSurviveReopeningAndParticipateInTheVersion() throws {
        let store = try store()
        let model = ChatChannelModel(key: key, channel: channel); model.follow(store)
        model.saveDraft("@bot@me question", root: nil)
        let original = model.draftVersion(root: nil)
        model.saveDraft("@bot@me question", root: nil, mentionOnly: true, contextIds: ["context"])
        let saved = model.composerDraft(root: nil)
        XCTAssertTrue(saved.mentionOnly)
        XCTAssertEqual(saved.contextIds, ["context"])
        XCTAssertNotEqual(saved.version, original, "changing call consent invalidates another window's version")
        model.saveDraft("@bot@me question", root: nil)
        XCTAssertEqual(model.composerDraft(root: nil), saved)
        model.saveDraft("reply", root: "root", contextIds: ["reply-context"])
        let reopened = ChatChannelModel(key: key, channel: channel)
        reopened.follow(try ChatStore.open(files: ChatFiles(directory: directory), key: key).store)
        XCTAssertEqual(reopened.composerDraft(root: nil), saved)
        XCTAssertFalse(reopened.composerDraft(root: "root").mentionOnly)
        XCTAssertEqual(reopened.composerDraft(root: "root").contextIds, ["reply-context"])
        reopened.saveDraft(saved.text, root: nil, contextIds: ["another-context"])
        XCTAssertNotEqual(reopened.draftVersion(root: nil), saved.version)
        reopened.saveDraft("", root: nil)
        XCTAssertEqual(reopened.composerDraft(root: nil), ChatChannelModel.Draft())
        XCTAssertEqual(reopened.draft(root: "root"), "reply")
    }

    func testDraftOptionsMigrationPreservesTextAndVersion() throws {
        let db = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(db, upTo: "release-14-ux2-thread-read-floor")
        try db.write {
            try $0.execute(sql: "INSERT INTO drafts (channel_id, thread_root_id, text, updated_at, version) VALUES ('c', '', 'saved', 1, 'original')")
        }
        try ChatStoreMigrations.cache.migrate(db)
        try db.read {
            let row = try XCTUnwrap(Row.fetchOne($0, sql: "SELECT * FROM drafts"))
            XCTAssertEqual(row["text"] as String, "saved")
            XCTAssertEqual(row["version"] as String, "original")
            XCTAssertEqual(row["mention_only"] as Bool, false)
            XCTAssertEqual(row["context_ids"] as String, "[]")
        }
    }

    func testNavigationWithinCurrentThreadPreservesEditAndRevealsOlderReplies() throws {
        let store = try store()
        try insert(message("root", seq: 1), store: store)
        try insert(message("older", seq: 2, root: "root"), store: store)
        try insert(message("mine", seq: 10, author: me, root: "root"), store: store)
        try store.queue.write {
            try $0.execute(sql: "UPDATE channel_windows SET bottom_seq = 10")
            try $0.execute(sql: "INSERT INTO thread_cursors (channel_id, root_id, epoch, next, shown_from) VALUES (?, 'root', 1, 10, 10)", arguments: [channel])
        }
        let model = ChatChannelModel(key: key, channel: channel); model.follow(store); model.openThread("root")
        let older = try XCTUnwrap(model.message("older"))
        for viaLink in [false, true] {
            XCTAssertFalse(model.thread.contains { $0.id == "older" })
            XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("mine")), root: "root"))
            model.editing?.text = "unsaved 🐇"
            let edit = model.editing
            var position = ChatScrollPosition(); position.measured(bottom: false, anchor: "mine")
            model.positions["root"] = position
            model.setSearching(!viaLink)
            if viaLink { model.navigate(to: ChatMessageLink(key: key, message: older)) }
            else { model.navigate(to: older) }
            XCTAssertEqual(model.editing, edit)
            XCTAssertEqual(model.threadRoot, "root")
            XCTAssertTrue(model.thread.contains { $0.id == "older" })
            XCTAssertEqual(model.revealMessageID, "older")
            model.returnFromNavigation()
            XCTAssertEqual(model.editing, edit)
            XCTAssertEqual(model.positions["root"]?.anchor, "mine")
            model.cancelEditing()
        }
    }

    func testSearchToRootPreservesEditDraft() async throws { try await checkEditNavigation(target: "root", viaLink: false) }
    func testLinkToRootPreservesEditDraft() async throws { try await checkEditNavigation(target: "root", viaLink: true) }
    func testSearchToAnotherThreadPreservesEditDraft() async throws { try await checkEditNavigation(target: "elsewhere", viaLink: false) }
    func testLinkToAnotherThreadPreservesEditDraft() async throws { try await checkEditNavigation(target: "elsewhere", viaLink: true) }

    private func checkEditNavigation(target: String, viaLink: Bool) async throws {
        let store = try store()
        for item in [message("root"), message("another", seq: 2), message("mine", seq: 3, author: me, root: "root"),
                     message("elsewhere", seq: 4, root: "another")] { try insert(item, store: store) }
        for backToReading in [true, false] {
            try await store.queue.write { try $0.execute(sql: "UPDATE messages SET revision = 7 WHERE message_id = 'mine'") }
            let model = ChatChannelModel(key: key, channel: channel); model.follow(store); model.openThread("root")
            XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("mine")), root: "root"))
            model.editing?.text = "unsaved 🐇"; model.editing?.problem = "Keep the conflict explanation"
            model.setSearching(!viaLink)
            let destination = try XCTUnwrap(model.message(target))
            if viaLink { model.navigate(to: ChatMessageLink(key: key, message: destination)) }
            else { model.navigate(to: destination) }
            XCTAssertEqual(model.threadRoot, destination.threadRootId)
            XCTAssertNil(model.editing, "the hidden draft must not block editing in the destination")
            try await store.queue.write { try $0.execute(sql: "UPDATE messages SET revision = 8, text = 'remote' WHERE message_id = 'mine'") }
            try await Task.sleep(for: .milliseconds(30))
            if backToReading { model.returnFromNavigation() }
            else {
                let original = try XCTUnwrap(model.message("mine"))
                if viaLink { model.navigate(to: ChatMessageLink(key: key, message: original)) }
                else { model.navigate(to: original) }
            }
            let restored = try XCTUnwrap(model.editing)
            XCTAssertEqual(restored.messageId, "mine")
            XCTAssertEqual(restored.text, "unsaved 🐇")
            XCTAssertEqual(restored.revision, 7)
            XCTAssertEqual(restored.message.revision, 8)
            XCTAssertEqual(restored.problem, "Keep the conflict explanation")
        }
    }

    func testClosingOpeningAndSwitchingThreadsPreservesIndependentEditDrafts() throws {
        let store = try store()
        for item in [message("feed", author: me), message("root", seq: 2), message("another", seq: 3),
                     message("mine", seq: 4, author: me, root: "root"), message("second", seq: 5, author: me, root: "another")] {
            try insert(item, store: store)
        }
        let model = ChatChannelModel(key: key, channel: channel); model.follow(store)
        let conversations: [(String, String?)] = [("feed", nil), ("mine", "root"), ("second", "another")]
        for (id, root) in conversations {
            model.openThread(root)
            XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message(id)), root: root))
            model.editing?.text = "draft \(id)"
        }
        for (id, root) in conversations + conversations.reversed() {
            model.openThread(nil); model.openThread(root)
            XCTAssertEqual(model.editing?.messageId, id)
            XCTAssertEqual(model.editing?.text, "draft \(id)")
            XCTAssertEqual(model.editing?.revision, 1)
        }
    }

    func testThreadCloseReopenAndExplicitCancelKeepOtherDrafts() throws {
        let store = try store()
        for item in [message("root"), message("another", seq: 2), message("mine", seq: 3, author: me, root: "root"),
                     message("second", seq: 4, author: me, root: "another")] { try insert(item, store: store) }
        let model = ChatChannelModel(key: key, channel: channel); model.follow(store)
        for (id, root) in [("mine", "root"), ("second", "another")] {
            model.openThread(root)
            XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message(id)), root: root))
            model.editing?.text = "draft \(id)"
        }
        model.openThread(nil); XCTAssertNil(model.editing)
        model.openThread("root"); XCTAssertEqual(model.editing?.text, "draft mine")
        model.cancelEditing() // Cancel button's action.
        model.openThread(nil); model.openThread("root"); XCTAssertNil(model.editing)
        model.openThread("another"); XCTAssertEqual(model.editing?.text, "draft second")
        XCTAssertTrue(model.dismissTransient()) // Escape from the feed/composer.
        model.openThread(nil); model.openThread("another"); XCTAssertNil(model.editing)
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("second")), root: "another"))
        XCTAssertEqual(model.editing?.text, "Message second", "cancelled text is never resurrected")
    }

    func testNavigationToEditedRootAndBackRestoresItsOriginalArea() throws {
        let store = try store(); try insert(message("root", author: me), store: store)
        let model = ChatChannelModel(key: key, channel: channel); model.follow(store); model.openThread("root")
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("root")), root: "root"))
        model.editing?.text = "root draft"
        model.navigate(to: try XCTUnwrap(model.message("root")))
        XCTAssertNil(model.threadRoot); XCTAssertNil(model.editing?.root)
        XCTAssertEqual(model.editing?.text, "root draft")
        model.returnFromNavigation()
        XCTAssertEqual(model.editing?.root, "root")
        XCTAssertEqual(model.editing?.text, "root draft")
    }

    func testHiddenEditDraftsObserveDeletionAndAccessLoss() async throws {
        let store = try store()
        for item in [message("root"), message("another", seq: 2), message("mine", seq: 3, author: me, root: "root"),
                     message("second", seq: 4, author: me, root: "another")] { try insert(item, store: store) }
        let model = ChatChannelModel(key: key, channel: channel); model.follow(store)
        for (id, root) in [("mine", "root"), ("second", "another")] {
            model.openThread(root); XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message(id)), root: root))
            model.editing?.text = "draft \(id)"
        }
        try await store.queue.write { try $0.execute(sql: "UPDATE messages SET deleted_at = 'now' WHERE message_id = 'mine'") }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.editing?.text, "draft second", "deleting a hidden edit leaves the active one alone")
        model.openThread("root"); XCTAssertNil(model.editing)
        try await store.queue.write { try $0.execute(sql: "DELETE FROM channels") }
        try await Task.sleep(for: .milliseconds(30))
        model.openThread("another"); XCTAssertNil(model.editing)
    }

    func testSessionRebindKeepsHiddenEditDraftAndRevocationClearsIt() throws {
        let store = try store()
        try insert(message("root"), store: store); try insert(message("mine", seq: 2, author: me, root: "root"), store: store)
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        let card = ChatChannelCard(channelId: channel, teamId: team, name: "New", createdBy: me, archived: false, version: 1)
        let ready = ChannelTabState.ready(card, team: "Team", offline: true), session = ChatChannelSession()
        session.update(ready, key: key, store: store, service: service)
        let model = try XCTUnwrap(session.model); model.openThread("root")
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("mine")), root: "root"))
        model.editing?.text = "hidden draft"; model.openThread(nil)
        session.update(.checking, key: key, store: store, service: service)
        let reopened = try ChatStore.open(files: ChatFiles(directory: directory), key: key).store
        session.update(ready, key: key, store: reopened, service: service)
        XCTAssertTrue(session.model === model)
        model.openThread("root"); XCTAssertEqual(model.editing?.text, "hidden draft")
        XCTAssertEqual(model.editing?.revision, 1)
        model.openThread(nil)
        session.update(.noAccess, key: key, store: reopened, service: service)
        model.openThread("root"); XCTAssertNil(model.editing)
    }

    func testSearchIncludesCachedRepliesAndClearsRevokedOrDeletedContent() async throws {
        let store = try store()
        try insert(message("root"), store: store)
        try insert(message("reply", seq: 2, root: "root"), store: store)
        let model = ChatChannelModel(key: key, channel: channel); model.follow(store); model.setSearching(true)
        XCTAssertEqual(model.searchMessages.map(\.id), ["root", "reply"])
        model.navigate(to: try XCTUnwrap(model.message("reply")))
        XCTAssertEqual(model.threadRoot, "root"); XCTAssertEqual(model.revealMessageID, "reply")
        XCTAssertTrue(model.hasNavigationReturn)
        try await store.queue.write { try $0.execute(sql: "UPDATE messages SET text = '', deleted_at = 'now' WHERE message_id = 'reply'") }
        for _ in 0..<100 where model.searchMessages.count != 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.searchMessages.map(\.id), ["root"])
        try await store.queue.write { try $0.execute(sql: "DELETE FROM channels") }
        for _ in 0..<100 where !model.searchMessages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.searchMessages.isEmpty)
        model.returnFromNavigation()
        XCTAssertNil(model.threadRoot); XCTAssertFalse(model.searching)
    }

    func testMessageLinksValidateLocatorAndNeverSelectAnotherAccountOrServer() throws {
        let source = message("a1000000-0000-4000-8000-000000000001", seq: 3)
        let link = ChatMessageLink(key: key, message: source)
        let url = try XCTUnwrap(link.url)
        XCTAssertEqual(AgentPadDeepLink.parse(url), .chatMessage(link))
        XCTAssertEqual(MarkdownRenderer.chatLink(url.absoluteString), url)
        XCTAssertNil(MarkdownRenderer.chatLink("agentpad://resume?agent=codex&id=abc"))
        XCTAssertFalse(url.absoluteString.contains(me)); XCTAssertFalse(url.absoluteString.contains("Message"))
        let other = ChatOrgKey(server: try ChatServerAddress(parsing: "https://other.example.com"), accountId: me, orgId: key.orgId)
        XCTAssertFalse(link.matches(key: other, channel: channel))
        var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.queryItems?.append(URLQueryItem(name: "message", value: source.id))
        XCTAssertNil(ChatMessageLink(components: components))
    }

    func testMessageLinkTargetsOnlyItsTabEvenBeforeItBecomesVisible() throws {
        let link = ChatMessageLink(key: key, message: message("a1000000-0000-4000-8000-000000000001", seq: 3))
        let targetHost = NSView(), otherHost = NSView(), targetReader = NSView(), otherReader = NSView()
        targetHost.addSubview(targetReader); otherHost.addSubview(otherReader)
        targetHost.isHidden = true
        ChatMessageNavigation.request(link, key: key, destination: targetHost)
        XCTAssertNil(ChatMessageNavigation.take(key: key, channel: channel, from: otherReader))
        XCTAssertNil(ChatMessageNavigation.take(key: key, channel: channel, from: nil))
        let otherAccount = ChatOrgKey(server: key.server, accountId: "another", orgId: key.orgId)
        XCTAssertNil(ChatMessageNavigation.take(key: otherAccount, channel: channel, from: targetReader))
        XCTAssertEqual(ChatMessageNavigation.take(key: key, channel: channel, from: targetReader), link)
        XCTAssertNil(ChatMessageNavigation.take(key: key, channel: channel, from: targetReader), "a locator is handled once")
    }
}

extension ChatUX2Tests {
    private func rendered(_ host: NSView, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("UI did not finish mounting", file: file, line: line) }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testNarrowThreadNavigationShowsChannelTargetAndCanReturn() async throws {
        let store = try store()
        try insert(message("root"), store: store)
        try insert(message("target", seq: 2), store: store)
        try insert(message("reply", seq: 3, author: me, root: "root"), store: store)
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        let card = ChatChannelCard(channelId: channel, teamId: team, name: "New", createdBy: me, archived: false, version: 1)
        let session = ChatChannelSession()
        session.update(.ready(card, team: "Team", offline: true), key: key, store: store, service: service)
        let model = try XCTUnwrap(session.model)
        model.openThread("root")
        let host = NSHostingView(rootView: AnyView(ChatChannelView(card: card, team: "Team", offline: true, key: key, conversation: session)
            .frame(width: 700, height: 700)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func editors(_ view: NSView) -> [ChatMentionEditor.Editor] {
            (view as? ChatMentionEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("reply")), root: "root"))
        model.editing?.text = "native unsaved draft"
        try await Task.sleep(for: .milliseconds(100))
        for viaLink in [false, true] {
            XCTAssertNil(try XCTUnwrap(editors(host).first).navigationTarget)
            var position = ChatScrollPosition(); position.measured(bottom: false, anchor: "reply")
            model.positions["root"] = position
            model.setSearching(!viaLink)
            let target = try XCTUnwrap(model.message("target"))
            if viaLink { model.navigate(to: ChatMessageLink(key: key, message: target)) }
            else { model.navigate(to: target) }
            XCTAssertNil(model.threadRoot)
            XCTAssertNil(model.editing)
            XCTAssertEqual(model.revealMessageID, "target")
            XCTAssertTrue(model.hasNavigationReturn)
            try await rendered(host) { editors(host).first?.navigationTarget == ChannelRef(key, channel: channel) }
            XCTAssertEqual(editors(host).count, 1)
            XCTAssertEqual(editors(host).first?.navigationTarget, ChannelRef(key, channel: channel))
            model.returnFromNavigation()
            XCTAssertEqual(model.threadRoot, "root")
            XCTAssertEqual(model.positions["root"], position)
            XCTAssertEqual(model.focusedMessageID, "reply")
            XCTAssertFalse(model.hasNavigationReturn)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(editors(host).first { $0.accessibilityLabel() == "Edit message" }?.string, "native unsaved draft")
            XCTAssertEqual(model.editing?.revision, 1)
        }
        let inline = try XCTUnwrap(editors(host).first { $0.accessibilityLabel() == "Edit message" })
        XCTAssertEqual(inline.consume?(53, []), true)
        model.openThread(nil); model.openThread("root"); XCTAssertNil(model.editing)
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
    }

    func testNarrowSidebarMentionRestoresComposerAndKeepsThreadEdit() async throws {
        let store = try store()
        try insert(message("root"), store: store); try insert(message("reply", seq: 2, author: me, root: "root"), store: store)
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        let card = ChatChannelCard(channelId: channel, teamId: team, name: "New", createdBy: me, archived: false, version: 1)
        let session = ChatChannelSession()
        session.update(.ready(card, team: "Team", offline: true), key: key, store: store, service: service)
        let model = try XCTUnwrap(session.model)
        model.saveDraft("channel draft", root: nil, mentionOnly: true)
        model.openThread("root")
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("reply")), root: "root"))
        model.editing?.text = "thread edit"
        let org = ChatOrgModel(me: me) { _, _ in XCTFail("mention must not send a command"); return "unexpected" }
        org.key = key
        org.set(ChatOrgView(orgName: "Test", teams: [.init(teamId: team, name: "Team", isGeneral: true, archived: false, mine: true, members: [me])],
            channels: [card], channelsServed: true,
            channelAgents: [.init(channelId: channel, agentId: "agent", name: "reviewer", ownerAccountId: me, ownerHandle: "me",
                                  description: "", access: "read", enabled: true, available: true)], agentsServed: true))
        let host = NSHostingView(rootView: AnyView(ChatChannelView(card: card, team: "Team", offline: true, key: key, conversation: session)
            .frame(width: 700, height: 700)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func editors(_ view: NSView) -> [ChatMentionEditor.Editor] {
            (view as? ChatMentionEditor.Editor).map { [$0] } ?? view.subviews.flatMap(editors)
        }
        try await rendered(host) { editors(host).contains { $0.string == "thread edit" } }
        XCTAssertFalse(editors(host).contains { $0.navigationTarget != nil })
        XCTAssertTrue(ChatSidebarMention.request(agentID: "agent", ref: ChannelRef(key, channel: channel), window: window,
            destination: host, model: org, isActive: { true }, openChannel: { model.openThread(nil) }))
        try await rendered(host) { editors(host).contains { $0.string == "channel draft @reviewer@me " } }
        XCTAssertNil(model.threadRoot); XCTAssertNil(model.editing)
        XCTAssertEqual(model.draft(root: nil), "channel draft @reviewer@me ")
        XCTAssertTrue(model.composerDraft(root: nil).mentionOnly)
        XCTAssertTrue(window.firstResponder === editors(host).first { $0.navigationTarget != nil })
        model.openThread("root")
        try await rendered(host) { editors(host).contains { $0.string == "thread edit" } }
        XCTAssertEqual(model.editing?.revision, 1)
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
    }

    func testThreadStartsAtMockupWidthAndKeepsNativeResize() async throws {
        let store = try store()
        try insert(message("root", author: me), store: store)
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        let card = ChatChannelCard(channelId: channel, teamId: team, name: "New", createdBy: me, archived: false, version: 1)
        let session = ChatChannelSession()
        session.update(.ready(card, team: "Team", offline: true), key: key, store: store, service: service)
        let model = try XCTUnwrap(session.model)
        model.openThread("root")
        let content: (CGFloat) -> AnyView = { width in
            AnyView(ChatChannelView(card: card, team: "Team", offline: true, key: self.key, conversation: session)
                .frame(width: width, height: 700))
        }
        let host = NSHostingView(rootView: content(1112))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1112, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, type) }
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let split = try XCTUnwrap(descendants(host, NSSplitView.self).first)
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        XCTAssertEqual(split.arrangedSubviews.last?.frame.width ?? 0, 344, accuracy: 1)
        split.setPosition(split.bounds.width - 420 - split.dividerThickness, ofDividerAt: 0)
        model.saveDraft("kept while resizing", root: nil)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(split.arrangedSubviews.last?.frame.width ?? 0, 420, accuracy: 1)
        host.rootView = content(700); window.setContentSize(NSSize(width: 700, height: 700))
        try await Task.sleep(for: .milliseconds(100))
        let narrow = descendants(host, ChatMentionEditor.Editor.self)
        XCTAssertEqual(narrow.count, 1)
        XCTAssertNil(narrow.first?.navigationTarget, "narrow mode shows only the thread")
        model.openThread(nil)
        try await Task.sleep(for: .milliseconds(100))
        let main = descendants(host, ChatMentionEditor.Editor.self)
        XCTAssertEqual(main.count, 1)
        XCTAssertEqual(main.first?.navigationTarget, ChannelRef(key, channel: channel))
        XCTAssertEqual(model.draft(root: nil), "kept while resizing")
        host.rootView = AnyView(EmptyView()); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
    }

    private final class ViewportTransfer: @unchecked Sendable {
        var value: ChatScrollViewport?
        init(_ value: ChatScrollViewport) { self.value = value }
    }

    func testViewportCanBeReleasedAfterAsyncHandoff() async throws {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 500))
        var viewport: ChatScrollViewport? = ChatScrollViewport()
        viewport?.attach(scroll)
        weak let released = viewport
        let transfer = ViewportTransfer(try XCTUnwrap(viewport))
        viewport = nil
        await Task.detached { transfer.value = nil }.value
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(released, "notifications must not retain the viewport after its host disappears")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
    }

    func testRenderedComposersKeepSidebarAddressAndKeyboardScope() async throws {
        let store = try store()
        try insert(message("mine", author: me), store: store)
        let model = ChatChannelModel(key: key, channel: channel)
        model.service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        model.follow(store); model.openThread("mine")
        let content = HStack {
            ChatUX1Composer(model: model, root: nil, members: [], mentionable: [], agents: [])
            ChatUX1Composer(model: model, root: "mine", members: [], mentionable: [], agents: [])
        }.frame(width: 900, height: 300)
        let host = NSHostingView(rootView: AnyView(content))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        var editors: [ChatMentionEditor.Editor] = []
        func collect(_ view: NSView) {
            if let editor = view as? ChatMentionEditor.Editor { editors.append(editor) }
            for child in view.subviews { collect(child) }
        }
        collect(host)
        XCTAssertEqual(editors.count, 2)
        let main = try XCTUnwrap(editors.first { $0.navigationTarget == ChannelRef(key, channel: channel) })
        let reply = try XCTUnwrap(editors.first { $0.navigationTarget == nil })
        XCTAssertEqual(reply.accessibilityLabel(), "Reply in thread")
        XCTAssertEqual(main.consume?(36, []), false, "Return remains native text input")
        XCTAssertEqual(main.consume?(126, []), true)
        XCTAssertEqual(model.editing?.messageId, "mine"); XCTAssertNil(model.editing?.root)
        XCTAssertEqual(main.consume?(53, []), true); XCTAssertNil(model.editing)
        XCTAssertEqual(model.threadRoot, "mine", "first Escape cancels the edit")
        XCTAssertEqual(reply.consume?(53, []), true); XCTAssertNil(model.threadRoot)
        host.rootView = AnyView(EmptyView())
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
    }

    func testSidebarMentionsShareThreadReadSemantics() throws {
        let store = try store()
        try insert(message("root", seq: 1), store: store, mention: true)
        try insert(message("reply", seq: 2, root: "root"), store: store, mention: true)
        try insert(message("tail", seq: 3), store: store)
        try store.queue.write { db in
            XCTAssertEqual(try ChatUnread.unreadMentionsByChannel(db), [channel: 2])
            try ChatUnread.markRead(db, channel: channel, upTo: 3)
            XCTAssertEqual(try ChatUnread.unreadMentionsByChannel(db), [channel: 1])
            XCTAssertEqual(try ChatUnread.unreadMentions(db), 1)
            try ChatUnread.markRead(db, channel: channel, upTo: 2, thread: "root")
            XCTAssertEqual(try ChatUnread.unreadMentionsByChannel(db), [:])
        }
    }

    func testInlineKeyboardPreservesNativeInputAndIME() {
        XCTAssertEqual(ChatEditingKey.action(code: 36, modifiers: .command), .save)
        XCTAssertEqual(ChatEditingKey.action(code: 76, modifiers: .command), .save)
        XCTAssertEqual(ChatEditingKey.action(code: 36, modifiers: []), .native)
        XCTAssertEqual(ChatEditingKey.action(code: 36, modifiers: [.command, .shift]), .native)
        XCTAssertEqual(ChatEditingKey.action(code: 53, modifiers: []), .cancel)
        XCTAssertEqual(ChatEditingKey.action(code: 53, modifiers: .option), .native)
        XCTAssertEqual(ChatEditingKey.action(code: 36, modifiers: .command, markedText: true), .native)
        XCTAssertEqual(ChatEditingKey.action(code: 53, modifiers: [], markedText: true), .native)
    }

    func testAccessibilityAnnouncesResultsWithoutActivityChatter() {
        var sending = message("m"); sending.localState = .sending
        var delivered = sending; delivered.localState = nil
        XCTAssertEqual(ChatAccessibility.delivery(from: sending, to: delivered), "Message sent")
        var failed = sending; failed.localState = .failed; failed.localError = "forbidden"
        XCTAssertTrue(ChatAccessibility.delivery(from: sending, to: failed)?.contains("not sent") == true)
        XCTAssertNil(ChatAccessibility.delivery(from: delivered, to: delivered))
        let running = ChatSourceStatus(id: "req", source: "m", agent: "reviewer", state: "running")
        XCTAssertNil(ChatAccessibility.agent(from: running, to: running))
        var finished = running; finished.state = "finished"; finished.publication = "awaiting_publish"
        XCTAssertTrue(ChatAccessibility.agent(from: running, to: finished)?.contains("awaiting publication") == true)
        var published = finished; published.publication = "published"
        XCTAssertTrue(ChatAccessibility.agent(from: finished, to: published)?.contains("answered") == true)
        XCTAssertEqual(ChatMentionCandidate(id: "a", address: "reviewer@me", label: "Reviewer", agentId: "a").accessibilityName,
                       "Reviewer, BOT agent, @reviewer@me")
    }

    func testTabSessionKeepsCheckingStateAndSeparatesOtherStores() throws {
        let store = try store()
        try insert(message("mine", author: me), store: store)
        let service = ChatService(files: ChatFiles(directory: directory), tokens: FakeTokenStore())
        let card = ChatChannelCard(channelId: channel, teamId: team, name: "New", createdBy: me, archived: false, version: 1)
        let ready = ChannelTabState.ready(card, team: "Team", offline: false)
        let first = ChatChannelSession(), second = ChatChannelSession()
        first.update(ready, key: key, store: store, service: service)
        second.update(ready, key: key, store: store, service: service)
        let model = try XCTUnwrap(first.model)
        XCTAssertTrue(model.beginEditing(try XCTUnwrap(model.message("mine")), root: nil))
        model.editing?.text = "edit draft"
        model.focusRequest = ChatFocusRequest(area: .composer)
        first.update(.checking, key: key, store: store, service: service)
        first.update(ready, key: key, store: store, service: service)
        XCTAssertTrue(first.model === model)
        XCTAssertEqual(first.model?.editing?.text, "edit draft")
        XCTAssertNil(second.model?.editing)
        XCTAssertNil(second.model?.focusRequest)
        first.update(.notConnected, key: nil, store: nil, service: service)
        XCTAssertNil(first.model); XCTAssertNil(model.editing)
        XCTAssertNotNil(second.model)
    }
}
