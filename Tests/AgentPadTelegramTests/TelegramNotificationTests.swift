import Foundation
import GRDB
import XCTest
@testable import AgentPadTelegram

enum NotificationFixture {
    static func notification(_ id: Int64, message: Int64, chat: Int64 = 1, silent: Bool = false,
                             unreadMention: Bool = false, reply: Int64? = nil) -> TDLibValue {
        .typed("notification", ["id": .integer(id), "date": .integer(AttentionFixture.now), "is_silent": .bool(silent),
            "type": .typed("notificationTypeNewMessage", ["message": .object(AttentionFixture.message(message, chat: chat,
                unreadMention: unreadMention, reply: reply).fields), "show_preview": .bool(true)])])
    }
    static func group(_ id: Int64 = 1, chat: Int64 = 1, added: [TDLibValue], removed: [Int64] = []) -> TDLibMessage {
        .init("updateNotificationGroup", ["notification_group_id": .integer(id), "chat_id": .integer(chat),
            "type": .typed("notificationGroupTypeMessages"), "notification_settings_chat_id": .integer(chat),
            "notification_sound_id": .integer(1), "total_count": .integer(added.isEmpty ? 0 : Int64(added.count)),
            "added_notifications": .array(added), "removed_notification_ids": .array(removed.map(TDLibValue.integer))])
    }
    static func snapshot(_ values: [TDLibValue]) -> TDLibMessage {
        .init("updateActiveNotifications", ["groups": .array(values.isEmpty ? [] : [.typed("notificationGroup", ["id": .integer(1),
            "type": .typed("notificationGroupTypeMessages"), "chat_id": .integer(1), "total_count": .integer(Int64(values.count)), "notifications": .array(values)])])])
    }
}

final class TelegramNotificationTests: XCTestCase {
    func testReplyCategoryStaysPendingUntilTargetIsVerified() throws {
        for outgoing in [true, false] {
            let fixture = try TelegramFixture(), now = AttentionFixture.now
            let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
            try AttentionFixture.chat(index, kind: .group)
            let scan = try XCTUnwrap(index.nextAttentionWork(lane: 0, now: now))
            try index.finishAttentionWork(scan, response: .init("foundChatMessages", ["messages": .array([])]), now: now)
            try index.apply(NotificationFixture.snapshot([]), now: now)
            let notice = NotificationFixture.notification(1, message: 100, unreadMention: true, reply: 50)
            try index.apply(NotificationFixture.group(added: [notice]), now: now)
            let pending = try XCTUnwrap(index.project(now: now).attention.notifications.items.first)
            XCTAssertTrue(pending.categoryPending); XCTAssertTrue(pending.mayDeliver)
            let work = try XCTUnwrap(index.nextAttentionWork(lane: 0, now: now))
            XCTAssertEqual(work.method, "getMessage"); XCTAssertEqual(work.message, 50)
            try index.finishAttentionWork(work, response: .init("error", ["code": .integer(404)]), now: now)
            XCTAssertTrue(try XCTUnwrap(index.project(now: now).attention.notifications.items.first).categoryPending)
            try index.finishAttentionWork(work, response: AttentionFixture.message(50, outgoing: outgoing), now: now)
            try index.apply(NotificationFixture.group(added: [notice]), now: now)
            let resolved = try XCTUnwrap(index.project(now: now).attention.notifications.items.first)
            XCTAssertEqual(resolved.id, pending.id); XCTAssertFalse(resolved.categoryPending)
            XCTAssertEqual(resolved.kind, outgoing ? .reply : .mention); XCTAssertTrue(resolved.mayDeliver)
        }
    }

