import Foundation
import GRDB

/// The run journal, `chat/journal.sqlite` (docs/agentpad/CHAT-PLAN.md 6.11,
/// C4): what this Mac promised as an executor — the executor's commands
/// and results not yet delivered here; assignments, approvals and runs come
/// with D9. Neither a resync, a deleted cache nor Disconnect removes it.
final class ChatJournal: Sendable {
    let url: URL
    let queue: DatabaseQueue

    private init(url: URL, queue: DatabaseQueue) {
        self.url = url
        self.queue = queue
    }

    /// A damaged journal throws `corrupt`: server runs on this Mac stop until
    /// the user resets it (`reset`), everything else goes on.
    static func open(files: ChatFiles) throws -> ChatJournal {
        try files.prepareDirectory()
        return ChatJournal(url: files.journalURL, queue: try ChatDatabase.open(files.journalURL, migrator: ChatStoreMigrations.journal))
    }

    /// "Reset Run Journal" in the Team window: the damaged file is set aside
    /// and an empty one made.
    static func reset(files: ChatFiles) throws -> ChatJournal {
        if FileManager.default.fileExists(atPath: files.journalURL.path) { try ChatDatabase.setAside(files.journalURL) }
        return try open(files: files)
    }

    /// The executor's send queue of one organization.
    func runCommands(_ key: ChatOrgKey) -> ChatCommandTable {
        ChatCommandTable(queue: queue, table: "run_commands", scope: key)
    }

    @discardableResult
    func enqueue(_ command: ChatCommandRecord, key: ChatOrgKey, resultText: String? = nil) throws -> ChatCommandRecord {
        try runCommands(key).enqueue(command, resultText: resultText)
    }

    func commands(for key: ChatOrgKey) throws -> [ChatCommandRecord] {
        try runCommands(key).commands()
    }

    func resultText(of commandId: String) throws -> String? {
        try queue.read { db in try String.fetchOne(db, sql: "SELECT result_text FROM run_commands WHERE command_id = ?", arguments: [commandId]) }
    }
}

// MARK: Assignments, approvals, runs (6.8, D9, D11)

/// An agent the owner published to an organization from this Mac. Made only
/// by the publish button (D3); no server event makes or changes it.
struct ChatAssignment: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    enum State: String, Codable, Sendable { case pending, active, removing }

    static let databaseTableName = "assignments"
    var server: String
    var accountId: String
    var orgId: String
    var agentId: String
    var state: State
    var name: String
    var description: String
    var access: String
    /// JSON array of team ids.
    var teamIds: String
    var createdAt: Date
    /// The session the server took the last `agent.publish` from (D3).
    var publishedSession: String? = nil
    /// A publication asked and not settled yet (`ChatPublishRequest` JSON), and when.
    var requested: String? = nil
    var requestedAt: Date? = nil
    /// The server's last refusal, until the owner publishes again.
    var lastError: String? = nil
    /// `{team_id: seq}` of the last publication the server took, from its
    /// answer; nil when not known (D3b).
    var teamSeqs: String? = nil

    enum CodingKeys: String, CodingKey {
        case server, state, name, description, access, requested
        case teamSeqs = "team_seqs"
        case accountId = "account_id", orgId = "org_id", agentId = "agent_id", teamIds = "team_ids", createdAt = "created_at"
        case publishedSession = "published_session", requestedAt = "requested_at", lastError = "last_error"
    }
}

