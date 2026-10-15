import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramChatConnectorTests: XCTestCase, @unchecked Sendable {
    func testReadyUpdatesSearchAndLogoutUseOnlyFakeTDLib() async throws {
        let fixture = try TelegramFixture()
        let connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        fixture.client.enqueue(TDLibMessage("updateConnectionState", ["state": .object(["@type": .string("connectionStateReady")])]))
        fixture.client.auth("authorizationStateReady")
        await eventually { if case .connected = await connector.currentSnapshot().state { true } else { false } }
        let time = Int64(Date().timeIntervalSince1970)
        fixture.client.enqueue(ChatFixture.chat(100, title: "From last message", message: ChatFixture.message(date: time)))
        let id = TelegramChatID(environment: .test, account: ChatFixture.me, chat: 100)
        await eventually { await connector.chat(id)?.knownRelevant == true }
        let loaded = await connector.chat(id)
        let row = try XCTUnwrap(loaded)
        await connector.setChatMode(id, mode: .hidden)
        let stream = await connector.searchTelegram("From last message")
        var iterator = stream.makeAsyncIterator()
        let hits = await iterator.next()
        XCTAssertEqual(hits?.hits.first?.row.id, id); XCTAssertEqual(hits?.hits.first?.row.hidden, true)
        let opened = await connector.resolveChat(.init(row: row))
        XCTAssertEqual(opened?.id, id)
        await connector.didOpenChat(id)
        XCTAssertTrue(fixture.client.requests.contains { $0.type == "addRecentlyFoundChat" })
        XCTAssertFalse(fixture.client.mainThreadReceives)
        XCTAssertFalse(fixture.client.requests.contains { ["sendMessage", "viewMessages", "getChatHistory", "searchChatMessages"].contains($0.type) })
        await connector.disconnect()
        await eventually { await connector.currentSnapshot().state == .disconnected }
        let stale = await connector.resolveChat(.init(row: row))
        XCTAssertNil(stale)
        _ = await connector.close()
    }
}