    func testRetirementIsPerGroupAndSurvivesRestart() throws {
        let fixture = try TelegramFixture(), now = AttentionFixture.now
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index!, kind: .group)
        try index!.apply(NotificationFixture.snapshot([]), now: now)
        for id: Int64 in 101...111 {
            try index!.apply(NotificationFixture.group(2, added: [NotificationFixture.notification(id, message: id, unreadMention: true)]), now: now)
            try index!.apply(NotificationFixture.group(2, added: [], removed: [id]), now: now)
        }
        XCTAssertEqual(try index!.db.read { try Int64.fetchOne($0, sql: "SELECT value FROM checkpoint WHERE key='notificationRetired:2'") }, 101)
        // A legacy global boundary cannot be carried into unrelated groups.
        try index!.db.write { try $0.execute(sql: "INSERT INTO checkpoint VALUES ('notificationRetired',999)") }
        index = nil
        let restored = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try restored.apply(NotificationFixture.snapshot([]), now: now)
        try restored.apply(NotificationFixture.group(1, added: [NotificationFixture.notification(100, message: 100, unreadMention: true)]), now: now)
        let delayed = try XCTUnwrap(restored.project(now: now).attention.notifications.items.first)
        XCTAssertEqual(delayed.kind, .mention); XCTAssertTrue(delayed.mayDeliver)
        try restored.apply(NotificationFixture.group(2, added: [NotificationFixture.notification(101, message: 101, unreadMention: true)]), now: now)
        let replay = try XCTUnwrap(restored.project(now: now).attention.notifications.items.first { $0.id.hasSuffix(":2:101") })
        XCTAssertFalse(replay.mayDeliver, "Eviction still prevents replay within the same group")
        try restored.clearNotifications()
        XCTAssertEqual(try restored.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM checkpoint WHERE key LIKE 'notificationRetired%'") }, 0)
    }

