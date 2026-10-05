import Foundation
import GRDB

/// The organization a call belongs to, as `TeamCalls` keeps it (6.11).
struct TeamCallScope: Codable, Equatable, Sendable {
    var server: String
    var accountId: String
    var orgId: String

    init(_ key: ChatOrgKey) {
        server = key.server.description
        accountId = key.accountId
        orgId = key.orgId
    }
}

/// `TeamCalls`' store in server mode (D8): its calls are the requests of
/// the organization's cache, one representation of each. Calls to my
/// agents are `incoming`, calls I made are `outgoing` (a call to my own
/// agent is both). The server's part is only ever written by the server's
/// events and snapshots; `saveLog` keeps what is this Mac's alone.
struct ChatTeamCallStore: TeamCallStore {
    let calls: ChatCallStore
    let key: ChatOrgKey
    var forExecution = false

    static func personal(_ alias: String = "") -> String { "\(alias.isEmpty ? "" : alias + ".")kind IS NOT 'channel'" }

    /// What history shows: open calls, and final ones within its bounds.
    func loadLog() throws -> TeamCalls.Log {
        try log { db in try ChatCallStore.shownIds(db, now: Date()) }
    }

    /// One call by its id, wherever it is in history: what `check` and the
    /// other actions by id read (review D8f-p2-7).
    func loadCall(_ id: String) throws -> TeamCalls.Log {
        try log { db in try String.fetchAll(db, sql: "SELECT request_id FROM requests WHERE request_id = ?", arguments: [id]) }
    }

    private func log(_ ids: @escaping (Database) throws -> [String]) throws -> TeamCalls.Log {
        let me = key.accountId
        let (requests, members, agents) = try calls.queue.read { db in
            let wanted = try ids(db)
            let shown: [String]
            if forExecution || wanted.isEmpty { shown = wanted }
            else {
                let marks = wanted.map { _ in "?" }.joined(separator: ",")
                shown = try String.fetchAll(db, sql: "SELECT request_id FROM requests WHERE \(Self.personal()) AND request_id IN (\(marks))",
                                            arguments: StatementArguments(wanted))
            }
            return (
                try shown.compactMap { try ChatCallStore.request(db, $0) }
                    // Its fixed part known (also one being read anew after a restore), or asked here.
                    .filter { $0.agentId != nil || $0.askedHere }
                    .sorted { ($0.createdAt ?? "", $0.requestId) < ($1.createdAt ?? "", $1.requestId) },
                Dictionary(try Row.fetchAll(db, sql: "SELECT account_id, name, handle FROM members").map {
                    ($0["account_id"] as String, (name: $0["name"] as String, handle: $0["handle"] as String))
                }, uniquingKeysWith: { a, _ in a }),
                Dictionary(try Row.fetchAll(db, sql: "SELECT agent_id, name FROM agents_catalog").map { ($0["agent_id"] as String, $0["name"] as String) },
                           uniquingKeysWith: { a, _ in a })
            )
        }
        let scope = TeamCallScope(key)
        // Never a plausible stand-in: what is not known says so, with its id (review D8d-p3-6).
        func agentName(_ r: ChatRequest) -> String {
            r.agentName ?? r.agentId.flatMap { agents[$0] } ?? "(unknown agent \(r.agentId.map { String($0.prefix(8)) } ?? "?"))"
        }
        func memberName(_ account: String?) -> String {
            account.flatMap { members[$0]?.name } ?? "(unknown member \(account.map { String($0.prefix(8)) } ?? "?"))"
        }
        var incoming: [TeamCalls.Incoming] = []
        var outgoing: [TeamCalls.Outgoing] = []
        for r in requests {
            let created = r.createdAt.flatMap(ChatStore.date) ?? Date()
            let deliverBy = r.deliverBy.flatMap(ChatStore.date) ?? created.addingTimeInterval(7 * 24 * 60 * 60)
            let finishedAt = Self.state(r, incoming: false).isFinal ? (r.updatedAt.flatMap(ChatStore.date) ?? created) : nil
            // Its fixed part known — also one read anew after a restore (`resyncing`).
            if r.ownerAccountId == me, let agentId = r.agentId.flatMap(UUID.init(uuidString:)) {
                var call = TeamCalls.Incoming(
                    id: r.requestId, peer: r.initiatorAccountId ?? "", peerName: memberName(r.initiatorAccountId),
                    agentId: agentId, agentName: agentName(r), prompt: r.text ?? "", threadId: r.threadId ?? r.requestId,
                    resume: false, origin: r.origin, receivedAt: created, decideBy: deliverBy
                )
                call.state = Self.state(r, incoming: true)
                call.serverState = r.state.rawValue
                let text = r.localText ?? r.result?.shownText
                call.answer = text.map { TeamRunResult(text: $0, isError: false) }
                call.truncated = r.localText == nil && (r.result?.truncated == true || r.result?.trimmed == true)
                call.detail = Self.detail(r)
                call.finishedAt = call.state.isFinal ? finishedAt : nil
                call.hidden = r.hiddenIncoming ? true : nil
                call.scope = scope
                call.version = r.version
                call.runId = r.runId
                call.executorDeviceName = r.executorDeviceName
                call.onThisDevice = r.onThisDevice
                incoming.append(call)
            }
            if r.initiatorAccountId == me {
                let state = Self.state(r, incoming: false)
                var call = TeamCalls.Outgoing(
                    id: r.requestId, peer: r.ownerAccountId ?? "", colleague: memberName(r.ownerAccountId),
                    agent: agentName(r), prompt: r.text ?? "", createdAt: created, deliverBy: deliverBy,
                    report: TeamCallReport(
                        // The thread to go on with, once answered (D5b §3.2): the result's.
                        callId: r.requestId, state: state, threadId: state == .done ? (r.result?.threadId ?? r.threadId ?? r.requestId) : nil,
                        text: r.result?.shownText, truncated: r.result.map { $0.truncated || $0.trimmed == true }, detail: Self.detail(r)
                    ),
                    note: nil, finishedAt: finishedAt, hidden: r.hiddenOutgoing ? true : nil, thread: r.threadId, origin: r.origin
                )
                call.delivered = r.state != .creating
                call.scope = scope
                call.version = r.version
                call.runId = r.runId
                call.executorDeviceName = r.executorDeviceName
                // The handle the address was resolved by, not one made from the name.
                call.handle = r.ownerHandle ?? r.ownerAccountId.flatMap { members[$0]?.handle } ?? "(unknown)"
                call.serverState = r.state.rawValue
                call.answered = r.answered
                call.answerTrimmed = r.answered && r.result?.trimmed == true ? true : nil
                outgoing.append(call)
            }
        }
        return TeamCalls.Log(incoming: incoming, outgoing: outgoing)
    }

