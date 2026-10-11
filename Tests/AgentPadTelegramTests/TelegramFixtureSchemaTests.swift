import Foundation
import XCTest
@testable import AgentPadTelegram

/// Sparse fixtures are intentional; invented fields and constructors are not.
/// Validate replies and shared fixtures against the actual pinned checkout.
enum TelegramFixtureSchema {
    static let definitions: [String: [String: String]] = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let schema = try! String(contentsOf: root.appendingPathComponent(".build/checkouts/TDLibFramework/td/td/generate/scheme/td_api.tl"), encoding: .utf8)
        var result: [String: [String: String]] = [:]
        for line in schema.split(separator: "\n") where !line.hasPrefix("//") && line.contains(" = ") {
            let tokens = line.components(separatedBy: " = ")[0].split(separator: " ")
            guard let name = tokens.first else { continue }
            var fields: [String: String] = [:]
            for token in tokens.dropFirst() {
                let pair = token.split(separator: ":", maxSplits: 1)
                if pair.count == 2 { fields[String(pair[0])] = String(pair[1]) }
            }
            result[String(name)] = fields
        }
        return result
    }()

    static func check(_ message: TDLibMessage, file: StaticString = #filePath, line: UInt = #line) {
        check(.object(message.fields), file: file, line: line)
    }
    static func check(_ value: TDLibValue, expected: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        switch value {
        case .object(let fields):
            let type = fields["@type"]?.string ?? expected
            let definition = type.flatMap { definitions[$0] }
            if let explicit = fields["@type"]?.string { XCTAssertNotNil(definition, "Unknown TDLib constructor: \(explicit)", file: file, line: line) }
            for (key, nested) in fields {
                // JSON transport metadata is outside the TL object schema.
                if ["@type", "@extra", "@client_id"].contains(key) { continue }
                if let definition { XCTAssertNotNil(definition[key], "Unknown TDLib field: \(type!).\(key)", file: file, line: line) }
                check(nested, expected: definition?[key], file: file, line: line)
            }
        case .array(let values):
            let element = expected.flatMap { $0.hasPrefix("vector<") ? String($0.dropFirst(7).dropLast()) : nil }
            for value in values { check(value, expected: element, file: file, line: line) }
        default: break
        }
    }
}

final class TelegramFixtureSchemaTests: XCTestCase {
    func testSharedFixturesUseOnlyPinnedFields() throws {
        for type in ["chatTypePrivate", "chatTypeSecret", "chatTypeBasicGroup", "chatTypeSupergroup"] {
            TelegramFixtureSchema.check(ChatFixture.chat(1, type: type, message: ChatFixture.message()))
        }
        TelegramFixtureSchema.check(ChatFixture.group(1, channel: true))
        TelegramFixtureSchema.check(AttentionFixture.message(100, unreadMention: true, reply: 50, topic: 2))
        TelegramFixtureSchema.check(AttentionFixture.settings())
        TelegramFixtureSchema.check(NotificationFixture.snapshot([NotificationFixture.notification(1, message: 100)]))
        TelegramFixtureSchema.check(NotificationFixture.group(added: [NotificationFixture.notification(2, message: 101)]))
        let h = try TelegramFeedHarness()
        TelegramFixtureSchema.check(h.chat()); TelegramFixtureSchema.check(h.user()); TelegramFixtureSchema.check(h.message(100))
        for kind in ["messageText", "messagePhoto", "messageVideo", "messageAnimation"] {
            TelegramFixtureSchema.check(h.ads([h.ad(kind: kind, file: kind == "messageText" ? nil : .typed("file", ["id": .integer(1)]))]))
        }
    }
}
