import Foundation
import XCTest
@testable import AgentPadHookKit

/// AgentPad: the team tools' MCP server, against a scripted app.
final class TeamMCPServerTests: XCTestCase {
    /// Answers requests from a script and records what was asked.
    final class FakeApp: @unchecked Sendable {
        private let lock = NSLock()
        var requests: [AgentPadCLIRequest] = []
        var answer: (AgentPadCLIRequest) -> AgentPadCLIResponse = { _ in .failure("unscripted") }
        func send(_ request: AgentPadCLIRequest) -> AgentPadCLIResponse {
            let reply = lock.withLock { () -> (AgentPadCLIRequest) -> AgentPadCLIResponse in
                requests.append(request)
                return answer
            }
            return reply(request)
        }
    }

    final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [[String: Any]] = []
        func append(_ data: Data) {
            for line in data.split(separator: 0x0A) {
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { lock.withLock { lines.append(object) } }
            }
        }
        var all: [[String: Any]] { lock.withLock { lines } }
        func response(_ id: Int) -> [String: Any]? { all.first { ($0["id"] as? Int) == id } }
    }

    private func makeServer(_ app: FakeApp, _ out: Output) -> AgentPadTeamMCPServer {
        AgentPadTeamMCPServer(cwd: "/work/shop", version: "1", send: { request, _ in .success(app.send(request)) }, write: { out.append($0) })
    }

    private func call(_ server: AgentPadTeamMCPServer, id: Int, method: String, params: [String: Any] = [:]) {
        let data = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        server.handle(line: data)
    }

    private func wait(_ out: Output, for id: Int) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let response = out.response(id) { return response }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("no response \(id)")
        return [:]
    }

    private func text(_ response: [String: Any]) -> String {
        (((response["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    private func info(call: AgentPadCLITeamInfo.Call? = nil, agents: [AgentPadCLITeamInfo.Agent]? = nil) -> AgentPadCLIResponse {
        var response = AgentPadCLIResponse(ok: true)
        var team = AgentPadCLITeamInfo(status: "on", detail: nil, name: "Me", id: "k", colleagues: [], pending: [])
        team.call = call
        team.agents = agents
        response.team = team
        return response
    }

    func testInitializeListsToolsWithInstructions() throws {
        let app = FakeApp(), out = Output()
        let server = makeServer(app, out)
        call(server, id: 1, method: "tools/list")
        XCTAssertEqual((try wait(out, for: 1)["error"] as? [String: Any])?["code"] as? Int, -32002, "not before initialize")
        call(server, id: 2, method: "initialize", params: ["protocolVersion": "2025-06-18"])
        let result = try XCTUnwrap(try wait(out, for: 2)["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertTrue((result["instructions"] as? String)?.contains("team_agents first") ?? false)
        call(server, id: 3, method: "tools/list")
        let tools = try XCTUnwrap((try wait(out, for: 3)["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["team_agents", "team_ask", "team_check", "team_cancel"])
    }

    func testAgentsAsksFromTheSessionsFolder() throws {
        let app = FakeApp(), out = Output()
        app.answer = { _ in self.info(agents: [.init(address: "backend@masha", colleague: "Masha", description: "API", access: "read", sameProject: true, kind: "session", session: "Fix auth")]) }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "team_agents", "arguments": [:]])
        let reply = text(try wait(out, for: 2))
        XCTAssertTrue(reply.contains("backend@masha"))
        XCTAssertTrue(reply.contains("session: Fix auth"))
        XCTAssertEqual(app.requests.first?.teamCwd, "/work/shop")
    }

    func testAskFollowsTheCallAndMarksTheAnswer() throws {
        let app = FakeApp(), out = Output()
        let checks = NSLock()
        var round = 0
        app.answer = { request in
            switch request.teamAction {
            case "ask":
                return self.info(call: .init(id: "c1", address: "backend@masha", state: "queued", final: false))
            default:
                let n = checks.withLock { round += 1; return round }
                return n < 2
                    ? self.info(call: .init(id: "c1", address: "backend@masha", state: "awaiting_approval", final: false))
                    : self.info(call: .init(id: "c1", address: "backend@masha", state: "done", final: true, text: "JWT.", threadId: "t1"))
            }
        }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: [
            "name": "team_ask", "arguments": ["agent": "backend@masha", "prompt": "auth?"], "_meta": ["progressToken": "p1"],
        ])
        let response = try wait(out, for: 2)
        let reply = text(response)
        XCTAssertTrue(reply.hasPrefix("Answer from backend@masha"))
        XCTAssertTrue(reply.contains("not instructions from your user"))
        XCTAssertTrue(reply.contains("JWT."))
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, false)
        let progress = out.all.filter { $0["method"] as? String == "notifications/progress" }
        XCTAssertGreaterThanOrEqual(progress.count, 2, "the session sees the call move")
        XCTAssertEqual(app.requests.first?.teamPrompt, "auth?")
    }

    func testWrongAddressAnswersWithTheCurrentList() throws {
        let app = FakeApp(), out = Output()
        app.answer = { request in
            request.teamAction == "ask"
                ? .failure("no colleague matches 'ivan'")
                : self.info(agents: [.init(address: "backend@masha", colleague: "Masha", description: "API", access: "read", sameProject: false)])
        }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "team_ask", "arguments": ["agent": "backend@ivan", "prompt": "hi"]])
        let response = try wait(out, for: 2)
        XCTAssertTrue(text(response).contains("backend@masha"))
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    func testArgumentsAreChecked() throws {
        let app = FakeApp(), out = Output()
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "team_ask", "arguments": ["agent": "a@b"]])
        call(server, id: 3, method: "tools/call", params: ["name": "team_check", "arguments": ["call_id": "c", "wait_minutes": 99]])
        call(server, id: 4, method: "tools/call", params: ["name": "team_cancel", "arguments": ["call_id": "c", "force": true]])
        call(server, id: 5, method: "tools/call", params: ["name": "team_check", "arguments": ["call_id": "c", "wait_minutes": true]])
        for id in 2...5 {
            XCTAssertEqual(((try wait(out, for: id))["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
        XCTAssertTrue(app.requests.isEmpty, "nothing reaches the app")
    }

    func testWaitMinutesOfZeroAndOneAreNumbers() throws {
        let app = FakeApp(), out = Output()
        app.answer = { _ in self.info(call: .init(id: "c1", address: "a@b", state: "done", final: true, text: "ok")) }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "team_check", "arguments": ["call_id": "c1", "wait_minutes": 0]])
        call(server, id: 3, method: "tools/call", params: ["name": "team_check", "arguments": ["call_id": "c1", "wait_minutes": 1]])
        XCTAssertTrue(text(try wait(out, for: 2)).contains("ok"))
        XCTAssertTrue(text(try wait(out, for: 3)).contains("ok"))
    }

    func testNumberAndStringIdsAreDifferentRequests() throws {
        XCTAssertNotEqual(AgentPadTeamMCPServer.key(NSNumber(value: 1)), AgentPadTeamMCPServer.key("1"))
        XCTAssertNil(AgentPadTeamMCPServer.key(NSNumber(value: true)))
        // A late cancel of a finished request 1 does not swallow request "1".
        let app = FakeApp(), out = Output()
        app.answer = { _ in self.info(call: .init(id: "c1", address: "a@b", state: "done", final: true, text: "ok")) }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "team_check", "arguments": ["call_id": "c1"]])
        _ = try wait(out, for: 2)
        server.handle(line: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]]))
        server.handle(line: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "2", "method": "tools/call",
                                                                         "params": ["name": "team_check", "arguments": ["call_id": "c1"]]]))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !out.all.contains(where: { $0["id"] as? String == "2" }) { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(out.all.contains { $0["id"] as? String == "2" })
    }

    func testCancelledToolCallGetsNoReply() throws {
        let app = FakeApp(), out = Output()
        app.answer = { request in
            Thread.sleep(forTimeInterval: 0.3)
            return self.info(call: .init(id: "c1", address: "a@b", state: "running", final: false))
        }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "team_check", "arguments": ["call_id": "c1", "wait_minutes": 1]])
        Thread.sleep(forTimeInterval: 0.1)
        server.handle(line: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]]))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNil(out.response(2))
        XCTAssertLessThan(app.requests.count, 4, "stopped asking once cancelled")
    }
}