/// The owner's Allow, with everything the run will get (6.8). Never changed
/// after it is made, except to spend it or void it.
struct ChatApproval: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "approvals"
    var id: String
    var server: String
    var accountId: String
    var orgId: String
    var requestId: String
    var agentId: String
    var kind: String
    /// `TeamLaunchParams` as canonical JSON.
    var params: String
    var paramsHash: String
    var runId: String
    var startCommandId: String
    var generation: String
    var createdAt: Date
    var consumedAt: Date?
    var voidAt: Date?
    var voidReason: String?

    enum CodingKeys: String, CodingKey {
        case id, server, kind, params, generation
        case accountId = "account_id", orgId = "org_id", requestId = "request_id", agentId = "agent_id"
        case paramsHash = "params_hash", runId = "run_id", startCommandId = "start_command_id", createdAt = "created_at"
        case consumedAt = "consumed_at", voidAt = "void_at", voidReason = "void_reason"
    }

    var key: ChatOrgKey? {
        (try? ChatServerAddress(parsing: server)).map { ChatOrgKey(server: $0, accountId: accountId, orgId: orgId) }
    }
}

/// One run of an approval: written before the process exists, its PID right
/// after, its outcome at the end (6.8, D11).
struct ChatRunRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    enum Outcome: String, Codable, Sendable {
        case finished, failed
        case didNotStart = "did_not_start"
        case stoppedLocally = "stopped_locally"
        case executorRestarted = "executor_restarted"
    }

    static let databaseTableName = "runs"
    var runId: String
    var requestId: String
    var approvalId: String
    var agentId: String
    var conversationId: String
    var pid: Int32?
    var pgid: Int32?
    var processStartedAt: UInt64?
    var startedAt: Date
    var endedAt: Date?
    var outcome: Outcome?
    /// An allowlisted runner code, never stderr or a localized message.
    var launchFailure: ClaudeLaunchDiagnostic.Failure? = nil
    /// Being stopped for this reason when the app had to quit.
    var stopReason: String?
    /// When its processes were confirmed gone — by this app's own stop, or by
    /// the owner after a crash: from then on only its outcome and fact are
    /// owed, and its numbers are not looked at again (review C6-6, C7).
    var processesGoneAt: Date?
    /// Only Y5's automatic `.stopped`: both the processes and output are
    /// gone. The owner's "They Are Gone" never changes this verdict.
    var stopConfirmedAt: Date? = nil
    /// The full result of a run that finished, written with its outcome (D4).
    var resultText: String? = nil
    /// Y2 service process: never evidence that the executor ran.
    var preflightPID: Int32? = nil
    var preflightPGID: Int32? = nil
    var preflightStartedAt: UInt64? = nil
    var kind: String? = nil
    var org: String? = nil
    var channelId: String? = nil
    var threadRootId: String? = nil
    var resultErased = false
    /// Confirmed loss of this run's channel, distinct from request cancellation.
    var channelRevoked = false

    enum CodingKeys: String, CodingKey {
        case pid, pgid, outcome, kind, org
        case launchFailure = "launch_failure"
        case channelId = "channel_id", threadRootId = "thread_root_id", resultErased = "result_erased"
        case channelRevoked = "channel_revoked"
        case runId = "run_id", requestId = "request_id", approvalId = "approval_id", agentId = "agent_id"
        case conversationId = "conversation_id", processStartedAt = "process_started_at", startedAt = "started_at", endedAt = "ended_at"
        case stopReason = "stop_reason", processesGoneAt = "processes_gone_at", resultText = "result_text"
        case stopConfirmedAt = "stop_confirmed_at"
        case preflightPID = "preflight_pid", preflightPGID = "preflight_pgid", preflightStartedAt = "preflight_started_at"
    }
}

extension ChatJournal {
    func assignment(_ key: ChatOrgKey, agentId: String) throws -> ChatAssignment? {
        try queue.read { db in
            try ChatAssignment.fetchOne(db, sql: "SELECT * FROM assignments WHERE server = ? AND account_id = ? AND org_id = ? AND agent_id = ?",
                                        arguments: [key.server.description, key.accountId, key.orgId, agentId])
        }
    }

