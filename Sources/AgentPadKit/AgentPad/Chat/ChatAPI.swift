import Foundation
import Security

// MARK: Wire types (server docs/api.md)

struct ChatServerInfo: Codable, Equatable, Sendable {
    struct Limits: Codable, Equatable, Sendable {
        let message, request, result, frame: Int
    }

    let name: String
    let version: String
    let commit: String?
    let generation: String
    let apiVersions: [String]
    let capabilities: [String]
    let limits: Limits?

    enum CodingKeys: String, CodingKey {
        case name, version, commit, generation, capabilities, limits
        case apiVersions = "api_versions"
    }
}

struct ChatOrgMembership: Codable, Equatable, Sendable {
    let orgId: String
    let orgName: String
    let role: String
    let handle: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case role, handle, name
        case orgId = "org_id", orgName = "org_name"
    }
}

struct ChatCodeRequest: Codable, Equatable, Sendable {
    let email: String
}

struct ChatSignInRequest: Codable, Equatable, Sendable {
    let email: String
    let code: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case email, code
        case deviceName = "device_name"
    }
}

struct ChatSignIn: Codable, Equatable, Sendable {
    let token: String
    let sessionId: String
    let accountId: String
    let orgs: [ChatOrgMembership]

    enum CodingKeys: String, CodingKey {
        case token, orgs
        case sessionId = "session_id", accountId = "account_id"
    }
}

struct ChatMe: Codable, Equatable, Sendable {
    let accountId: String
    let sessionId: String
    let orgs: [ChatOrgMembership]
    let streams: [String: Int]

    enum CodingKeys: String, CodingKey {
        case orgs, streams
        case accountId = "account_id", sessionId = "session_id"
    }
}

/// One open session of the account (`GET /v1/sessions`).
struct ChatDeviceSession: Codable, Equatable, Sendable, Identifiable {
    let sessionId: String
    let deviceName: String
    let createdAt: String
    let lastSeenAt: String?
    let current: Bool
    var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case current
        case sessionId = "session_id", deviceName = "device_name", createdAt = "created_at", lastSeenAt = "last_seen_at"
    }
}

struct ChatDeviceSessions: Codable, Equatable, Sendable {
    let sessions: [ChatDeviceSession]
}

/// A page of the organization's security log (`GET /v1/orgs/{org}/audit`).
struct ChatAuditPage: Codable, Equatable, Sendable {
    struct Record: Codable, Equatable, Sendable, Identifiable {
        let id: Int
        let at: String
        let actorAccountId: String?
        let action: String
        let object: String?
        let result: String

        enum CodingKeys: String, CodingKey {
            case id, at, action, object, result
            case actorAccountId = "actor_account_id"
        }
    }
    let records: [Record]
    let next: Int?
}

/// `POST /v1/commands` body. Encoded once, with sorted keys, and kept as bytes.
struct ChatCommandEnvelope: Codable, Equatable, Sendable {
    var commandId: String
    let org: String
    let type: String
    let args: ChatJSON

    enum CodingKeys: String, CodingKey {
        case org, type, args
        case commandId = "command_id"
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

struct ChatCommandAnswer: Codable, Equatable, Sendable {
    struct Written: Codable, Equatable, Sendable {
        let stream: String
        let seq: Int
        let id: String
    }

    let events: [Written]
    let result: ChatJSON
}

struct ChatErrorBody: Codable, Equatable, Sendable {
    let error: String
    /// `409 invalid_state`: the request's state now.
    var state: String? = nil
}

// MARK: Errors

enum ChatAPIError: Error, Equatable, LocalizedError {
    /// No answer: offline, timed out, TLS. Repeated later.
    case network(String)
    /// The server answered with an error status and code.
    case server(status: Int, code: String, retryAfter: TimeInterval?)
    /// A 3xx: never followed, so the token never goes to another address.
    case redirect(Int)
    case unexpectedAnswer(String)
    /// `/v1/server` lacks what this build needs.
    case unsuitableServer(missing: [String])

    var errorDescription: String? {
        switch self {
        case .network(let detail): "The server could not be reached: \(detail)"
        case .server(let status, let code, _): "The server refused (\(status) \(code))."
        case .redirect(let status): "The server answered with a redirect (\(status)); AgentPad does not follow it."
        case .unexpectedAnswer(let detail): "Unexpected answer from the server: \(detail)"
        case .unsuitableServer(let missing):
            "The server version does not fit this AgentPad (missing: \(missing.joined(separator: ", ")))."
        }
    }

