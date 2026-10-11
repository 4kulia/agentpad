import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramSendQueueTests: XCTestCase {
    private func chat(_ h: TelegramFeedHarness, _ id: Int64) -> TDLibMessage {
        var chat = h.chat(); chat["id"] = .integer(id); return chat
    }
    private func message(_ h: TelegramFeedHarness, chat: Int64, id: Int64, pending: Bool = false) -> TDLibMessage {
        var message = h.message(id, outgoing: true, state: pending ? .typed("messageSendingStatePending") : .null)
        message["chat_id"] = .integer(chat); return message
    }
    private func respond(_ h: TelegramFeedHarness, to request: TDLibMessage, with response: TDLibMessage) {
        var response = response; response["@extra"] = request["@extra"]
        h.session.receive(response, now: h.session.now, uptime: h.session.uptime)
    }
    private func refresh(_ h: TelegramFeedHarness, chat id: Int64) throws {
        let request = try h.answer("getChat", chat(h, id))
        XCTAssertEqual(request["chat_id"], .integer(id))
        try h.answer("getUser", h.user())
    }
    @discardableResult private func send(_ h: TelegramFeedHarness, chat id: Int64, attachments: [TelegramStagedAttachment] = []) throws -> TelegramChatID {
        let destination = TelegramChatID(environment: .test, account: 101, chat: id)
        if h.session.feeds[destination] == nil {
            _ = h.session.subscribe(destination, pane: UUID())
            let feed = try XCTUnwrap(h.session.feeds[destination])
            h.session.applyChat(chat(h, id), to: feed); feed.peer = h.user(); h.session.capabilities(feed)
            feed.loaded = true; feed.needsDetails = false
        }
        let draft = TelegramDraft(text: "Message for \(id)", attachments: attachments)
        h.session.draft(destination, epoch: h.epoch, value: draft)
        h.session.sendDraft(destination, epoch: h.epoch, draft: draft)
        try refresh(h, chat: id)
        XCTAssertTrue(h.session.feeds[destination]!.snapshot.draft.isEmpty)
        return destination
    }
    private func succeed(_ h: TelegramFeedHarness, chat: Int64, pending: Int64) {
        h.update("updateMessageSendSucceeded", ["old_message_id": .integer(pending),
            "message": .object(message(h, chat: chat, id: pending + 1000).fields)])
    }

    func testFIFOAdvancesAcrossChatsOnSuccessFailedUpdateAndFailedResponse() throws {
        for outcome in ["success", "failedUpdate", "failedResponse", "earlySuccess"] {
            let h = try TelegramFeedHarness()
            try send(h, chat: 202)
            try h.answer("sendMessage", message(h, chat: 202, id: 91, pending: true))
            try send(h, chat: 303)
            let secondSend = try XCTUnwrap(h.client.requests.last { $0.type == "sendMessage" })
            if outcome == "earlySuccess" {
                var pending = message(h, chat: 303, id: 92, pending: true)
                pending["sending_state"] = .typed("messageSendingStatePending", ["sending_id": .integer(h.journal.operations[1].parts[0].sendingID)])
                h.update("updateNewMessage", ["message": .object(pending.fields)])
            } else if outcome != "failedResponse" { try h.answer("sendMessage", message(h, chat: 303, id: 92, pending: true)) }
            try send(h, chat: 404); try send(h, chat: 505)
            XCTAssertEqual(h.client.requests.filter { $0.type == "sendMessage" }.count, 2)
            XCTAssertEqual(h.journal.operations.suffix(2).map { $0.parts[0].state }, [.queued, .queued])
            switch outcome {
            case "success", "earlySuccess": succeed(h, chat: 303, pending: 92)
            case "failedUpdate":
                var failed = message(h, chat: 303, id: 93)
                failed["sending_state"] = .typed("messageSendingStateFailed")
                h.update("updateMessageSendFailed", ["old_message_id": .integer(92), "message": .object(failed.fields)])
            default: try h.answer("sendMessage", TDLibMessage("error", ["message": .string("SEND_FAILED")]))
            }
            try refresh(h, chat: 404)
            XCTAssertEqual(h.sendingChats, [202, 404])
            try h.answer("sendMessage", message(h, chat: 404, id: 94, pending: true))
            succeed(h, chat: 202, pending: 91)
            try refresh(h, chat: 505)
            XCTAssertEqual(h.client.requests.filter { $0.type == "sendMessage" }.compactMap { $0["chat_id"]?.integer }, [202, 303, 404, 505])
            XCTAssertEqual(h.session.sending.count, 2)
            if outcome == "earlySuccess" {
                respond(h, to: secondSend, with: message(h, chat: 303, id: 92, pending: true))
                XCTAssertEqual(h.journal.operations[1].parts[0].state, .sent)
                XCTAssertEqual(h.session.sending.count, 2)
            }
        }
    }

    func testBatchContinuationWaitsBehindOlderQueuedChat() throws {
        let h = try TelegramFeedHarness()
        let a = try h.journal.stage(Data([1]), name: "a.txt", mime: "text/plain", width: 0, height: 0)
        let b = try h.journal.stage(Data([2]), name: "b.txt", mime: "text/plain", width: 0, height: 0)
        try send(h, chat: 202, attachments: [a, b])
        try h.answer("sendMessage", message(h, chat: 202, id: 91, pending: true))
        try send(h, chat: 303)
        try h.answer("sendMessage", message(h, chat: 303, id: 92, pending: true))
        try send(h, chat: 404)
        succeed(h, chat: 202, pending: 91)
        try refresh(h, chat: 404)
        try h.answer("sendMessage", message(h, chat: 404, id: 93, pending: true))
        succeed(h, chat: 303, pending: 92)
        try refresh(h, chat: 202)
        let requests = h.client.requests.filter { $0.type == "sendMessage" }
        XCTAssertEqual(requests.compactMap { $0["chat_id"]?.integer }, [202, 303, 404, 202])
        XCTAssertEqual(requests.last?["input_message_content"]?.object?["caption"]?.object?["text"], .string(""))
        XCTAssertEqual(h.session.sending.count, 2)
    }

    func testQueuedSendSurvivesClosedPaneAndInteractiveBackpressure() throws {
        let h = try TelegramFeedHarness()
        for id: Int64 in [202, 303] {
            try send(h, chat: id); try h.answer("sendMessage", message(h, chat: id, id: id + 1, pending: true))
        }
        let destination = try send(h, chat: 404)
        let feed = try XCTUnwrap(h.session.feeds[TelegramChatID(environment: .test, account: 101, chat: 404)])
        for pane in feed.observers.keys { h.session.release(destination, pane: pane) }
        h.session.externalInteractive = { 6 }
        succeed(h, chat: 202, pending: 203)
        h.session.tick(now: h.now, uptime: 10)
        XCTAssertNotNil(h.session.feeds[TelegramChatID(environment: .test, account: 101, chat: 404)]); XCTAssertEqual(h.session.sendQueue.count, 1)
        h.session.externalInteractive = { 0 }
        h.session.tick(now: h.now, uptime: 11)
        try refresh(h, chat: 404)
        XCTAssertEqual(h.client.requests.filter { $0.type == "sendMessage" }.compactMap { $0["chat_id"]?.integer }, [202, 303, 404])
    }

    func testRestartRestoresQueuedTextReplyAndFilesWithoutReplaying() throws {
        for firstState in [TelegramSendJournal.Part.State.queued, .submitting, .pending] {
            let h = try TelegramFeedHarness()
            let a = try h.journal.stage(Data([1]), name: "a.txt", mime: "text/plain", width: 0, height: 0)
            let b = try h.journal.stage(Data([2]), name: "b.txt", mime: "text/plain", width: 0, height: 0)
            let original = TelegramDraft(text: "caption", replyTo: 10, attachments: [a, b])
            let operation = try h.journal.create(chat: 202, draft: original, parts: [.init(attachment: a.id), .init(attachment: b.id)], now: h.now)
            try h.journal.update(operation) { $0.parts[0].state = firstState }
            let journal = try TelegramSendJournal(directory: h.fixture.directory, databaseKey: Data(repeating: 7, count: 32), now: h.now)
            let session = TelegramFeedSession(account: 101, environment: .test, epoch: h.epoch, journal: journal, send: { [client = h.client] in try client.send($0) })
            _ = session.subscribe(h.id, pane: h.pane)
            session.publish()
            let feed = try XCTUnwrap(session.feeds[TelegramChatID(environment: .test, account: 101, chat: 202)])
            XCTAssertTrue(try XCTUnwrap(feed.snapshot.operations.first).canRecover)
            session.recover(h.id, epoch: h.epoch, operation: operation)
            XCTAssertEqual(feed.snapshot.draft.attachments, firstState == .queued ? [a, b] : [b])
            XCTAssertEqual(feed.snapshot.draft.text, firstState == .queued ? "caption" : "")
            XCTAssertEqual(feed.snapshot.draft.replyTo, 10)
            for file in feed.snapshot.draft.attachments { try journal.validate(file) }
            XCTAssertFalse(h.client.requests.contains { $0.type == "sendMessage" })
            XCTAssertEqual(journal.operation(operation)?.parts.last?.state, .restored)
            // Removing restored attachments releases their quota; unresolved
            // sends still own their files and can settle later.
            session.draft(h.id, epoch: h.epoch, value: .init())
            XCTAssertFalse(FileManager.default.fileExists(atPath: journal.staging.appendingPathComponent(b.id.uuidString).path))
            if firstState != .queued { try journal.validate(a) }
        }
    }

    func testRestoreCancelsQueuedValidationBeforeSendMessage() throws {
        let h = try TelegramFeedHarness()
        for id: Int64 in [202, 303] {
            try send(h, chat: id); try h.answer("sendMessage", message(h, chat: id, id: id + 1, pending: true))
        }
        let destination = try send(h, chat: 404)
        succeed(h, chat: 202, pending: 203) // queued chat's validation is now in flight
        let operation = try XCTUnwrap(h.journal.operations.last)
        h.session.recover(destination, epoch: h.epoch, operation: operation.id)
        try refresh(h, chat: 404)
        XCTAssertEqual(h.session.feeds[TelegramChatID(environment: .test, account: 101, chat: 404)]?.snapshot.draft.text, "Message for 404")
        XCTAssertEqual(h.client.requests.filter { $0.type == "sendMessage" }.count, 2)
        XCTAssertNil(h.session.preparingSend)
    }

    func testRetryUsesTheSameFIFOAndSendLimit() throws {
        let h = try TelegramFeedHarness()
        try send(h, chat: 202)
        try h.answer("sendMessage", message(h, chat: 202, id: 91, pending: true))
        var failed = message(h, chat: 202, id: 92)
        failed["sending_state"] = .typed("messageSendingStateFailed", ["can_retry": .bool(true), "retry_after": .decimal(0),
            "need_drop_reply": .bool(false), "need_another_sender": .bool(false), "need_another_reply_quote": .bool(false), "required_paid_message_star_count": .integer(0)])
        h.update("updateMessageSendFailed", ["old_message_id": .integer(91), "message": .object(failed.fields)])
        for id: Int64 in [303, 404] {
            try send(h, chat: id); try h.answer("sendMessage", message(h, chat: id, id: id + 1, pending: true))
        }
        h.session.retry(h.id, epoch: h.epoch, messageID: 92)
        h.session.retry(h.id, epoch: h.epoch, messageID: 92)
        try send(h, chat: 505)
        XCTAssertEqual(h.session.sendQueue.count, 2) // repeated Retry is deduplicated
        XCTAssertFalse(h.client.requests.contains { $0.type == "resendMessages" })
        succeed(h, chat: 303, pending: 304)
        try refresh(h, chat: 202)
        try h.answer("getMessage", failed)
        try h.answer("getMessageProperties", TDLibMessage("messageProperties"))
        XCTAssertEqual(h.session.sending.count, 2)
        try h.answer("resendMessages", TDLibMessage("error", ["message": .string("RETRY_FAILED")]))
        try refresh(h, chat: 505)
        let sends = h.client.requests.filter { ["sendMessage", "resendMessages"].contains($0.type) }
        XCTAssertEqual(sends.compactMap { $0["chat_id"]?.integer }, [202, 303, 404, 202, 505])
    }
}

private extension TelegramFeedHarness {
    var sendingChats: Set<Int64> {
        Set(journal.operations.filter { operation in operation.parts.contains { session.sending.contains($0.key) } }.map(\.chat))
    }
}
