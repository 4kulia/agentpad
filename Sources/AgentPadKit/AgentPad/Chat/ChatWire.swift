import Foundation

/// Any JSON value, for event bodies and command arguments whose shape
/// depends on their type.
enum ChatJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ChatJSON])
    case object([String: ChatJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([ChatJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: ChatJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    subscript(key: String) -> ChatJSON? {
        if case .object(let o) = self { o[key] } else { nil }
    }

    var string: String? { if case .string(let v) = self { v } else { nil } }
    var int: Int? { if case .number(let v) = self, v == v.rounded() { Int(v) } else { nil } }
}

/// One event of a stream (server `docs/api.md`, "Event envelope").
struct ChatEvent: Codable, Equatable, Sendable {
    struct Actor: Codable, Equatable, Sendable {
        let accountId: String
        let sessionId: String?

        enum CodingKeys: String, CodingKey {
            case accountId = "account_id"
            case sessionId = "session_id"
        }
    }

    let stream: String
    let seq: Int
    let id: String
    let type: String
    let actor: Actor?
    let body: ChatJSON
    let commandId: String?
    let at: String
    /// F3: an event of a message carries it as it is now; a frame may come without it.
    var message: ChatJSON? = nil
    /// Retained with skipped events so future envelope fields survive recovery too.
    var additionalFields: [String: ChatJSON] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case stream, seq, id, type, actor, body, at, message
        case commandId = "command_id"
    }
}

extension ChatEvent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stream = try c.decode(String.self, forKey: .stream); seq = try c.decode(Int.self, forKey: .seq)
        id = try c.decode(String.self, forKey: .id); type = try c.decode(String.self, forKey: .type)
        actor = try c.decodeIfPresent(Actor.self, forKey: .actor); body = try c.decode(ChatJSON.self, forKey: .body)
        commandId = try c.decodeIfPresent(String.self, forKey: .commandId); at = try c.decode(String.self, forKey: .at)
        message = try c.decodeIfPresent(ChatJSON.self, forKey: .message)
        let known = Set(CodingKeys.allCases.map(\.rawValue))
        additionalFields = try [String: ChatJSON](from: decoder).filter { !known.contains($0.key) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(stream, forKey: .stream); try c.encode(seq, forKey: .seq)
        try c.encode(id, forKey: .id); try c.encode(type, forKey: .type)
        try c.encodeIfPresent(actor, forKey: .actor); try c.encode(body, forKey: .body)
        try c.encodeIfPresent(commandId, forKey: .commandId); try c.encode(at, forKey: .at)
        try c.encodeIfPresent(message, forKey: .message)
        try additionalFields.encode(to: encoder)
    }
}

/// `GET /v1/events` (stage B).
struct ChatEventPage: Codable, Equatable, Sendable {
    let stream: String
    let head: Int
    let events: [ChatEvent]
}

/// `GET /v1/orgs/{org}/state`: the organization snapshot (stage B).
struct ChatOrgState: Codable, Equatable, Sendable {
    struct Org: Codable, Equatable, Sendable {
        let orgId: String
        let name: String
        enum CodingKeys: String, CodingKey { case name, orgId = "org_id" }
    }

    struct Member: Codable, Equatable, Sendable {
        let accountId, handle, name, role: String
        enum CodingKeys: String, CodingKey { case handle, name, role, accountId = "account_id" }
    }

    struct Team: Codable, Equatable, Sendable {
        let teamId: String
        let name: String
        let isGeneral: Bool
        let archivedAt: String?
        let members: [String]
        enum CodingKeys: String, CodingKey {
            case name, members
            case teamId = "team_id", isGeneral = "is_general", archivedAt = "archived_at"
        }
    }

    struct Invitation: Codable, Equatable, Sendable {
        let invitationId, email, role: String
        let teamIds: [String]
        let createdAt: String?
        let expiresAt: String?
        enum CodingKeys: String, CodingKey {
            case email, role
            case invitationId = "invitation_id", teamIds = "team_ids", createdAt = "created_at", expiresAt = "expires_at"
        }
    }

    struct Admin: Codable, Equatable, Sendable {
        let teams: [Team]
        let invitations: [Invitation]
    }

    let org: Org
    let members: [Member]
    let teams: [Team]
    let myTeams: [String]
    let admin: Admin?
    /// Stage D ("Snapshot, stage D"); absent from a server without it.
    var agents: [ChatAgentCard]? = nil
    var requests: [ChatRequestWire]? = nil
    /// More requests are left: read from this one with `GET /v1/orgs/{org}/requests`.
    var requestsNext: String? = nil
    /// F2: absent from a server without `chat.channels`.
    var channels: [ChatChannelCard]? = nil
    /// More channels are left: `GET /v1/orgs/{org}/channels?after=`, then each page's `next`.
    var channelsNext: String? = nil
    /// F8: absent from a server without `chat.agents`.
    var agentChannels: [ChatChannelAgentWire]? = nil
    var threadParticipationReload: Bool? = nil
    let streams: [String: Int]

    enum CodingKeys: String, CodingKey {
        case threadParticipationReload = "thread_participation_reload"
        case org, members, teams, admin, streams, agents, requests, channels
        case myTeams = "my_teams", requestsNext = "requests_next", channelsNext = "channels_next", agentChannels = "agent_channels"
    }

    /// What the cache keeps of it (C4): every team this member sees (an
    /// admin sees all), marked whether the member is in it.
    var snapshot: ChatSnapshot {
        var seen: [String: Team] = [:]
        for team in (admin?.teams ?? []) + teams { seen[team.teamId] = team }
        let all = seen.values.sorted { $0.teamId < $1.teamId }
        return ChatSnapshot(
            cursors: streams,
            orgName: org.name,
            members: members.map { .init(accountId: $0.accountId, handle: $0.handle, name: $0.name, role: $0.role) },
            teams: all.map { .init(teamId: $0.teamId, name: $0.name, isGeneral: $0.isGeneral, archivedAt: $0.archivedAt, mine: myTeams.contains($0.teamId)) },
            teamMembers: all.flatMap { team in team.members.map { .init(teamId: team.teamId, accountId: $0) } },
            invitations: admin.map { $0.invitations.map { .init(invitationId: $0.invitationId, email: $0.email, role: $0.role, state: "open", expiresAt: $0.expiresAt) } },
            agents: agents,
            requests: requests,
            channels: channels,
            channelsComplete: channelsNext == nil,
            agentChannels: agentChannels,
            threadParticipationReload: threadParticipationReload == true
        )
    }
}

/// One WebSocket frame (stage B, "Frames"): JSON with a `frame` field.
enum ChatFrame: Equatable, Sendable {
    case hello(generation: String, heartbeatSeconds: Int, version: String)
    /// `sub`: the client's number of this subscription, echoed by the server
    /// in the stream's `subscribed`, `unsubscribed` and `resync_required`
    /// (review C10-4); a server that does not echo it sends none back.
    case subscribe([String: Int], sub: Int? = nil)
    case unsubscribe([String])
    case event(ChatEvent)
    case subscribed(stream: String, head: Int, sub: Int? = nil)
    case resyncRequired(String, sub: Int? = nil)
    case unsubscribed(String, sub: Int? = nil)
    /// `unsubscribed` with `reason: "too_many_streams"`: the socket's limit
    /// of streams, not a refusal of the right to read it.
    case tooManyStreams(String, sub: Int? = nil)
    case ping
    case pong
    /// A hint about a run (`run.activity`, `run.access_wait`): no stream, no
    /// number; never state (D4b).
    case ephemeral(org: String, type: String, body: ChatJSON)
    /// A frame this build does not know; ignored.
    case unknown(String)

    private struct Head: Decodable { let frame: String }
    private struct Hello: Codable { let generation: String; let heartbeat_seconds: Int; let version: String }
    private struct Streams<T: Codable>: Codable { let streams: T }
    private struct Stream: Codable { let stream: String; let sub: Int?; var reason: String? = nil }
    private struct Subscribed: Codable { let stream: String; let head: Int; let sub: Int? }

    static func decode(_ data: Data) throws -> ChatFrame {
        let d = JSONDecoder()
        switch try d.decode(Head.self, from: data).frame {
        case "hello":
            let h = try d.decode(Hello.self, from: data)
            return .hello(generation: h.generation, heartbeatSeconds: h.heartbeat_seconds, version: h.version)
        case "subscribe":
            struct Subscribe: Codable { let streams: [String: Int]; let sub: Int? }
            let s = try d.decode(Subscribe.self, from: data)
            return .subscribe(s.streams, sub: s.sub)
        case "unsubscribe": return .unsubscribe(try d.decode(Streams<[String]>.self, from: data).streams)
        case "event": return .event(try d.decode(ChatEvent.self, from: data))
        case "subscribed":
            let s = try d.decode(Subscribed.self, from: data)
            return .subscribed(stream: s.stream, head: s.head, sub: s.sub)
        case "resync_required":
            let s = try d.decode(Stream.self, from: data)
            return .resyncRequired(s.stream, sub: s.sub)
        case "unsubscribed":
            let s = try d.decode(Stream.self, from: data)
            if s.reason == "too_many_streams" { return .tooManyStreams(s.stream, sub: s.sub) }
            return .unsubscribed(s.stream, sub: s.sub)
        case "ephemeral":
            struct Ephemeral: Decodable { let org_id: String; let type: String; let body: ChatJSON }
            let e = try d.decode(Ephemeral.self, from: data)
            return .ephemeral(org: e.org_id, type: e.type, body: e.body)
        case "ping": return .ping
        case "pong": return .pong
        case let other: return .unknown(other)
        }
    }

    /// The frames a client sends.
    func encoded() -> String {
        let object: [String: Any]
        switch self {
        case .subscribe(let streams, let sub):
            var frame: [String: Any] = ["frame": "subscribe", "streams": streams]
            if let sub { frame["sub"] = sub }
            object = frame
        case .unsubscribe(let streams): object = ["frame": "unsubscribe", "streams": streams]
        case .ping: object = ["frame": "ping"]
        case .pong: object = ["frame": "pong"]
        default: return "{}"
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
