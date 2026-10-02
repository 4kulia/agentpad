import XCTest
import AgentPadHookKit

final class ShellCommandProtocolTests: XCTestCase {
    func testCommandNormalizationRejectsControlsAndOversizedUTF8() {
        XCTAssertEqual(AgentPadHookKit.normalizedShellCommand("git switch '中文'\r"), "git switch '中文'")
        for command in ["", "\r", "nvm use v22\nexit", "nvm\0use", "\u{1B}evil", String(repeating: "a", count: 4097), String(repeating: "中", count: 1366)] {
            XCTAssertNil(AgentPadHookKit.normalizedShellCommand(command))
        }
    }

    func testRequestCarriesSessionAndShellIdentity() throws {
        let id = UUID()
        let request = AgentPadShellCommandRequest(surface: id, shellPID: 123)
        let line = try XCTUnwrap(AgentPadCLIProtocol.encodeLine(request))
        let decoded = try XCTUnwrap(AgentPadCLIProtocol.decodeLine(AgentPadShellCommandRequest.self, from: line))
        XCTAssertEqual(decoded.kind, "shellCommand")
        XCTAssertEqual(decoded.surface, id)
        XCTAssertEqual(decoded.shellPID, 123)
    }
}
