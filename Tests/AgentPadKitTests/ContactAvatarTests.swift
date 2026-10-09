import XCTest
@testable import AgentPadKit

final class ContactAvatarTests: XCTestCase {
    func testFixedUTF8HashesAndSameNameDifferentIdentity() {
        XCTAssertEqual(AvatarPlaceholder.hash(""), 0x811c9dc5)
        XCTAssertEqual(AvatarPlaceholder.hash("hello"), 0x4f9f2cab)
        XCTAssertEqual(AvatarPlaceholder.hash("агент-é"), 0x864a7282)
        var alex = AvatarPlaceholder(stableID: "acc_01J7VQ3A9KA0", name: "Alex Kim", kind: .person)
        let otherAlex = AvatarPlaceholder(stableID: "acc_01J9C0F4T8AT", name: alex.name, kind: .person)
        XCTAssertEqual(alex.colorIndex, 7)
        XCTAssertEqual(otherAlex.colorIndex, 1)
        let original = alex.color(isLight: true)
        alex.name = "Sam Lee"
        XCTAssertEqual(alex.letter, "S")
        XCTAssertEqual(alex.color(isLight: true), original)
    }

    func testOneUnicodeLetterOrNumberSkippingEmojiAndWhitespace() {
        for (name, letter) in [("  élodie Martin", "É"), ("e\u{301}lodie", "É"), ("🐇 Rabbit", "R"),
                               (" Марина Иванова ", "М"), ("deploy-bot", "D"), ("--42 bots", "4"),
                               ("李 明", "李"), ("🤖💬  ", "?"), ("", "?")] {
            XCTAssertEqual(AvatarPlaceholder.letter(name), letter, name)
        }
    }

    func testPaletteContrastInBothThemes() {
        func channel(_ value: UInt32) -> Double {
            let s = Double(value) / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        for palette in [AvatarPlaceholder.lightPalette, AvatarPlaceholder.darkPalette] {
            XCTAssertEqual(palette.count, 12)
            XCTAssertEqual(Set(palette).count, 12)
            for rgb in palette {
                let luminance = 0.2126 * channel((rgb >> 16) & 255)
                    + 0.7152 * channel((rgb >> 8) & 255) + 0.0722 * channel(rgb & 255)
                XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5, String(rgb, radix: 16))
            }
        }
    }

    func testAttributionUsesStableAgentOrAccountNeverSessionName() {
        let agent = ChatAuthorIdentity(account: "owner", agent: "agent-id", session: "Old name")
        let renamed = ChatAuthorIdentity(account: "owner", agent: "agent-id", session: "New name")
        XCTAssertEqual(agent.avatarID, "agent-id")
        XCTAssertEqual(agent.avatarID, renamed.avatarID)
        let legacy = ChatAuthorIdentity(account: "account-id", agent: nil, session: "Terminal")
        XCTAssertEqual(legacy.avatarID, "account-id")
        XCTAssertTrue(legacy.isBot)
        let person = AvatarPlaceholder(stableID: "account-id", name: "Alex", kind: .person)
        let bot = AvatarPlaceholder(stableID: "agent-id", name: "reviewer", kind: .agent)
        XCTAssertEqual(person.cornerRadius(size: 100), 50)
        XCTAssertEqual(bot.cornerRadius(size: 100), 27)
    }
}
