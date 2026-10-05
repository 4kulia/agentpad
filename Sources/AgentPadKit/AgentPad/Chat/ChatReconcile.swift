import Foundation
import GRDB

/// What this Mac's run journal knows of a request (6.8, D9, D11): read
/// before the cache's transaction, so `reconcile` stays a function of what
/// it is given.
struct ChatLocalFacts: Equatable, Sendable {
    enum Approval: Equatable, Sendable {
        case none
        /// Neither spent nor void: the run may start.
        case valid
        case void(String)
        case spent

        /// Never spent: the run did not begin on it.
        var unspent: Bool {
            switch self {
            case .valid, .void: true
            case .none, .spent: false
            }
        }
    }

    struct Run: Equatable, Sendable {
        var runId: String
        /// Its outcome is written.
        var ended: Bool
        /// Running in this app now.
        var live: Bool
    }

    var approval: Approval = .none
    var approvalId: String?
    /// The run id the approval was made for (`run.start` names it).
    var approvalRunId: String?
    /// The approval's run row, if one was written.
    var run: Run?
    /// A result kept in the journal (`runs.result_text`) that the server's
    /// generation now has not taken — on its way, never sent, refused, or
    /// taken by an earlier generation a restored server may not have
    /// (review D8g-p3-1, D4b-p2-1).
    var resultUndelivered = false
    /// The run ended here, and its end (`run.finished`, `run.failed`,
    /// `run.failed_to_start`) is not on its way to, nor taken by, the
    /// server now — whenever its earlier answer was stored (review D8h-p3-1,
    /// D8i-p2-3, p3-4).
    var endUntold = false
}

/// One kind of side effect a request owes this Mac (6.12). One row per
/// `(request_id, kind)`: each runs once, from whichever stream and however
/// often its state came. A new server generation reads the cache anew, its
/// actions with it (`ChatStore.beginGeneration`): a notification shown may
/// be shown once more then.
enum ChatActionKind: String, CaseIterable, Sendable {
    case receive
    case notifyDecision = "notify_decision"
    case start
    case failStart = "fail_start"
    case recover
    case deliver
    case notifyOutcome = "notify_outcome"
    /// `stop_requested` for a run of this Mac: its process stopped, the
    /// stop's outcome told (D4b).
    case stop
}

/// Derives the actions a request owes from its current state and the
/// journal's facts — never from the event that brought it, so a state that
/// came by event, snapshot or from the cache at launch gives the same rows
/// (docs/agentpad/CHAT-PLAN.md 6.12).
enum ChatReconcile {
    /// What `reconcile` looks at of a request.
    struct Request: Equatable, Sendable {
        var state: TeamRequestState
        var onThisDevice: Bool
        var askedHere: Bool
        /// The server holds the result of its current run (the cache holds
        /// the current generation only).
        var answered: Bool
        var runId: String? = nil
    }

    /// The table of 6.12. `facts` nil: the journal is not known (none, or
    /// damaged) — nothing of the executor's side is decided then.
    static func actions(_ request: Request, facts: ChatLocalFacts?) -> [ChatActionKind] {
        var kinds: [ChatActionKind] = []
        if let facts {
            let state = request.state
            let executing: Set<TeamRequestState> = [.approved, .starting, .running]
            let sameRun = { (runId: String?) in request.runId == nil || request.runId == runId }
            if state == .stopRequested, let run = facts.run, run.live, sameRun(run.runId) {
                // Being stopped while it runs here — whichever session of the
                // owner started it: the run is this Mac's (DESIGN-D3b-D4b-D5b §11.1).
                kinds.append(.stop)
            } else if state == .stopRequested, facts.run == nil, request.onThisDevice, facts.approval.unspent, sameRun(facts.approvalRunId) {
                // Being stopped before its process: it never starts (§10.2).
                kinds.append(.stop)
            } else if let run = facts.run, !run.live,
               (!run.ended && (executing.contains(state) || state == .stopRequested))
                || (run.ended && facts.endUntold && Self.beforeTheEnd.contains(state) && (request.runId == nil || request.runId == run.runId)) {
                // A run left without its outcome: checked and stopped first
                // (D11). Or one that ended here whose end the server does not
                // have — a restored one: its end is told again, nothing runs
                // again (review D8h-p3-1, D8i-p2-3, p3-4). A server restored
                // to `awaiting_decision` asks the owner first (D4c-p1-1).
                kinds.append(.recover)
            } else if request.onThisDevice {
                switch state {
                case .submitted: kinds.append(.receive)
                case .awaitingDecision: kinds.append(.notifyDecision)
                case .approved, .starting:
                    switch facts.approval {
                    case .valid: kinds.append(.start)
                    case .none, .void: if facts.run == nil { kinds.append(.failStart) }
                    case .spent: break
                    }
                default: break
                }
            } else if [.approved, .starting].contains(state), facts.run == nil, facts.approval.unspent {
                // Allowed here, but this Mac's session is no longer the
                // executor (signed in again): it does not start; the server
                // is told — also when the approval was voided before, and a
                // new generation read the request anew (DESIGN-D4 §0.3,
                // review D4b-p2-3).
                kinds.append(.failStart)
            }
            // Owed while the server's generation now has not taken it.
            if facts.resultUndelivered, !request.answered {
                kinds.append(.deliver)
            }
        }
        // `finished` waits for its result: the outcome is told with the text.
        if request.askedHere, request.answered || (request.state.isFinal && request.state != .finished) {
            kinds.append(.notifyOutcome)
        }
        return kinds
    }

    /// The server's states of a run before its end is known to it.
    static let beforeTheEnd: Set<TeamRequestState> = [.approved, .starting, .running, .stopRequested]

