import Foundation
import XCTest
@testable import AgentPadTelegram

final class TelegramEnvelopeTests: XCTestCase {
    func testTruncatedEnvelopeFailsWithoutReadingPastItsBuffer() {
        for json in ["{   ", "{\"@type\":\"messages\",   ", "{\"@type\": ", "{\"truncated\\"] {
            XCTAssertNil(json.withCString { TDLibEnvelope.scan($0, count: strlen($0)) })
        }
    }
    func testCorrelationAfterLargeEscapedBodyWithoutDecodingIt() throws {
        let body = String(repeating: "a😀\\\"{[]}@@", count: 350000)
        let message = TDLibValue.typed("message", ["content": .typed("messageText", ["text": .typed("formattedText", ["text": .string(body)])])])
        let bytes = try JSONEncoder().encode(TDLibMessage("messages", ["messages": .array([message]), "@client_id": .integer(7)]))
        var json = String(decoding: bytes, as: UTF8.self)
        json.removeLast(); json += ",\"@extra\":\"feed:history:synthetic\"}"
        let result = json.withCString { TDLibEnvelope.oversizedHistory($0, count: strlen($0), client: 7) }
        XCTAssertEqual(result?["message"], .string("page_too_large"))
        XCTAssertEqual(result?["@extra"], .string("feed:history:synthetic"))
        XCTAssertNil(json.withCString { TDLibEnvelope.oversizedHistory($0, count: strlen($0), client: 8) })
    }
    func testSendAndNotificationFramesAreNeverReclassifiedAsHistory() throws {
        let message = TDLibValue.typed("message", ["content": .typed("messageText", ["text": .typed("formattedText", ["text": .string("}\\\"")])])])
        for var frame in [message.object!, TDLibMessage("updateMessageSendSucceeded", ["message": message]),
                          TDLibMessage("updateActiveNotifications", ["groups": .array([])])] {
            frame["@client_id"] = .integer(7); frame["@extra"] = .string("feed:test")
            TelegramFixtureSchema.check(frame)
            let json = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
            XCTAssertNil(json.withCString { TDLibEnvelope.oversizedHistory($0, count: strlen($0), client: 7) })
        }
    }
    func testForumTopicPageUsesBoundedHistoryEnvelope() {
        let json = "{\"@type\":\"forumTopics\",\"@client_id\":7,\"topics\":[],\"@extra\":\"feed:history:topics\"}"
        let result = json.withCString { TDLibEnvelope.oversizedHistory($0, count: strlen($0), client: 7) }
        XCTAssertEqual(result?["message"], .string("page_too_large"))
    }

}
