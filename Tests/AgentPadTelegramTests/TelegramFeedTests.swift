import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramFeedHarness {
    let fixture = try! TelegramFixture()
    let client = FakeTDLibClient()
    let observations = TelegramPresentationObservations()
    let epoch = UUID(), pane = UUID()
    let id = TelegramChatID(environment: .test, account: 101, chat: 202)
    let now = Date(timeIntervalSince1970: 10000)
    let journal: TelegramSendJournal
    let session: TelegramFeedSession
    var feed: TelegramFeedSession.Feed { session.feeds[id]! }
    init() throws {
        client.automaticForms = false
        journal = try TelegramSendJournal(directory: fixture.directory, databaseKey: Data(repeating: 7, count: 32), now: now)
        session = TelegramFeedSession(account: id.account, environment: id.environment, epoch: epoch, journal: journal, send: { [client] in try client.send($0) })
        session.now = now; session.uptime = 10; session.network = .ready; session.active = true; session.online = true
        _ = session.subscribe(id, pane: pane)
        session.applyChat(chat(), to: feed); feed.peer = user()
        session.rememberUser(user()); session.capabilities(feed); feed.needsDetails = false; feed.loaded = true
    }
    func chat(type: TDLibValue? = nil) -> TDLibMessage {
        TDLibMessage("chat", ["id": .integer(id.chat), "title": .string("Synthetic chat"),
            "type": type ?? .typed("chatTypePrivate", ["user_id": .integer(202)]),
            "permissions": .typed("chatPermissions", ["can_send_basic_messages": .bool(true), "can_send_photos": .bool(true), "can_send_documents": .bool(true)]),
            "last_read_inbox_message_id": .integer(0), "last_read_outbox_message_id": .integer(0)])
    }
    func user(type: String = "userTypeRegular") -> TDLibMessage {
        TDLibMessage("user", ["id": .integer(202), "first_name": .string("Casey"), "have_access": .bool(true), "paid_message_star_count": .integer(0), "type": .typed(type)])
    }
    func message(_ id: Int64, text: String = "hello", outgoing: Bool = false, state: TDLibValue = .null, reply: Int64? = nil) -> TDLibMessage {
        TDLibMessage("message", ["id": .integer(id), "chat_id": .integer(self.id.chat), "sender_id": .typed("messageSenderUser", ["user_id": .integer(outgoing ? 101 : 202)]),
            "date": .integer(9000), "is_outgoing": .bool(outgoing), "can_be_saved": .bool(true), "sending_state": state,
            "topic_id": .null, "reply_to": reply.map { .typed("messageReplyToMessage", ["chat_id": .integer(self.id.chat), "message_id": .integer($0)]) } ?? .null,
            "content": .typed("messageText", ["text": .typed("formattedText", ["text": .string(text), "entities": .array([])])])])
    }
    @discardableResult func answer(_ method: String, _ response: TDLibMessage = TDLibMessage("ok"), beforeResponse: (() -> Void)? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> TDLibMessage {
        let request = try XCTUnwrap(client.requests.last { $0.type == method && $0["@extra"]?.string.map { session.calls[$0] != nil } == true }, file: file, line: line)
        let messages = client.replyMessages(request, response)
        for update in messages.dropLast() { session.receive(update, now: session.now, uptime: session.uptime) }
        beforeResponse?()
        session.receive(messages.last!, now: session.now, uptime: session.uptime)
        return request
    }
    func refresh() throws { try answer("getChat", chat()); try answer("getUser", user()) }
    func update(_ type: String, _ fields: [String: TDLibValue]) {
        let update = TDLibMessage(type, fields)
        TelegramFixtureSchema.check(update)
        session.receive(update, now: session.now, uptime: session.uptime)
    }
    func observe(_ id: TelegramChatID, _ value: TelegramPresentationObservation) { session.observation(id, observations.record(value)) }
    func send(_ text: String = "A private draft", reply: Int64? = nil) throws -> TDLibMessage {
        let draft = TelegramDraft(text: text, replyTo: reply)
        session.draft(id, epoch: epoch, value: draft)
        session.sendDraft(id, epoch: epoch, revision: draft.revision)
        try refresh()
        if let reply { try answer("getMessage", message(reply)); try answer("getMessageProperties", TDLibMessage("messageProperties", ["can_be_replied": .bool(true)])) }
        return try XCTUnwrap(client.requests.last { $0.type == "sendMessage" })
    }
}

final class TelegramFeedTests: XCTestCase {
    func testFloodWaitIsSharedWithAccountSchedulerAndNeverReplaysSend() throws {
        let h = try TelegramFeedHarness()
        var accountPause = Date.distantPast
        h.session.accountRetryAt = { accountPause }
        h.session.onFloodWait = { accountPause = $0 }
        _ = try h.send()
        try h.answer("sendMessage", TDLibMessage("error", ["code": .integer(429), "message": .string("Too Many Requests: retry after 12")]))
        XCTAssertGreaterThanOrEqual(accountPause.timeIntervalSince(h.now), 12)
        XCTAssertFalse(h.session.request("getChatHistory"))
        accountPause = h.now.addingTimeInterval(60) // a later chat-list wait also gates the feed
        h.session.tick(now: h.now.addingTimeInterval(20), uptime: 30)
        XCTAssertFalse(h.session.request("getChatHistory"))
        XCTAssertEqual(h.client.requests.filter { $0.type == "sendMessage" }.count, 1)
    }
    func testLateCacheOptionAckCannotOverrideNewLimit() throws {
        let h = try TelegramFeedHarness()
        h.session.configureCache()
        let original = try XCTUnwrap(h.client.requests.first { $0["name"]?.string == "storage_max_files_size" })
        XCTAssertEqual(original["value"]?.object?["value"], .integer(512 * 1024)) // TDLib uses KiB
        h.session.setCacheLimit(128)
        h.update("ok", ["@extra": original["@extra"]!])
        h.session.configureCache()
        XCTAssertEqual(h.client.requests.last { $0["name"]?.string == "storage_max_files_size" }?["value"]?.object?["value"], .integer(128 * 1024))
    }
    func testIncomingChatSenderIsDistinctFromUserAndHasPresence() throws {
        let h = try TelegramFeedHarness()
        h.session.chatNameLookup = { _ in "Group identity" }
        var message = h.message(10)
        message["sender_id"] = .typed("messageSenderChat", ["chat_id": .integer(202)])
        h.session.merge(message, into: h.feed)
        XCTAssertEqual(h.feed.snapshot.messages.first?.senderChatID, 202)
        XCTAssertEqual(h.feed.snapshot.messages.first?.author, "Synthetic chat")
        h.update("updateChatAction", ["chat_id": .integer(202), "topic_id": .null, "sender_id": message["sender_id"]!, "action": .typed("chatActionTyping")])
        h.update("updateChatAction", ["chat_id": .integer(202), "topic_id": .null, "sender_id": .typed("messageSenderUser", ["user_id": .integer(202)]), "action": .typed("chatActionUploadingDocument")])
        XCTAssertEqual(h.feed.actions.count, 2)
        XCTAssertTrue(h.session.presence(h.feed, live: true).contains("Synthetic chat typing"))
        h.update("updateChatAction", ["chat_id": .integer(202), "topic_id": .null, "sender_id": message["sender_id"]!, "action": .typed("chatActionCancel")])
        XCTAssertEqual(h.feed.actions.count, 1)
    }
    func testChangedSenderOutcomeRemainsUnknownInPresentedRow() throws {
        let h = try TelegramFeedHarness(); _ = try h.send()
        try h.answer("sendMessage", h.message(91, outgoing: true, state: .typed("messageSendingStatePending")))
        var final = h.message(100, outgoing: true)
        final["sender_id"] = .typed("messageSenderChat", ["chat_id": .integer(-303)])
        h.update("updateMessageSendSucceeded", ["old_message_id": .integer(91), "message": .object(final.fields)])
        XCTAssertEqual(h.journal.operations.first?.parts.first?.state, .unknown)
        XCTAssertEqual(h.feed.snapshot.messages.last?.delivery, .unknown)
    }
    func testPrivateForwardRemainsReplyableButDiscussionRootDoesNot() throws {
        let h = try TelegramFeedHarness()
        var target = h.message(10)
        target["forward_info"] = .typed("messageForwardInfo", ["origin": .typed("messageOriginChannel", ["chat_id": .integer(-303)]), "source": .null])
        var allowed: Bool?
        h.session.validateReply(10, feed: h.feed) { allowed = $0 }
        try h.answer("getMessage", target)
        try h.answer("getMessageProperties", TDLibMessage("messageProperties", ["can_be_replied": .bool(true)]))
        XCTAssertEqual(allowed, true)
        h.feed.snapshot.kind = .supergroup
        target["forward_info"] = .typed("messageForwardInfo", ["origin": .typed("messageOriginChannel"), "source": .typed("forwardSource", ["chat_id": .integer(-303)])])
        h.session.validateReply(10, feed: h.feed) { allowed = $0 }
        try h.answer("getMessage", target)
        XCTAssertEqual(allowed, false)
    }
    func testScopeAndSenderFailClosedAndGroupRestrictionsApply() throws {
        let h = try TelegramFeedHarness()
        XCTAssertNil(h.feed.chat?["message_sender_id"]) // pinned JSON omits a fixed private sender
        XCTAssertTrue(h.feed.snapshot.capabilities.canSend)
        h.feed.chat?["message_sender_id"] = .typed("messageSenderChat", ["chat_id": .integer(-777)])
        h.session.capabilities(h.feed); XCTAssertFalse(h.feed.snapshot.capabilities.canSend)
        for type in ["userTypeUnknown", "userTypeDeleted"] {
            h.feed.peer = h.user(type: type); h.session.capabilities(h.feed); XCTAssertFalse(h.feed.snapshot.capabilities.canRead)
        }
        h.session.applyChat(h.chat(type: .typed("chatTypeSupergroup", ["supergroup_id": .integer(303), "is_channel": .bool(false)])), to: h.feed)
        h.feed.peer = TDLibMessage("supergroup", ["id": .integer(303), "status": .typed("chatMemberStatusMember")])
        h.feed.fullInfo = TDLibMessage("supergroupFullInfo")
        h.session.capabilities(h.feed); XCTAssertTrue(h.feed.snapshot.capabilities.canSend)
        for field in ["is_channel", "is_forum", "is_direct_messages_group"] {
            h.feed.peer?[field] = .bool(true); h.session.capabilities(h.feed)
            XCTAssertEqual(h.feed.snapshot.capabilities.canRead, field != "is_direct_messages_group"); XCTAssertFalse(h.feed.snapshot.capabilities.canSend)
            h.feed.peer?[field] = .bool(false)
        }
        h.feed.peer?["status"] = .typed("chatMemberStatusRestricted", ["is_member": .bool(true), "permissions": .typed("chatPermissions", ["can_send_basic_messages": .bool(false)])])
        h.session.capabilities(h.feed); XCTAssertTrue(h.feed.snapshot.capabilities.canRead); XCTAssertFalse(h.feed.snapshot.capabilities.canSend)
        h.feed.peer?["status"] = .typed("chatMemberStatusLeft"); h.session.capabilities(h.feed); XCTAssertFalse(h.feed.snapshot.capabilities.canRead)
    }
    func testOmittedPrivateSenderAllowsTextReplyFilesAndSavedMessages() throws {
        let h = try TelegramFeedHarness()
        XCTAssertNil(h.chat()["message_sender_id"])
        XCTAssertTrue(h.feed.snapshot.capabilities.canSendPhotos)
        XCTAssertTrue(h.feed.snapshot.capabilities.canSendDocuments)
        let request = try h.send("Private reply", reply: 10)
        XCTAssertEqual(request["reply_to"]?.object?["message_id"], .integer(10))
        XCTAssertEqual(request["input_message_content"]?.object?["text"]?.object?["text"], .string("Private reply"))
        for sender: TDLibValue in [.typed("messageSenderUser", ["user_id": .integer(999)]),
                                   .typed("messageSenderChat", ["chat_id": .integer(202)])] {
            h.feed.chat?["message_sender_id"] = sender
            h.session.capabilities(h.feed)
            XCTAssertFalse(h.feed.snapshot.capabilities.canSend)
        }
        // A null object is omitted on updates as well as getChat responses.
        h.update("updateChatMessageSender", ["chat_id": .integer(202)])
        XCTAssertTrue(h.feed.snapshot.capabilities.canSend)
        h.feed.chat?["type"] = .typed("chatTypePrivate", ["user_id": .integer(101)])
        h.feed.peer?["id"] = .integer(101)
        h.session.capabilities(h.feed)
        XCTAssertEqual(h.feed.snapshot.kind, .savedMessages)
        XCTAssertTrue(h.feed.snapshot.capabilities.canSend)
    }
    func testOmittedGroupSenderAllowsRepliesAndFilesSubjectToPermissionsAndMembership() throws {
        for basic in [true, false] {
            let h = try TelegramFeedHarness()
            let chat = h.chat(type: basic
                ? .typed("chatTypeBasicGroup", ["basic_group_id": .integer(303)])
                : .typed("chatTypeSupergroup", ["supergroup_id": .integer(303), "is_channel": .bool(false)]))
            var peer = TDLibMessage(basic ? "basicGroup" : "supergroup", ["id": .integer(303),
                "status": .typed("chatMemberStatusMember")])
            if basic { peer["is_active"] = .bool(true) }
            h.session.applyChat(chat, to: h.feed); h.feed.peer = peer
            h.feed.fullInfo = basic ? nil : TDLibMessage("supergroupFullInfo")
            h.session.capabilities(h.feed)
            XCTAssertNil(chat["message_sender_id"])
            XCTAssertEqual(h.feed.snapshot.kind, basic ? .group : .supergroup)
            XCTAssertEqual(h.feed.snapshot.capabilities.sender, "You")
            XCTAssertTrue(h.feed.snapshot.capabilities.canSend)
            XCTAssertTrue(h.feed.snapshot.capabilities.canSendPhotos)
            XCTAssertTrue(h.feed.snapshot.capabilities.canSendDocuments)

            let file = try h.session.stage(h.id, epoch: h.epoch, data: Data("notes".utf8), name: "notes.txt", mime: "text/plain", width: 0, height: 0)
            let draft = TelegramDraft(text: "Group reply", replyTo: 10, attachments: [file])
            h.session.draft(h.id, epoch: h.epoch, value: draft)
            h.session.sendDraft(h.id, epoch: h.epoch, draft: draft)
            try h.answer("getChat", chat); try h.answer(basic ? "getBasicGroup" : "getSupergroup", peer)
            if !basic { try h.answer("getSupergroupFullInfo", TDLibMessage("supergroupFullInfo")) }
            try h.answer("getMessage", h.message(10))
            try h.answer("getMessageProperties", TDLibMessage("messageProperties", ["can_be_replied": .bool(true)]))
            let sent = try XCTUnwrap(h.client.requests.last { $0.type == "sendMessage" })
            XCTAssertEqual(sent["reply_to"]?.object?["message_id"], .integer(10))
            XCTAssertEqual(sent["input_message_content"]?.object?.type, "inputMessageDocument")
            XCTAssertEqual(sent["input_message_content"]?.object?["caption"]?.object?["text"], .string("Group reply"))

            for field in ["can_send_basic_messages", "can_send_photos", "can_send_documents"] {
                var permissions = try XCTUnwrap(chat["permissions"]?.object)
                permissions[field] = .bool(false)
                h.feed.chat?["permissions"] = .object(permissions.fields)
                h.session.capabilities(h.feed)
                XCTAssertEqual(h.feed.snapshot.capabilities.canSend, field != "can_send_basic_messages")
                XCTAssertEqual(h.feed.snapshot.capabilities.canSendPhotos, field != "can_send_photos")
                XCTAssertEqual(h.feed.snapshot.capabilities.canSendDocuments, field != "can_send_documents")
            }
            h.feed.chat?["permissions"] = chat["permissions"]
            for status: TDLibValue in [.typed("chatMemberStatusLeft"), .typed("chatMemberStatusBanned"),
                .typed("chatMemberStatusRestricted", ["is_member": .bool(true), "permissions": .typed("chatPermissions", [
                    "can_send_basic_messages": .bool(false), "can_send_photos": .bool(false), "can_send_documents": .bool(false)])]),
                .typed("chatMemberStatusAdministrator", ["rights": .typed("chatAdministratorRights", ["is_anonymous": .bool(true)])])] {
                h.feed.peer?["status"] = status; h.session.capabilities(h.feed)
                XCTAssertFalse(h.feed.snapshot.capabilities.canSend)
                XCTAssertFalse(h.feed.snapshot.capabilities.canSendPhotos)
                XCTAssertFalse(h.feed.snapshot.capabilities.canSendDocuments)
            }
            h.feed.peer = peer
            if basic { h.feed.peer?["is_active"] = .bool(false) }
            else { h.feed.fullInfo = nil }
            h.session.capabilities(h.feed)
            XCTAssertFalse(h.feed.snapshot.capabilities.canSend)
        }
    }
    func testHistoryDedupShortPagesCursorAndCaps() throws {
        let h = try TelegramFeedHarness()
        h.session.load(h.feed, latest: true)
        let first = try h.answer("getChatHistory", TDLibMessage("messages", ["messages": .array([.object(h.message(30).fields), .object(h.message(20).fields)])]))
        XCTAssertEqual(first["limit"], .integer(50)); XCTAssertEqual(first["from_message_id"], .integer(0))
        XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [20, 30]); XCTAssertTrue(h.feed.snapshot.hasOlder)
        h.session.load(h.feed, latest: false)
        let second = try h.answer("getChatHistory", TDLibMessage("messages", ["messages": .array([.object(h.message(20).fields), .object(h.message(10).fields)])]))
        XCTAssertEqual(second["from_message_id"], .integer(20))
        XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [10, 20, 30])
        h.session.load(h.feed, latest: false); try h.answer("getChatHistory", TDLibMessage("messages", ["messages": .array([])]))
        XCTAssertFalse(h.feed.snapshot.hasOlder)
        for n in 1...600 { h.session.merge(h.message(Int64(n)), into: h.feed) }
        h.session.trim(h.feed, keepOlder: true)
        XCTAssertEqual(h.feed.snapshot.messages.count, 500); XCTAssertTrue(h.feed.snapshot.hasNewer)
    }
    func testOversizedPageRetriesSameCursorWithoutEpochChange() throws {
        let h = try TelegramFeedHarness(); h.feed.historyCursor = 200
        h.session.load(h.feed, latest: false)
        try h.answer("getChatHistory", TDLibMessage("error", ["message": .string("page_too_large")]))
        let request = try XCTUnwrap(h.client.requests.last)
        XCTAssertEqual(request["from_message_id"], .integer(200)); XCTAssertEqual(request["limit"], .integer(25))
        XCTAssertEqual(h.session.epoch, h.epoch)
    }
    func testReadRegistryUsesExactIDsAndWaitsForUpdates() throws {
        let h = try TelegramFeedHarness(), secondPane = UUID()
        _ = h.session.subscribe(h.id, pane: secondPane)
        h.session.merge(h.message(10), into: h.feed); h.session.merge(h.message(20, outgoing: true), into: h.feed)
        XCTAssertFalse(h.client.requests.contains { $0.type == "openChat" || $0.type == "viewMessages" })
        h.observe(h.id, .init(pane: h.pane, epoch: h.epoch, active: false, shown: true, ordinaryIDs: [10]))
        try h.answer("openChat")
        XCTAssertFalse(h.client.requests.contains { $0.type == "viewMessages" })
        h.observe(h.id, .init(pane: h.pane, epoch: h.epoch, active: true, shown: true, ordinaryIDs: [10, 999]))
        let viewed = try h.answer("viewMessages")
        XCTAssertEqual(viewed["message_ids"], .array([.integer(10)])); XCTAssertEqual(viewed["force_read"], .bool(false))
        XCTAssertEqual(viewed["source"]?.object?.type, "messageSourceChatHistory")
        XCTAssertEqual(h.feed.snapshot.inbox, 0)
        h.observe(h.id, .init(pane: secondPane, epoch: h.epoch, active: true, shown: true, ordinaryIDs: [10]))
        XCTAssertEqual(h.client.requests.filter { $0.type == "viewMessages" }.count, 1)
        h.update("updateChatReadInbox", ["chat_id": .integer(202), "last_read_inbox_message_id": .integer(10)])
        h.update("updateChatReadOutbox", ["chat_id": .integer(202), "last_read_outbox_message_id": .integer(20)])
        XCTAssertEqual(h.feed.snapshot.inbox, 10); XCTAssertEqual(h.feed.snapshot.messages.last?.delivery, .read)
        h.session.release(h.id, pane: h.pane); XCTAssertFalse(h.client.requests.contains { $0.type == "closeChat" })
        h.session.release(h.id, pane: secondPane); XCTAssertEqual(h.client.requests.filter { $0.type == "closeChat" }.count, 1)
    }
    func testEntityRangesRejectSurrogatesAndUnsafeLinks() {
        let text = "a😀z link"
        let formatted = TDLibMessage("formattedText", ["entities": .array([
            .typed("textEntity", ["offset": .integer(2), "length": .integer(1), "type": .typed("textEntityTypeBold")]),
            .typed("textEntity", ["offset": .integer(1), "length": .integer(2), "type": .typed("textEntityTypeItalic")]),
            .typed("textEntity", ["offset": .integer(5), "length": .integer(4), "type": .typed("textEntityTypeTextUrl", ["url": .string("file:///tmp/test")])]),
            .typed("textEntity", ["offset": .integer(Int64.max), "length": .integer(2), "type": .typed("textEntityTypeBold")])])])
        let entities = TelegramMessageDecoder.entities(formatted, text: text)
        XCTAssertEqual(entities.count, 1); XCTAssertEqual(entities.first?.kind, .italic)
        XCTAssertNil(TelegramMessageDecoder.safeURL("javascript:alert(1)")); XCTAssertNil(TelegramMessageDecoder.safeURL("tg://login"))
        XCTAssertEqual(TelegramMessageDecoder.safeURL("https://example.com/a"), "https://example.com/a")
    }
    func testEditDeleteExpiryAndProtectedMediaDoNotRetainQuotes() throws {
        let h = try TelegramFeedHarness()
        var first = h.message(10, text: "expires"); first["auto_delete_in"] = .decimal(2)
        h.session.merge(first, into: h.feed); h.session.merge(h.message(20, reply: 10), into: h.feed)
        h.session.draft(h.id, epoch: h.epoch, value: .init(text: "reply", replyTo: 10))
        h.update("updateDeleteMessages", ["chat_id": .integer(202), "message_ids": .array([.integer(10)]), "is_permanent": .bool(false), "from_cache": .bool(true)])
        XCTAssertEqual(h.feed.snapshot.messages.count, 2)
        h.session.tick(now: h.now.addingTimeInterval(3), uptime: 13)
        XCTAssertEqual(h.feed.snapshot.messages.count, 1); XCTAssertEqual(h.feed.snapshot.messages[0].replyPreview, "Message unavailable")
        XCTAssertNil(h.feed.snapshot.draft.replyTo)
        h.session.merge(first, into: h.feed); XCTAssertEqual(h.feed.snapshot.messages.count, 1)
        var secret = h.message(30, text: "must not be retained"); secret["self_destruct_type"] = .typed("messageSelfDestructTypeImmediately")
        h.session.merge(secret, into: h.feed)
        XCTAssertEqual(h.feed.snapshot.messages.last?.text, ""); XCTAssertNil(h.feed.snapshot.messages.last?.attachment)
    }
    func testPresenceTTLTopicIsolationPrivacyAndTypingThrottle() throws {
        let h = try TelegramFeedHarness()
        h.observe(h.id, .init(pane: h.pane, epoch: h.epoch, active: true, shown: true, ordinaryIDs: [])); try h.answer("openChat")
        let action: [String: TDLibValue] = ["chat_id": .integer(202), "topic_id": .null, "sender_id": .typed("messageSenderUser", ["user_id": .integer(202)]), "action": .typed("chatActionTyping")]
        h.update("updateChatAction", action); XCTAssertTrue(h.session.presence(h.feed, live: true).contains("typing"))
        h.session.tick(now: h.now.addingTimeInterval(7), uptime: 17); XCTAssertEqual(h.session.presence(h.feed, live: true), "")
        var topic = action; topic["topic_id"] = .typed("messageTopicForum", ["forum_topic_id": .integer(2)])
        h.update("updateChatAction", topic); XCTAssertTrue(h.feed.actions.isEmpty)
        h.update("updateUserStatus", ["user_id": .integer(202), "status": .typed("userStatusRecently", ["by_my_privacy_settings": .bool(true)])])
        XCTAssertEqual(h.session.presence(h.feed, live: true), "Last seen recently")
        h.session.composer(h.id, epoch: h.epoch, pane: h.pane, typing: true)
        h.session.composer(h.id, epoch: h.epoch, pane: h.pane, typing: true)
        XCTAssertEqual(h.client.requests.filter { $0.type == "sendChatAction" }.count, 1)
        h.session.composer(h.id, epoch: h.epoch, pane: h.pane, typing: false)
        XCTAssertEqual(h.client.requests.last?["action"], .null)
        h.session.active = false; h.session.tick(now: h.now, uptime: 18)
        XCTAssertEqual(h.client.requests.last? ["value"]?.object?["value"], .bool(false))
    }
    func testSendIsIdempotentAndPendingResponseIsNotSent() throws {
        let h = try TelegramFeedHarness()
        let request = try h.send()
        let operation = try XCTUnwrap(h.journal.operations.first)
        XCTAssertNil(request["topic_id"]?.object); XCTAssertEqual(request["reply_markup"], .null)
        XCTAssertEqual(request["options"]?.object?["paid_message_star_count"], .integer(0))
        XCTAssertEqual(request["input_message_content"]?.object?["link_preview_options"]?.object?["is_disabled"], .bool(true))
        XCTAssertTrue(h.feed.snapshot.draft.isEmpty)
        h.session.sendDraft(h.id, epoch: h.epoch, revision: operation.revision)
        XCTAssertEqual(h.client.requests.filter { $0.type == "sendMessage" }.count, 1)
        let pending = h.message(91, outgoing: true, state: .typed("messageSendingStatePending", ["sending_id": .integer(operation.parts[0].sendingID)]))
        try h.answer("sendMessage", pending)
        XCTAssertEqual(h.feed.snapshot.messages.last?.delivery, .pending)
        let key = h.feed.snapshot.messages.last?.id
        h.session.draft(h.id, epoch: h.epoch, value: .init(text: "Newer draft"))
        h.update("updateMessageSendSucceeded", ["old_message_id": .integer(91), "message": .object(h.message(100, outgoing: true).fields)])
        XCTAssertEqual(h.feed.snapshot.messages.last?.delivery, .sent); XCTAssertEqual(h.feed.snapshot.messages.last?.id, key)
        XCTAssertEqual(h.feed.snapshot.draft.text, "Newer draft")
    }
    func testSendOutcomeBeforeResponseKeepsStableKey() throws {
        let h = try TelegramFeedHarness(); _ = try h.send()
        h.update("updateMessageSendSucceeded", ["old_message_id": .integer(91), "message": .object(h.message(100, outgoing: true).fields)])
        try h.answer("sendMessage", h.message(91, outgoing: true, state: .typed("messageSendingStatePending")))
        XCTAssertEqual(h.journal.operations.first?.parts.first?.state, .sent)
        XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), [100])
    }
    func testReplyDeletedBeforeSendPreservesDraft() throws {
        let h = try TelegramFeedHarness(), draft = TelegramDraft(text: "reply", replyTo: 10)
        h.session.draft(h.id, epoch: h.epoch, value: draft); h.session.sendDraft(h.id, epoch: h.epoch, revision: draft.revision)
        try h.refresh(); try h.answer("getMessage", TDLibMessage("error", ["code": .integer(404)]))
        XCTAssertFalse(h.client.requests.contains { $0.type == "sendMessage" }); XCTAssertEqual(h.feed.snapshot.draft, draft)
    }
    func testJournalRecoveryEncryptedAndNeverReplays() throws {
        let h = try TelegramFeedHarness(); _ = try h.send("Sensitive synthetic draft")
        let restored = try TelegramSendJournal(directory: h.fixture.directory, databaseKey: Data(repeating: 7, count: 32), now: h.now)
        XCTAssertEqual(restored.operations.first?.parts.first?.state, .unknown)
        let directory = h.fixture.directory.appendingPathComponent("conversation")
        for name in ["operations.json", "recovery.enc", "draft-202.enc"] {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(name))
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Sensitive synthetic draft"))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
    func testAttachmentBatchUsesPinnedInputsAndCaptionExactlyOnce() throws {
        let h = try TelegramFeedHarness()
        let file = try h.session.stage(h.id, epoch: h.epoch, data: Data("notes".utf8), name: "notes.txt", mime: "text/plain", width: 0, height: 0)
        let draft = TelegramDraft(text: "caption", attachments: [file])
        h.session.draft(h.id, epoch: h.epoch, value: draft); h.session.sendDraft(h.id, epoch: h.epoch, revision: draft.revision); try h.refresh()
        let content = try XCTUnwrap(h.client.requests.last { $0.type == "sendMessage" }?["input_message_content"]?.object)
        XCTAssertEqual(content.type, "inputMessageDocument")
        XCTAssertEqual(content["document"]?.object?.type, "inputDocument")
        XCTAssertTrue(content["document"]?.object?["document"]?.object?["path"]?.string?.hasSuffix("/notes.txt") == true)
        XCTAssertEqual(content["caption"]?.object?["text"], .string("caption"))
    }
    func testEpochAndSixInteractiveSlotsApplyAcrossFeatures() throws {
        let h = try TelegramFeedHarness()
        h.session.externalInteractive = { 6 }
        XCTAssertFalse(h.session.request("getChatHistory"))
        XCTAssertTrue(h.session.request("viewMessages", service: true))
        let draft = h.feed.snapshot.draft
        h.session.draft(h.id, epoch: UUID(), value: .init(text: "wrong account"))
        XCTAssertEqual(h.feed.snapshot.draft, draft)
        h.session.stop(); XCTAssertTrue(h.session.feeds.isEmpty)
    }
    func testEditWhileSendValidatesKeepsNewDraftAndSendsCapturedRevision() throws {
        let h = try TelegramFeedHarness(), captured = TelegramDraft(text: "Captured at Send")
        h.session.draft(h.id, epoch: h.epoch, value: captured)
        h.session.sendDraft(h.id, epoch: h.epoch, draft: captured)
        let newer = TelegramDraft(text: "Typed during validation")
        h.session.draft(h.id, epoch: h.epoch, value: newer)
        try h.refresh()
        XCTAssertEqual(h.feed.snapshot.draft, newer)
        XCTAssertEqual(h.client.requests.last { $0.type == "sendMessage" }?["input_message_content"]?.object?["text"]?.object?["text"], .string(captured.text))
        h.session.draft(h.id, epoch: h.epoch, value: captured)
        XCTAssertEqual(h.feed.snapshot.draft, newer) // late autosave cannot resurrect consumed text
    }
    func testTimeoutRetainsSlotAndLateOutcomeStillSettles() throws {
        let h = try TelegramFeedHarness(); _ = try h.send()
        h.session.tick(now: h.now.addingTimeInterval(41), uptime: 51)
        XCTAssertEqual(h.journal.operations.first?.parts.first?.state, .unknown)
        XCTAssertEqual(h.client.requests.filter { $0.type == "sendMessage" }.count, 1)
        XCTAssertGreaterThan(h.session.interactiveCount, 0)
        try h.answer("sendMessage", h.message(91, outgoing: true, state: .typed("messageSendingStatePending")))
        h.update("updateMessageSendSucceeded", ["old_message_id": .integer(91), "message": .object(h.message(100, outgoing: true).fields)])
        XCTAssertEqual(h.journal.operations.first?.parts.first?.state, .sent)
    }
    func testRetryPreservesReplyAndRejectsEverySemanticChange() throws {
        for blocked in ["can_retry", "need_drop_reply", "need_another_sender", "need_another_reply_quote", "required_paid_message_star_count", "retry_after", "none"] {
            let h = try TelegramFeedHarness(); _ = try h.send(reply: 10)
            try h.answer("sendMessage", h.message(91, outgoing: true, state: .typed("messageSendingStatePending"), reply: 10))
            var fields: [String: TDLibValue] = ["can_retry": .bool(true), "need_drop_reply": .bool(false), "need_another_sender": .bool(false),
                "need_another_reply_quote": .bool(false), "required_paid_message_star_count": .integer(0), "retry_after": .decimal(0)]
            if blocked == "can_retry" { fields[blocked] = .bool(false) }
            else if blocked == "required_paid_message_star_count" { fields[blocked] = .integer(1) }
            else if blocked == "retry_after" { fields[blocked] = .decimal(10) }
            else if blocked != "none" { fields[blocked] = .bool(true) }
            let failed = h.message(92, outgoing: true, state: .typed("messageSendingStateFailed", fields), reply: 10)
            h.update("updateMessageSendFailed", ["old_message_id": .integer(91), "message": .object(failed.fields)])
            h.session.retry(h.id, epoch: h.epoch, messageID: 92); try h.refresh(); try h.answer("getMessage", failed)
            if blocked == "none" {
                try h.answer("getMessageProperties", TDLibMessage("messageProperties"))
                try h.answer("getMessage", h.message(10)); try h.answer("getMessageProperties", TDLibMessage("messageProperties", ["can_be_replied": .bool(true)]))
                let resend = try XCTUnwrap(h.client.requests.last { $0.type == "resendMessages" })
                XCTAssertEqual(resend["paid_message_star_count"], .integer(0)); XCTAssertEqual(resend["message_ids"], .array([.integer(92)]))
                let key = h.journal.operations[0].parts[0].key
                h.update("updateDeleteMessages", ["chat_id": .integer(202), "message_ids": .array([.integer(92)]), "is_permanent": .bool(true)])
                XCTAssertFalse(h.feed.expired.contains(92))
                try h.answer("resendMessages", TDLibMessage("messages", ["messages": .array([.object(h.message(93, outgoing: true, state: .typed("messageSendingStatePending"), reply: 10).fields)])]))
                h.update("updateMessageSendSucceeded", ["old_message_id": .integer(93), "message": .object(h.message(100, outgoing: true, reply: 10).fields)])
                XCTAssertEqual(h.feed.snapshot.messages.last?.id, key.uuidString)
                XCTAssertEqual(h.journal.operations[0].parts[0].state, .sent)
            } else { XCTAssertFalse(h.client.requests.contains { $0.type == "resendMessages" }, blocked) }
        }
    }
    func testTextAndMultipleFilesAreSequentialAndShareReply() throws {
        let h = try TelegramFeedHarness(); h.session.captionLimit = 3
        let a = try h.session.stage(h.id, epoch: h.epoch, data: Data("one".utf8), name: "a.txt", mime: "text/plain", width: 0, height: 0)
        let b = try h.session.stage(h.id, epoch: h.epoch, data: Data("two".utf8), name: "b.txt", mime: "text/plain", width: 0, height: 0)
        let draft = TelegramDraft(text: "Long text", replyTo: 10, attachments: [a, b])
        h.session.draft(h.id, epoch: h.epoch, value: draft); h.session.sendDraft(h.id, epoch: h.epoch, draft: draft); try h.refresh()
        try h.answer("getMessage", h.message(10)); try h.answer("getMessageProperties", TDLibMessage("messageProperties", ["can_be_replied": .bool(true)]))
        for index in 0..<3 {
            let pending = Int64(91 + index * 2), final = pending + 1
            let sent = try h.answer("sendMessage", h.message(pending, outgoing: true, state: .typed("messageSendingStatePending"), reply: 10))
            XCTAssertEqual(sent["reply_to"]?.object?["message_id"], .integer(10))
            let content = sent["input_message_content"]?.object
            XCTAssertEqual(content?[index == 0 ? "text" : "caption"]?.object?["text"], .string(index == 0 ? "Long text" : ""))
            h.update("updateMessageSendSucceeded", ["old_message_id": .integer(pending), "message": .object(h.message(final, outgoing: true, reply: 10).fields)])
            if index < 2 {
                try h.refresh(); try h.answer("getMessage", h.message(10)); try h.answer("getMessageProperties", TDLibMessage("messageProperties", ["can_be_replied": .bool(true)]))
            }
        }
        XCTAssertEqual(h.journal.operations[0].parts.map(\.state), [.sent, .sent, .sent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.journal.stageURL(a.id).path))
    }
    func testLateOnlineAckCannotMarkBackgroundClientOnline() throws {
        let h = try TelegramFeedHarness(); h.session.online = false
        h.session.tick(now: h.now, uptime: 10)
        XCTAssertEqual(h.client.requests.last?["value"]?.object?["value"], .bool(true))
        h.session.active = false
        try h.answer("setOption")
        h.session.tick(now: h.now, uptime: 11)
        XCTAssertEqual(h.client.requests.last?["value"]?.object?["value"], .bool(false))
    }
    func testMemoryBudgetEvictsLeastRecentlyVisiblePagesWithoutDeletion() throws {
        let h = try TelegramFeedHarness()
        for chat in 1...6 {
            let id = TelegramChatID(environment: .test, account: 101, chat: Int64(chat))
            _ = h.session.subscribe(id, pane: UUID())
            let feed = try XCTUnwrap(h.session.feeds[id])
            feed.snapshot.capabilities.canRead = true
            feed.used = h.now.addingTimeInterval(Double(chat))
            for n in 1...500 {
                var message = h.message(Int64(n), text: String(repeating: "界", count: 3000)); message["chat_id"] = .integer(id.chat)
                h.session.merge(message, into: feed)
            }
        }
        h.session.boundMemory()
        XCTAssertLessThanOrEqual(h.session.feeds.values.reduce(0) { $0 + $1.snapshot.messages.count }, 2000)
        XCTAssertLessThanOrEqual(h.session.feeds.values.reduce(0) { $0 + $1.snapshot.messages.reduce(0) { $0 + $1.storageBytes } }, 16 * 1024 * 1024)
        XCTAssertTrue(h.session.feeds.values.allSatisfy { $0.expired.isEmpty })
        XCTAssertTrue(h.session.feeds[TelegramChatID(environment: .test, account: 101, chat: 1)]?.snapshot.hasOlder == true)
    }
}
