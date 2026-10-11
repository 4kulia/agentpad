import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramHistoryEvictionTests: XCTestCase {
    private func page(_ h: TelegramFeedHarness, ids: ClosedRange<Int64>, text: String = "hello") -> TDLibMessage {
        TDLibMessage("messages", ["messages": .array(ids.reversed().map { .object(h.message($0, text: text).fields) })])
    }
    private func assertContinuous(_ feed: TelegramFeedSession.Feed, file: StaticString = #filePath, line: UInt = #line) {
        let ids = feed.snapshot.messages.map(\.messageID)
        if let first = ids.first, let last = ids.last { XCTAssertEqual(ids, Array(first...last), file: file, line: line) }
    }
    private func addFeed(_ h: TelegramFeedHarness, chat: Int64, count: Int, text: String) throws {
        let id = TelegramChatID(environment: .test, account: 101, chat: chat)
        _ = h.session.subscribe(id, pane: UUID())
        let feed = try XCTUnwrap(h.session.feeds[id])
        feed.snapshot.capabilities.canRead = true; feed.loaded = true; feed.needsDetails = false
        feed.used = h.now.addingTimeInterval(Double(chat))
        feed.historyCursor = 1
        for value in 1...count {
            var raw = h.message(Int64(value), text: text); raw["chat_id"] = .integer(chat)
            h.session.merge(raw, into: feed)
        }
    }

    func testLiveEvictionKeepsEarlierPagesContiguousUnderCountAndByteLimits() throws {
        for text in ["hello", String(repeating: "x", count: 9000)] {
            let h = try TelegramFeedHarness()
            h.session.load(h.feed, latest: true)
            try h.answer("getChatHistory", page(h, ids: 1...50, text: text))
            for id in 51...550 { h.update("updateNewMessage", ["message": .object(h.message(Int64(id), text: text).fields)]) }
            let oldest = try XCTUnwrap(h.feed.snapshot.messages.first?.messageID)
            XCTAssertGreaterThan(oldest, 1)
            XCTAssertEqual(h.feed.historyCursor, oldest)
            h.session.load(h.feed, latest: false)
            let request = try h.answer("getChatHistory", page(h, ids: (oldest - 49)...oldest, text: text))
            XCTAssertEqual(request["from_message_id"], .integer(oldest))
            XCTAssertEqual(h.feed.historyCursor, oldest - 49)
            XCTAssertEqual(h.feed.snapshot.messages.first?.messageID, oldest - 49)
            XCTAssertTrue(h.feed.snapshot.hasNewer)
            assertContinuous(h.feed)
            XCTAssertTrue(h.feed.expired.isEmpty)
        }
    }

    func testGlobalEvictionMovesTheCursorForBothMemoryLimits() throws {
        for byteLimit in [false, true] {
            let h = try TelegramFeedHarness(), text = String(repeating: "x", count: byteLimit ? 9000 : 1)
            h.feed.used = h.now; h.feed.historyCursor = 1
            for id in 1...(byteLimit ? 400 : 500) { h.session.merge(h.message(Int64(id), text: text), into: h.feed) }
            let counts = byteLimit ? [400, 400, 400, 400] : [500, 500, 500, 250]
            for (index, count) in counts.enumerated() { try addFeed(h, chat: Int64(index + 1), count: count, text: text) }
            h.session.boundMemory()
            let oldest = try XCTUnwrap(h.feed.snapshot.messages.first?.messageID)
            XCTAssertGreaterThan(oldest, 1)
            XCTAssertEqual(h.feed.historyCursor, oldest)
            h.session.load(h.feed, latest: false)
            let request = try h.answer("getChatHistory", page(h, ids: (oldest - 49)...oldest, text: text))
            XCTAssertEqual(request["from_message_id"], .integer(oldest))
            assertContinuous(h.feed)
            XCTAssertTrue(h.feed.expired.isEmpty)
        }
    }

    func testEvictionRejectsAnInFlightPageFromTheOldBoundary() throws {
        let h = try TelegramFeedHarness()
        h.session.load(h.feed, latest: true)
        try h.answer("getChatHistory", page(h, ids: 101...150))
        h.session.load(h.feed, latest: false)
        for id in 151...650 { h.update("updateNewMessage", ["message": .object(h.message(Int64(id)).fields)]) }
        XCTAssertEqual(h.feed.historyCursor, 151)
        try h.answer("getChatHistory", page(h, ids: 51...100))
        XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), Array(Int64(151)...650))
        XCTAssertEqual(h.feed.historyCursor, 151)
        h.session.load(h.feed, latest: false)
        let request = try h.answer("getChatHistory", page(h, ids: 102...151))
        XCTAssertEqual(request["from_message_id"], .integer(151))
        assertContinuous(h.feed)
    }

    func testCompleteGlobalEvictionReloadsAtTheEvictedWindowPosition() throws {
        let h = try TelegramFeedHarness()
        h.feed.used = h.now; h.feed.historyCursor = 1
        for id in 1...500 { h.session.merge(h.message(Int64(id)), into: h.feed) }
        for chat: Int64 in 1...4 { try addFeed(h, chat: chat, count: 500, text: "hello") }
        h.session.boundMemory()
        XCTAssertTrue(h.feed.snapshot.messages.isEmpty)
        XCTAssertEqual(h.feed.historyCursor, 500)
        XCTAssertTrue(h.feed.snapshot.hasOlder)
        h.session.load(h.feed, latest: false)
        let request = try h.answer("getChatHistory", page(h, ids: 451...500))
        XCTAssertEqual(request["from_message_id"], .integer(500))
        XCTAssertEqual(h.feed.snapshot.messages.map(\.messageID), Array(Int64(451)...500))
        XCTAssertEqual(h.feed.historyCursor, 451)
        XCTAssertTrue(h.feed.expired.isEmpty)
    }
}
