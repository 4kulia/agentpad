import Foundation
import GRDB

/// A request's state on the server (docs/agentpad/CHAT-PLAN.md 6.9, server
/// `docs/api.md` "Requests"). A state this build does not know is kept as
/// it came: not final, nothing to do.
struct TeamRequestState: RawRepresentable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let submitted = Self(rawValue: "submitted")
    static let awaitingDecision = Self(rawValue: "awaiting_decision")
    static let approved = Self(rawValue: "approved")
    static let starting = Self(rawValue: "starting")
    static let running = Self(rawValue: "running")
    static let declined = Self(rawValue: "declined")
    static let failedToStart = Self(rawValue: "failed_to_start")
    static let finished = Self(rawValue: "finished")
    static let failed = Self(rawValue: "failed")
    static let cancelled = Self(rawValue: "cancelled")
    static let expired = Self(rawValue: "expired")
    static let stopped = Self(rawValue: "stopped")
    static let stopFailed = Self(rawValue: "stop_failed")
    static let stopRequested = Self(rawValue: "stop_requested")

    /// What happened, as the server's `docs/api.md` words it ("What each
    /// state means"); nil for a state this build does not know.
    var meaning: String? {
        switch rawValue {
        case "submitted": "The request reached the server and waits for the owner's Mac."
        case "awaiting_decision": "The owner's Mac has the request; the owner has not decided yet."
        case "approved": "The owner allowed it; the agent is about to start."
        case "declined": "The owner declined it."
        case "starting": "The owner's Mac is starting the agent."
        case "failed_to_start": "The agent could not be started."
        case "running": "The agent is working on it."
        case "stop_requested": "Someone asked to stop the run; the owner's Mac is stopping it."
        case "finished": "The agent finished; the result follows."
        case "failed": "The agent's run ended with an error."
        case "cancelled": "The initiator cancelled it before it ran."
        case "expired": "Its deadline passed before it ran, so it was given up."
        case "stopped": "The run was stopped before it finished."
        case "stop_failed": "The run was asked to stop, but its processes could not be stopped."
        default: nil
        }
    }
    /// Made on this Mac, not yet created on the server (D5).
    static let creating = Self(rawValue: "creating")
    /// Not on a restored server: what an earlier generation said of it is
    /// no longer the server's word (review D8b-3). Local, final — only after
    /// the new generation's whole read did not list it (review D8i).
    static let lost = Self(rawValue: "lost")
    /// The server was restored and its new generation is being read: this
    /// call of this Mac (asked here, or run here) waits for its word.
    /// Local, not final; no server field of the earlier generation is kept
    /// but the fixed part, for showing it (review D8i).
    static let resyncing = Self(rawValue: "resyncing")

    static let finals: Set<Self> = [.declined, .failedToStart, .finished, .failed, .cancelled, .expired, .stopped, .stopFailed, .lost]
    var isFinal: Bool { Self.finals.contains(self) }
}

/// An agent's card as members see it (server `docs/api.md` "Agents").
struct ChatAgentCard: Codable, Equatable, Sendable {
    var agentId: String
    var ownerAccountId: String
    var name: String
    var description: String
    var access: String
    var enabled: Bool
    var executorSessionId: String?
    var executorDeviceName: String?
    var available: Bool
    /// In the snapshot: the caller's teams among the agent's audience.
    var teamIds: [String]?

    enum CodingKeys: String, CodingKey {
        case name, description, access, enabled, available
        case agentId = "agent_id", ownerAccountId = "owner_account_id", executorSessionId = "executor_session_id"
        case executorDeviceName = "executor_device_name", teamIds = "team_ids"
    }
}

/// A delivered result (`result.deliver`).
struct ChatCallResult: Codable, Equatable, Sendable {
    var requestId: String?
    var runId: String
    var text: String
    var truncated: Bool
    var threadId: String?
    var deliveredAt: String?
    /// Local: history let go of the text (`trim`); the delivery stays known.
    var trimmed: Bool? = nil

    /// What is shown for the text: the text, or that it is no longer kept (review D8f-p3-8).
    var shownText: String { trimmed == true ? "[The answer is no longer kept on this Mac: history limit.]" : text }

    enum CodingKeys: String, CodingKey {
        case text, truncated
        case requestId = "request_id", runId = "run_id", threadId = "thread_id", deliveredAt = "delivered_at"
    }
}

/// A request as the server sends it: whole (`request.create`,
/// `request.snapshot`, snapshot, page) or only its changing part (the
/// events of a move). Fixed fields are nil in the latter.
struct ChatRequestWire: Codable, Equatable, Sendable {
    var requestId: String
    var kind: String?
    var agentId: String?
    var ownerAccountId: String?
    var executorDeviceName: String?
    var initiatorAccountId: String?
    var text: String?
    var origin: TeamCallOrigin?
    var threadId: String?
    var conditionsVersion: Int?
    var deliverBy: String?
    var createdAt: String?
    var state: String
    var version: Int
    var runId: String?
    var declineReason: String?
    var failureReason: String?
    /// Why the server moved it (D7), kept as it came — also a value this
    /// build does not know (review D8g-p3-9).
    var cause: String?
    var updatedAt: String?
    /// Snapshot and page only: this session executes it.
    var onThisDevice: Bool?
    /// Snapshot and page only: the delivered result, if any.
    var result: ChatCallResult?
    /// F8: a channel's request — its channel and the thread the agent
    /// answers in (fixed; also in the signal without text); its
    /// publication (changing: `awaiting_publish`, `published`, `withheld`,
    /// `publish_failed`) and why it failed.
    var channelId: String?
    var threadRootId: String?
    var publication: String?
    var publishReason: String?
    var context: [ChatChannelContent.Reference]? = nil
    var sourceMessageId: String? = nil
    var sourceRevision: Int? = nil
    var replyMode: String? = nil
    var requestedPolicyId: String? = nil
    var decisionBasis: String? = nil
    var decisionPolicyId: String? = nil

