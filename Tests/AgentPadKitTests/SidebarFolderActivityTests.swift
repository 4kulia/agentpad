import Foundation
import GRDB
import XCTest
@testable import AgentPadKit
@testable import AgentPadTelegram

final class SidebarFolderActivityTests: XCTestCase {
    func testChannelActivityIgnoresPlaceholderDeletedAndLocalRowsAndChangesOrgEquality() throws {
        let db = try DatabaseQueue()
        try ChatStoreMigrations.cache.migrate(db)
        let activity = try db.write { db in
            try db.execute(sql: "INSERT INTO channels(channel_id,team_id,name,archived,version,stamp,created_at) VALUES ('one','team','One',0,1,1,'2026-01-01T00:00:00Z'),('empty','team','Empty',0,1,1,'2026-01-02T00:00:00Z')")
            try db.execute(sql: "INSERT INTO messages(message_id,channel_id,created_at,deleted_at,local_state) VALUES ('placeholder','one',NULL,NULL,NULL),('real','one','2026-01-03T00:00:00Z',NULL,NULL),('local','one','2026-01-04T00:00:00Z',NULL,'pending'),('deleted','one','2026-01-05T00:00:00Z','gone',NULL)")
            return try ChatChannels.activity(db)
        }
        XCTAssertEqual(activity["one"],ChatFeedLayout.date("2026-01-03T00:00:00Z"))
        XCTAssertEqual(activity["empty"],ChatFeedLayout.date("2026-01-02T00:00:00Z"))
        var a = ChatOrgView(), b = a; b.channelActivity = activity
        XCTAssertNotEqual(a,b); a.channelActivity = activity; XCTAssertEqual(a,b)
    }
    func testFullCrossTypeActivityOrderIncomingOutgoingEmptyAndStableTies() throws {
        let scope = ChatOrgKey(server: try ChatServerAddress(parsing: "https://example.com"),accountId: "owner",orgId: "org")
        func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        func person(_ name: String,_ activity: Double?) -> ChatDMPerson {
            let peer = ChatDMCard.Peer(accountId: name,name: name,handle: name,active: true)
            let conversation = activity.map { ChatDMEntry(card: .init(dmId: name,peer: peer,state: "active",version: 1,createdAt: ""),lastUsed: date($0),roots: .init(),replies: 0,hasMessages: true) }
            return .init(peer: peer,conversation: conversation)
        }
        let profile = AgentProfile(id: UUID(),name: "Agent",templateID: "test",rosterID: "test",folder: URL(fileURLWithPath: "/fixture"),launchOptions: "",createdAt: date(4))
        let session = AgentSessionRecord(agentId: "test",conversationId: "session",title: "",cwd: profile.folder,lastActivity: date(8))
        let channel = ChatSidebarSnapshot.Channel(card: .init(channelId: "channel",teamId: "team",name: "Channel",archived: false,version: 1),unread: .init(),mentions: 0,activity: date(5))
        let team = ChatSidebarSnapshot.Agent(id: "team",name: "Team",owner: "owner",description: "",access: "",mine: false,channels: [],inCurrentChannel: false)
        func telegram(_ id: Int64,_ name: String,_ time: Int64) -> SidebarItemSummary {
            .telegram(.init(id: .init(environment: .test,account: 1,chat: id),title: name,username: "",kind: .person,
                unreadCount: 0,unreadMentionCount: 0,inMain: true,inArchive: false,pinned: false,hidden: false,lastMessageDate: time,knownRelevant: false))
        }
        let values: [SidebarItemSummary] = [.person(person("Incoming",7),scope: scope),.person(person("Outgoing",6),scope: scope),
            .person(person("Empty",nil),scope: scope),.channel(channel,scope: scope),.myAgent(profile,sessions: [session]),
            .myAgent(profile,sessions: []),.teamAgent(team,scope: scope),telegram(1,"Telegram",9),telegram(2,"Undated",0)]
        XCTAssertEqual(values.sorted(by: SidebarItemSummary.precedes).map(\.title),["Telegram","Agent","Incoming","Outgoing","Channel","Agent","Empty","Team","Undated"])
        XCTAssertEqual([telegram(3,"Same",0),telegram(2,"Same",0)].sorted(by: SidebarItemSummary.precedes).map(\.reference),[.telegram(2),.telegram(3)])
    }
    func testMeasureTwentyThousandSummarySortAndHundredThousandReferenceRewrite() throws {
        let fixture = try SidebarFolderFixture()
        var catalog = SidebarFolderCatalog(), values: [SidebarItemSummary] = []
        for folder in 0..<5 {
            let id = UUID()
            let items = (0..<20_000).map { SidebarAgentPadReference.person(.init(server: "https://example.com",account: "owner",org: "org",peer: "person-\(folder)-\($0)")) }
            catalog.custom.append(.init(id: id,name: "Collection",items: items)); catalog.order.insert(SidebarEntryIdentity.custom(id),at: 0)
            if folder == 0 { values = items.enumerated().map { .init(reference: .agentpad($0.element),title: "Person \($0.offset)",activity: Date(timeIntervalSince1970: Double($0.offset))) } }
        }
        try catalog.validate()
        let sortStart = ContinuousClock.now
        let sorted = values.sorted(by: SidebarItemSummary.precedes)
        let sortTime = sortStart.duration(to: .now)
        XCTAssertEqual(sorted.count,20_000); XCTAssertEqual(sorted.first?.title,"Person 19999")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let writeStart = ContinuousClock.now
        let bytes = try encoder.encode(catalog); try SidebarFoldersDisk.write(bytes,to: fixture.catalogURL)
        let writeTime = writeStart.duration(to: .now)
        print("Folder budgets (debug, local hardware): sort20k=\(sortTime), encode+atomicWrite100k=\(writeTime), bytes=\(bytes.count)")
        // Release budgets are measured, not replaced by slower debug thresholds.
        XCTAssertEqual(try JSONDecoder().decode(SidebarFolderCatalog.self,from: Data(contentsOf: fixture.catalogURL)),catalog)
    }
}