    /// The requests of this organization's runs without an outcome.
    func runningRequests(_ key: ChatOrgKey) throws -> Set<String> {
        try queue.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT r.request_id FROM runs r JOIN approvals a ON a.id = r.approval_id
                WHERE a.server = ? AND a.account_id = ? AND a.org_id = ? AND r.outcome IS NULL
                """, arguments: [key.server.description, key.accountId, key.orgId]))
        }
    }

    func save(_ assignment: ChatAssignment) throws {
        try queue.write { db in try assignment.save(db) }
    }

    func approval(_ id: String) throws -> ChatApproval? {
        try queue.read { db in try ChatApproval.fetchOne(db, key: id) }
    }

    /// The approval of a request of this organization (server, account, organization) (review C6-9).
    func approval(_ key: ChatOrgKey, requestId: String, kind: String = "initial") throws -> ChatApproval? {
        try queue.read { db in
            try ChatApproval.fetchOne(db, sql: """
                SELECT * FROM approvals WHERE server = ? AND account_id = ? AND org_id = ? AND request_id = ? AND kind = ?
                """, arguments: [key.server.description, key.accountId, key.orgId, requestId, kind])
        }
    }

    func approvals() throws -> [ChatApproval] {
        try queue.read { db in try ChatApproval.order(Column("created_at")).fetchAll(db) }
    }

    func insert(_ approval: ChatApproval) throws {
        try queue.write { db in try approval.insert(db) }
    }

    /// Voids an approval not yet spent; false when it was spent or void already.
    @discardableResult
    func void(_ id: String, reason: String, at: Date = Date()) throws -> Bool {
        try queue.write { db in
            try db.execute(sql: "UPDATE approvals SET void_at = ?, void_reason = ? WHERE id = ? AND consumed_at IS NULL AND void_at IS NULL",
                           arguments: [at, reason, id])
            return db.changesCount == 1
        }
    }

    /// The continuation of a run not spent, if the owner granted one (D4b
    /// §2.5): of the same organization's request and run — a request id is
    /// not a key across servers (review D5b-1).
    func pendingContinuation(of initial: ChatApproval) throws -> ChatApproval? {
        try latestContinuation(of: initial).flatMap { $0.consumedAt == nil && $0.voidAt == nil ? $0 : nil }
    }

    /// The run's latest continuation record — spent, void or waiting: a void
    /// one not spent is a continuation promised and refused (review D4b2-4).
    func latestContinuation(of initial: ChatApproval) throws -> ChatApproval? {
        try queue.read { db in
            try ChatApproval.fetchOne(db, sql: """
                SELECT * FROM approvals WHERE server = ? AND account_id = ? AND org_id = ? AND request_id = ? AND agent_id = ?
                    AND kind LIKE 'continuation-%'
                ORDER BY created_at DESC LIMIT 1
                """, arguments: [initial.server, initial.accountId, initial.orgId, initial.requestId, initial.agentId])
        }
    }

    /// A segment of the run went on under a continuation: a process of it
    /// existed, whatever its row says now (review D4b2-3).
    func continued(_ initial: ChatApproval) throws -> Bool {
        try queue.read { db in
            try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM approvals WHERE server = ? AND account_id = ? AND org_id = ? AND request_id = ? AND agent_id = ?
                    AND kind LIKE 'continuation-%' AND consumed_at IS NOT NULL)
                """, arguments: [initial.server, initial.accountId, initial.orgId, initial.requestId, initial.agentId]) ?? false
        }
    }

    /// Spends a continuation and opens its run's row for a new process, in
    /// one transaction: the run goes on under the same id (D4b §2.5).
    func consumeContinuation(_ approval: ChatApproval, runId: String, at: Date = Date()) throws -> Bool {
        try queue.write { db in
            try db.execute(sql: "UPDATE approvals SET consumed_at = ? WHERE id = ? AND consumed_at IS NULL AND void_at IS NULL",
                           arguments: [at, approval.id])
            guard db.changesCount == 1 else { return false }
            try db.execute(sql: "UPDATE runs SET pid = NULL, pgid = NULL, process_started_at = NULL WHERE run_id = ? AND outcome IS NULL",
                           arguments: [runId])
            guard db.changesCount == 1 else { throw ChatError.storage("the run \(runId) is not open") }
            return true
        }
    }

    /// Another session of the account: every approval (initial or
    /// continuation) of the account on this server not spent is voided.
    /// Atomic with spending one (`consume`, `consumeContinuation`).
    @discardableResult
    func voidUnspent(server: String, accountId: String, reason: String, at: Date = Date()) throws -> Int {
        try queue.write { db in
            try db.execute(sql: """
                UPDATE approvals SET void_at = ?, void_reason = ? WHERE server = ? AND account_id = ? AND consumed_at IS NULL AND void_at IS NULL
                """, arguments: [at, reason, server, accountId])
            return db.changesCount
        }
    }

    /// Spends the approval and writes its run row in one transaction, before
    /// any process exists. False when it was spent or void already.
    func consume(_ approval: ChatApproval, run: ChatRunRecord, at: Date = Date()) throws -> Bool {
        try queue.write { db in
            try db.execute(sql: "UPDATE approvals SET consumed_at = ? WHERE id = ? AND consumed_at IS NULL AND void_at IS NULL",
                           arguments: [at, approval.id])
            guard db.changesCount == 1 else { return false }
            var scoped = run
            let params = try TeamLaunchParams.decode(approval.params)
            scoped.kind = params.channelId == nil ? "personal" : "channel"
            scoped.org = approval.orgId
            scoped.channelId = params.channelId
            scoped.threadRootId = params.threadRootId
            try scoped.insert(db)
            return true
        }
    }

    func run(_ runId: String) throws -> ChatRunRecord? {
        try queue.read { db in try ChatRunRecord.fetchOne(db, key: runId) }
    }

    func runs() throws -> [ChatRunRecord] {
        try queue.read { db in try ChatRunRecord.order(Column("started_at")).fetchAll(db) }
    }

    func unfinishedRuns() throws -> [ChatRunRecord] {
        try queue.read { db in try ChatRunRecord.filter(Column("outcome") == nil).order(Column("started_at")).fetchAll(db) }
    }

    func recordProcess(_ runId: String, _ start: TeamProcessStart) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE runs SET pid = ?, pgid = ?, process_started_at = ? WHERE run_id = ?",
                           arguments: [start.pid, start.pgid, Int64(bitPattern: start.startTime), runId])
        }
    }

    func recordPreflightProcess(_ runId: String, _ start: TeamProcessStart?) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE runs SET preflight_pid = ?, preflight_pgid = ?, preflight_started_at = ? WHERE run_id = ?",
                           arguments: [start?.pid, start?.pgid, start.map { Int64(bitPattern: $0.startTime) }, runId])
        }
    }

    /// Writes the outcome once — and, in the same transaction, the fact owed
    /// to the server for it, so neither exists without the other (review C2-18).
    /// `result`: the full text of a run that finished; `facts`: the commands
    /// owed for it, inserted in the same transaction (D4: the chain of facts).
    @discardableResult
    func finish(_ runId: String, _ outcome: ChatRunRecord.Outcome, at: Date = Date(), result: String? = nil,
                diagnosis: ClaudeLaunchDiagnostic.Failure? = nil,
                facts: ((Database) throws -> Void)? = nil) throws -> Bool {
        try queue.write { db in
            // A run of an approval set aside (another call under its id):
            // nothing of it is kept to tell or deliver — read in this
            // transaction, closed by default (review D45-final-1).
            let own = try String.fetchOne(db, sql: "SELECT a.kind FROM runs r JOIN approvals a ON a.id = r.approval_id WHERE r.run_id = ?",
                                          arguments: [runId]) == "initial"
            // A confirmed channel revocation is permanent for this run, even
            // when the process ends later during Disconnect or a snapshot.
            try db.execute(sql: "UPDATE runs SET outcome = ?, ended_at = ?, launch_failure = ?, result_text = CASE WHEN result_erased = 1 THEN NULL ELSE ? END WHERE run_id = ? AND outcome IS NULL",
                           arguments: [outcome.rawValue, at, diagnosis?.rawValue, own ? result : nil, runId])
            guard db.changesCount == 1 else { return false }
            if own { try facts?(db) }
            return true
        }
    }

    /// The run's processes are confirmed gone (review C6-6).
    func markProcessesGone(_ runId: String, at: Date = Date()) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE runs SET processes_gone_at = ? WHERE run_id = ? AND outcome IS NULL AND processes_gone_at IS NULL",
                           arguments: [at, runId])
        }
    }

    /// Marks a run as being stopped for `reason` (quit, where nothing can wait).
    func markStopping(_ runId: String, reason: String, confirmed: Bool = false, at: Date = Date()) throws {
        try queue.write { db in
            try db.execute(sql: "UPDATE runs SET stop_reason = ? WHERE run_id = ? AND outcome IS NULL", arguments: [reason, runId])
            if confirmed {
                try db.execute(sql: """
                    UPDATE runs SET stop_confirmed_at = coalesce(stop_confirmed_at, ?), processes_gone_at = coalesce(processes_gone_at, ?)
                    WHERE run_id = ? AND outcome IS NULL
                    """, arguments: [at, at, runId])
            }
        }
    }

    /// The latest `run.started` of `runId` that did not fail or go (review C3-12).
    func startedFact(_ runId: String) throws -> ChatCommandRecord? {
        let rows = try queue.read { db in
            try ChatCommandRecord.fetchAll(db, sql: """
                SELECT * FROM run_commands WHERE type = 'run.started' AND state NOT IN ('failed', 'dropped') ORDER BY seq DESC
                """)
        }
        return rows.first { (try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0.bodyBytes))?.args["run_id"]?.string == runId }
    }
}

