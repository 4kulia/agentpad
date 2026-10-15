import Foundation
import GRDB
import SQLite3
import XCTest
@testable import AgentPadTelegram

enum FolderFixture {
    static let now = ChatFixture.now
    static func folders(_ ids: [Int64], main: Int64 = 0, name: String = "Work") -> TDLibMessage {
        TDLibMessage("updateChatFolders", ["chat_folders": .array(ids.map { id in
            .typed("chatFolderInfo",["id": .integer(id),"name": .typed("chatFolderName",[
                "text": .typed("formattedText",["text": .string(name + String(id)),"entities": .array([])]),"animate_custom_emoji": .bool(false)]),
                "icon": .typed("chatFolderIcon",["name": .string("Work")]),"color_id": .integer(-1),"is_shareable": .bool(false),"has_my_invite_links": .bool(false)])
        }),"main_chat_list_position": .integer(main),"are_tags_enabled": .bool(false)])
    }
    static func apply(_ message: TDLibMessage, _ index: TelegramChatIndex) throws {
        TelegramFixtureSchema.check(message)
        func noNull(_ value: TDLibValue) {
            switch value {
            case .null: XCTFail("Fixture null fields must be omitted")
            case .array(let values): values.forEach(noNull)
            case .object(let values): values.values.forEach(noNull)
            default: break
            }
        }
        noNull(.object(message.fields)); try index.apply(message, now: now)
    }
    static func position(_ chat: Int64, _ key: TelegramListKey, _ order: Int64, _ index: TelegramChatIndex, pinned: Bool = false) throws {
        try apply(TDLibMessage("updateChatPosition",["chat_id": .integer(chat),"position": ChatFixture.position(list: key,order: order,pinned: pinned)]),index)
    }
    static func seed(_ index: TelegramChatIndex, count: Int, list: TelegramListKey = .main, epoch: String? = nil) throws {
        try index.db.write { db in
            for id in 1...count {
                try db.execute(sql: "INSERT OR IGNORE INTO chats(id,title,kind,lastDate) VALUES (?,?,'person',?)",arguments: [id,"Chat \(id)",now - Int64(id)])
                try db.execute(sql: "INSERT OR REPLACE INTO tg_position VALUES (?,?,?,0,?)",arguments: [id,list.rawValue,count + 1 - id,epoch ?? index.attentionEpoch])
            }
        }
        index.dirtyLists.insert(list); index.countDirtyLists.insert(list)
    }
    static func page(_ index: TelegramChatIndex, _ key: TelegramListKey = .main, _ start: Int = 0) throws -> TelegramChatPage {
        try index.listPage(key,from: start,revision: index.listStates[key]!.revision,now: now)
    }
}

