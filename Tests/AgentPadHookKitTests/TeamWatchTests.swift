import Foundation
import XCTest
@testable import AgentPadHookKit

/// AgentPad: `agentpad-cli team watch`.
final class TeamWatchTests: XCTestCase {
    private func line(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)! + "\n"
    }

    func testFollowsARunAndItsContinuation() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("watch-\(UUID().uuidString).jsonl").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let first = line(["type": "agentpad_request", "from": "Masha", "agent": "backend", "folder": "/p", "session": "s1", "prompt": "read\u{1B}[2J it", "access": "Read"])
            + line(["type": "assistant", "message": ["content": [["type": "tool_use", "name": "request_folder_access", "input": ["path": "/kb"]]]]])
            + line(["type": "result", "result": "ok", "num_turns": 2, "duration_ms": 1000])
            + line(["type": "agentpad_end"])
        try first.write(toFile: path, atomically: true, encoding: .utf8)
        // The continuation is appended a moment later.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            let more = self.line(["type": "agentpad_request", "continuation": true, "folders": ["/kb"], "session": "s1", "prompt": "go on"])
                + self.line(["type": "assistant", "message": ["content": [["type": "text", "text": "The report says x."]]]])
                + self.line(["type": "result", "result": "The report says x.", "num_turns": 1])
                + self.line(["type": "agentpad_end"])
            let handle = FileHandle(forWritingAtPath: path)!
            handle.seekToEndOfFile()
            handle.write(Data(more.utf8))
            try? handle.close()
        }
        var printed: [String] = []
        let session = AgentPadTeamWatch.follow(path: path) { printed.append($0) }
        let all = printed.joined(separator: "\n")
        XCTAssertEqual(session, "s1")
        XCTAssertTrue(all.contains("Team call: Masha → backend"))
        XCTAssertTrue(all.contains("▸ request_folder_access"))
        XCTAssertTrue(all.contains("Continuing with access the owner granted"))
        XCTAssertTrue(all.contains("The report says x."))
        XCTAssertFalse(all.contains("\u{1B}[2J"), "no control sequences from the request")
        XCTAssertFalse(all.contains("Stopped"), "it was answered")
    }
}