    /// Only what is this Mac's: whether a call was cleared from the Team
    /// tab — each side of a call on its own. Only a call over for that side
    /// in the cache now is hidden, whatever the view held when it was
    /// cleared (review D8h-p2-6, p3-3, D8i-p2-4).
    func saveLog(_ log: TeamCalls.Log) throws {
        try calls.queue.write { db in
            let sides = [("hidden_incoming", log.incoming.map { ($0.id, $0.hidden == true) }),
                         ("hidden_outgoing", log.outgoing.map { ($0.id, $0.hidden == true) })]
            for (column, calls) in sides {
                let over = ChatCallStore.overSQL(incoming: column == "hidden_incoming")
                for (id, hidden) in calls {
                    try db.execute(sql: "UPDATE requests SET \(column) = ? WHERE request_id = ? AND (? = 0 OR (\(over)))",
                                   arguments: [hidden, id, hidden] + ChatCallStore.overArguments)
                }
            }
        }
    }

    func loadThreads() throws -> [TeamCalls.Thread] {
        try calls.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM threads WHERE NOT EXISTS (
                    SELECT 1 FROM requests r WHERE (r.request_id = threads.thread_id OR r.thread_root_id = threads.thread_id)
                        AND NOT (\(Self.personal("r")))) ORDER BY created_at
                """).compactMap { row in
                guard let agent = UUID(uuidString: row["agent_id"]) else { return nil }
                return TeamCalls.Thread(id: row["thread_id"], peer: row["peer"], agentId: agent, createdAt: row["created_at"])
            }
        }
    }

    func saveThreads(_ threads: [TeamCalls.Thread]) throws {
        try calls.queue.write { db in
            try db.execute(sql: "DELETE FROM threads")
            for t in threads {
                try db.execute(sql: "INSERT INTO threads (thread_id, peer, agent_id, created_at) VALUES (?, ?, ?, ?)",
                               arguments: [t.id, t.peer, t.agentId.uuidString.lowercased(), t.createdAt])
            }
        }
    }

    /// The state the Team tab, the CLI and MCP know (1.0.x), from the
    /// server's. A finished call is done for its caller only with its
    /// result: until then it still runs (decision 21).
    static func state(_ r: ChatRequest, incoming: Bool) -> TeamCallState {
        switch r.state {
        // Not yet received (D4's checks come first): no decision is asked
        // for yet (review D8e-p3-12).
        case .creating, .submitted: .queued
        case .awaitingDecision: .awaitingApproval
        case .approved: .queued
        case .starting, .running, .stopRequested: .running
        case .finished: incoming || r.answered ? .done : .running
        case .declined: .denied
        case .failed, .failedToStart, .stopFailed: .failed
        case .cancelled, .stopped: .cancelled
        case .expired: .expired
        case .lost: .failed
        case .resyncing: .unknown
        // Said so, not taken for anything (server `docs/api.md`).
        default: .unknown
        }
    }

    private static func detail(_ r: ChatRequest) -> String? {
        if r.state == .lost { return "The server no longer lists this call (restored from a backup, or ended long ago); its outcome is not known here." }
        if r.state == .resyncing { return "The server was restored from a backup; this call's state is being read from it again." }
        // Made here, on its way to the server (D5).
        if r.state == .creating { return "Not on the server yet: it goes as soon as this Mac can send it." }
        // Never taken by the server: the queue's word (D5; texts of codes — D5b).
        if r.state == .failed, r.version == 0 {
            if r.failureReason == ChatCallStore.sessionEnded { return "Not sent: the session it was asked in ended." }
            if let text = r.failureReason.flatMap({ Self.createRefusals[$0] }) { return "Not sent: \(text)" }
            return "Not sent: the server refused it (\(r.failureReason ?? "refused"))."
        }
        // Why the server stopped or declined it, told with what came of it
        // (api.md: the cause's sentence with the state's, not instead).
        let cause = r.cause.map { Self.causes[$0] ?? "(cause: \(String($0.prefix(40))))" }
        func with(_ text: String?) -> String? {
            guard let cause else { return text }
            return text.map { "\(cause) \($0)" } ?? cause
        }
        if let reason = r.declineReason { return with("Declined: \(reason)") }
        // Each state's own words, with the server's reason (review D8f-p3-5).
        let why = r.failureReason.map { " (\($0))" } ?? ""
        switch r.state {
        case .stopFailed: return with("The run was asked to stop, but its processes could not be stopped\(why).")
        case .failedToStart: return with("The agent could not be started\(why).")
        // Failed for a cause (the owner left the organization): the cause says it.
        case .failed where r.cause != nil && r.failureReason == r.cause: return with(nil)
        case .failed: return with("The agent's run ended with an error\(why).")
        default: break
        }
        guard let meaning = r.state.meaning else {
            return "The server reports a state this AgentPad does not know (“\(String(r.state.rawValue.prefix(40)))”); update AgentPad."
        }
        // Finished though asked to stop for a cause: its own outcome first,
        // the cause after it as why it was asked (review D5-p2-3).
        if r.state == .finished, let cause { return "\(meaning) \(cause)" }
        // Under way: what the state means, for the CLI's and MCP's progress (D10);
        // finished without its result yet says the result follows.
        if [.submitted, .awaitingDecision, .approved, .starting, .running].contains(r.state) || (r.state == .finished && !r.answered) {
            return meaning
        }
        // What happened, for the states that end a call or are on their way.
        return with([.cancelled, .expired, .stopped, .stopFailed, .stopRequested, .declined].contains(r.state) ? meaning : nil)
    }

    /// The server's refusals of `request.create`, said (D5b §3.3).
    static let createRefusals: [String: String] = [
        "not_found": "the agent is not available or does not exist.",
        "agent_unavailable": "the agent is turned off, or its owner's Mac is not signed in.",
        "rate_limited": "too many calls are waiting; try again later.",
    ]

    /// What each `cause` means, as api.md says it may be told.
    static let causes: [String: String] = [
        "result_lost": "The result was lost after the server was restored. The agent was not run again.",
        "agent_disabled": "The agent was disabled or taken down by its owner or an admin.",
        "audience_narrowed": "The agent's owner no longer shares the agent with your teams.",
        "owner_left_team": "The agent's owner left the team you share, so the agent is no longer available to you.",
        "owner_removed": "The agent's owner is no longer in the organization.",
        "initiator_removed": "The person who asked is no longer in the organization.",
        "executor_signed_out": "The Mac that runs the agent signed out of the server.",
    ]
}

extension ChatCallStore {
    /// Colleagues' agents of the organization's catalog (D3, answer (а)):
    /// Only agents_catalog is read; agent_channels never enters this D catalog.
    /// by `name@handle`, as `team agents` and the Team window list them;
    /// one that cannot be read lists none.
    func colleaguesCatalog(me: String) -> [TeamCalls.CatalogItem] {
        let rows = (try? queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.*, m.handle, m.name AS owner_name FROM agents_catalog a JOIN members m ON m.account_id = a.owner_account_id
                WHERE a.owner_account_id != ? ORDER BY a.name, m.handle
                """, arguments: [me])
        }) ?? []
        return rows.compactMap { row in
            guard let access = TeamAccessProfile(rawValue: row["access"]) else { return nil }
            let name: String = row["name"], handle: String = row["handle"]
            let entry = TeamCatalogEntry(name: name, description: row["description"], access: access, remotes: [])
            let available: Bool = row["available"], enabled: Bool = row["enabled"]
            return TeamCalls.CatalogItem(address: "\(name)@\(handle)", colleague: row["owner_name"], colleagueId: row["owner_account_id"],
                                         online: available && enabled, entry: entry, sameProject: false)
        }
    }
}