final class TelegramFolderTests: XCTestCase {
    func testCustomFolderMetadataAndHeldRowPositionsUseBoundProfile() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        try FolderFixture.apply(FolderFixture.folders([2]),index)
        try FolderFixture.seed(index,count: 120)
        try FolderFixture.position(2,.folder(2),900,index)
        let first = UUID(), second = UUID()
        for (folder,chat) in [(first,Int64(2)),(first,70),(second,2)] {
            try index.setCustomMember(folder: folder,chat: chat,member: true,binding: index.binding)
        }
        try FolderFixture.apply(TDLibMessage("updateChatReadInbox",["chat_id": .integer(2),"last_read_inbox_message_id": .integer(50),"unread_count": .integer(8)]),index)
        try index.mode(70,.hidden,now: FolderFixture.now)
        let values = try index.customSummaries(binding: index.binding,now: FolderFixture.now)
        XCTAssertEqual(Set(values.map(\.chat)),[2,70],"Unique members, including outside the eight-row viewport")
        XCTAssertEqual(values.count,2)
        XCTAssertTrue(try XCTUnwrap(values.first { $0.chat == 2 }).unread)
        XCTAssertTrue(try XCTUnwrap(values.first { $0.chat == 2 }).muted,"Unknown mute state is muted")
        XCTAssertTrue(try XCTUnwrap(values.first { $0.chat == 70 }).hidden)
        XCTAssertThrowsError(try index.customSummaries(binding: .init(environment: .test,account: ChatFixture.me,connectionID: UUID()),now: FolderFixture.now))
        _ = try index.project(now: FolderFixture.now)
        index.hold(.main,held: true,owner: UUID())
        try index.mode(1,.hidden,now: FolderFixture.now)
        let page = try FolderFixture.page(index)
        XCTAssertEqual(page.rows.first?.id.chat,2)
        XCTAssertEqual(page.rows.first?.listPosition,1,"Live-filtered holes must not pull the ninth row into the eight-row UI")
        XCTAssertEqual(page.rows.first?.lists,[.main,.folder(2)])
    }
    func testPositionVectorsDeltasEmptyVectorsAndEveryListPage() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        try FolderFixture.apply(FolderFixture.folders([2,3]),index)
        try index.setListVisible(.archive,visible: true)
        for id: Int64 in 1...123 {
            try FolderFixture.apply(ChatFixture.chat(id,positions: [.main,.archive,.folder(2),.folder(3)].map { ChatFixture.position(list: $0,order: 100) }),index)
        }
        _ = try index.project(now: FolderFixture.now)
        for list in try index.listKeys() {
            for start in [0,50,100] {
                let page = try FolderFixture.page(index,list,start)
                XCTAssertEqual(page.rows.map(\.id.chat),Array((1...123).reversed().dropFirst(start).prefix(50)).map(Int64.init))
                XCTAssertEqual(page.next,start == 100 ? nil : start + 50)
            }
        }
        for list in try index.listKeys() {
            try FolderFixture.position(5,list,500,index); _ = try index.project(now: FolderFixture.now)
            XCTAssertEqual(try FolderFixture.page(index,list).rows.first?.id.chat,5)
            for other in try index.listKeys() where other != list {
                XCTAssertEqual(try FolderFixture.page(index,other).rows.first?.id.chat,123)
            }
            try FolderFixture.position(5,list,100,index); _ = try index.project(now: FolderFixture.now)
        }
        try FolderFixture.position(1,.folder(2),200,index,pinned: true)
        _ = try index.project(now: FolderFixture.now)
        XCTAssertEqual(try FolderFixture.page(index,.folder(2)).rows.first?.id.chat,1)
        XCTAssertTrue(try XCTUnwrap(FolderFixture.page(index,.folder(2)).rows.first).pinned)
        XCTAssertFalse(try XCTUnwrap(FolderFixture.page(index,.main).rows.first).pinned)
        try FolderFixture.apply(TDLibMessage("updateChatDraftMessage",["chat_id": .integer(1),"positions": .array([ChatFixture.position(list: .folder(3))])]),index)
        XCTAssertEqual(try index.db.read { try String.fetchAll($0,sql: "SELECT list FROM tg_position WHERE chat=1") },["folder:3"])
        try FolderFixture.apply(TDLibMessage("updateChatLastMessage",["chat_id": .integer(1),"positions": .array([])]),index)
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0,sql: "SELECT count(*) FROM tg_position WHERE chat=1") },0)
        try FolderFixture.position(2,.archive,0,index)
        XCTAssertFalse(try XCTUnwrap(index.get(2,now: FolderFixture.now)).inArchive)
        XCTAssertEqual(try index.db.read { try Set(String.fetchAll($0,sql: "SELECT DISTINCT epoch FROM tg_position")) },[index.attentionEpoch])
    }

    func testHoldsFreezeWindowsThroughPromotionDemotionHidingAndReadUpdates() throws {
        for hidden in [[1],[50,51],Array(1...50)] {
            let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
            try FolderFixture.seed(index,count: 120)
            _ = try index.project(now: FolderFixture.now)
            let revision = index.listStates[.main]!.revision, owner = UUID()
            index.hold(.main,held: true,owner: owner)
            try FolderFixture.position(61,.main,999,index); try FolderFixture.position(11,.main,1,index)
            for id in hidden { try index.mode(Int64(id),.hidden,now: FolderFixture.now) }
            try FolderFixture.apply(TDLibMessage("updateChatReadInbox",["chat_id": .integer(2),"last_read_inbox_message_id": .integer(50),"unread_count": .integer(7)]),index)
            _ = try index.project(now: FolderFixture.now,force: true)
            let a = try FolderFixture.page(index), b = try FolderFixture.page(index,.main,50)
            XCTAssertEqual(a.revision,revision); XCTAssertEqual(a.next,50); XCTAssertEqual(b.next,100)
            XCTAssertEqual(a.rows.map(\.id.chat),(1...50).filter { !hidden.contains($0) }.map(Int64.init))
            XCTAssertEqual(b.rows.map(\.id.chat),(51...100).filter { !hidden.contains($0) }.map(Int64.init))
            XCTAssertTrue(Set(a.rows.map(\.id)).isDisjoint(with: b.rows.map(\.id)))
            if !hidden.contains(2) { XCTAssertEqual(a.rows.first { $0.id.chat == 2 }?.unreadCount,7) }
            index.hold(.main,held: false,owner: owner); _ = try index.project(now: FolderFixture.now)
            XCTAssertNotEqual(index.listStates[.main]!.revision,revision)
            XCTAssertEqual(try FolderFixture.page(index).rows.first?.id.chat,61)
            XCTAssertTrue(try index.listPage(.main,from: 0,revision: revision,now: FolderFixture.now).rows.isEmpty)
        }
    }

    func testWindowQueryUsesIndexRangeAndConstantVMSteps() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        try FolderFixture.seed(index,count: 5_000); _ = try index.project(now: FolderFixture.now)
        try index.db.read { db in
            let plan = try Row.fetchAll(db,sql: "EXPLAIN QUERY PLAN " + TelegramChatIndex.windowSQL,arguments: ["main",4900,4950]).map { $0["detail"] as String }.joined(separator: " ")
            XCTAssertTrue(plan.contains("position>?") && plan.contains("position<?"),plan)
            func steps(_ start: Int) throws -> Int32 {
                let statement = try db.makeStatement(sql: TelegramChatIndex.windowSQL)
                let rows = try Row.fetchAll(statement,arguments: ["main",start,start + 50]); XCTAssertEqual(rows.count,50)
                return sqlite3_stmt_status(statement.sqliteStatement,SQLITE_STMTSTATUS_VM_STEP,0)
            }
            let first = try steps(0), deep = try steps(4900)
            XCTAssertLessThanOrEqual(deep,first * 2)
            print("Folder window VM steps: first=\(first), deep=\(deep)")
        }
    }

    func testFolderLifecycleKeepsVisibilityAndCollapseAcrossRenameAndDropsAllDeletedState() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me), window = UUID()
        try FolderFixture.apply(FolderFixture.folders([2,3]),index)
        try FolderFixture.seed(index,count: 3,list: .folder(2))
        try index.setListCollapsed(window: window,list: .folder(2),collapsed: true,binding: index.binding)
        _ = try index.project(now: FolderFixture.now)
        index.hold(.folder(2),held: true,owner: window)
        try index.setListVisible(.folder(2),visible: false)
        try FolderFixture.apply(FolderFixture.folders([3,2,4],main: 2,name: "Renamed"),index)
        let lists = try index.project(now: FolderFixture.now).lists
        XCTAssertEqual(lists.map(\.key),[.folder(3),.folder(2),.main,.folder(4),.archive])
        XCTAssertFalse(try XCTUnwrap(lists.first { $0.key == .folder(2) }).visible)
        XCTAssertEqual(lists.first { $0.key == .folder(2) }?.collapsedWindows,[window])
        XCTAssertEqual(lists.first { $0.key == .folder(2) }?.name,"Renamed2")
        XCTAssertTrue(try XCTUnwrap(lists.first { $0.key == .folder(4) }).visible)
        try FolderFixture.apply(FolderFixture.folders([3,4]),index)
        for table in ["tg_slot","tg_position","tg_list_order","tg_list_counts","tg_collapse"] {
            XCTAssertEqual(try index.db.read { try Int.fetchOne($0,sql: "SELECT count(*) FROM \(table) WHERE list='folder:2'") },0)
        }
        XCTAssertNil(index.listStates[.folder(2)])
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0,sql: "SELECT count(*) FROM chats") },3)
    }

    func testRestartSweepOnlyDeletesUnconfirmedPositionsInCompletedList() throws {
        let fixture = try TelegramFixture()
        var old: TelegramChatIndex? = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        try FolderFixture.apply(FolderFixture.folders([2,3]),old!)
        for list: TelegramListKey in [.main,.archive,.folder(2),.folder(3)] { try FolderFixture.seed(old!,count: 3,list: list) }
        old = nil
        let index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        try FolderFixture.position(1,.folder(2),100,index)
        try FolderFixture.position(2,.archive,100,index)
        try index.completeList(.folder(2),generation: 0)
        XCTAssertEqual(try index.db.read { try Int64.fetchAll($0,sql: "SELECT chat FROM tg_position WHERE list='folder:2'") },[1])
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0,sql: "SELECT count(*) FROM tg_position WHERE list='folder:3'") },3)
        try index.completeList(.main,generation: 0); try index.completeList(.archive,generation: 0)
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0,sql: "SELECT count(*) FROM tg_position WHERE list='main'") },0)
        XCTAssertEqual(try index.db.read { try Int64.fetchAll($0,sql: "SELECT chat FROM tg_position WHERE list='archive'") },[2])
        try index.completeList(.folder(3),generation: 0)
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0,sql: "SELECT count(*) FROM tg_position WHERE list='folder:3'") },0)
    }

    func testWholeChatCountsUseChatThenScopeIgnoreTopicAndFailClosed() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        for id: Int64 in 1...4 { try FolderFixture.apply(ChatFixture.chat(id,unread: id == 4 ? 0 : 2),index) }
        try FolderFixture.apply(TDLibMessage("updateChatIsMarkedAsUnread",["chat_id": .integer(4),"is_marked_as_unread": .bool(true)]),index)
        XCTAssertEqual(try index.project(now: FolderFixture.now).lists[0].counts.unreadItems,4)
        XCTAssertEqual(try index.project(now: FolderFixture.now).lists[0].counts.unmutedUnreadItems,0)
        try FolderFixture.apply(TDLibMessage("updateScopeNotificationSettings",["scope": .typed("notificationSettingsScopePrivateChats"),"notification_settings": .typed("scopeNotificationSettings",["mute_for": .integer(0)])]),index)
        try FolderFixture.apply(TDLibMessage("updateChatNotificationSettings",["chat_id": .integer(1),"notification_settings": .typed("chatNotificationSettings",["use_default_mute_for": .bool(false),"mute_for": .integer(100)])]),index)
        try FolderFixture.apply(ChatFixture.group(3,forum: true),index)
        try FolderFixture.apply(ChatFixture.chat(3,type: "chatTypeSupergroup",unread: 5),index)
        try index.db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO tg_settings VALUES (3,'',0,0,0),(3,'forum:7',9999999999,0,0)")
        }
        index.changed()
        var counts = try index.project(now: FolderFixture.now).lists[0].counts
        XCTAssertEqual(counts.unreadItems,4); XCTAssertEqual(counts.unmutedUnreadItems,3)
        try index.mode(4,.hidden,now: FolderFixture.now)
        counts = try index.project(now: FolderFixture.now).lists[0].counts
        XCTAssertEqual(counts.unreadItems,3); XCTAssertEqual(counts.unmutedUnreadItems,2)
    }

    func testMembersBindingsCollapseAndTombstonesAreIdempotent() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        try FolderFixture.apply(ChatFixture.chat(1),index)
        let a = UUID(), unknown = UUID(), window = UUID()
        for _ in 0..<2 { try index.setCustomMember(folder: a,chat: 1,member: true,binding: index.binding) }
        try index.setCustomMember(folder: unknown,chat: 1,member: true,binding: index.binding)
        XCTAssertEqual(try index.customMembers(binding: index.binding)[a],[1])
        let wrong = TelegramProfileBinding(environment: .test,account: ChatFixture.me,connectionID: UUID())
        XCTAssertThrowsError(try index.setCustomMember(folder: a,chat: 1,member: false,binding: wrong))
        for _ in 0..<2 { try index.applyTombstones([a],binding: index.binding) }
        XCTAssertEqual(try index.customMembers(binding: index.binding),[unknown:[1]])
        try index.setListCollapsed(window: window,list: .main,collapsed: true,binding: index.binding)
        try index.setListCollapsed(window: UUID(),list: .main,collapsed: true,binding: index.binding)
        try index.retainWindows([window],binding: index.binding)
        XCTAssertEqual(try index.project(now: FolderFixture.now).lists[0].collapsedWindows,[window])
    }

    func testAttentionWindowsFreezeKeysAndFilterClosedRowsWithoutShiftingCursors() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        try FolderFixture.seed(index,count: 120)
        try index.flushAttention(now: FolderFixture.now)
        try index.db.write { db in
            for id in 1...120 {
                try db.execute(sql: "INSERT INTO tg_reason_messages VALUES (?,1,'',?,'direct',0)",arguments: [id,1000 - id])
            }
            try index.rebuildAttentionSummaries(db)
        }
        index.changed(); let initial = try index.project(now: FolderFixture.now), owner = UUID()
        index.attentionHolds.insert(owner)
        try index.db.write { db in
            try db.execute(sql: "UPDATE tg_reason_messages SET date=9999 WHERE chat=61; DELETE FROM tg_reason_messages WHERE chat=11")
            try index.rebuildAttentionSummaries(db)
        }
        index.changed(); let held = try index.project(now: FolderFixture.now)
        XCTAssertEqual(held.attentionRevision,initial.attentionRevision); XCTAssertEqual(held.attentionTotal,119)
        let a = try index.attentionPage(start: 0,revision: initial.attentionRevision,now: FolderFixture.now)
        let b = try index.attentionPage(start: 50,revision: initial.attentionRevision,now: FolderFixture.now)
        let c = try index.attentionPage(start: 100,revision: initial.attentionRevision,now: FolderFixture.now)
        XCTAssertEqual(a.next,50); XCTAssertEqual(b.next,100)
        XCTAssertEqual(c.rows.map(\.id.chat),(101...120).map(Int64.init)); XCTAssertNil(c.next)
        XCTAssertEqual(a.rows.map(\.id.chat),(1...50).filter { $0 != 11 }.map(Int64.init))
        XCTAssertEqual(b.rows.map(\.id.chat),(51...100).map(Int64.init))
        XCTAssertEqual(b.rows.first { $0.id.chat == 61 }?.attentionOrderKey?.rankingTime,939)
        XCTAssertEqual(b.rows.first { $0.id.chat == 61 }?.attention?.lastDate,9999)
        XCTAssertEqual(a.attentionKeys?.map(\.chat),(1...50).map(Int64.init))
        XCTAssertEqual(held.attentionKeys,initial.attentionKeys)
        XCTAssertEqual(held.attentionKeys?.map(\.chat),(1...120).map(Int64.init),"Snapshots carry geometry beyond loaded metadata")
        XCTAssertEqual(held.attentionLiveChats,Set((1...120).filter { $0 != 11 }.map(Int64.init)))
        let initialState = try XCTUnwrap(initial.attentionState), heldState = try XCTUnwrap(held.attentionState)
        XCTAssertEqual(heldState.order,initialState.order,"The provider retains the position index during a hold")
        XCTAssertEqual(heldState.order.binding,index.binding)
        XCTAssertEqual(heldState.order.revision,initial.attentionRevision)
        XCTAssertEqual(heldState.order.positions.count,120)
        XCTAssertEqual(heldState.order.positions[11],10)
        XCTAssertEqual(heldState.order.positions[120],119)
        XCTAssertEqual(heldState.inactive,[11])
        XCTAssertNotEqual(heldState.version,initialState.version,"Live marks are versioned separately from frozen order")
        XCTAssertEqual(try index.project(now: FolderFixture.now).attentionState,heldState,"Unchanged held marks reuse their version and inactive set")
        try index.db.write { db in
            try db.execute(sql: "DELETE FROM tg_reason_messages WHERE chat BETWEEN 51 AND 100")
            try index.rebuildAttentionSummaries(db)
        }
        index.changed()
        let empty = try index.attentionPage(start: 50,revision: initial.attentionRevision,now: FolderFixture.now)
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertEqual(empty.attentionKeys,b.attentionKeys,"Even a first visit to a read window must carry its entire frozen membership")
        try index.db.write { db in
            try db.execute(sql: "INSERT INTO tg_reason_messages VALUES (61,2,'',9999,'direct',0)")
            try index.rebuildAttentionSummaries(db)
        }
        index.changed()
        let renewed = try index.attentionPage(start: 50,revision: initial.attentionRevision,now: FolderFixture.now)
        XCTAssertEqual(renewed.rows.map(\.id.chat),[61]); XCTAssertEqual(renewed.attentionKeys,b.attentionKeys)
        let renewedState = try XCTUnwrap(index.project(now: FolderFixture.now).attentionState)
        XCTAssertNotEqual(renewedState.version,heldState.version,"Further live changes invalidate the cached state during a hold")
        index.attentionHolds.remove(owner); let released = try index.project(now: FolderFixture.now)
        XCTAssertEqual(released.attentionRows.first?.id.chat,61)
        XCTAssertEqual(released.attentionLiveChats,renewedState.liveChats)
        XCTAssertNotEqual(released.attentionState?.version,renewedState.version,"An order change invalidates the state even when live marks are unchanged")
        XCTAssertNotEqual(released.attentionState?.order,initialState.order)
        XCTAssertEqual(released.attentionState?.order.positions[61],0)
        XCTAssertNil(released.attentionState?.order.positions[11])
        XCTAssertTrue(released.attentionState?.inactive.isEmpty == true)
        XCTAssertTrue(try index.attentionPage(start: 0,revision: initial.attentionRevision,now: FolderFixture.now).rows.isEmpty)
    }

    func testSearchRankSQLMatchesMergedResultsIncludingUnicodeHiddenAndArchive() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        for id: Int64 in 1...60 {
            try FolderFixture.apply(ChatFixture.chat(id,title: "Ада \(id)",message: ChatFixture.message(date: 100 + id)),index)
        }
        try FolderFixture.apply(ChatFixture.chat(61,title: "Ада",positions: [ChatFixture.position(list: .archive)]),index)
        try index.mode(61,.hidden,now: FolderFixture.now)
        _ = try index.project(now: FolderFixture.now)
        let rows = try index.localMatches("ада",now: FolderFixture.now)
        XCTAssertEqual(rows.count,50); XCTAssertEqual(rows.first?.id.chat,61)
        XCTAssertEqual(rows.map(\.id),rows.reversed().map { TelegramSearchHit(row: $0) }.sorted { TelegramSearchRank.precedes($0,$1,query: "ада") }.map(\.row.id))
        try index.db.write { db in
            try db.execute(sql: "INSERT INTO tg_reason_messages VALUES (60,1,'',9999,'direct',0)")
            try index.rebuildAttentionSummaries(db)
        }
        index.changed(); let snapshot = try index.project(now: FolderFixture.now)
        XCTAssertEqual(snapshot.suggestionRows.first?.id.chat,60)
        XCTAssertEqual(snapshot.suggestionRows.dropFirst().map(\.id.chat),(1...49).map(Int64.init))
        XCTAssertEqual(Set(snapshot.suggestionRows.map(\.id)).count,50)
    }

    func testOnlyAffectedListCountsAreRecomputedAndViewportBudgetIsGlobal() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        try FolderFixture.apply(FolderFixture.folders([2,3]),index)
        try FolderFixture.apply(ChatFixture.chat(1,positions: [ChatFixture.position(list: .folder(2))]),index)
        _ = try index.project(now: FolderFixture.now)
        try FolderFixture.apply(TDLibMessage("updateChatIsMarkedAsUnread",["chat_id": .integer(1),"is_marked_as_unread": .bool(true)]),index)
        XCTAssertEqual(index.countDirtyLists,[.folder(2)])
        _ = try index.project(now: FolderFixture.now)
        try index.mode(1,.hidden,now: FolderFixture.now)
        XCTAssertEqual(index.countDirtyLists,[.folder(2)])
        try index.setViewport(.main,windows: [0,50,100]); try index.setViewport(.folder(2),windows: [0,50])
        XCTAssertThrowsError(try index.setViewport(.folder(3),windows: [0]))
        let snapshot = try index.project(now: FolderFixture.now)
        XCTAssertEqual(snapshot.lists.reduce(0) { $0 + $1.windows.count },5)
    }

    func testMeasureFiveThousandChatOrderRebuild() throws {
        let fixture = try TelegramFixture(), index = try TelegramChatIndex(directory: fixture.directory,environment: .test,account: ChatFixture.me)
        try FolderFixture.seed(index,count: 5_000)
        var times: [Duration] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now; try index.rebuildList(.main); times.append(start.duration(to: .now))
        }
        let median = times.sorted()[2]
        print("Folder order rebuild 5k: median=\(median); design budget=5ms; within=\(median < .milliseconds(5))")
        XCTAssertEqual(try index.db.read { try Int.fetchOne($0,sql: "SELECT count(*) FROM tg_list_order WHERE list='main'") },5_000)
    }
}