    enum CodingKeys: String, CodingKey {
        case kind, text, origin, state, version, result, cause, publication, context
        case sourceMessageId = "source_message_id", sourceRevision = "source_revision", replyMode = "reply_mode"
        case requestedPolicyId = "requested_policy_id", decisionBasis = "decision_basis", decisionPolicyId = "decision_policy_id"
        case requestId = "request_id", agentId = "agent_id", ownerAccountId = "owner_account_id"
        case executorDeviceName = "executor_device_name", initiatorAccountId = "initiator_account_id", threadId = "thread_id"
        case conditionsVersion = "conditions_version", deliverBy = "deliver_by", createdAt = "created_at", runId = "run_id"
        case declineReason = "decline_reason", failureReason = "failure_reason", updatedAt = "updated_at"
        case onThisDevice = "on_this_device", channelId = "channel_id", threadRootId = "thread_root_id",
             publishReason = "publish_reason"
    }

    /// The fixed part came with it: every field its contract requires
    /// (server `docs/api.md`, the request). One short of it is not taken —
    /// a later snapshot or page brings it whole (review D8h-p3-2, D8i-p3-5).
    var hasFixed: Bool {
        kind != nil && agentId != nil && initiatorAccountId != nil && ownerAccountId != nil && text != nil
            && executorDeviceName != nil && conditionsVersion != nil && deliverBy != nil && createdAt != nil
    }
}

/// `GET /v1/orgs/{org}/requests?before=`: the requests a snapshot left out.
struct ChatRequestsPage: Codable, Equatable, Sendable {
    let requests: [ChatRequestWire]
    let next: String?
}

/// A request as the cache has it: the server's parts, its result, and what
/// only this Mac knows.
struct ChatRequest: Equatable, Sendable {
    var requestId: String
    var hasFixed: Bool
    var kind: String?
    var agentId: String?
    var ownerAccountId: String?
    var initiatorAccountId: String?
    var executorDeviceName: String?
    var text: String?
    var origin: TeamCallOrigin?
    var threadId: String?
    var conditionsVersion: Int?
    var deliverBy: String?
    var createdAt: String?
    var state: TeamRequestState
    var version: Int
    var runId: String?
    var declineReason: String?
    var cause: String?
    var failureReason: String?
    var updatedAt: String?
    var onThisDevice: Bool
    var askedHere: Bool
    /// Local: the full result text (the delivered one may be cut, 6.10).
    var localText: String?
    /// Local: the run's log.
    var localLog: String?
    /// Local: the agent's name and its owner's handle, kept once known —
    /// the address does not depend on the live catalog (review D8d-p3-6).
    var agentName: String?
    var ownerHandle: String?
    /// Local: cleared from the Team tab, as a call to me and as mine.
    var hiddenIncoming: Bool
    var hiddenOutgoing: Bool
    var result: ChatCallResult?
    /// F8: a channel's request (see `ChatRequestWire`).
    var channelId: String?
    var threadRootId: String?
    var publication: String?
    var publishReason: String?

    var sourceMessageId: String?
    var sourceRevision: Int?
    var replyMode: String?
    var requestedPolicyId: String?
    var decisionBasis: String?
    var decisionPolicyId: String?

    /// The result reached the initiator (D8: `answered`).
    var answered: Bool { result != nil }

    init(row: Row, result: ChatCallResult?) {
        requestId = row["request_id"]
        hasFixed = row["has_fixed"]
        kind = row["kind"]
        agentId = row["agent_id"]
        ownerAccountId = row["owner_account_id"]
        initiatorAccountId = row["initiator_account_id"]
        executorDeviceName = row["executor_device_name"]
        text = row["text"]
        let session: String? = row["origin_session"], project: String? = row["origin_project"]
        origin = session == nil && project == nil ? nil : TeamCallOrigin(session: session, project: project)
        threadId = row["thread_id"]
        conditionsVersion = row["conditions_version"]
        deliverBy = row["deliver_by"]
        createdAt = row["created_at"]
        state = TeamRequestState(rawValue: row["state"])
        version = row["version"]
        runId = row["run_id"]
        declineReason = row["decline_reason"]
        cause = row["cause"]
        failureReason = row["failure_reason"]
        updatedAt = row["updated_at"]
        onThisDevice = row["on_this_device"]
        askedHere = row["asked_here"]
        // The local full text and log of the current run only (review D8f-p3-4).
        let current = (row["local_run_id"] as String?) == (row["run_id"] as String?) && row["run_id"] != nil
        localText = current ? row["local_text"] : nil
        localLog = current ? row["local_log"] : nil
        agentName = row["agent_name"]
        ownerHandle = row["owner_handle"]
        hiddenIncoming = row["hidden_incoming"]
        hiddenOutgoing = row["hidden_outgoing"]
        channelId = row["channel_id"]
        threadRootId = row["thread_root_id"]
        publication = row["publication"]
        publishReason = row["publish_reason"]
        sourceMessageId = row["source_message_id"]
        sourceRevision = row["source_revision"]
        replyMode = row["reply_mode"]
        requestedPolicyId = row["requested_policy_id"]
        decisionBasis = row["decision_basis"]
        decisionPolicyId = row["decision_policy_id"]
        self.result = result
    }
}

