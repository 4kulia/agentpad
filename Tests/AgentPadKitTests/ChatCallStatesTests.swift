import AgentPadHookKit
import Foundation
import GRDB
import XCTest
@testable import AgentPadKit

/// D10 (decision 21): every state of a request as the CLI and MCP tell it —
/// `state` in 1.0.x's values, `serverState` the request's own, `final`, the
/// progress word, the exit code and MCP's error flag — from one mapping.
@MainActor
final class ChatCallStatesTests: XCTestCase {
    private var root: URL!
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")
    private let org = "0d6f1e1a-4b55-4c6a-8a2e-3b6c9d5e7f10"
    private var boris: ChatOrgKey { ChatOrgKey(server: server, accountId: CallJSON.boris, orgId: org) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-states-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The call Boris asked, in `state` (with a result when `answered`), as the CLI is told it.
    private func call(_ state: String, answered: Bool = false, trimmed: Bool = false, local: String? = nil) throws -> AgentPadCLITeamInfo.Call {
        let store = try ChatStore.open(files: ChatFiles(directory: root.appendingPathComponent(UUID().uuidString)), key: boris).store
        let id = UUID().uuidString.lowercased()
        var body = CallJSON.request(id, state: state, version: 4, owner: CallJSON.anna, initiator: CallJSON.boris)
        if answered {
            body["run_id"] = "run-1"
            body["result"] = ["run_id": "run-1", "text": "Twice: a retry.", "truncated": false, "thread_id": NSNull(),
                              "delivered_at": "2026-10-04T18:30:00Z"]
        }
        try store.apply(ChatSnapshot(cursors: [:],
                                     members: [.init(accountId: CallJSON.anna, handle: "anna", name: "Anna", role: "owner"),
                                               .init(accountId: CallJSON.boris, handle: "boris", name: "Boris", role: "member")],
                                     agents: [CallJSON.card()], requests: [CallJSON.wire(body)]))
        try store.queue.write { db in
            try db.execute(sql: "UPDATE requests SET asked_here = 1 WHERE request_id = ?", arguments: [id])
            if let local {
                try db.execute(sql: "UPDATE requests SET state = ?, version = ? WHERE request_id = ?",
                               arguments: [local, local == "failed" ? 0 : 4, id])
            }
            if trimmed { try db.execute(sql: "UPDATE results SET text = '', trimmed = 1 WHERE request_id = ?", arguments: [id]) }
        }
        let outgoing = try XCTUnwrap(try ChatTeamCallStore(calls: store.calls, key: boris).loadCall(id).outgoing.first)
        return TeamCLIHandler.callInfo(outgoing)
    }

    func testEveryStateAsTheCLIAndMCPTellIt() throws {
        // serverState, answered → state (1.0.x), final, exit code.
        let table: [(String, Bool, String, Bool, Int32)] = [
            ("submitted", false, "queued", false, 2),
            ("awaiting_decision", false, "awaiting_approval", false, 2),
            ("approved", false, "queued", false, 2),
            ("starting", false, "running", false, 2),
            ("running", false, "running", false, 2),
            ("stop_requested", false, "running", false, 2),
            ("finished", false, "running", false, 2),
            ("finished", true, "done", true, 0),
            ("declined", false, "denied", true, 1),
            ("failed_to_start", false, "failed", true, 1),
            ("failed", false, "failed", true, 1),
            ("stop_failed", false, "failed", true, 1),
            ("cancelled", false, "cancelled", true, 1),
            ("stopped", false, "cancelled", true, 1),
            ("expired", false, "expired", true, 1),
            ("paused_by_server", false, "unknown", false, 2),
        ]
        for (serverState, answered, state, final, code) in table {
            let info = try call(serverState, answered: answered)
            let what = "\(serverState), answered \(answered)"
            XCTAssertEqual(info.serverState, serverState, what)
            XCTAssertEqual(info.answered, answered, what)
            XCTAssertEqual(info.state, state, what)
            XCTAssertEqual(info.final, final, what)
            XCTAssertEqual(AgentPadHookKit.teamCallExitCode(info), code, what)
            XCTAssertTrue(AgentPadHookKit.renderCLITeamProgress(info).contains(serverState.replacingOccurrences(of: "_", with: " ")), what)
            if !final { XCTAssertNotNil(info.detail, "\(what): what it means is told while it goes on") }
            if final, !answered { XCTAssertTrue(AgentPadHookKit.renderCLITeamCall(info).contains(serverState.replacingOccurrences(of: "_", with: " ")), what) }
        }
        // This Mac's own states.
        for (local, state, final, code) in [("creating", "queued", false, Int32(2)), ("failed", "failed", true, 1),
                                            ("lost", "failed", true, 1), ("resyncing", "unknown", false, 2)] {
            let info = try call("submitted", local: local)
            XCTAssertEqual(info.serverState, local)
            XCTAssertEqual(info.state, state, local)
            XCTAssertEqual(info.final, final, local)
            XCTAssertEqual(AgentPadHookKit.teamCallExitCode(info), code, local)
            XCTAssertNotNil(info.detail, local)
        }
    }

    /// An answer whose text the history limit took is still an answer —
    /// exit 0 — and says plainly that its text is gone (review D10, 2).
    func testAnAnswerNoLongerKeptSaysSo() throws {
        let info = try call("finished", answered: true, trimmed: true)
        XCTAssertEqual(info.answered, true)
        XCTAssertEqual(info.answerTrimmed, true)
        XCTAssertEqual(AgentPadHookKit.teamCallExitCode(info), 0)
        let shown = AgentPadHookKit.renderCLITeamCall(info)
        XCTAssertEqual(shown.components(separatedBy: "no longer kept on this Mac").count - 1, 1, "said once: \(shown)")
        let whole = try call("finished", answered: true)
        XCTAssertNil(whole.answerTrimmed)
    }

    /// The notice's title by the server's own state.
    func testOutcomeTitles() throws {
        func title(_ state: String, version: Int = 4) -> String {
            var call = TeamCalls.Outgoing(id: "c", peer: CallJSON.anna, colleague: "Anna", agent: "billing", prompt: "x",
                                          createdAt: Date(), deliverBy: Date(), report: TeamCallReport(callId: "c", state: .failed), note: nil)
            call.handle = "anna"
            call.serverState = state
            call.version = version
            return ChatOutgoing.outcomeTitle(call)
        }
        XCTAssertEqual(title("finished"), "billing@anna answered")
        XCTAssertEqual(title("declined"), "Anna declined your call")
        XCTAssertEqual(title("failed_to_start"), "billing@anna could not start")
        XCTAssertEqual(title("stopped"), "Your call to billing@anna was stopped")
        XCTAssertEqual(title("cancelled"), "Your call to billing@anna was cancelled")
        XCTAssertEqual(title("expired"), "Your call to billing@anna was not taken in time")
        XCTAssertEqual(title("failed", version: 0), "Your call to billing@anna was not sent")
        XCTAssertEqual(title("failed"), "Your call to billing@anna failed")
    }
}
