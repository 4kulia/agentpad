import Foundation
import XCTest
@testable import AgentPadKit

/// Stands in for the network: every request is recorded and answered by `respond`.
final class ChatStubProtocol: URLProtocol, @unchecked Sendable {
    struct Answer: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data("{}".utf8)
    }

    struct Seen {
        let request: URLRequest
        let body: Data
    }

    typealias Responder = @Sendable (URLRequest, Data) -> Result<Answer, URLError>

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _respond: Responder = { _, _ in .success(Answer(status: 200)) }
    nonisolated(unsafe) private static var _seen: [Seen] = []
    nonisolated(unsafe) private static var _inFlight = 0
    nonisolated(unsafe) private static var _maxInFlight = 0
    /// How long each answer takes.
    nonisolated(unsafe) static var delay: TimeInterval = 0

    static func reset(_ respond: @escaping Responder = { _, _ in .success(Answer(status: 200)) }) {
        lock.lock()
        _respond = respond
        _seen = []
        _inFlight = 0
        _maxInFlight = 0
        lock.unlock()
        delay = 0
    }

    static var seen: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return _seen
    }

    static var maxInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return _maxInFlight
    }

    private static func begin(_ seen: Seen) -> Responder {
        lock.lock()
        defer { lock.unlock() }
        _seen.append(seen)
        _inFlight += 1
        _maxInFlight = max(_maxInFlight, _inFlight)
        return _respond
    }

    private static func end() {
        lock.lock()
        _inFlight -= 1
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let body = Self.readBody(request)
        let respond = Self.begin(Seen(request: request, body: body))
        let me = self
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay) {
            Self.end()
            me.finish(respond(request, body), for: request)
        }
    }

    private func finish(_ result: Result<Answer, URLError>, for request: URLRequest) {
        switch result {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .success(let answer):
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

final class ChatAPITests: XCTestCase {
    private let server = try! ChatServerAddress(parsing: "https://chat.example.com")

    override func setUp() {
        ChatStubProtocol.reset()
    }

    private func api() -> ChatAPI { ChatAPI(server: server, protocolClasses: [ChatStubProtocol.self]) }

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/chat")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json"))
    }

    private func serverInfo(capabilities: [String]) -> Data {
        Data("""
        {"name":"agentpad-server","version":"0.1.0","commit":"x","generation":"g1","api_versions":["v1"],
         "capabilities":\(String(decoding: try! JSONEncoder().encode(capabilities), as: UTF8.self)),"limits":{"message":1,"request":2,"result":3,"frame":4}}
        """.utf8)
    }

    // (4)
    func testRedirectIsNotFollowed() async throws {
        ChatStubProtocol.reset { request, _ in
            request.url?.host == "chat.example.com"
                ? .success(.init(status: 302, headers: ["Location": "https://evil.example.net/v1/me"]))
                : .success(.init(status: 200))
        }
        do {
            _ = try await api().me(token: "aps_secret")
            XCTFail("expected a redirect error")
        } catch let error as ChatAPIError {
            XCTAssertEqual(error, .redirect(302))
            XCTAssertTrue(error.localizedDescription.contains("redirect"))
        }
        XCTAssertEqual(ChatStubProtocol.seen.map { $0.request.url?.host }, ["chat.example.com"])
    }

    // (8)
    func testEveryServerSampleDecodes() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.fixtures.path).filter { $0.hasSuffix(".json") }
        XCTAssertGreaterThanOrEqual(names.count, 36)
        let decoder = JSONDecoder()
        for name in names {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
            switch name.replacingOccurrences(of: ".json", with: "") {
            case "auth_code_request": _ = try decoder.decode(ChatCodeRequest.self, from: data)
            case "auth_code_response": XCTAssertEqual(try decoder.decode(ChatJSON.self, from: data), .object([:]))
            case "auth_session_request": _ = try decoder.decode(ChatSignInRequest.self, from: data)
            case "auth_session_response": XCTAssertTrue(try decoder.decode(ChatSignIn.self, from: data).token.hasPrefix("aps_"))
            case "command_request": _ = try decoder.decode(ChatCommandEnvelope.self, from: data)
            case "command_response": XCTAssertEqual(try decoder.decode(ChatCommandAnswer.self, from: data).events.count, 1)
            case "error": XCTAssertEqual(try decoder.decode(ChatErrorBody.self, from: data).error, "invalid_code")
            case "error_invalid_state_request":
                // The code is `invalid_state`; the sample is the one of a request.
                XCTAssertEqual(try decoder.decode(ChatErrorBody.self, from: data).error, "invalid_state")
            case let error where error.hasPrefix("error_"):
                XCTAssertEqual(try decoder.decode(ChatErrorBody.self, from: data).error, String(error.dropFirst("error_".count)))
            case "events_response": XCTAssertFalse(try decoder.decode(ChatEventPage.self, from: data).events.isEmpty)
            case "state_response", "state_response_agents":
                let state = try decoder.decode(ChatOrgState.self, from: data)
                XCTAssertEqual(state.snapshot.cursors, state.streams)
                if name.hasPrefix("state_response_agents") {
                    XCTAssertEqual(state.snapshot.agents?.first?.teamIds?.count, 1)
                    XCTAssertEqual(state.snapshot.requests?.first?.result?.runId, state.snapshot.requests?.first?.runId)
                    XCTAssertEqual(state.snapshot.requests?.first?.hasFixed, true)
                }
            case "requests_page_response": XCTAssertNotNil(try decoder.decode(ChatRequestsPage.self, from: data).next)
            case "sessions_response":
                XCTAssertEqual(try decoder.decode(ChatDeviceSessions.self, from: data).sessions.map(\.current), [false, true])
            case "audit_response":
                let page = try decoder.decode(ChatAuditPage.self, from: data)
                XCTAssertEqual(page.next, 1041)
                XCTAssertEqual(page.records.map(\.result), ["ok", "denied"])
            // Commands of stage D (agents, requests, runs, results): the client's
            // envelope and answer types carry them all.
            case "agent_publish_request", "request_create_request", "request_decide_request", "request_decide_decline_request",
                 "request_received_request", "result_deliver_request", "run_start_request", "run_started_request",
                 "run_finished_request", "run_failed_request", "run_failed_to_start_request":
                _ = try decoder.decode(ChatCommandEnvelope.self, from: data)
            case "agent_publish_response", "request_create_response", "result_deliver_response", "run_start_final_response",
                 "transition_response":
                _ = try decoder.decode(ChatCommandAnswer.self, from: data)
            case let frame where frame.hasPrefix("frame_"):
                let decoded = try ChatFrame.decode(data)
                if case .unknown(let kind) = decoded { XCTFail("frame \(kind) is not known to the client") }
                if frame.hasSuffix("_sub") {
                    // The subscription number the server echoes (review C10-4).
                    switch decoded {
                    case .subscribe(_, let sub?), .subscribed(_, _, let sub?), .resyncRequired(_, let sub?), .unsubscribed(_, let sub?):
                        XCTAssertGreaterThanOrEqual(sub, 0, frame)
                    default: XCTFail("\(frame) carries no sub")
                    }
                }
                if [.ping, .pong].contains(decoded) || ["frame_subscribe", "frame_subscribe_sub", "frame_unsubscribe"].contains(frame) {
                    XCTAssertEqual(try ChatFrame.decode(Data(decoded.encoded().utf8)), decoded, "the client's own frames round-trip")
                }
            case "message_post_request", "message_edit_request", "message_delete_request":
                _ = try decoder.decode(ChatCommandEnvelope.self, from: data)
            case "message_post_response", "message_response":
                XCTAssertNotNil(try decoder.decode(ChatJSON.self, from: data)["result"]?["message_id"]?.string)
            case "channel_messages_response": XCTAssertFalse(try decoder.decode(ChatMessagesPage.self, from: data).messages.isEmpty)
            case "channel_create_request", "channel_rename_request", "channel_archive_request":
                _ = try decoder.decode(ChatCommandEnvelope.self, from: data)
            case "channel_response":
                // A command's answer: its card is never written (review F2b-1), only read here.
                let answer = try decoder.decode(ChatJSON.self, from: data)
                XCTAssertNotNil(answer["result"]?["channel"].flatMap(ChatChannels.card))
            case "channels_page_response": XCTAssertFalse(try decoder.decode(ChatChannelsPage.self, from: data).channels.isEmpty)
            case "me_response": _ = try decoder.decode(ChatMe.self, from: data)
            case "server_response", "server": _ = try decoder.decode(ChatServerInfo.self, from: data)
            case let event where event.hasPrefix("event_"): _ = try decoder.decode(ChatEvent.self, from: data)
            default: XCTFail("no client type for the sample \(name); add it here")
            }
        }
        // The client's own encoding of the sign-in request matches the sample's fields.
        let ours = try JSONEncoder().encode(ChatSignInRequest(email: "anna@example.com", code: "12345678", deviceName: "Anna's MacBook Pro"))
        XCTAssertEqual(try decoder.decode(ChatJSON.self, from: ours), try decoder.decode(ChatJSON.self, from: try fixture("auth_session_request")))
    }

    // (9)
    func testServerWithoutTheEventFeedIsRefused() async throws {
        ChatStubProtocol.reset { [info = serverInfo(capabilities: ["auth.email_code"])] _, _ in .success(.init(status: 200, body: info)) }
        do {
            _ = try await api().serverInfo()
            XCTFail("expected a refusal")
        } catch let error as ChatAPIError {
            XCTAssertEqual(error, .unsuitableServer(missing: ["events.ws"]))
            XCTAssertTrue(error.localizedDescription.contains("server version does not fit"))
        }
        ChatStubProtocol.reset { [info = serverInfo(capabilities: ["auth.email_code", "events.ws"])] _, _ in .success(.init(status: 200, body: info)) }
        let info = try await api().serverInfo()
        XCTAssertEqual(info.generation, "g1")
    }

    func testRequestsGoToTheRightPlaceWithTheToken() async throws {
        ChatStubProtocol.reset { [me = try fixture("me_response")] request, _ in
            .success(.init(status: request.httpMethod == "DELETE" ? 204 : 200, body: request.httpMethod == "DELETE" ? Data() : me))
        }
        let me = try await api().me(token: "aps_t")
        XCTAssertEqual(me.orgs.first?.orgName, "Rabbitshat")
        try await api().signOut(token: "aps_t")
        let seen = ChatStubProtocol.seen
        XCTAssertEqual(seen.map { $0.request.url?.absoluteString }, ["https://chat.example.com:443/v1/me", "https://chat.example.com:443/v1/auth/session"])
        XCTAssertEqual(seen.map(\.request.httpMethod), ["GET", "DELETE"])
        XCTAssertEqual(seen.first?.request.value(forHTTPHeaderField: "Authorization"), "Bearer aps_t")
        XCTAssertNil(seen.first?.request.value(forHTTPHeaderField: "Cookie"))
    }

    /// C6: devices, closing one, and the security log go to their addresses
    /// with the token; a closed session already gone is an error.
    func testDevicesAndSecurityLogRequests() async throws {
        ChatStubProtocol.reset { [sessions = try fixture("sessions_response"), audit = try fixture("audit_response")] request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/v1/sessions"): .success(.init(status: 200, body: sessions))
            case ("DELETE", "/v1/sessions/gone"): .success(.init(status: 404, body: Data(#"{"error":"not_found"}"#.utf8)))
            case ("DELETE", _): .success(.init(status: 204, body: Data()))
            default: .success(.init(status: 200, body: audit))
            }
        }
        let devices = try await api().sessions(token: "aps_t")
        XCTAssertEqual(devices.map(\.deviceName), ["Anna's Mac mini", "Anna's MacBook Pro"])
        try await api().closeSession("9d8c", token: "aps_t")
        do {
            try await api().closeSession("gone", token: "aps_t")
            XCTFail("a session not found is an error")
        } catch let error as ChatAPIError {
            XCTAssertEqual(error.code, "not_found")
        }
        let page = try await api().audit("o1", before: 1041, limit: 20, token: "aps_t")
        XCTAssertEqual(page.records.count, 2)
        let seen = ChatStubProtocol.seen
        XCTAssertEqual(seen.map(\.request.httpMethod), ["GET", "DELETE", "DELETE", "GET"])
        XCTAssertEqual(seen[1].request.url?.path, "/v1/sessions/9d8c")
        XCTAssertEqual(seen[3].request.url?.path, "/v1/orgs/o1/audit")
        XCTAssertEqual(seen[3].request.url?.query, "limit=20&before=1041")
        XCTAssertTrue(seen.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == "Bearer aps_t" })
    }

    func testErrorsCarryTheirCode() async throws {
        ChatStubProtocol.reset { _, _ in .success(.init(status: 401, body: Data(#"{"error":"invalid_code"}"#.utf8))) }
        do {
            _ = try await api().signIn(email: "a@b.c", code: "1", deviceName: "Mac")
            XCTFail("expected an error")
        } catch let error as ChatAPIError {
            XCTAssertEqual(error.code, "invalid_code")
        }
        let body = try XCTUnwrap(ChatStubProtocol.seen.first?.body)
        XCTAssertEqual(try JSONDecoder().decode(ChatSignInRequest.self, from: body).deviceName, "Mac")
    }

    func testRetryAfterAndVersion7Ids() throws {
        XCTAssertEqual(ChatAPI.retryAfter("7"), 7)
        XCTAssertNil(ChatAPI.retryAfter(nil))
        XCTAssertNil(ChatAPI.retryAfter("soon"))
        let date = Date(timeIntervalSinceNow: 120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(try XCTUnwrap(ChatAPI.retryAfter(formatter.string(from: date))), 120, accuracy: 2)

        let at = Date(timeIntervalSince1970: 1_790_000_000.123)
        let id = ChatUUID.v7(now: at)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(Array(id)[14], "7")
        XCTAssertTrue("89ab".contains(Array(id)[19]))
        XCTAssertEqual(try XCTUnwrap(ChatUUID.time(of: id)).timeIntervalSince1970, at.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(ChatUUID.time(of: UUID().uuidString))
        XCTAssertNotEqual(ChatUUID.v7(), ChatUUID.v7())
    }

    /// The deployed server; opt-in, read-only (`/healthz`, `/v1/server`).
    func testLiveServer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTPAD_LIVE_SERVER"] == "1", "set AGENTPAD_LIVE_SERVER=1")
        let live = ChatAPI(server: try ChatServerAddress(parsing: "https://agentpad.rabbitshat.ai"))
        let health = try await live.send("GET", "/healthz")
        XCTAssertEqual(health.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(ChatJSON.self, from: health.body)["ok"], .bool(true))
        let info = try await live.serverInfo(requiring: [])
        XCTAssertEqual(info.name, "agentpad-server")
        XCTAssertTrue(info.apiVersions.contains("v1"))
        XCTAssertNotNil(UUID(uuidString: info.generation))
    }
}
