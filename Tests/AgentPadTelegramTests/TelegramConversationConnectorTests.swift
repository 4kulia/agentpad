import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramConversationConnectorTests: XCTestCase, @unchecked Sendable {
    func testFakeConnectorOpensHistoryReadsVisibleIDsAndRevokesOnLogout() async throws {
        let fixture = try TelegramFixture(), connector = try fixture.connector()
        await connector.connect(); await eventually { await isQR(connector) }
        fixture.client.enqueue(TDLibMessage("updateConnectionState", ["state": .typed("connectionStateReady")]))
        fixture.client.auth("authorizationStateReady")
        await eventually { if case .connected = await connector.currentSnapshot().state { true } else { false } }
        fixture.client.automaticForms = false
        let id = TelegramChatID(environment: .test, account: FakeTDLibClient.user["id"]!.integer!, chat: 202), pane = UUID()
        await connector.setApplicationActive(true)
        let stream = await connector.conversation(id, pane: pane)
        await eventually { fixture.client.requests.contains { $0.type == "getChat" } }
        let getChat = try XCTUnwrap(fixture.client.requests.last { $0.type == "getChat" })
        fixture.client.reply(getChat, TDLibMessage("chat", ["id": .integer(202), "title": .string("Synthetic chat"),
            "type": .typed("chatTypePrivate", ["user_id": .integer(202)])]))
        await eventually { fixture.client.requests.contains { $0.type == "getUser" } }
        fixture.client.reply(try XCTUnwrap(fixture.client.requests.last { $0.type == "getUser" }), TDLibMessage("user", ["id": .integer(202), "type": .typed("userTypeRegular"), "have_access": .bool(true)]))
        await eventually { fixture.client.requests.contains { $0.type == "getChatHistory" } }
        let history = try XCTUnwrap(fixture.client.requests.last { $0.type == "getChatHistory" })
        let message = TDLibMessage("message", ["id": .integer(1 << 20), "chat_id": .integer(202), "sender_id": .typed("messageSenderUser", ["user_id": .integer(202)]),
            "content": .typed("messageText", ["text": .typed("formattedText", ["text": .string("Synthetic incoming")])])])
        fixture.client.reply(history, TDLibMessage("messages", ["messages": .array([.object(message.fields)])]))
        var epoch: UUID?
        for await snapshot in stream {
            if !snapshot.messages.isEmpty {
                XCTAssertTrue(snapshot.capabilities.canSend)
                XCTAssertTrue(snapshot.capabilities.canSendPhotos)
                XCTAssertTrue(snapshot.capabilities.canSendDocuments)
                epoch = snapshot.epoch; break
            }
        }
        let current = try XCTUnwrap(epoch)
        XCTAssertFalse(fixture.client.requests.contains { ["viewMessages", "openChat", "sendMessage"].contains($0.type) })
        await connector.observePresentation(id, observation: TelegramPresentationObservations().record(.init(pane: pane, epoch: current, active: true, shown: true, ordinaryIDs: [1 << 20])))
        await eventually { fixture.client.requests.contains { $0.type == "openChat" } }
        fixture.client.reply(try XCTUnwrap(fixture.client.requests.last { $0.type == "openChat" }))
        await eventually { fixture.client.requests.contains { $0.type == "viewMessages" } }
        let read = try XCTUnwrap(fixture.client.requests.last { $0.type == "viewMessages" })
        XCTAssertEqual(read["message_ids"], .array([.integer(1 << 20)])); XCTAssertEqual(read["force_read"], .bool(false))
        fixture.client.reply(read)
        await connector.disconnect(); await eventually { await connector.currentSnapshot().state == .disconnected }
        await connector.sendDraft(id, epoch: current, draft: .init(text: "Stale action"))
        XCTAssertFalse(fixture.client.requests.contains { $0.type == "sendMessage" })
        XCTAssertFalse(fixture.client.mainThreadReceives)
    }
}