    /// The kinds a request in its state may owe whatever the journal says.
    /// Facts are read before the transaction and may be late; the state is
    /// the transaction's own — so only the state voids an action.
    static func possible(_ request: Request) -> Set<ChatActionKind> {
        var kinds: Set<ChatActionKind> = [.deliver]
        if beforeTheEnd.contains(request.state) { kinds.insert(.recover) }
        if request.state == .stopRequested { kinds.insert(.stop) }
        // Told only of an outcome the cache holds now: a state open again
        // voids one not shown (review D8i-p2-1).
        if actions(request, facts: nil).contains(.notifyOutcome) { kinds.insert(.notifyOutcome) }
        if [.approved, .starting].contains(request.state) { kinds.insert(.failStart) }
        if request.onThisDevice {
            switch request.state {
            case .submitted: kinds.insert(.receive)
            case .awaitingDecision: kinds.insert(.notifyDecision)
            case .approved, .starting: kinds.insert(.start)
            default: break
            }
        }
        return kinds
    }

    /// Inserts the actions `requestIds` owe that are missing, and voids
    /// those not done their state no longer allows — inside the transaction
    /// that wrote the state, so a handler never begins on a state gone by
    /// (review D8h-p2-4). A request without its facts in `facts` is decided
    /// as one whose journal is not known.
    static func reconcile(_ db: Database, _ requestIds: some Sequence<String>, facts: [String: ChatLocalFacts]?, now: Date = Date()) throws {
        for id in requestIds {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT state, run_id, on_this_device, asked_here, EXISTS(SELECT 1 FROM results WHERE results.request_id = requests.request_id AND results.run_id IS requests.run_id) AS answered
                FROM requests WHERE request_id = ?
                """, arguments: [id])
            else { continue }
            let request = Request(state: TeamRequestState(rawValue: row["state"]), onThisDevice: row["on_this_device"],
                                  askedHere: row["asked_here"], answered: row["answered"], runId: row["run_id"])
            for kind in actions(request, facts: facts?[id]) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO actions (request_id, kind, state, created_at, updated_at) VALUES (?, ?, 'pending', ?, ?)
                    """, arguments: [id, kind.rawValue, now, now])
            }
            let void = ChatActionKind.allCases.filter { !possible(request).contains($0) }
            if !void.isEmpty { try ChatCallStore.voidActions(db, request: id, kinds: void, reason: "no_longer_owed") }
        }
    }
}

extension ChatJournal {
    /// The facts of `requestIds` of one organization, in one read of the
    /// journal. `isLive`: the run is running in this app.
    func facts(_ key: ChatOrgKey, requestIds: some Collection<String>, isLive: (String) -> Bool) throws -> [String: ChatLocalFacts] {
        let wanted = Set(requestIds)
        // The generation the organization's commands now belong to.
        let kept = try generation(key)
        let current = kept.pending ?? kept.generation
        let (approvals, runs, delivered, endsTold) = try queue.read { db in
            let approvals = try ChatApproval.fetchAll(db, sql: """
                SELECT * FROM approvals WHERE server = ? AND account_id = ? AND org_id = ? AND kind = 'initial'
                """, arguments: [key.server.description, key.accountId, key.orgId])
                .filter { wanted.contains($0.requestId) }
            let runs = try ChatRunRecord.fetchAll(db, keys: approvals.map(\.runId))
            // Runs whose result the server's generation now has taken.
            let delivered = try Data.fetchAll(db, sql: """
                SELECT body_bytes FROM run_commands
                WHERE server = ? AND account_id = ? AND org_id = ? AND type = 'result.deliver' AND state = 'sent' AND sent_generation IS ?
                """, arguments: [key.server.description, key.accountId, key.orgId, current])
                .compactMap { try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0).args["run_id"]?.string }
            // Runs whose end is on its way to, or taken by, the server now.
            let endsTold = try Data.fetchAll(db, sql: """
                SELECT body_bytes FROM run_commands
                WHERE server = ? AND account_id = ? AND org_id = ? AND type IN ('run.finished', 'run.failed', 'run.failed_to_start', 'run.stopped', 'run.stop_failed')
                    AND (state = 'pending' OR (state = 'sent' AND sent_generation IS ?))
                """, arguments: [key.server.description, key.accountId, key.orgId, current])
                .compactMap { try? JSONDecoder().decode(ChatCommandEnvelope.self, from: $0).args["run_id"]?.string }
            return (approvals, runs, Set(delivered), Set(endsTold))
        }
        var facts: [String: ChatLocalFacts] = Dictionary(uniqueKeysWithValues: wanted.map { ($0, ChatLocalFacts()) })
        for approval in approvals {
            facts[approval.requestId]?.approval = approval.voidAt != nil ? .void(approval.voidReason ?? "void")
                : approval.consumedAt != nil ? .spent : .valid
            facts[approval.requestId]?.approvalId = approval.id
            facts[approval.requestId]?.approvalRunId = approval.runId
            if let run = runs.first(where: { $0.runId == approval.runId }) {
                facts[approval.requestId]?.run = .init(runId: run.runId, ended: run.outcome != nil, live: isLive(run.runId))
                facts[approval.requestId]?.endUntold = run.outcome != nil && !endsTold.contains(run.runId)
                // The duty to deliver is the result kept, not a command's
                // state: a refused delivery stays owed (review D4b-p2-1).
                facts[approval.requestId]?.resultUndelivered = run.outcome == .finished && run.resultText != nil
                    && !delivered.contains(run.runId)
            }
        }
        return facts
    }
}