    func testHistoryIsBoundedByCountAndAgeAndEvictedIDsCannotReplay() throws {
        let fixture = try TelegramFixture(), now = AttentionFixture.now
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index)
        try index.apply(NotificationFixture.snapshot([]), now: now)
        // Each group disappears before the next arrives: active limits alone
        // cannot bound this history of 300 delivered and removed notices.
        for id: Int64 in 1...300 {
            let group = (id - 1) / 10 + 1
            try index.apply(NotificationFixture.group(group, added: [NotificationFixture.notification(id, message: 1000 + id)]), now: now)
            let item = try XCTUnwrap(index.project(now: now).attention.notifications.items.first)
            try index.consumeNotification(item.id, now: now)
            try index.apply(NotificationFixture.group(group, added: [], removed: [id]), now: now)
        }
        let counts = try index.db.read { db in
            try [Int.fetchOne(db, sql: "SELECT count(*) FROM tg_notification_seen")!,
                 Int.fetchOne(db, sql: "SELECT count(DISTINCT groupID) FROM tg_notification_seen")!,
                 Int.fetchOne(db, sql: "SELECT count(*) FROM tg_notification_consumed")!]
        }
        XCTAssertEqual(counts, [250, 25, 250])
        try index.apply(NotificationFixture.group(1, added: [NotificationFixture.notification(1, message: 1001)]), now: now)
        XCTAssertFalse(try XCTUnwrap(index.project(now: now).attention.notifications.items.first).mayDeliver)
        try index.expireNotificationHistory(now: now + TelegramNotificationLimits.historySeconds + 1)
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tg_notification_seen") }, 0)
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tg_notification_consumed") }, 0)
    }

    func testSingleGroupHistoryAndLongChannelEpisodeStayBoundedAcrossRestart() throws {
        let fixture = try TelegramFixture(), now = AttentionFixture.now
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index!, kind: .channel); try index!.mode(1, .auto, now: now)
        try AttentionFixture.follow(index!, chat: 1)
        try index!.apply(NotificationFixture.snapshot([]), now: now)
        for id: Int64 in 1...30 {
            try index!.apply(NotificationFixture.group(added: [NotificationFixture.notification(id, message: 1000 + id)]), now: now)
            let item = try XCTUnwrap(index!.project(now: now).attention.notifications.items.first)
            if id == 1 { try index!.consumeNotification(item.id, now: now) }
            else { XCTAssertFalse(item.mayDeliver) }
            try index!.apply(NotificationFixture.group(added: [], removed: [id]), now: now)
        }
        XCTAssertEqual(try index!.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tg_notification_seen") }, 10)
        let later = now + TelegramNotificationLimits.historySeconds + 1
        try index!.expireNotificationHistory(now: later)
        XCTAssertEqual(try index!.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tg_notification_consumed") }, 0)
        index = nil
        let restored = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try restored.apply(NotificationFixture.snapshot([]), now: later)
        var fresh = NotificationFixture.notification(31, message: 1031).object!
        fresh["date"] = .integer(later)
        try restored.apply(NotificationFixture.group(added: [.object(fresh.fields)]), now: later)
        XCTAssertFalse(try XCTUnwrap(restored.project(now: later).attention.notifications.items.first).mayDeliver)
    }

    func testLegacyHistoryMigratesWithBoundsAndPreservesChannelConsumption() throws {
        let fixture = try TelegramFixture(), now = AttentionFixture.now
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index!, kind: .channel); try index!.mode(1, .auto, now: now)
        try AttentionFixture.follow(index!, chat: 1)
        try index!.apply(NotificationFixture.snapshot([]), now: now)
        try index!.apply(NotificationFixture.group(added: [NotificationFixture.notification(1, message: 100)]), now: now)
        let item = try XCTUnwrap(index!.project(now: now).attention.notifications.items.first)
        try index!.consumeNotification(item.id, now: now)
        try index!.db.write { db in
            try db.execute(sql: """
                ALTER TABLE tg_notification_seen DROP COLUMN date;
                ALTER TABLE tg_notification_consumed DROP COLUMN date;
                ALTER TABLE tg_state DROP COLUMN notifiedEpisode;
                """)
            try LegacyFolderFixture.makeVersionOne(db)
        }
        index = nil
        let restored = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        XCTAssertEqual(try restored.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tg_notification_seen") }, 0)
        XCTAssertEqual(try restored.db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tg_notification_consumed") }, 0)
        try restored.apply(NotificationFixture.snapshot([]), now: now)
        try restored.apply(NotificationFixture.group(added: [NotificationFixture.notification(2, message: 101)]), now: now)
        XCTAssertFalse(try XCTUnwrap(restored.project(now: now).attention.notifications.items.first).mayDeliver)
    }

    func testLogoutClearsHistoryEvenWhileServerLogoutIsPending() async throws {
        let fixture = try TelegramFixture(), client = fixture.client
        client.database.save(TDLibMessage("authorizationStateReady")); client.logoutBehavior = .acceptedPending
        client.startupUpdates = [TDLibMessage("updateUser", ["user": .typed("user", ["id": .integer(1), "type": .typed("userTypeRegular")])]), ChatFixture.chat(1)]
        client.initialNotificationGroups = NotificationFixture.snapshot([NotificationFixture.notification(1, message: 100)])["groups"]!.array
        let connector = try fixture.connector(); await connector.connect()
        await eventually { await self.snapshot(connector).account != nil }
        let provider: any TelegramChatProvider = connector
        let consumed = await provider.consumeNotification("telegram:test:\(ChatFixture.me):notification:1:1")
        XCTAssertTrue(consumed)
        let directory = try XCTUnwrap(client.requests.first { $0.type == "setTdlibParameters" }?["database_directory"]?.string)
        let url = URL(fileURLWithPath: directory).deletingLastPathComponent().appendingPathComponent("chat-index.sqlite")
        var config = Configuration(); config.readonly = true; config.busyMode = .timeout(5)
        let db = try DatabaseQueue(path: url.path, configuration: config)
        let before = try await db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM tg_notification_consumed") }
        XCTAssertEqual(before, 1)
        await connector.disconnect()
        client.enqueue(NotificationFixture.group(added: [NotificationFixture.notification(2, message: 101)]))
        for table in ["tg_notification_seen", "tg_notification_consumed", "tg_notifications", "tg_notification_groups"] {
            let count = try await db.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM \(table)") }
            XCTAssertEqual(count, 0)
        }
        _ = await connector.close()
    }

    func testSnoozeUndoDoesNotCreateAnotherChannelBannerAndLimitViolationIsAtomic() throws {
        let fixture = try TelegramFixture()
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index, kind: .channel); try index.mode(1, .auto)
        try AttentionFixture.follow(index, chat: 1)
        try index.apply(NotificationFixture.snapshot([]), now: AttentionFixture.now)
        try index.apply(NotificationFixture.group(added: [NotificationFixture.notification(1, message: 100)]), now: AttentionFixture.now)
        XCTAssertTrue(try index.project(now: AttentionFixture.now).attention.notifications.items[0].mayDeliver)
        try index.snooze(1, undo: false, now: AttentionFixture.now)
        try index.snooze(1, undo: true, now: AttentionFixture.now)
        XCTAssertFalse(try index.project(now: AttentionFixture.now).attention.notifications.items[0].mayDeliver)
        let before = try index.project(now: AttentionFixture.now).attention.notifications
        XCTAssertThrowsError(try index.apply(NotificationFixture.snapshot((1...11).map { NotificationFixture.notification(Int64($0), message: 100) }), now: AttentionFixture.now))
        XCTAssertEqual(try index.project(now: AttentionFixture.now).attention.notifications, before)
    }
    func testFakeClientPreservesNonemptySnapshotBeforeBindingAndPublishesLiveGroups() async throws {
        let fixture = try TelegramFixture(), client = fixture.client
        client.database.save(TDLibMessage("authorizationStateReady")); client.automaticMe = false
        var chat = ChatFixture.chat(1, unread: 1)
        var value = chat["chat"]!.object!; value["notification_settings"] = AttentionFixture.settings(); chat["chat"] = .object(value.fields)
        client.startupUpdates = [TDLibMessage("updateUser", ["user": .typed("user", ["id": .integer(1), "type": .typed("userTypeRegular")])]), chat]
        client.initialNotificationGroups = NotificationFixture.snapshot([NotificationFixture.notification(1, message: 100)])["groups"]!.array
        let connector = try fixture.connector(); await connector.connect()
        await eventually { await connector.currentSnapshot().receivedNotificationSnapshot }
        let before = await snapshot(connector)
        XCTAssertNil(before.account); XCTAssertTrue(before.attention.notifications.items.isEmpty)
        client.reply(try XCTUnwrap(client.requests.first { $0.type == "getMe" }), FakeTDLibClient.user)
        await eventually { await self.snapshot(connector).attention.notifications.items.count == 1 }
        let restored = await snapshot(connector)
        XCTAssertFalse(try XCTUnwrap(restored.attention.notifications.items.first).mayDeliver)
        client.enqueue(NotificationFixture.group(added: [NotificationFixture.notification(2, message: 101)]))
        await eventually { await self.snapshot(connector).attention.notifications.items.contains(where: \.mayDeliver) }
        let live = await snapshot(connector)
        XCTAssertEqual(live.attention.totalCount, 2)
        client.enqueue(NotificationFixture.group(added: [], removed: [1,2]))
        await eventually { await self.snapshot(connector).attention.notifications.items.isEmpty }
        let removed = await snapshot(connector); XCTAssertEqual(removed.attention.totalCount, 2)
        client.enqueue(TDLibMessage("updateChatReadInbox", ["chat_id": .integer(1), "last_read_inbox_message_id": .integer(101), "unread_count": .integer(0)]))
        await eventually { await self.snapshot(connector).attention.totalCount == 0 }
        XCTAssertFalse(client.mainThreadReceives)
        _ = await connector.close()
    }
    private func snapshot(_ connector: LocalTDLibConnector) async -> TelegramChatSnapshot {
        let stream = await connector.chatSnapshots(); var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? .init()
    }

    func testLargeSnapshotRetainsOnlyBoundedMetadataAndOldUnseenGroupsStayQuiet() throws {
        let fixture = try TelegramFixture()
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index)
        let content = String(repeating: "界", count: 1_500_000)
        var message = AttentionFixture.message(100)
        message["content"] = .typed("messageText", ["text": .typed("formattedText", ["text": .string(content)])])
        let notification = TDLibValue.typed("notification", ["id": .integer(1), "date": .integer(AttentionFixture.now - 100),
            "type": .typed("notificationTypeNewMessage", ["message": .object(message.fields), "show_preview": .bool(true)])])
        let input = NotificationFixture.snapshot([notification])
        XCTAssertGreaterThan(TDLibValue.object(input.fields).estimatedBytes, 4 * 1024 * 1024)
        try index.apply(input, now: AttentionFixture.now)
        XCTAssertEqual(try index.project(now: AttentionFixture.now).attention.notifications.items.count, 1)
        XCTAssertLessThan(try Data(contentsOf: fixture.directory.appendingPathComponent("chat-index.sqlite")).count, 256 * 1024)
        var old = NotificationFixture.notification(2, message: 101).object!
        old["date"] = .integer(AttentionFixture.now - 1)
        try index.apply(NotificationFixture.group(added: [.object(old.fields)]), now: AttentionFixture.now)
        XCTAssertFalse(try index.project(now: AttentionFixture.now).attention.notifications.items.contains(where: \.mayDeliver))
    }
    func testSnapshotDuplicatesRemovalAndReadAreSeparate() throws {
        let fixture = try TelegramFixture()
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index)
        let old = NotificationFixture.notification(1, message: 100)
        try index.apply(NotificationFixture.snapshot([old]), now: AttentionFixture.now)
        var items = try index.project(now: AttentionFixture.now).attention.notifications.items
        XCTAssertEqual(items.count, 1); XCTAssertFalse(items[0].mayDeliver)
        let fresh = NotificationFixture.notification(2, message: 101)
        try index.apply(NotificationFixture.group(added: [fresh]), now: AttentionFixture.now)
        items = try index.project(now: AttentionFixture.now).attention.notifications.items
        let live = try XCTUnwrap(items.first(where: \.mayDeliver))
        try index.consumeNotification(live.id)
        try index.apply(NotificationFixture.group(added: [fresh]), now: AttentionFixture.now)
        XCTAssertFalse(try index.project(now: AttentionFixture.now).attention.notifications.items.contains(where: \.mayDeliver))
        try index.apply(NotificationFixture.group(added: [], removed: [1,2]), now: AttentionFixture.now)
        XCTAssertTrue(try index.project(now: AttentionFixture.now).attention.notifications.items.isEmpty)
        XCTAssertEqual(try AttentionFixture.unread(index), 2, "Transport removal is not a read receipt")
        try index.apply(NotificationFixture.group(added: [fresh]), now: AttentionFixture.now)
        XCTAssertFalse(try index.project(now: AttentionFixture.now).attention.notifications.items[0].mayDeliver)
        try index.apply(TDLibMessage("updateChatReadInbox", ["chat_id": .integer(1), "last_read_inbox_message_id": .integer(101), "unread_count": .integer(0)]), now: AttentionFixture.now)
        XCTAssertTrue(try index.project(now: AttentionFixture.now).attention.notifications.items.isEmpty)
    }

    func testChannelTransportIDsShareDeliveryEpisodeAndRestartDoesNotReplay() throws {
        let fixture = try TelegramFixture()
        var index: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index!, kind: .channel); try index!.mode(1, .auto)
        try AttentionFixture.follow(index!, chat: 1)
        try index!.apply(NotificationFixture.snapshot([]), now: AttentionFixture.now)
        try index!.apply(NotificationFixture.group(added: [NotificationFixture.notification(1, message: 100)]), now: AttentionFixture.now)
        let first = try XCTUnwrap(index!.project(now: AttentionFixture.now).attention.notifications.items.first)
        XCTAssertTrue(first.mayDeliver); try index!.consumeNotification(first.id)
        try index!.apply(NotificationFixture.group(added: [NotificationFixture.notification(2, message: 101)]), now: AttentionFixture.now)
        let second = try XCTUnwrap(index!.project(now: AttentionFixture.now).attention.notifications.items.first)
        XCTAssertEqual(first.id, second.id); XCTAssertFalse(second.mayDeliver)
        index = nil
        let restored = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try restored.apply(NotificationFixture.snapshot([NotificationFixture.notification(2, message: 101)]), now: AttentionFixture.now)
        XCTAssertEqual(try restored.project(now: AttentionFixture.now).attention.notifications.items.first?.id, first.id)
        XCTAssertFalse(try restored.project(now: AttentionFixture.now).attention.notifications.items.first?.mayDeliver ?? true)
    }

    func testLateHistoryCannotResurrectReadOrDeletedMention() throws {
        let fixture = try TelegramFixture()
        let index = try TelegramChatIndex(directory: fixture.directory, environment: .test, account: ChatFixture.me)
        try AttentionFixture.chat(index, kind: .group)
        let raw = AttentionFixture.message(100, unreadMention: true)
        try index.apply(raw, now: AttentionFixture.now)
        try index.apply(TDLibMessage("updateMessageMentionRead", ["chat_id": .integer(1), "message_id": .integer(100)]), now: AttentionFixture.now)
        try index.apply(raw, now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 0)
        let newer = AttentionFixture.message(101, unreadMention: true)
        try index.apply(newer, now: AttentionFixture.now)
        try index.apply(TDLibMessage("updateDeleteMessages", ["chat_id": .integer(1), "message_ids": .array([.integer(101)]), "is_permanent": .bool(true)]), now: AttentionFixture.now)
        try index.apply(newer, now: AttentionFixture.now)
        XCTAssertEqual(try AttentionFixture.unread(index), 0)
    }

    func testFakeClientOptionsAndEarlySnapshotBindWithoutBanner() async throws {
        let fixture = try TelegramFixture(), client = fixture.client
        client.database.save(TDLibMessage("authorizationStateReady"))
        let connector = try fixture.connector()
        await connector.connect()
        await eventually { if case .connected = await connector.currentSnapshot().state { true } else { false } }
        let snapshot = await connector.currentSnapshot()
        XCTAssertTrue(snapshot.optionsVerified); XCTAssertTrue(snapshot.receivedNotificationSnapshot)
        XCTAssertFalse(client.mainThreadReceives)
        let options = client.requests.filter { $0.type == "setOption" }
        XCTAssertTrue(options.contains { $0["name"]?.string == "notification_group_size_max" && $0["value"]?.object?["value"]?.integer == 10 })
        XCTAssertTrue(options.contains { $0["name"]?.string == "notification_group_count_max" && $0["value"]?.object?["value"]?.integer == 25 })
        _ = await connector.close()
    }
}
