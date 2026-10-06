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
        AgentPadTeamMCPServer(cwd: "/work/shop", version: "1", send: { request, _, _ in .success(app.send(request)) }, write: { out.append($0) })
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
        var team = AgentPadCLITeamInfo(status: "server", detail: nil)
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
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["team_agents", "team_ask", "team_check", "team_cancel", "chat_channels", "chat_read", "chat_post"])
    }

    func testRunToolsOfferOnlyFolderAccess() throws {
        let app = FakeApp(), out = Output()
        app.answer = { request in
            var response = AgentPadCLIResponse(ok: true)
            var team = AgentPadCLITeamInfo(status: "server", detail: nil)
            team.access = .init(id: "a1", state: request.teamAction == "access" ? "pending" : "once", path: "/kb")
            response.team = team
            return response
        }
        let server = AgentPadTeamMCPServer(cwd: "/p", version: "1", runCallId: "c1", send: { request, _, _ in .success(app.send(request)) }, write: { out.append($0) })
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/list")
        let tools = ((try wait(out, for: 2)["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        XCTAssertEqual(tools, ["request_folder_access"])
        call(server, id: 3, method: "tools/call", params: ["name": "team_ask", "arguments": ["agent": "a@b", "prompt": "x"]])
        XCTAssertEqual(((try wait(out, for: 3))["result"] as? [String: Any])?["isError"] as? Bool, true, "a call's agent cannot call colleagues")
        call(server, id: 4, method: "tools/call", params: ["name": "request_folder_access", "arguments": ["path": "/kb", "reason": "notes"]])
        XCTAssertTrue(text(try wait(out, for: 4)).contains("granted"))
        XCTAssertEqual(app.requests.first?.teamCall, "c1")
        XCTAssertEqual(app.requests.first?.teamFolder, "/kb")
    }

    func testChannelToolsAreDeniedToEveryTeamRunEvenWhenManuallyNamed() {
        let app = FakeApp(), out = Output()
        let server = AgentPadTeamMCPServer(cwd: "/p", version: "1", runCallId: "self-call", send: { request, _, _ in .success(app.send(request)) }, write: { out.append($0) })
        for name in ["chat_channels", "chat_read", "chat_post"] {
            XCTAssertTrue(server.callTool(name, arguments: [:], requestKey: name, progressToken: nil).1)
        }
        XCTAssertTrue(app.requests.isEmpty)
    }

    func testChatPostImmediatelyForwardsCanonicalArgumentsAndPendingResult() throws {
        let app = FakeApp(), out = Output()
        app.answer = { request in
            var response = AgentPadCLIResponse(ok: true)
            let args = try! JSONSerialization.jsonObject(with: Data(request.chatArguments!.utf8)) as! [String: Any]
            response.chatResult = String(decoding: try! JSONSerialization.data(withJSONObject: ["status": "pending", "message_id": (args["message_id"] as! String).lowercased()]), as: UTF8.self)
            return response
        }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        let message = "ABCDEF00-0000-4000-8000-000000000001"
        call(server, id: 2, method: "tools/call", params: ["name": "chat_post", "arguments": ["org_id": "o1", "channel_id": "c1", "text": "@agent@owner hello", "message_id": message]])
        let result = try XCTUnwrap(try wait(out, for: 2)["result"] as? [String: Any])
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["status"] as? String, "pending")
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["message_id"] as? String, message.lowercased())
        XCTAssertEqual(app.requests.count, 1)
        XCTAssertEqual(app.requests[0].teamAction, "chat")
        XCTAssertTrue(app.requests[0].chatArguments?.contains("chat_post") == true)
        XCTAssertNil(app.requests[0].teamPrompt, "never use team_ask")
        for field in ["author_agent_id", "author_account_id", "author_session_name", "surface_id", "pid", "session_id"] {
            XCTAssertTrue(server.callTool("chat_post", arguments: ["org_id": "o1", "channel_id": "c1", "text": "hi", field: "forged"], requestKey: field, progressToken: nil).1)
        }
        XCTAssertEqual(app.requests.count, 1, "model-provided author/provenance never reaches the app")
    }

    func testChatPostTimeoutKeepsItsIDAndRepeatingTheCallKeyCannotDuplicate() throws {
        let app = FakeApp(), out = Output()
        let server = AgentPadTeamMCPServer(cwd: "/p", version: "1", send: { request, timeout, _ in
            XCTAssertGreaterThanOrEqual(timeout, 32, "HTTP preflight plus outbox wait")
            _ = app.send(request)
            return .failure(.init("timeout"))
        }, write: { out.append($0) })
        let args: [String: Any] = ["org_id": "o1", "channel_id": "c1", "text": "hello"]
        func invoke(_ key: String, _ arguments: [String: Any]) throws -> [String: Any] {
            let (raw, failed) = server.callTool("chat_post", arguments: arguments, requestKey: key, progressToken: nil)
            XCTAssertTrue(failed)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        }
        let first = try invoke("n:7", args), second = try invoke("n:7", args), distinct = try invoke("s:7", args)
        XCTAssertEqual(first["status"] as? String, "unknown")
        XCTAssertEqual(first["error"] as? String, "timeout")
        let id = try XCTUnwrap(first["message_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(second["message_id"] as? String, id)
        XCTAssertNotEqual(distinct["message_id"] as? String, id)
        let sent = try app.requests.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.chatArguments!.utf8)) as? [String: Any]) }
        XCTAssertEqual(sent[0]["message_id"] as? String, id)
        XCTAssertEqual(sent[1]["message_id"] as? String, id)
        var changed = args; changed["text"] = "different"
        XCTAssertTrue(server.callTool("chat_post", arguments: changed, requestKey: "n:7", progressToken: nil).1)
        XCTAssertEqual(app.requests.count, 3, "conflicting call key must not enqueue")
    }

    func testCancelledPostLogsAlreadyKnownSentOutcome() throws {
        let out = Output(), entered = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
        let server = AgentPadTeamMCPServer(cwd: "/p", version: "1", send: { request, _, cancellation in
            entered.signal()
            _ = proceed.wait(timeout: .now() + 5)
            XCTAssertTrue(cancellation?.isCancelled == true)
            let args = try! JSONSerialization.jsonObject(with: Data(request.chatArguments!.utf8)) as! [String: Any]
            var response = AgentPadCLIResponse(ok: true)
            response.chatResult = String(decoding: try! JSONSerialization.data(withJSONObject: ["status": "sent", "message_id": args["message_id"]!]), as: UTF8.self)
            return .success(response)
        }, write: { out.append($0) })
        call(server, id: 1, method: "initialize")
        let id = UUID().uuidString.lowercased()
        call(server, id: 2, method: "tools/call", params: ["name": "chat_post", "arguments": ["org_id": "o", "channel_id": "c", "text": "private text", "message_id": id]])
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        server.handle(line: try JSONSerialization.data(withJSONObject: ["method": "notifications/cancelled", "params": ["requestId": 2]]))
        proceed.signal()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !out.all.contains(where: { $0["method"] as? String == "notifications/message" }) { Thread.sleep(forTimeInterval: 0.01) }
        let notice = out.all.compactMap { ($0["params"] as? [String: Any])?["data"] as? String }.first
        XCTAssertTrue(notice?.contains(id) == true)
        XCTAssertTrue(notice?.contains("delivery status: sent") == true)
        XCTAssertFalse(notice?.contains("private text") == true)
        XCTAssertNil(out.response(2))
    }

    func testCancellationBeforeIPCRegistrationCannotConnect() {
        let cancellation = AgentPadCLITransport.Cancellation()
        cancellation.cancel()
        let result = AgentPadCLITransport.roundTrip(line: Data("request\n".utf8), socketPath: "/nonexistent/ux1.sock", timeout: 1, cancellation: cancellation)
        XCTAssertEqual(result, .failure(.cancelled))
    }

    func testChatPostCannotReportSuccessWithoutItsMessageIDAndDeliveryStatus() throws {
        for invalid in ["missing_id", "wrong_id", "missing_status"] {
            let app = FakeApp(), out = Output()
            app.answer = { request in
                let args = try! JSONSerialization.jsonObject(with: Data(request.chatArguments!.utf8)) as! [String: Any]
                var result: [String: Any] = ["status": "sent", "message_id": args["message_id"]!]
                if invalid == "missing_id" { result["message_id"] = nil }
                if invalid == "wrong_id" { result["message_id"] = UUID().uuidString }
                if invalid == "missing_status" { result["status"] = nil }
                var response = AgentPadCLIResponse(ok: true)
                response.chatResult = String(decoding: try! JSONSerialization.data(withJSONObject: result), as: UTF8.self)
                return response
            }
            let server = makeServer(app, out)
            let (raw, failed) = server.callTool("chat_post", arguments: ["org_id": "o1", "channel_id": "c1", "text": "hi"], requestKey: invalid, progressToken: nil)
            XCTAssertTrue(failed, invalid)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            XCTAssertEqual(result["status"] as? String, "unknown")
            XCTAssertEqual(result["error"] as? String, "invalid_post_response")
            XCTAssertNotNil((result["message_id"] as? String).flatMap(UUID.init(uuidString:)))
        }
    }

    /// `team_ask` takes the thread as `thread_id` (as its answer names it),
    /// and as `thread`, the older name (review D5b-4).
    func testAskTakesTheThreadAsThreadId() throws {
        let app = FakeApp(), out = Output()
        app.answer = { _ in self.info(call: .init(id: "c2", address: "backend@masha", state: "done", final: true, text: "ok")) }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "team_ask", "arguments": ["agent": "backend@masha", "prompt": "and?", "thread_id": "t1"]])
        XCTAssertNotEqual(((try wait(out, for: 2))["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(app.requests.first { $0.teamAction == "ask" }?.teamThread, "t1")
        call(server, id: 3, method: "tools/call", params: ["name": "team_ask", "arguments": ["agent": "backend@masha", "prompt": "and?", "thread": "t2"]])
        _ = try wait(out, for: 3)
        XCTAssertEqual(app.requests.last { $0.teamAction == "ask" }?.teamThread, "t2")
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

    /// D10: a call not answered by the end of the wait is told as such —
    /// `status: pending`, "Not answered yet", not an error and not an
    /// answer; `finished` without its result is not the end; an answer is
    /// `answered`, an end without one `ended` and an error.
    func testPendingIsNoAnswer() throws {
        let app = FakeApp(), out = Output()
        var finished = AgentPadCLITeamInfo.Call(id: "c1", address: "billing@anna", state: "running", final: false,
                                                detail: "The agent finished; the result follows.")
        finished.serverState = "finished"
        finished.answered = false
        app.answer = { _ in self.info(call: finished) }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "team_check", "arguments": ["call_id": "c1", "wait_minutes": 0]])
        let pending = try wait(out, for: 2)
        let result = pending["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        XCTAssertEqual((result?["structuredContent"] as? [String: Any])?["status"] as? String, "pending")
        XCTAssertTrue(text(pending).hasPrefix("Not answered yet"), text(pending))
        XCTAssertTrue(text(pending).contains("finished"), text(pending))
        XCTAssertFalse(text(pending).contains("Answer from"), "pending is no answer")

        var done = AgentPadCLITeamInfo.Call(id: "c1", address: "billing@anna", state: "done", final: true, text: "Twice: a retry.")
        done.serverState = "finished"
        done.answered = true
        app.answer = { _ in self.info(call: done) }
        call(server, id: 3, method: "tools/call", params: ["name": "team_check", "arguments": ["call_id": "c1", "wait_minutes": 0]])
        let answered = try wait(out, for: 3)
        XCTAssertEqual((answered["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertEqual(((answered["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["status"] as? String, "answered")

        var declined = AgentPadCLITeamInfo.Call(id: "c1", address: "billing@anna", state: "denied", final: true, detail: "Declined: not now")
        declined.serverState = "declined"
        app.answer = { _ in self.info(call: declined) }
        call(server, id: 4, method: "tools/call", params: ["name": "team_check", "arguments": ["call_id": "c1", "wait_minutes": 0]])
        let ended = try wait(out, for: 4)
        XCTAssertEqual((ended["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertEqual(((ended["result"] as? [String: Any])?["structuredContent"] as? [String: Any])?["status"] as? String, "ended")
    }

    /// D10 review: MCP's own error flag and status, at the end of each kind
    /// of call; `team_ask` keeps waiting through `finished` without its result.
    func testMCPsFlagAtEachEnd() throws {
        let cases: [(String, String, Bool, Bool, String)] = [
            // state (1.0.x), serverState, final → isError, status
            ("done", "finished", true, false, "answered"),
            ("denied", "declined", true, true, "ended"),
            ("failed", "failed_to_start", true, true, "ended"),
            ("cancelled", "stopped", true, true, "ended"),
            ("expired", "expired", true, true, "ended"),
            ("running", "finished", false, false, "pending"),
            ("queued", "creating", false, false, "pending"),
            ("running", "starting", false, false, "pending"),
            ("running", "running", false, false, "pending"),
        ]
        for (n, (state, serverState, final, isError, status)) in cases.enumerated() {
            let app = FakeApp(), out = Output()
            var c = AgentPadCLITeamInfo.Call(id: "c1", address: "billing@anna", state: state, final: final, text: state == "done" ? "ok" : nil)
            c.serverState = serverState
            app.answer = { _ in self.info(call: c) }
            let server = makeServer(app, out)
            call(server, id: 1, method: "initialize")
            call(server, id: 2, method: "tools/call", params: ["name": "team_check", "arguments": ["call_id": "c1", "wait_minutes": 0]])
            let result = try wait(out, for: 2)["result"] as? [String: Any]
            XCTAssertEqual(result?["isError"] as? Bool, isError, "\(n): \(serverState)")
            XCTAssertEqual((result?["structuredContent"] as? [String: Any])?["status"] as? String, status, "\(n): \(serverState)")
        }

        // team_ask: finished without its result is not the end — it asks on until the answer.
        let app = FakeApp(), out = Output()
        var checks = 0
        let lock = NSLock()
        app.answer = { request in
            var c = AgentPadCLITeamInfo.Call(id: "c1", address: "billing@anna", state: "running", final: false)
            c.serverState = "finished"
            if request.teamAction == "check" {
                let n = lock.withLock { checks += 1; return checks }
                if n >= 3 {
                    c = AgentPadCLITeamInfo.Call(id: "c1", address: "billing@anna", state: "done", final: true, text: "ok")
                    c.serverState = "finished"
                }
            }
            return self.info(call: c)
        }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "team_ask", "arguments": ["agent": "billing@anna", "prompt": "Why?"]])
        let asked = try wait(out, for: 2)["result"] as? [String: Any]
        XCTAssertEqual(asked?["isError"] as? Bool, false)
        XCTAssertEqual((asked?["structuredContent"] as? [String: Any])?["status"] as? String, "answered")
        XCTAssertGreaterThanOrEqual(lock.withLock { checks }, 3)
    }

    func testVersionWaitRemainsPendingWithOrWithoutActivity() throws {
        let hint = "Ожидает разрешения владельца на версию Claude Code 2.1.290"
        for state in ["starting", "running"] {
            for activity in [hint, nil] {
                let app = FakeApp(), out = Output()
                var c = AgentPadCLITeamInfo.Call(id: "c1", address: "billing@anna", state: "running", final: false, activity: activity)
                c.serverState = state
                XCTAssertEqual(AgentPadHookKit.teamCallExitCode(c), 2)
                app.answer = { _ in self.info(call: c) }
                let server = makeServer(app, out)
                call(server, id: 1, method: "initialize")
                call(server, id: 2, method: "tools/call", params: ["name": "team_check", "arguments": ["call_id": "c1", "wait_minutes": 0]])
                let response = try wait(out, for: 2)
                let result = response["result"] as? [String: Any]
                XCTAssertEqual((result?["structuredContent"] as? [String: Any])?["status"] as? String, "pending")
                XCTAssertEqual(result?["isError"] as? Bool, false)
                XCTAssertTrue(text(response).contains("Continue with other work"))
                if activity != nil { XCTAssertTrue(text(response).contains(hint)) }
            }
        }
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
        XCTAssertEqual(server.keptStatuses, 0, "a cancelled request leaves no status behind")
    }

    /// The tool call is cancelled while the call is being made; the app
    /// cannot cancel it (a server's core): no "Cancelled." — the call goes
    /// on, and its id is told in the log, since a cancelled call gets no
    /// reply (review D8c-5).
    func testCancelledAskWhoseCallGoesOnTellsItsId() throws {
        let app = FakeApp(), out = Output()
        app.answer = { request in
            if request.teamAction == "cancel" {
                return self.info(call: .init(id: "c9", address: "a@b", state: "queued", final: false,
                                             note: "Cancelling a call through a server is not available yet."))
            }
            Thread.sleep(forTimeInterval: 0.3)
            return self.info(call: .init(id: "c9", address: "a@b", state: "queued", final: false))
        }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "team_ask", "arguments": ["agent": "a@b", "prompt": "hi"]])
        Thread.sleep(forTimeInterval: 0.1)
        server.handle(line: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]]))
        let deadline = Date().addingTimeInterval(5)
        func logged() -> [String] {
            out.all.filter { $0["method"] as? String == "notifications/message" }.compactMap { ($0["params"] as? [String: Any])?["data"] as? String }
        }
        while Date() < deadline, logged().isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(logged().first?.contains("c9") == true, "\(logged())")
        XCTAssertTrue(logged().first?.contains("goes on") == true)
        XCTAssertTrue(logged().first?.contains("not available yet") == true, "the cancel's refusal comes along")
        XCTAssertFalse(out.all.contains { "\($0)".contains("Cancelled.") })
    }

    /// The cancel comes later, while the call is followed: the reply is
    /// withheld, and the call's id is told in the log all the same.
    func testCancelWhileFollowingTellsTheCallsId() throws {
        let app = FakeApp(), out = Output()
        app.answer = { request in
            if request.teamAction == "check" { Thread.sleep(forTimeInterval: 0.2) }
            return self.info(call: .init(id: "c7", address: "a@b", state: "running", final: false))
        }
        let server = makeServer(app, out)
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "team_ask", "arguments": ["agent": "a@b", "prompt": "hi"]])
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !app.requests.contains(where: { $0.teamAction == "check" }) { Thread.sleep(forTimeInterval: 0.01) }
        server.handle(line: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]]))
        func logged() -> [String] {
            out.all.filter { $0["method"] as? String == "notifications/message" }.compactMap { ($0["params"] as? [String: Any])?["data"] as? String }
        }
        while Date() < deadline, logged().isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(logged().first?.contains("c7") == true, "\(logged())")
        XCTAssertNil(out.response(2))
    }

    /// A folder request the app refuses comes back with the app's reason.
    func testAFolderRequestRefusedKeepsTheReason() throws {
        let app = FakeApp(), out = Output()
        app.answer = { _ in .failure("Extending folder access through a server is not available yet.") }
        let server = AgentPadTeamMCPServer(cwd: "/p", version: "1", runCallId: "c1", send: { request, _, _ in .success(app.send(request)) },
                                           write: { out.append($0) })
        call(server, id: 1, method: "initialize")
        call(server, id: 2, method: "tools/call", params: ["name": "request_folder_access", "arguments": ["path": "/tmp", "reason": "x"]])
        XCTAssertEqual(text(try wait(out, for: 2)), "Extending folder access through a server is not available yet.")
    }

    /// What a state means comes along in the progress line and the answer
    /// that is not yet one (review D8g-p3-5).
    func testAStatesMeaningComesAlong() {
        let call = AgentPadCLITeamInfo.Call(id: "c1", address: "a@b", state: "unknown", final: false,
                                            detail: "The server reports a state this AgentPad does not know (“paused”); update AgentPad.")
        XCTAssertTrue(AgentPadHookKit.renderCLITeamProgress(call).contains("does not know"))
    }
}