/// The calls of one organization in its cache (D8): requests and their
/// results, the agent catalog, and the actions `reconcile` owes. Writes that
/// come from the server run inside `ChatStore`'s transactions, with the
/// stream's cursor.
final class ChatCallStore: Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    /// The cache file's identity (`meta.instance`); nil when it cannot be read.
    var instance: String? {
        try? queue.read { db in try String.fetchOne(db, sql: "SELECT instance FROM meta WHERE id = 1") }
    }

    // MARK: Reading

    func request(_ id: String) throws -> ChatRequest? {
        try queue.read { db in try Self.request(db, id) }
    }

    func requestIds(in state: TeamRequestState) throws -> [String] {
        try queue.read { db in try String.fetchAll(db, sql: "SELECT request_id FROM requests WHERE state = ?", arguments: [state.rawValue]) }
    }

    /// Newest first.
    func requests() throws -> [ChatRequest] {
        try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM requests ORDER BY created_at DESC, request_id").map { row in
                ChatRequest(row: row, result: try Self.result(db, request: row["request_id"], run: row["run_id"]))
            }
        }
    }

    func requestIds() throws -> [String] {
        try queue.read { db in try String.fetchAll(db, sql: "SELECT request_id FROM requests") }
    }

    /// The requests history shows (`shownIds`).
    func historyIds(now: Date = Date()) throws -> [String] {
        try queue.read { db in try Self.shownIds(db, now: now) }
    }

    /// The agents members of my teams may call.
    func catalog() throws -> [ChatAgentCard] {
        try queue.read { db in try Self.catalog(db) }
    }

    static func catalog(_ db: Database) throws -> [ChatAgentCard] {
        try Row.fetchAll(db, sql: "SELECT * FROM agents_catalog ORDER BY name, agent_id").map { row in
            ChatAgentCard(
                agentId: row["agent_id"], ownerAccountId: row["owner_account_id"], name: row["name"],
                description: row["description"], access: row["access"], enabled: row["enabled"],
                executorSessionId: row["executor_session_id"], executorDeviceName: row["executor_device_name"],
                available: row["available"],
                teamIds: try String.fetchAll(db, sql: "SELECT team_id FROM agent_teams WHERE agent_id = ? ORDER BY team_id",
                                             arguments: [row["agent_id"]])
            )
        }
    }

    static func request(_ db: Database, _ id: String) throws -> ChatRequest? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM requests WHERE request_id = ?", arguments: [id]) else { return nil }
        return ChatRequest(row: row, result: try result(db, request: id, run: row["run_id"]))
    }

    /// The result of the request's current run only: a result of an
    /// earlier run (before a restored server ran it again) does not answer
    /// this one (review D8e-p3-7).
    private static func result(_ db: Database, request id: String, run: String?) throws -> ChatCallResult? {
        guard let run, let row = try Row.fetchOne(db, sql: "SELECT * FROM results WHERE request_id = ? AND run_id = ?",
                                                  arguments: [id, run])
        else { return nil }
        return ChatCallResult(requestId: id, runId: row["run_id"], text: row["text"], truncated: row["truncated"],
                              threadId: row["thread_id"], deliveredAt: row["delivered_at"], trimmed: row["trimmed"])
    }

    // MARK: Local columns

    /// Keeps the full result text and the run's log here; no snapshot or
    /// event changes them.
    /// They belong to the run `runId`: shown only while it is the request's
    /// current run (review D8f-p3-4). A run that is not the request's
    /// current one — nor, before the server named one, the run already kept
    /// — writes nothing: a late write of an earlier run never replaces a
    /// later one's (review D8h-p2-8).
    func setLocal(_ requestId: String, text: String?, log: String?, runId: String) throws {
        try queue.write { db in
            try db.execute(sql: """
                UPDATE requests SET local_text = coalesce(?, CASE WHEN local_run_id IS ? THEN local_text END),
                    local_log = coalesce(?, CASE WHEN local_run_id IS ? THEN local_log END), local_run_id = ?
                WHERE request_id = ? AND (run_id = ? OR (run_id IS NULL AND (local_run_id IS NULL OR local_run_id = ?)))
                """, arguments: [text, runId, log, runId, runId, requestId, runId, runId])
        }
    }

    // MARK: Asking (the caller's side)

    /// The agent `name@handle` names: a member by handle, and that member's
    /// agent by name in the catalog. No contacts of the direct mode.
    static func resolve(_ db: Database, address: String) throws -> ChatAgentCard {
        guard let at = address.lastIndex(of: "@") else { throw TeamError.refused("unknown_agent") }
        let name = address[..<at].lowercased(), handle = address[address.index(after: at)...].lowercased()
        guard let row = try Row.fetchOne(db, sql: """
            SELECT a.* FROM agents_catalog a JOIN members m ON m.account_id = a.owner_account_id
            WHERE a.name = ? AND lower(m.handle) = ?
            """, arguments: [name, handle])
        else { throw TeamError.refused("unknown_agent") }
        return ChatAgentCard(
            agentId: row["agent_id"], ownerAccountId: row["owner_account_id"], name: row["name"], description: row["description"],
            access: row["access"], enabled: row["enabled"], executorSessionId: row["executor_session_id"],
            executorDeviceName: row["executor_device_name"], available: row["available"], teamIds: nil
        )
    }

    /// A call asked from this Mac: the agent found by its address and the
    /// request kept here, before the server has it. `also` runs in the same
    /// transaction — the send queue's `request.create` (D5).
    @discardableResult
    func createOutgoing(address: String, text: String, origin: TeamCallOrigin?, initiator: String, deliverBy: Date? = nil,
                        requestId: String = UUID().uuidString.lowercased(), threadId: String? = nil,
                        also: (Database, ChatRequestWire) throws -> Void = { _, _ in }) throws -> ChatRequest {
        try queue.write { db in
            let agent = try Self.resolve(db, address: address)
            let wire = ChatRequestWire(
                requestId: requestId, kind: "personal", agentId: agent.agentId, ownerAccountId: agent.ownerAccountId,
                executorDeviceName: agent.executorDeviceName, initiatorAccountId: initiator, text: text, origin: origin, threadId: threadId,
                conditionsVersion: 1, deliverBy: deliverBy.map(ChatCallStore.timestamp), createdAt: ChatCallStore.timestamp(Date()), state: TeamRequestState.creating.rawValue, version: 0
            )
            try Self.insert(db, wire)
            // The server's own copy of the fixed part replaces this one.
            try db.execute(sql: "UPDATE requests SET has_fixed = 0, asked_here = 1, agent_name = ? WHERE request_id = ?",
                           arguments: [agent.name, requestId])
            try Self.rememberNames(db, request: requestId)
            try also(db, wire)
            return try Self.request(db, requestId)!
        }
    }

    /// A thread the caller may continue with `agentId` (D5b §3.2): an
    /// earlier call of this account — the server's word, whatever Mac or
    /// sign-in asked it (review D5b-3) — to the same agent, which is the
    /// thread or belongs to it.
    static func knowsThread(_ db: Database, _ threadId: String, agentId: String, initiator: String) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM requests r LEFT JOIN results s ON s.request_id = r.request_id
                WHERE r.initiator_account_id = ? AND r.agent_id = ? AND (r.request_id = ? OR r.thread_id = ? OR s.thread_id = ?))
            """, arguments: [initiator, agentId, threadId, threadId, threadId]) ?? false
    }

    /// D5: calls asked here the server never took end here — a request
    /// still `creating` none of whose `request.create` rows in the send queue
    /// lives (`pending`, `sent`, `unconfirmed`) and whose last row was
    /// refused (`failed`) or dropped becomes `failed`, version 0, so any
    /// version of the server's wins if it comes after all. By request id, not
    /// by row: a command the core carried to a new session has a new living
    /// row of the same request. Reconciled in the same transaction (its
    /// outcome is told). Returns the requests settled.
    @discardableResult
    func settleCreates(now: Date = Date()) throws -> [String] {
        try queue.write { db in try Self.settleCreates(db, now: now) }
    }

    /// The reason a call not sent keeps: the server's code, or this one.
    static let sessionEnded = "session_ended"

    static func settleCreates(_ db: Database, now: Date = Date()) throws -> [String] {
        let creating = try String.fetchAll(db, sql: "SELECT request_id FROM requests WHERE state = ? AND asked_here = 1",
                                           arguments: [TeamRequestState.creating.rawValue])
        guard !creating.isEmpty else { return [] }
        var rows: [String: [(state: String, error: String?)]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT state, error, body_bytes FROM outbox WHERE type = 'request.create' ORDER BY seq") {
            let body: Data = row["body_bytes"]
            guard let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: body),
                  case .object(let args) = envelope.args, let id = args["request_id"]?.string else { continue }
            rows[id.lowercased(), default: []].append((row["state"], row["error"]))
        }
        let alive = Set([ChatCommandRecord.State.pending, .sent, .unconfirmed].map(\.rawValue))
        var settled: [String] = []
        for id in creating {
            guard let list = rows[id], let last = list.last, !list.contains(where: { alive.contains($0.state) }) else { continue }
            let reason = last.state == ChatCommandRecord.State.failed.rawValue
                ? ((last.error.map { $0 == "dismissed" ? "refused" : $0 }) ?? "refused")
                : sessionEnded
            try db.execute(sql: "UPDATE requests SET state = ?, failure_reason = ?, updated_at = ? WHERE request_id = ? AND state = ?",
                           arguments: [TeamRequestState.failed.rawValue, reason, timestamp(now), id, TeamRequestState.creating.rawValue])
            if db.changesCount == 1 { settled.append(id) }
        }
        if !settled.isEmpty { try ChatReconcile.reconcile(db, settled, facts: nil) }
        return settled
    }

    // MARK: From the server (inside the cache's transactions)

    /// Event types this store applies.
    static let eventTypes: Set<String> = [
        "request.create", "request.snapshot", "request.received", "request.decide", "request.decide_automatic", "run.start", "run.failed_to_start",
        "run.started", "run.finished", "run.failed", "result.deliver", "agent.publish", "agent.unpublish", "agent.disable",
        // Hardening (D2b, D7): the changing part of a request, applied the same way.
        "request.cancel", "request.stop", "run.stopped", "run.stop_failed", "request.expired",
        // F8: a channel's request's publication, the changing part.
        "result.publish", "result.withhold",
    ]

    /// Whether this store reads `event`: a type it knows, or a later type
    /// whose body is a request's changing part, or a card on a team stream.
    static func reads(_ event: ChatEvent) -> Bool {
        if eventTypes.contains(event.type) { return true }
        let body = event.body
        if body["request_id"]?.string != nil, body["state"]?.string != nil, body["version"] != nil { return true }
        return event.stream.hasPrefix("team:") && body["agent_id"]?.string != nil && body["owner_account_id"]?.string != nil
            && body["name"]?.string != nil
    }

    /// Applies an event; returns the request it touched, for `reconcile`.
    /// What applying an event came to.
    struct EventApplied {
        /// The request it touched, for `reconcile`.
        var request: String?
        /// The body read as its type says; false: nothing of it was applied.
        var read: Bool
    }

    static func apply(_ db: Database, _ event: ChatEvent) throws -> EventApplied {
        let team = event.stream.hasPrefix("team:") ? String(event.stream.dropFirst("team:".count)) : nil
        switch event.type {
        case "agent.publish", "agent.disable":
            // The card as this team's stream tells it (`agent.disable`: the
            // card with `enabled` changed).
            guard let team, let card = decode(ChatAgentCard.self, event.body) else { return EventApplied(read: false) }
            try link(db, card, team: team, seq: event.seq)
            return EventApplied(read: true)
        case "agent.unpublish":
            guard let team, let agent = event.body["agent_id"]?.string else { return EventApplied(read: false) }
            try db.execute(sql: "DELETE FROM agent_teams WHERE agent_id = ? AND team_id = ?", arguments: [agent, team])
            try refreshCard(db, agent)
            return EventApplied(read: true)
        case "result.deliver":
            guard let result = decode(ChatCallResult.self, event.body), let id = result.requestId else { return EventApplied(read: false) }
            try apply(db, result: result, requestId: id)
            return EventApplied(request: id, read: true)
        case _ where event.body["request_id"] == nil:
            // A card of a later type (`reads`).
            guard let team, let card = decode(ChatAgentCard.self, event.body) else { return EventApplied(read: false) }
            try link(db, card, team: team, seq: event.seq)
            return EventApplied(read: true)
        default:
            guard let wire = decode(ChatRequestWire.self, event.body) else { return EventApplied(read: false) }
            // An event of the device stream is this session's to execute. A
            // move carries no `updated_at`: the event's time is the move's.
            try apply(db, wire, onThisDevice: event.stream.hasPrefix("device:") ? true : nil, at: event.at)
            return EventApplied(request: wire.requestId, read: true)
        }
    }

    /// The rule of applying a request from anywhere (server `docs/api.md`,
    /// "Applying a request"): the fixed part when it is not held yet, the
    /// changing part only from a greater version, the result once per run.
    /// Versions compare within one server generation: the first word of the
    /// current one replaces what an earlier generation said (a restored
    /// server counts again). `onThisDevice`: the snapshot's word, or true
    /// from the device stream. `at`: when the move happened, for history.
    /// Rows stay within a generation: their version and actions guard
    /// against old words; a new generation reads the cache anew
    /// (`ChatStore.beginGeneration`). A request open again is shown again:
    /// clearing history hides final ones only (review D8h-p2-6, p3-3).
    static func apply(_ db: Database, _ wire: ChatRequestWire, onThisDevice: Bool?, at: String? = nil) throws {
        let current = try generation(db)
        let held = try Row.fetchOne(db, sql: "SELECT has_fixed, version, generation FROM requests WHERE request_id = ?",
                                    arguments: [wire.requestId])
        if let held {
            if wire.hasFixed, !(held["has_fixed"] as Bool) { try takeFixed(db, wire) }
            // F8: the signal without text tells the kind and channel before the whole form comes.
            if !(held["has_fixed"] as Bool), wire.kind != nil || wire.channelId != nil {
                try db.execute(sql: "UPDATE requests SET kind = coalesce(kind, ?), channel_id = coalesce(channel_id, ?) WHERE request_id = ?",
                               arguments: [wire.kind, wire.channelId, wire.requestId])
            }
            // A call asked here, `lost` over a new generation, has none: the
            // new generation's word replaces it by the rule itself.
            let sameGeneration = (held["generation"] as String?) == current
            if wire.version > held["version"] as Int || !sameGeneration {
                try db.execute(sql: """
                    UPDATE requests SET state = ?, version = ?, run_id = ?, decline_reason = ?, failure_reason = ?, cause = ?,
                        publication = ?, publish_reason = ?, updated_at = coalesce(?, ?, updated_at), generation = ?
                    WHERE request_id = ?
                    """, arguments: [wire.state, wire.version, wire.runId, wire.declineReason, wire.failureReason, wire.cause,
                                     wire.publication, wire.publishReason, wire.updatedAt, at, current, wire.requestId])
            }
        } else {
            try insert(db, wire)
            if wire.updatedAt == nil, let at {
                try db.execute(sql: "UPDATE requests SET updated_at = ? WHERE request_id = ?", arguments: [at, wire.requestId])
            }
        }
        if wire.hasFixed, held == nil || (held?["has_fixed"] as Bool?) == false {
            try db.execute(sql: """
                UPDATE requests SET source_message_id = ?, source_revision = ?, reply_mode = ?, requested_policy_id = ?
                WHERE request_id = ?
                """, arguments: [wire.sourceMessageId, wire.sourceRevision, wire.replyMode, wire.requestedPolicyId, wire.requestId])
        }
        if held == nil || wire.version > (held?["version"] as Int? ?? 0) || (held?["generation"] as String?) != current {
            try db.execute(sql: "UPDATE requests SET decision_basis = ?, decision_policy_id = ? WHERE request_id = ?",
                           arguments: [wire.decisionBasis, wire.decisionPolicyId, wire.requestId])
        }
        if let onThisDevice {
            let was = try Bool.fetchOne(db, sql: "SELECT on_this_device FROM requests WHERE request_id = ?", arguments: [wire.requestId])
            try db.execute(sql: "UPDATE requests SET on_this_device = ? WHERE request_id = ?", arguments: [onThisDevice, wire.requestId])
            // No longer this session's to execute: what it owed as executor is void.
            if was == true, !onThisDevice {
                try voidActions(db, request: wire.requestId, kinds: [.receive, .notifyDecision, .start], reason: "not_this_device")
            }
        }
        try rememberNames(db, request: wire.requestId)
        if let result = wire.result { try apply(db, result: result, requestId: wire.requestId) }
        try showOpen(db, wire.requestId)
    }

    /// Clear History hides a call only while it is over for that side: for
    /// its executor once final, for its caller once final with its result
    /// when finished (the adapter's rule). A call open again is shown again
    /// (review D8h-p2-6, D8i-p2-4).
    static func showOpen(_ db: Database, _ id: String) throws {
        try db.execute(sql: "UPDATE requests SET hidden_incoming = 0 WHERE request_id = ? AND hidden_incoming AND NOT (\(overSQL(incoming: true)))",
                       arguments: [id] + StatementArguments(finalStates))
        try db.execute(sql: "UPDATE requests SET hidden_outgoing = 0 WHERE request_id = ? AND hidden_outgoing AND NOT (\(overSQL(incoming: false)))",
                       arguments: [id] + StatementArguments(finalStates))
    }

    private static var finalStates: [String] { TeamRequestState.finals.map(\.rawValue).sorted() }

    /// SQL over `requests`: the call is over for that side (arguments: `finalStates`).
    static func overSQL(incoming: Bool) -> String {
        let final = "requests.state IN (\(finalStates.map { _ in "?" }.joined(separator: ", ")))"
        if incoming { return final }
        return final + " AND NOT (requests.state = 'finished' AND NOT EXISTS(SELECT 1 FROM results c WHERE c.request_id = requests.request_id AND c.run_id IS requests.run_id))"
    }

    /// The arguments `overSQL` needs.
    static var overArguments: StatementArguments { StatementArguments(finalStates) }

    private static func takeFixed(_ db: Database, _ wire: ChatRequestWire) throws {
        try db.execute(sql: """
            UPDATE requests SET has_fixed = 1, kind = ?, agent_id = ?, owner_account_id = ?, initiator_account_id = ?,
                executor_device_name = ?, text = ?, origin_session = ?, origin_project = ?, thread_id = ?,
                conditions_version = ?, deliver_by = ?, created_at = ?, channel_id = ?, thread_root_id = ?, context_refs = ?
            WHERE request_id = ?
            """, arguments: fixedArguments(wire) + [wire.requestId])
    }

    private static func insert(_ db: Database, _ wire: ChatRequestWire) throws {
        try db.execute(sql: """
            INSERT INTO requests (kind, agent_id, owner_account_id, initiator_account_id, executor_device_name, text,
                origin_session, origin_project, thread_id, conditions_version, deliver_by, created_at, channel_id, thread_root_id, context_refs,
                request_id, has_fixed, state, version, run_id, decline_reason, failure_reason, cause, publication, publish_reason,
                updated_at, generation)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: fixedArguments(wire) + [
                wire.requestId, wire.hasFixed, wire.state, wire.version, wire.runId, wire.declineReason, wire.failureReason, wire.cause,
                wire.publication, wire.publishReason, wire.updatedAt, try generation(db),
            ])
    }

    /// The server generation the cache follows now: one being taken up
    /// (`pending_generation`, written before its snapshot), else the settled one.
    private static func generation(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT coalesce(pending_generation, generation) FROM meta WHERE id = 1")
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func fixedArguments(_ wire: ChatRequestWire) -> StatementArguments {
        [wire.kind, wire.agentId, wire.ownerAccountId, wire.initiatorAccountId, wire.executorDeviceName, wire.text,
         wire.origin?.session, wire.origin?.project, wire.threadId, wire.conditionsVersion, wire.deliverBy, wire.createdAt,
         wire.channelId, wire.threadRootId, wire.context.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }]
    }

    /// Actions a request no longer owes: failed with `reason`, so the
    /// runner's conditional write of a handler that had them changes nothing.
    static func voidActions(_ db: Database, request: String, kinds: [ChatActionKind], reason: String) throws {
        let marks = kinds.map { _ in "?" }.joined(separator: ", ")
        try db.execute(sql: """
            UPDATE actions SET state = 'failed', error = ? WHERE request_id = ? AND kind IN (\(marks)) AND state IN ('pending', 'in_progress')
            """, arguments: [reason, request] + StatementArguments(kinds.map(\.rawValue)))
    }

    /// The agent's name and its owner's handle, from the catalog and the
    /// members, kept in the request the first time they are known.
    static func rememberNames(_ db: Database, request: String? = nil) throws {
        let only = request == nil ? "" : " AND request_id = ?"
        let arguments: StatementArguments = request.map { [$0] } ?? []
        try db.execute(sql: """
            UPDATE requests SET agent_name = (SELECT name FROM agents_catalog a WHERE a.agent_id = requests.agent_id)
            WHERE agent_name IS NULL\(only)
            """, arguments: arguments)
        try db.execute(sql: """
            UPDATE requests SET owner_handle = (SELECT handle FROM members m WHERE m.account_id = requests.owner_account_id)
            WHERE owner_handle IS NULL\(only)
            """, arguments: arguments)
    }

    /// A result is taken when none is held for its run.
    static func apply(_ db: Database, result: ChatCallResult, requestId: String) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO results (run_id, request_id, text, truncated, thread_id, delivered_at) VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [result.runId, requestId, result.text, result.truncated, result.threadId, result.deliveredAt])
    }

    /// The snapshot's catalog replaces the one held: each agent with the
    /// caller's teams among its audience.
    /// The snapshot's cards come before every event after its head (`seq` 0).
    static func replaceCatalog(_ db: Database, _ agents: [ChatAgentCard]) throws {
        try db.execute(sql: "DELETE FROM agent_teams")
        try db.execute(sql: "DELETE FROM agents_catalog")
        for card in agents {
            for team in card.teamIds ?? [] { try link(db, card, team: team, seq: 0) }
        }
    }

    /// A team stream no longer followed: the agents it brought, unless
    /// another followed team still brings them — then with that one's card.
    static func dropTeam(_ db: Database, _ team: String) throws {
        let agents = try String.fetchAll(db, sql: "SELECT agent_id FROM agent_teams WHERE team_id = ?", arguments: [team])
        try db.execute(sql: "DELETE FROM agent_teams WHERE team_id = ?", arguments: [team])
        for agent in agents { try refreshCard(db, agent) }
    }

    /// Each team stream's own word of a card, kept apart. Within a stream
    /// its order is the stream's (`seq`) — never the server's clock, which
    /// may go against it (review D8g-p2-7, p3-2). Across streams there is no
    /// order to know: the catalog shows the one applied last here; a stream
    /// that leaves takes its card along, and a snapshot settles the rest.
    private static func link(_ db: Database, _ card: ChatAgentCard, team: String, seq: Int) throws {
        var own = card
        own.teamIds = nil
        let text = String(decoding: try JSONEncoder().encode(own), as: UTF8.self)
        let applied = (try Int.fetchOne(db, sql: "SELECT coalesce(max(applied), 0) FROM agent_teams") ?? 0) + 1
        try db.execute(sql: """
            INSERT INTO agent_teams (agent_id, team_id, card, seq, applied) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(agent_id, team_id) DO UPDATE SET card = excluded.card, seq = excluded.seq, applied = excluded.applied
            WHERE agent_teams.seq <= excluded.seq
            """, arguments: [card.agentId, team, text, seq, applied])
        try refreshCard(db, card.agentId)
    }

    /// The catalog's card of `agent`: the latest any followed team stream
    /// told; none left, the agent leaves the catalog.
    private static func refreshCard(_ db: Database, _ agent: String) throws {
        guard let text = try String.fetchOne(db, sql: """
            SELECT card FROM agent_teams WHERE agent_id = ? AND card IS NOT NULL ORDER BY applied DESC LIMIT 1
            """, arguments: [agent]),
            let card = try? JSONDecoder().decode(ChatAgentCard.self, from: Data(text.utf8))
        else {
            try db.execute(sql: "DELETE FROM agents_catalog WHERE agent_id = ?", arguments: [agent])
            return
        }
        try upsert(db, card)
        try rememberNames(db)
    }

    private static func upsert(_ db: Database, _ card: ChatAgentCard) throws {
        try db.execute(sql: """
            INSERT INTO agents_catalog (agent_id, owner_account_id, name, description, access, enabled, executor_session_id,
                executor_device_name, available) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(agent_id) DO UPDATE SET owner_account_id = excluded.owner_account_id, name = excluded.name,
                description = excluded.description, access = excluded.access, enabled = excluded.enabled,
                executor_session_id = excluded.executor_session_id, executor_device_name = excluded.executor_device_name,
                available = excluded.available
            """, arguments: [card.agentId, card.ownerAccountId, card.name, card.description, card.access, card.enabled,
                             card.executorSessionId, card.executorDeviceName, card.available])
    }

    static func decode<T: Decodable>(_ type: T.Type, _ body: ChatJSON) -> T? {
        guard let data = try? JSONEncoder().encode(body) else { return nil }
        do { return try JSONDecoder().decode(type, from: data) } catch {
            NSLog("agentpad: a chat event body did not read as \(type): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: History

    /// History shows every open request and the final ones of the last 30
    /// days, at most 300 of them (as in 1.0.6), aged by their last move or
    /// their result's delivery, whichever is later. Rows stay within a
    /// generation — their versions and actions guard against old words
    /// (owner's decision after review D8e); a final request no longer shown
    /// keeps no heavy text: its results' texts and the local full text and
    /// log go (`trim`). One shown again (a late result) shows what is left.
    static let keepFinished: TimeInterval = 30 * 24 * 60 * 60
    static let maxHistory = 300

    /// The ids history shows, newest first among the final ones.
    static func shownIds(_ db: Database, now: Date) throws -> [String] {
        let (shown, _) = try split(db, now: now)
        return shown
    }

    /// (shown, not shown) among the requests. Ages are compared as times,
    /// not as text: the server's times vary in their fraction's length
    /// (review D8h-p3-6).
    private static func split(_ db: Database, now: Date) throws -> (shown: [String], hidden: [String]) {
        let cutoff = now.addingTimeInterval(-keepFinished)
        let finals = TeamRequestState.finals.map(\.rawValue)
        let marks = finals.map { _ in "?" }.joined(separator: ", ")
        let open = try String.fetchAll(db, sql: "SELECT request_id FROM requests WHERE state NOT IN (\(marks))",
                                       arguments: StatementArguments(finals))
        let rows = try Row.fetchAll(db, sql: """
            SELECT r.request_id, r.updated_at, r.created_at, s.delivered_at,
                r.state = 'finished' AND NOT EXISTS(SELECT 1 FROM results c WHERE c.request_id = r.request_id AND c.run_id IS r.run_id) AS awaiting
            FROM requests r LEFT JOIN results s ON s.request_id = r.request_id
            WHERE r.state IN (\(marks))
            """, arguments: StatementArguments(finals))
        // Each request's age: its last move (else its making) or a result's
        // delivery, whichever is later.
        var ages: [String: (age: Date, awaiting: Bool)] = [:]
        for row in rows {
            let id: String = row["request_id"]
            let moved = ((row["updated_at"] as String?) ?? row["created_at"]).flatMap(ChatStore.date)
            let delivered = (row["delivered_at"] as String?).flatMap(ChatStore.date)
            let age = [moved, delivered, ages[id]?.age].compactMap { $0 }.max() ?? .distantPast
            ages[id] = (age, row["awaiting"])
        }
        let ordered = ages.sorted { $0.value.age != $1.value.age ? $0.value.age > $1.value.age : $0.key < $1.key }
        var shown = open, hidden: [String] = []
        var counted = 0
        for (id, entry) in ordered {
            // Finished, its result still on its way (30 days at most): an
            // open call for its initiator, not history (review D8f-p3-3).
            if entry.awaiting, entry.age >= cutoff {
                shown.append(id)
                continue
            }
            if counted < maxHistory, entry.age >= cutoff { shown.append(id) } else { hidden.append(id) }
            counted += 1
        }
        return (shown, hidden)
    }

    /// Final requests no longer shown lose their heavy texts. A request
    /// with an action not done keeps them (the action may need them).
    func trim(now: Date = Date()) throws {
        try queue.write { db in
            for id in try Self.split(db, now: now).hidden {
                let acting = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM actions WHERE request_id = ? AND state IN ('pending', 'in_progress'))
                    """, arguments: [id]) ?? false
                guard !acting else { continue }
                try db.execute(sql: "UPDATE results SET text = '', trimmed = 1 WHERE request_id = ? AND trimmed = 0", arguments: [id])
                try db.execute(sql: "UPDATE requests SET local_text = NULL, local_log = NULL WHERE request_id = ? AND (local_text IS NOT NULL OR local_log IS NOT NULL)",
                               arguments: [id])
            }
        }
    }
}

/// The result's text as delivered (6.10): the whole command body, with the
/// text JSON-encoded inside it, at most 128 KiB — measured on the bytes the
/// queue really sends; cut texts are marked. The full text stays local.
enum ChatResultText {
    static let maxBody = 128 * 1024

    /// The `result.deliver` args that fit, and whether the text was cut.
    static func deliverArgs(org: String, requestId: String, runId: String, text: String, threadId: String?) throws
        -> (args: ChatJSON, truncated: Bool) {
        func args(_ text: String, _ truncated: Bool) -> ChatJSON {
            .object(["request_id": .string(requestId), "run_id": .string(runId), "text": .string(text),
                     "truncated": .bool(truncated), "thread_id": threadId.map { .string($0) } ?? .null])
        }
        func size(_ text: String, _ truncated: Bool) throws -> Int {
            // A command id of the size the queue gives (a UUID).
            try ChatCommandEnvelope(commandId: UUID().uuidString.lowercased(), org: org, type: "result.deliver", args: args(text, truncated))
                .encoded().count
        }
        if try size(text, false) <= maxBody { return (args(text, false), false) }
        // The longest prefix, in whole characters, whose body fits.
        let characters = Array(text)
        var low = 0, high = characters.count
        while low < high {
            let mid = (low + high + 1) / 2
            if try size(String(characters[..<mid]), true) <= maxBody { low = mid } else { high = mid - 1 }
        }
        return (args(String(characters[..<low]), true), true)
    }
}