// MARK: Server generation (review C3-4)

/// Where an organization's server generation and a change of it under way
/// are kept: the run journal (with the commands it protects), else the cache.
protocol ChatGenerationState: AnyObject {
    func generation(_ key: ChatOrgKey) throws -> (generation: String?, pending: String?)
    func setPending(_ key: ChatOrgKey, _ generation: String) throws
    func finish(_ key: ChatOrgKey, _ generation: String) throws
}

extension ChatJournal: ChatGenerationState {
    func generation(_ key: ChatOrgKey) throws -> (generation: String?, pending: String?) {
        try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT generation, pending_generation FROM org_generations WHERE server = ? AND account_id = ? AND org_id = ?",
                                       arguments: [key.server.description, key.accountId, key.orgId])
            return (row?["generation"], row?["pending_generation"])
        }
    }

    func setPending(_ key: ChatOrgKey, _ generation: String) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO org_generations (server, account_id, org_id, generation, pending_generation) VALUES (?, ?, ?, NULL, ?)
                ON CONFLICT(server, account_id, org_id) DO UPDATE SET pending_generation = excluded.pending_generation
                """, arguments: [key.server.description, key.accountId, key.orgId, generation])
            // Where each team's stream stood is the earlier server's: not
            // known now — the fresh snapshot rules (review D3b3-3).
            try db.execute(sql: "UPDATE assignments SET team_seqs = NULL WHERE server = ? AND account_id = ? AND org_id = ?",
                           arguments: [key.server.description, key.accountId, key.orgId])
        }
    }

    func finish(_ key: ChatOrgKey, _ generation: String) throws {
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO org_generations (server, account_id, org_id, generation, pending_generation) VALUES (?, ?, ?, ?, NULL)
                ON CONFLICT(server, account_id, org_id) DO UPDATE SET generation = excluded.generation, pending_generation = NULL
                """, arguments: [key.server.description, key.accountId, key.orgId, generation])
        }
    }
}

extension ChatStore: ChatGenerationState {
    func generation(_ key: ChatOrgKey) throws -> (generation: String?, pending: String?) {
        (try generation, try pendingGeneration)
    }
    func setPending(_ key: ChatOrgKey, _ generation: String) throws { try beginGeneration(generation) }
    func finish(_ key: ChatOrgKey, _ generation: String) throws { try finishGeneration(generation) }
}