    var code: String? { if case .server(_, let code, _) = self { code } else { nil } }
}

// MARK: Client

/// The HTTP side of the server (docs/agentpad/CHAT-PLAN.md C2): an
/// ephemeral session without cookies or cache, `https` only (C1), no
/// redirects followed.
final class ChatAPI: Sendable {
    /// What connecting needs: sign-in and the event feed.
    static let requiredCapabilities = ["auth.email_code", "events.ws"]

    let server: ChatServerAddress
    private let session: URLSession
    private let refuser = RedirectRefuser()

    /// `protocolClasses` replaces the network in tests.
    init(server: ChatServerAddress, protocolClasses: [AnyClass]? = nil, timeout: TimeInterval = 30) {
        self.server = server
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        if let protocolClasses { config.protocolClasses = protocolClasses }
        session = URLSession(configuration: config, delegate: refuser, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    struct Response: Sendable {
        let status: Int
        let body: Data
        let retryAfter: TimeInterval?
    }

    /// One request. Any status comes back; only a transport failure or a
    /// redirect throws.
    func send(_ method: String, _ path: String, token: String? = nil, body: Data? = nil, query: String? = nil) async throws -> Response {
        var url = server.baseURL.appendingPathComponent(path)
        if let query, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.percentEncodedQuery = query
            url = parts.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentPad/\(AgentPadApp.displayVersion)", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatAPIError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ChatAPIError.unexpectedAnswer("not HTTP") }
        if (300..<400).contains(http.statusCode) { throw ChatAPIError.redirect(http.statusCode) }
        return Response(status: http.statusCode, body: data, retryAfter: Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
    }

    /// `send`, then a 2xx decoded as `T`; any other status throws `.server`.
    func call<T: Decodable>(_ type: T.Type, _ method: String, _ path: String, token: String? = nil, body: Data? = nil,
                            query: String? = nil) async throws -> T {
        let answer = try await send(method, path, token: token, body: body, query: query)
        try Self.check(answer)
        do {
            return try JSONDecoder().decode(T.self, from: answer.body)
        } catch {
            throw ChatAPIError.unexpectedAnswer("\(path): \(error.localizedDescription)")
        }
    }

    static func check(_ answer: Response) throws {
        guard (200..<300).contains(answer.status) else {
            let code = (try? JSONDecoder().decode(ChatErrorBody.self, from: answer.body).error) ?? "http_\(answer.status)"
            throw ChatAPIError.server(status: answer.status, code: code, retryAfter: answer.retryAfter)
        }
    }

    private static func json(_ value: some Encodable) throws -> Data { try JSONEncoder().encode(value) }

    // MARK: Endpoints

    /// `GET /v1/server`, refused when `v1` or a capability in `requiring` is missing.
    func serverInfo(requiring: [String] = ChatAPI.requiredCapabilities) async throws -> ChatServerInfo {
        let info = try await call(ChatServerInfo.self, "GET", "/v1/server")
        var missing = requiring.filter { !info.capabilities.contains($0) }
        if !info.apiVersions.contains("v1") { missing.insert("api v1", at: 0) }
        guard missing.isEmpty else { throw ChatAPIError.unsuitableServer(missing: missing) }
        return info
    }

    func requestCode(email: String) async throws {
        try Self.check(try await send("POST", "/v1/auth/code", body: try Self.json(ChatCodeRequest(email: email))))
    }

    func signIn(email: String, code: String, deviceName: String) async throws -> ChatSignIn {
        try await call(ChatSignIn.self, "POST", "/v1/auth/session",
                       body: try Self.json(ChatSignInRequest(email: email, code: code, deviceName: deviceName)))
    }

    func me(token: String) async throws -> ChatMe {
        try await call(ChatMe.self, "GET", "/v1/me", token: token)
    }

    /// `DELETE /v1/auth/session`: closes the token's session.
    func signOut(token: String) async throws {
        try Self.check(try await send("DELETE", "/v1/auth/session", token: token))
    }

    /// `GET /v1/orgs/{org}/state`: the organization snapshot.
    func orgState(_ org: String, token: String) async throws -> ChatOrgState {
        try await call(ChatOrgState.self, "GET", "/v1/orgs/\(org)/state", token: token)
    }

    /// `GET /v1/orgs/{org}/requests?before=`: the next page of the requests
    /// a snapshot left out (stage D).
    func requestsPage(_ org: String, before: String, token: String) async throws -> ChatRequestsPage {
        var parts = URLComponents()
        parts.queryItems = [.init(name: "before", value: before)]
        return try await call(ChatRequestsPage.self, "GET", "/v1/orgs/\(org)/requests", token: token, query: parts.percentEncodedQuery)
    }

    /// `GET /v1/orgs/{org}/channels?after=`: channels the snapshot left out (F2).
    func channelsPage(_ org: String, after: String, token: String) async throws -> ChatChannelsPage {
        var parts = URLComponents()
        parts.queryItems = [.init(name: "after", value: after)]
        return try await call(ChatChannelsPage.self, "GET", "/v1/orgs/\(org)/channels", token: token, query: parts.percentEncodedQuery)
    }

    /// F3: a channel's messages with `seq < before` (newest first), or a thread's.
    func messagesPage(_ org: String, channel: String, root: String? = nil, before: Int?, token: String) async throws -> ChatMessagesPage {
        var parts = URLComponents()
        parts.queryItems = before.map { [.init(name: "before", value: String($0))] }
        let path = root.map { "/v1/orgs/\(org)/channels/\(channel)/threads/\($0)" } ?? "/v1/orgs/\(org)/channels/\(channel)/messages"
        return try await call(ChatMessagesPage.self, "GET", path, token: token, query: parts.percentEncodedQuery)
    }

    /// `GET /v1/events`: one page of a stream after `after`.
    func events(stream: String, after: Int, limit: Int = 500, token: String) async throws -> ChatEventPage {
        var parts = URLComponents(url: server.baseURL.appendingPathComponent("/v1/events"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "stream", value: stream), .init(name: "after", value: String(after)), .init(name: "limit", value: String(limit))]
        return try await call(ChatEventPage.self, "GET", "/v1/events", token: token, query: parts.percentEncodedQuery)
    }

    /// `GET /v1/sessions`: the account's open sessions — its devices (C6).
    func sessions(token: String) async throws -> [ChatDeviceSession] {
        try await call(ChatDeviceSessions.self, "GET", "/v1/sessions", token: token).sessions
    }

    /// `DELETE /v1/sessions/{id}`: closes a session of the account, on the
    /// whole server — this Mac's own too.
    func closeSession(_ sessionId: String, token: String) async throws {
        try Self.check(try await send("DELETE", "/v1/sessions/\(sessionId)", token: token))
    }

    /// `GET /v1/orgs/{org}/audit`: a page of the security log, newest first
    /// (owners and admins).
    func audit(_ org: String, before: Int? = nil, limit: Int = 50, token: String) async throws -> ChatAuditPage {
        var parts = URLComponents()
        parts.queryItems = [.init(name: "limit", value: String(limit))] + (before.map { [.init(name: "before", value: String($0))] } ?? [])
        return try await call(ChatAuditPage.self, "GET", "/v1/orgs/\(org)/audit", token: token, query: parts.percentEncodedQuery)
    }

    /// `POST /v1/ephemeral` (D4b): a hint to the run's audience, best effort.
    func postEphemeral(org: String, type: String, body: ChatJSON, token: String) async throws {
        let bytes = try JSONEncoder().encode(ChatJSON.object(["org": .string(org), "type": .string(type), "body": body]))
        let response = try await send("POST", "/v1/ephemeral", token: token, body: bytes)
        guard (200..<300).contains(response.status) else { throw ChatError.storage("ephemeral \(type): \(response.status)") }
    }

    /// `POST /v1/commands` with the stored bytes, as they are.
    func postCommand(_ bytes: Data, token: String) async throws -> Response {
        try await send("POST", "/v1/commands", token: token, body: bytes)
    }

    // MARK: Retry-After

    static func retryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}

/// Never follows a redirect: the 3xx itself comes back and is refused.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// UUID version 7: 48 bits of Unix milliseconds, then random bits (RFC 9562).
enum ChatUUID {
    static func v7(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        let ms = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x70
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }

    /// The time inside a version 7 id; nil for any other id.
    static func time(of id: String) -> Date? {
        let hex = id.replacingOccurrences(of: "-", with: "")
        guard hex.count == 32, Array(hex)[12] == "7", let ms = UInt64(hex.prefix(12), radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
