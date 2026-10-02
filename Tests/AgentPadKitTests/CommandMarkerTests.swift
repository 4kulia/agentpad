import XCTest
@testable import AgentPadKit

final class CommandMarkerTests: XCTestCase {
    func testParsesThePayloadAfterThePrefix() {
        XCTAssertEqual(
            CommandMarker.parseTitle(CommandMarker.titlePrefix + "git status --short"),
            "git status --short"
        )
    }

    func testIgnoresTitlesThatArentMarkers() {
        XCTAssertNil(CommandMarker.parseTitle("~/Github/agentpadcode"))
        XCTAssertNil(CommandMarker.parseTitle("agentpad-remote-login:build-box"))
        XCTAssertNil(CommandMarker.parseTitle(""))
    }

    func testRejectsAnEmptyPayload() {
        XCTAssertNil(CommandMarker.parseTitle(CommandMarker.titlePrefix))
        XCTAssertNil(CommandMarker.parseTitle(CommandMarker.titlePrefix + "   \t "))
    }

    /// The shell flattens controls before emitting, but the byte stream is not
    /// a trust boundary — any program can print this escape sequence, so a
    /// control character must never reach SwiftUI from here.
    func testFlattensControlCharactersToSpaces() {
        let raw = "echo\u{1B}[2Jone\u{07}two\u{7F}three"
        XCTAssertEqual(CommandMarker.parseTitle(CommandMarker.titlePrefix + raw), "echo [2Jone two three")
    }

    func testTrimsEdgesAndCapsLength() {
        XCTAssertEqual(CommandMarker.parseTitle(CommandMarker.titlePrefix + "  ls -la  "), "ls -la")

        // Truncation counts Characters, not bytes, so CJK stays whole.
        let long = String(repeating: "界", count: CommandMarker.maxLength + 20)
        let parsed = CommandMarker.parseTitle(CommandMarker.titlePrefix + long)
        XCTAssertEqual(parsed?.count, CommandMarker.maxLength)
        XCTAssertEqual(parsed?.last, "界")
    }
}
