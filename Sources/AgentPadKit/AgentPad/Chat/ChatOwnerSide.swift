import Foundation
import GRDB

/// The facts an executor owes the server for a run, as one chain (DESIGN-D4
/// §0.2, lead's rule on review D4b): from the server's state of the request
/// now, the predecessors it lacks, then the run's end, then its result. One
/// algorithm for a run that ends, for one that started, and for `recover`
/// and `deliver`. A step the server has — on its way, or taken by the
/// current generation — is kept; one not taken is made anew.
enum ChatFactChain {
    /// The steps owed, in order. `outcome` nil: the process exists, no end
    /// yet. `processStarted`: a process was recorded, or an unconfirmed stop
    /// cannot exclude it. A missing PID alone does not prove it never ran.
    /// `delivers` false: the result is not delivered as the chain's last step
    /// (F5: a channel's request publishes it by the owner's button).
    /// `stopConfirmed`: Y5's saved `.stopped`, never the owner's word alone.
    static func plan(state: TeamRequestState, outcome: ChatRunRecord.Outcome?, processStarted: Bool = true, stopConfirmed: Bool = false,
                     hasResult: Bool, answered: Bool, delivers: Bool = true) -> [String] {
        // A server waiting for the decision (`awaiting_decision`) is owed
        // nothing here: only the owner's button decides (DESIGN-D4 §0.2,
        // review D4c-p1-1).
        if outcome == .didNotStart || (outcome != nil && !processStarted), [.approved, .starting].contains(state) {
            return ["run.failed_to_start"]
        }
        if outcome == .didNotStart {
            // No process, while the server has the run going: it ended
            // without running — stopped while being stopped, never `run.failed`
            // from `stop_requested` (review D4b-p2-2).
            switch state {
            case .running: return ["run.failed"]
            case .stopRequested: return ["run.stopped"]
            default: return []
            }
        }
        var steps: [String] = []
        var now = state
        if now == .approved {
            steps.append("run.start")
            now = .starting
        }
        if now == .starting {
            steps.append("run.started")
            now = .running
        }
        guard let outcome else { return steps }
        switch now {
        // `run.failed` only from `running`. A stop is confirmed only by
        // Y5's `.stopped`, or when no process ever existed.
        case .running: steps.append(outcome == .finished ? "run.finished" : "run.failed")
        case .stopRequested: steps.append(outcome == .finished ? "run.finished" : !processStarted || stopConfirmed ? "run.stopped" : "run.stop_failed")
        case .finished: break
        default: return []
        }
        if outcome == .finished, hasResult, !answered, delivers { steps.append("result.deliver") }
        return steps
    }
}

extension ChatService {
    /// Commands of one run, and of one request before its run.
    static func runKey(_ runId: String) -> String { ChatOutbox.executorKeyPrefix + "run:\(runId)" }
    static func requestKey(_ requestId: String) -> String { ChatOutbox.executorKeyPrefix + "req:\(requestId)" }
    /// Why a command not taken by the server was replaced after a new generation.
    static let supersededError = "superseded after a new generation"

    /// What the chain of `run` is planned from: the request's state as the
    /// cache has it, whether the server holds its result, and the session to
    /// send under. Nil while the state is not known (not read, being read
    /// anew) or there is no session of the organization: the outcome is then
    /// written alone, and `recover` tells the end later.
    private func chainContext(_ key: ChatOrgKey, _ run: ChatRunRecord) -> (state: TeamRequestState, answered: Bool, session: String, thread: String, kind: String?)? {
        guard let connection, connection.orgKey == key, let raw = requestState(key, run.requestId) else { return nil }
        let state = TeamRequestState(rawValue: raw)
        guard state != .resyncing else { return nil }
        let request = (try? orgSessions[key]?.store?.calls.request(run.requestId)) ?? nil
        // The thread the result belongs to: the request's, or one it begins (D5b §3.2).
        return (state, request?.result?.runId == run.runId, connection.sessionId, request?.threadId ?? run.requestId, run.kind == "channel" ? "channel" : request?.kind)
    }

    /// Inserts, in the caller's journal transaction, the steps of `run`'s
    /// chain the server lacks now (`ChatFactChain`).
    private func insertChain(_ db: Database, key: ChatOrgKey, run: ChatRunRecord, approval: ChatApproval?, steps: [String],
                             reason: String, result: String?, session: String, thread: String? = nil, seq: inout Int64, now: Date) throws {
        let table = try requireJournal().runCommands(key)
        // A fact of an approval set aside (another call under its id) is
        // never written — read in the writing transaction (review D9-2).
        guard try String.fetchOne(db, sql: "SELECT kind FROM approvals WHERE id = ?", arguments: [run.approvalId]) == "initial" else { return }
        let current = try String.fetchOne(db, sql: """
            SELECT coalesce(pending_generation, generation) FROM org_generations WHERE server = ? AND account_id = ? AND org_id = ?
            """, arguments: [key.server.description, key.accountId, key.orgId])
        let order = Self.runKey(run.runId)
        var last: String?
        // A stop that could not be confirmed was told: the server's word on
        // the run's end is that one (D4b).
        let stopFailed = try ChatOwnerSide.told(db, key, order: order, type: "run.stop_failed") != nil
        for type in steps {
            if stopFailed, ["run.stopped", "run.finished", "run.failed"].contains(type) { continue }
            let rows = try ChatCommandRecord.fetchAll(db, sql: """
                SELECT * FROM run_commands WHERE server = ? AND account_id = ? AND org_id = ? AND order_key = ? AND type = ? ORDER BY seq, rowid
                """, arguments: [key.server.description, key.accountId, key.orgId, order, type])
            if let told = rows.last(where: { $0.state == .pending || ($0.state == .sent && ($0.sentGeneration == nil || $0.sentGeneration == current)) }) {
                last = told.state == .pending ? told.commandId : nil
                continue
            }
            try db.execute(sql: """
                UPDATE run_commands SET state = 'dropped', error = ?
                WHERE server = ? AND account_id = ? AND org_id = ? AND order_key = ? AND type = ? AND state = 'unconfirmed'
                """, arguments: [Self.supersededError, key.server.description, key.accountId, key.orgId, order, type])
            var args: [String: ChatJSON] = ["request_id": .string(run.requestId), "run_id": .string(run.runId)]
            var fullText: String?
            switch type {
            case "run.stop_failed":
                // The stop's own reasons (api.md); any other end told as not confirmed.
                let stopReason = run.preflightPID != nil ? "preflight_cleanup_unconfirmed" : reason
                args["reason"] = .string(["processes_alive", "processes_unknown", "preflight_cleanup_unconfirmed"].contains(stopReason) ? stopReason : "processes_unknown")
            case "run.failed", "run.failed_to_start":
                let text = run.kind == "channel" ? (type == "run.failed_to_start" ? "failed_to_start" : "failed") : String(reason.prefix(300))
                args["reason"] = .string(text.isEmpty ? "failed" : text)
            case "result.deliver":
                guard let result else { continue }
                let made = try ChatResultText.deliverArgs(org: key.orgId, requestId: run.requestId, runId: run.runId, text: result, threadId: thread)
                if case .object(let o) = made.args { args = o }
                fullText = result
            default: break
            }
            // `run.start` keeps the id of its approval while that one was never stored.
            var id = ChatUUID.v7(now: now)
            if type == "run.start", let made = approval?.startCommandId, !rows.contains(where: { $0.commandId == made }) { id = made }
            let bytes = try ChatCommandEnvelope(commandId: id, org: key.orgId, type: type, args: .object(args)).encoded()
            var record = ChatCommandRecord(commandId: id, sessionId: session, type: type, bodyBytes: bytes, orderKey: order,
                                           dependsOn: last, createdAt: now, state: .pending)
            record.seq = seq
            _ = try table.insert(db, record, resultText: fullText, seq: seq)
            seq += 1
            last = id
        }
    }

    private func requireJournal() throws -> ChatJournal {
        guard let journal else { throw ChatError.storage("no run journal") }
        return journal
    }

    private func firstSeq(_ key: ChatOrgKey) throws -> Int64 {
        var tables = [try requireJournal().runCommands(key)]
        if let store = orgSessions[key]?.store { tables.append(store.outbox) }
        return try ChatCommandTable.maxSeq(tables) + 1
    }

    /// Writes `run`'s outcome — with its full result — and, in the same
    /// transaction, its chain of facts as far as the server's state is known
    /// (`TeamRunFacts`). True when written.
    func end(_ given: ChatRunRecord, outcome: ChatRunRecord.Outcome, reason: String, result: String?, at: Date,
             journal: ChatJournal, waitForState: Bool) throws -> Bool {
        // As the journal has it now: its process recorded since.
        let run = try journal.run(given.runId) ?? given
        guard let approval = try journal.approval(run.approvalId), let key = approval.key else {
            return try journal.finish(run.runId, outcome, at: at, result: result)
        }
        let context = chainContext(key, run)
        if waitForState, context == nil { throw ChatError.storage("the request's state is not known") }
        var seq = try firstSeq(key)
        // A run that ended by itself here ran — whether or not its runner
        // told its process (`didNotStart` says otherwise); one recovered
        // after the app ended ran only if its process was recorded, or a
        // segment of it went on. Read before the journal's transaction.
        let ran = !waitForState || self.ran(run, journal)
        let done = try journal.finish(run.runId, outcome, at: at, result: result) { db in
            guard let context else { return }
            let steps = ChatFactChain.plan(state: context.state, outcome: outcome, processStarted: ran,
                                           stopConfirmed: run.stopConfirmedAt != nil,
                                           hasResult: result != nil, answered: context.answered, delivers: context.kind != "channel")
            try self.insertChain(db, key: key, run: run, approval: approval, steps: steps, reason: reason, result: result,
                                 session: context.session, thread: context.thread, seq: &seq, now: at)
        }
        if done { factStored(key); reconcileChannelResults() }
        return done
    }

    /// The process of `run` exists: what the server lacks before its end
    /// (`run.started`, and its predecessors) goes.
    func processStarted(_ run: ChatRunRecord) {
        do { try tellRun(run.runId) } catch {
            NSLog("agentpad: the start of run \(run.runId) could not be told: \(error.localizedDescription)")
        }
    }

    /// Where a run's chain stands after `tellRun`.
    enum ChainStatus: Equatable {
        /// Nothing owed, or all of it taken by the server now.
        case told
        /// Steps on their way: the server's answers wake the runner.
        case waiting
        /// A step was refused, and is made anew only after a pause
        /// (`mayResend` said no): asked again then.
        case paused
    }

    /// The chain of a run as the journal has it now, completed for the
    /// server's state: `recover` and `deliver` (D4, D8i). Nothing when the
    /// state is not known yet. A step the server refused is made anew only
    /// when `mayResend` allows it — once per pause, so a refusal (`403`
    /// while the earlier session is open, or a state the cache does not
    /// have yet) is not repeated at the network's pace (review D4b-p1-2, p2-1).
    @discardableResult
    func tellRun(_ runId: String, mayResend: (ChatCommandRecord) -> Bool = { _ in true }) throws -> ChainStatus {
        let journal = try requireJournal()
        guard let run = try journal.run(runId), let approval = try journal.approval(run.approvalId), let key = approval.key,
              let context = chainContext(key, run)
        else { return .waiting }
        let planned = ChatFactChain.plan(state: context.state, outcome: run.outcome, processStarted: ran(run, journal),
                                         stopConfirmed: run.stopConfirmedAt != nil,
                                         hasResult: run.resultText != nil, answered: context.answered, delivers: context.kind != "channel")
        let order = Self.runKey(run.runId)
        // A step the server refused because the request had ended is paid (d8d2ea0).
        func refusedNotTold() throws -> [ChatCommandRecord] {
            try journal.queue.read { db in
                try planned.compactMap { type -> ChatCommandRecord? in
                    guard try ChatOwnerSide.told(db, key, order: order, type: type) == nil else { return nil }
                    let last = try ChatCommandRecord.fetchAll(db, sql: """
                        SELECT * FROM run_commands WHERE server = ? AND account_id = ? AND org_id = ? AND order_key = ? AND type = ? ORDER BY seq, rowid
                        """, arguments: [key.server.description, key.accountId, key.orgId, order, type]).last
                    return last?.state == .failed ? last : nil
                }
            }
        }
        let refused = try refusedNotTold()
        let paid = Set(refused.filter { $0.error == ChatOutbox.requestEnded }.map(\.type))
        let steps = planned.filter { !paid.contains($0) }
        if refused.contains(where: { $0.error != ChatOutbox.requestEnded && !mayResend($0) }) { return .paused }
        if !steps.isEmpty {
            var seq = try firstSeq(key)
            let now = Date()
            try journal.queue.write { db in
                try insertChain(db, key: key, run: run, approval: approval, steps: steps, reason: Self.reason(run), result: run.resultText,
                                session: context.session, thread: context.thread, seq: &seq, now: now)
            }
            factStored(key)
            reconcileChannelResults()
        }
        let waiting = try journal.queue.read { db in
            try steps.contains { try ChatOwnerSide.told(db, key, order: order, type: $0)?.state == .pending }
        }
        return waiting ? .waiting : .told
    }

    /// Stopped before its process (DESIGN-D3b-D4b-D5b §10.2): the approval
    /// not spent is voided — atomic with its spending by `TeamLauncher` — and
    /// `run.stopped` goes, in one journal transaction. False when the
    /// approval was spent meanwhile: the run began.
    func stopUnstarted(_ approval: ChatApproval, key: ChatOrgKey) throws -> Bool {
        let journal = try requireJournal()
        guard let connection, connection.orgKey == key else { throw ChatError.notConnected }
        var seq = try firstSeq(key)
        let now = Date()
        let run = ChatRunRecord(runId: approval.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
                                conversationId: "", pid: nil, pgid: nil, processStartedAt: nil, startedAt: now)
        let stopped = try journal.queue.write { db -> Bool in
            try db.execute(sql: "UPDATE approvals SET void_at = ?, void_reason = ? WHERE id = ? AND consumed_at IS NULL AND void_at IS NULL",
                           arguments: [now, "stop_requested", approval.id])
            guard try Bool.fetchOne(db, sql: "SELECT consumed_at IS NULL FROM approvals WHERE id = ?", arguments: [approval.id]) == true else { return false }
            try insertChain(db, key: key, run: run, approval: nil, steps: ["run.stopped"], reason: "stop_requested", result: nil,
                            session: connection.sessionId, seq: &seq, now: now)
            return true
        }
        if stopped { factStored(key) }
        return stopped
    }

    /// A stop that could not be confirmed: `run.stop_failed` with its reason;
    /// the row stays open, being stopped (D4b, §10.1). A debt as any end: a
    /// refused one is made anew after its pause (`mayResend`), one not taken
    /// by the server's generation now is made anew (review D4b-p1-3).
    @discardableResult
    func tellStopFailed(_ run: ChatRunRecord, reason: String, mayResend: (ChatCommandRecord) -> Bool = { _ in true }) throws -> ChainStatus {
        let journal = try requireJournal()
        guard let approval = try journal.approval(run.approvalId), let key = approval.key, let connection, connection.orgKey == key else {
            throw ChatError.notConnected
        }
        let order = Self.runKey(run.runId)
        let refused = try journal.queue.read { db -> ChatCommandRecord? in
            guard try ChatOwnerSide.told(db, key, order: order, type: "run.stop_failed") == nil else { return nil }
            return try ChatCommandRecord.fetchAll(db, sql: """
                SELECT * FROM run_commands WHERE server = ? AND account_id = ? AND org_id = ? AND order_key = ? AND type = 'run.stop_failed' ORDER BY seq, rowid
                """, arguments: [key.server.description, key.accountId, key.orgId, order]).last.flatMap { $0.state == .failed ? $0 : nil }
        }
        if refused?.error == ChatOutbox.requestEnded { return .told }
        if let refused, !mayResend(refused) { return .paused }
        var seq = try firstSeq(key)
        let now = Date()
        try journal.queue.write { db in
            try insertChain(db, key: key, run: run, approval: approval, steps: ["run.stop_failed"], reason: reason, result: nil,
                            session: connection.sessionId, seq: &seq, now: now)
        }
        factStored(key)
        let pending = try journal.queue.read { db in try ChatOwnerSide.told(db, key, order: order, type: "run.stop_failed")?.state == .pending }
        return pending ? .waiting : .told
    }

    /// Folders granted during a run (D4b §2.5): its continuation record —
    /// one waiting at a time, replaced by a later grant with all folders so
    /// far, at most three per run. Nil when written, else why not.
    func continueRun(_ requestId: String, folders: [String]) -> String? {
        guard let journal, let connection else { return "The server connection is not ready; try again." }
        do {
            guard let key = connection.orgKey, let initial = try journal.approval(key, requestId: requestId), initial.consumedAt != nil,
                  let generation = try journal.generation(key).generation
            else { return "The call is not running here." }
            let session = connection.sessionId
            try journal.queue.write { db in
                let earlier = try ChatApproval.fetchAll(db, sql: """
                    SELECT * FROM approvals WHERE server = ? AND account_id = ? AND org_id = ? AND request_id = ? AND kind LIKE 'continuation-%'
                    ORDER BY created_at
                    """, arguments: [key.server.description, key.accountId, key.orgId, requestId])
                let waiting = earlier.first { $0.consumedAt == nil && $0.voidAt == nil }
                let segment = waiting.map { Int($0.kind.dropFirst("continuation-".count)) ?? 1 }
                    ?? (earlier.filter { $0.consumedAt != nil }.count + 1)
                guard segment <= TeamCalls.maxContinuations else { throw TeamError.storage("this call cannot be given more folders") }
                if let waiting { _ = try waiting.delete(db) }
                try TeamApprovals.continuation(of: initial, segment: segment, granted: folders, generation: generation, session: session).insert(db)
            }
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The request this Mac's approval of `request`'s id was made for — the
    /// same agent, text and initiator (as the journal recorded them at the
    /// Allow) — or none. A restored server may give the id to another call:
    /// then the earlier approval, its run and continuations are set aside
    /// (renamed out of the request's kinds, history kept), and the request is
    /// a new one — decided by the button, run anew; nothing earlier is told
    /// or delivered for it (review D5b3-1). The one check every reuse goes
    /// through: decide, start, fail_start, recover, deliver, stop.
    @discardableResult
    func disownForeignApproval(_ key: ChatOrgKey, _ request: ChatRequest) throws -> Bool {
        let journal = try requireJournal()
        guard let approval = try journal.approval(key, requestId: request.requestId), request.hasFixed else { return false }
        // Closed by default: what was not recorded — the initiator, the
        // agent, the parameters — is not this call's (review D45-final-2).
        let params = try? TeamLaunchParams.decode(approval.params)
        let sameAgent = request.agentId != nil && approval.agentId == request.agentId
        let samePrompt = params != nil && params?.inputs.prompt == request.text
        let sameInitiator = params?.initiator != nil && params?.initiator == request.initiatorAccountId
        let sameScope = params?.channelId == request.channelId && params?.threadRootId == request.threadRootId
        let same = sameAgent && samePrompt && sameInitiator && sameScope
        guard !same else { return false }
        try journal.queue.write { db in
            try db.execute(sql: """
                UPDATE approvals SET kind = 'superseded:' || id
                WHERE server = ? AND account_id = ? AND org_id = ? AND request_id = ? AND (kind = 'initial' OR kind LIKE 'continuation-%')
                """, arguments: [key.server.description, key.accountId, key.orgId, request.requestId])
            // Its result is no one's to deliver now.
            try db.execute(sql: "UPDATE runs SET result_text = NULL WHERE approval_id = ?", arguments: [approval.id])
        }
        // A run of it still going stops — through the stop's outcome, as
        // any stop (review D45-final-1); its end tells nothing.
        if let launcher, launcher.live[approval.runId] != nil {
            let runId = approval.runId
            Task { @MainActor [weak launcher] in _ = try? await launcher?.stopForServer(runId) }
        }
        NSLog("agentpad: request \(request.requestId) is another call than the one allowed here before; that one is set aside")
        return true
    }

    /// The owner's Stop or the caller's cancel: `request.stop` /
    /// `request.cancel` queued, nothing ended here before the server's word
    /// (D4b, D5b). Nil when asked, else why not.
    func askToEnd(_ key: ChatOrgKey, _ requestId: String, type: String, states: Set<TeamRequestState>?) -> String? {
        guard let store = orgSessions[key]?.store, let request = (try? store.calls.request(requestId)) ?? nil else {
            return "The server connection is not ready; try again."
        }
        if let states, !states.contains(request.state) { return "Only a call that is running can be stopped." }
        if request.state.isFinal { return nil }
        do {
            // Its own order, by request: never behind another call's commands
            // (a `429` of another `request.create`), only after its own
            // `request.create` while that is on its way (review D4b-p2-2).
            _ = try enqueue(key, type: type, args: .object(["request_id": .string(requestId)]), orderKey: "out:\(requestId)",
                            afterCreateOf: requestId)
            return nil
        } catch {
            return "It could not be asked: \(error.localizedDescription)"
        }
    }

    /// The run's process existed: recorded, or the run finished, or a
    /// segment of it went on under a continuation (review D4b2-3).
    static func ran(_ run: ChatRunRecord) -> Bool {
        run.pid != nil || run.processStartedAt != nil || run.outcome == .finished
    }

    private func ran(_ run: ChatRunRecord, _ journal: ChatJournal) -> Bool {
        // A stopped run with no recorded PID is unknown, not evidence that
        // it never ran. The owner's confirmation cannot change that.
        Self.ran(run) || run.stopReason != nil || ((try? journal.approval(run.approvalId)).flatMap { $0 }.map { (try? journal.continued($0)) ?? false } ?? false)
    }

    private static func reason(_ run: ChatRunRecord) -> String {
        switch run.outcome {
        case .didNotStart?: "did_not_start"
        case .stoppedLocally?: run.stopReason ?? "stopped_locally"
        case .executorRestarted?: "executor_restarted"
        default: "failed"
        }
    }

    /// A fact of a run refused for good: the run's chain is told again from
    /// the server's state — the actions that tell it may be owed once more,
    /// now from the cache, or with the event of the server's move when it
    /// comes after the refusal.
    func factRefused(_ key: ChatOrgKey, _ record: ChatCommandRecord) {
        guard let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes),
              let requestId = envelope.args["request_id"]?.string, let session = orgSessions[key]
        else { return }
        do {
            try session.store?.queue.write { db in
                try db.execute(sql: "DELETE FROM actions WHERE request_id = ? AND kind IN ('recover', 'deliver') AND state IN ('done', 'failed')",
                               arguments: [requestId])
            }
        } catch {
            NSLog("agentpad: the chain of request \(requestId) could not be asked again: \(error.localizedDescription)")
        }
        reconcileCalls(session)
    }

    /// Results of runs that finished here and that no server has taken:
    /// shown to the owner from the journal — also after Disconnect, and
    /// with no connection (DESIGN-D4, review D4b-4).
    struct UndeliveredResult: Equatable, Identifiable {
        let runId: String
        let requestId: String
        let agentId: String
        let text: String
        var id: String { runId }
    }

    func undeliveredResults() -> [UndeliveredResult] {
        _ = publishRevision
        guard let journal else { return [] }
        return (try? journal.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.run_id, r.request_id, r.agent_id, r.result_text FROM runs r
                WHERE \(ChatTeamCallStore.personal("r")) AND r.outcome = 'finished' AND r.result_text IS NOT NULL
                    AND NOT EXISTS(SELECT 1 FROM run_commands c WHERE c.order_key = 'exec:run:' || r.run_id
                                   AND c.type = 'result.deliver' AND c.state = 'sent'
                                   -- taken by the server's generation now (review D4-p2-5)
                                   AND c.sent_generation IS (SELECT coalesce(g.pending_generation, g.generation) FROM org_generations g
                                       WHERE g.server = c.server AND g.account_id = c.account_id AND g.org_id = c.org_id))
                ORDER BY r.ended_at
                """).map { UndeliveredResult(runId: $0["run_id"], requestId: $0["request_id"], agentId: $0["agent_id"], text: $0["result_text"]) }
        }) ?? []
    }
}

/// A run's activity, told to its caller at most once per interval: the
/// latest goes when the interval is over (D4b §2.4).
@MainActor
final class ChatActivityThrottle {
    static var interval: Duration = .seconds(2)
    private let send: @MainActor (ChatRunRecord, String) -> Void
    private var last: [String: ContinuousClock.Instant] = [:]
    private var waiting: [String: (ChatRunRecord, String)] = [:]

    init(send: @escaping @MainActor (ChatRunRecord, String) -> Void) { self.send = send }

    func note(_ row: ChatRunRecord, _ text: String) {
        let text = String(text.prefix(200))
        guard !text.isEmpty else { return }
        let now = ContinuousClock.now
        if let at = last[row.runId], now - at < Self.interval {
            let due = waiting[row.runId] == nil
            waiting[row.runId] = (row, text)
            guard due else { return }
            Task { [weak self] in
                try? await Task.sleep(until: at + Self.interval, clock: .continuous)
                guard let self, let (row, text) = self.waiting.removeValue(forKey: row.runId) else { return }
                self.last[row.runId] = .now
                self.send(row, text)
            }
            return
        }
        last[row.runId] = now
        send(row, text)
    }
}

/// The owner's side of calls through the server (D4, docs/agentpad/DESIGN-D4.md):
/// the handlers of `reconcile`'s actions, the owner's decision, and the one
/// coordinator of server runs and their slots.
@MainActor
final class ChatOwnerSide {
    private weak var service: ChatService?
    /// Approvals being launched now: with the launcher's live runs, the slots.
    private var launching: [String: (agentId: String, runId: String)] = [:]  // by approval id
    /// Tests: a write of a command fails while true.
    var writeFails: () -> Bool = { false }

    init(service: ChatService) {
        self.service = service
    }

    /// Registers every handler of the owner's side in the service's one
    /// table of handlers, and the decision of the Allow and Decline buttons.
    static func install(service: ChatService, calls: TeamCalls) -> ChatOwnerSide {
        let owner = ChatOwnerSide(service: service)
        for kind in [ChatActionKind.receive, .notifyDecision, .start, .failStart, .deliver, .recover, .stop] {
            service.actionHandlers[kind] = Handler(kind: kind, owner: owner)
        }
        service.owner = owner
        calls.decideOnServer = { [weak owner, weak calls] call, allow, reason in
            guard let owner, let key = calls?.serverKey else { return TeamServerCore.decideNotYet }
            return owner.decide(key, requestId: call.id, allow: allow, reason: reason)
        }
        // Every answer of a request's command wakes the runner: what waits
        // for it goes on.
        for type in ["run.start", "request.received", "request.decide", "request.stop"] {
            service.commandOwners[type] = { [weak service, weak owner] key, record, outcome in
                if type == "request.received" { owner?.receiptAnswered(key, record, outcome) }
                service?.runner(for: key).run()
            }
        }
        // A fact of a run's chain refused (the server moved meanwhile, say to
        // `stop_requested`): the chain is built again from the server's state
        // now — read anew, and `recover`/`deliver` owed again (review D4-p2-3,
        // D4b-p2-2). Refused as `forbidden` (the earlier session still open),
        // the action that sent it stays owed and sends it again after a pause
        // (DESIGN-D4 §0.8, review D4b-p2-1). Taken: what waits goes on.
        for type in ["run.started", "run.finished", "run.failed", "run.stopped", "run.stop_failed", "result.deliver", "run.failed_to_start"] {
            service.commandOwners[type] = { [weak service] key, record, outcome in
                // Refused, also as `forbidden` (`403` while the earlier
                // session is open): owed again — a `recover` already done is
                // made anew, and sends again after its pause (review D4c-p2-1).
                if case .refused = outcome {
                    service?.factRefused(key, record)
                } else {
                    service?.runner(for: key).run()
                }
            }
        }
        for type in ["result.publish", "result.withhold"] {
            service.commandOwners[type] = { [weak service] key, record, outcome in
                service?.channelPublicationAnswered(key, record: record, outcome: outcome)
            }
        }
        let throttle = ChatActivityThrottle { [weak service] row, text in
            guard let key = service?.connection?.orgKey else { return }
            service?.sendEphemeral(key, type: "run.activity", body: ["request_id": .string(row.requestId), "text": .string(text)])
        }
        service.onRunActivity = { row, text in throttle.note(row, row.kind == "channel" ? "Working" : text) }
        service.onSessionChanged = { [weak calls] in calls?.forgetServerFolderGrants() }
        calls.accessScope = { [weak service, weak calls] id in
            guard let key = calls?.serverKey, let approval = try service?.journal?.approval(key, requestId: id) else { return nil }
            let params = try TeamLaunchParams.decode(approval.params)
            return .init(key: key, kind: params.channelId == nil ? "personal" : "channel", channelId: params.channelId)
        }
        calls.channelAccessAllowed = { [weak service] scope in
            guard let service, let channel = scope.channelId else { return false }
            return ChatNotifications.allowed(service, scope.key, channel: channel)
        }
        calls.continueOnServer = { [weak service] call, folders in
            guard let service else { return TeamServerCore.foldersNotYet }
            return service.continueRun(call.id, folders: folders)
        }
        calls.onAccessWait = { [weak service, weak calls] call in
            guard let key = calls?.serverKey else { return }
            service?.sendEphemeral(key, type: "run.access_wait", body: ["request_id": .string(call.id)])
        }
        calls.serverConversation = { [weak service, weak calls] call in
            guard let service, let key = calls?.serverKey, let store = service.orgSessions[key]?.store,
                  let request = (try? store.calls.request(call.id)) ?? nil, request.kind != "channel"
            else { return nil }
            guard case .known(let conversation) = service.threadLookup(request, store: store, key: key, includingItself: true) else { return nil }
            return conversation
        }
        calls.stopOnServer = { [weak service, weak calls] call in
            guard let service, let key = calls?.serverKey else { return TeamServerCore.decideNotYet }
            return service.askToEnd(key, call.id, type: "request.stop", states: [.starting, .running])
        }
        service.onAgentUnpublished = { [weak calls] agentId in
            guard let id = UUID(uuidString: agentId) else { return }
            do { try calls?.removeUnpublished(id) } catch {
                NSLog("agentpad: unpublished agent \(agentId) could not be removed here: \(error.localizedDescription)")
            }
        }
        calls.ranHere = { [weak service] key in
            guard let journal = service?.journal else { return [] }
            return Set((try? journal.queue.read { db in
                try String.fetchAll(db, sql: """
                    SELECT request_id FROM approvals WHERE server = ? AND account_id = ? AND org_id = ? AND kind = 'initial' AND consumed_at IS NOT NULL
                    """, arguments: [key.server.description, key.accountId, key.orgId])
            }) ?? [])
        }
        ChatOutgoing.asksOn = true
        calls.deliversAsks = true
        return owner
    }

    private final class Handler: ChatActionHandler {
        let kind: ChatActionKind
        weak var owner: ChatOwnerSide?
        init(kind: ChatActionKind, owner: ChatOwnerSide) {
            self.kind = kind
            self.owner = owner
        }
        func perform(_ action: ChatAction, request: ChatRequest, key: ChatOrgKey) async -> ChatActionResult {
            guard let owner else { return .later }
            return await owner.perform(kind, request: request, key: key)
        }
    }

    func perform(_ kind: ChatActionKind, request: ChatRequest, key: ChatOrgKey) async -> ChatActionResult {
        do {
            // Another call under an id this Mac allowed before: nothing of
            // that one is reused for it (review D5b3-1).
            if kind != .notifyOutcome, try service?.disownForeignApproval(key, request) == true, kind != .notifyDecision, kind != .receive {
                return .done
            }
            switch kind {
            case .receive:
                if request.kind == "channel" {
                    guard request.hasFixed else { return .later }
                    guard try await service?.loadChannelContent(key, request: request) == true else {
                        // A deletion can invalidate /content without another
                        // event waking receive. Retry through notBefore while accessible.
                        return request.channelId.map { service?.channelAgentAllowed(key, channel: $0) == true } == true ? .retry : .later
                    }
                }
                return try receive(request, key)
            case .notifyDecision:
                if request.kind == "channel" {
                    guard try await service?.loadChannelContent(key, request: request) == true else {
                        return request.channelId.map { service?.channelAgentAllowed(key, channel: $0) == true } == true ? .retry : .later
                    }
                }
                // The notice, without content, once per server generation (F4).
                if let service { ChatNotifications.requestAwaitsDecision(key, requestId: request.requestId, service: service) }
                service?.onDecisionWanted(request.requestId)
                return .done
            case .start: return try await start(request, key)
            case .failStart: return try failStart(request, key)
            case .deliver, .recover: return try await tell(kind, request, key)
            case .stop: return try await stop(request, key)
            case .notifyOutcome: return .later
            }
        } catch {
            NSLog("agentpad: \(kind.rawValue) of \(request.requestId) could not be done: \(error.localizedDescription)")
            return .retry
        }
    }

    // MARK: Commands of a request

    /// The request's command of `type` — on its way or taken.
    /// On its way, or taken by the current generation — what the server has
    /// now; an unconfirmed one, or one taken by an earlier generation, is
    /// not (DESIGN-D4 §0.2, review D4-p1-2, p2-2).
    nonisolated static func told(_ db: Database, _ key: ChatOrgKey, order: String, type: String) throws -> ChatCommandRecord? {
        let current = try String.fetchOne(db, sql: """
            SELECT coalesce(pending_generation, generation) FROM org_generations WHERE server = ? AND account_id = ? AND org_id = ?
            """, arguments: [key.server.description, key.accountId, key.orgId])
        return try ChatCommandRecord.fetchAll(db, sql: """
            SELECT * FROM run_commands WHERE server = ? AND account_id = ? AND org_id = ? AND order_key = ? AND type = ?
                AND state IN ('pending', 'sent') ORDER BY seq, rowid
            """, arguments: [key.server.description, key.accountId, key.orgId, order, type])
            .last { $0.state == .pending || $0.sentGeneration == nil || $0.sentGeneration == current }
    }

    /// A command of the request not taken now and not to be sent by itself:
    /// replaced by the one made now.
    nonisolated private static func supersede(_ db: Database, _ key: ChatOrgKey, order: String, type: String) throws {
        try db.execute(sql: """
            UPDATE run_commands SET state = 'dropped', error = ?
            WHERE server = ? AND account_id = ? AND org_id = ? AND order_key = ? AND type = ? AND state = 'unconfirmed'
            """, arguments: ["superseded after a new generation", key.server.description, key.accountId, key.orgId, order, type])
    }

    /// Stores commands of the request in one journal transaction; `body`
    /// returns them to insert, given the next place in the queue.
    private func store(_ key: ChatOrgKey, _ body: (Database) throws -> [(type: String, args: ChatJSON, order: String, dependsOn: String?)]) throws {
        guard let service, let journal = service.journal, let connection = service.connection, connection.orgKey == key else {
            throw ChatError.notConnected
        }
        if writeFails() { throw ChatError.storage("a write failed (test)") }
        var tables = [journal.runCommands(key)]
        if let store = service.orgSessions[key]?.store { tables.append(store.outbox) }
        var seq = try ChatCommandTable.maxSeq(tables) + 1
        let table = journal.runCommands(key)
        let now = Date()
        try journal.queue.write { db in
            var made: [String: String] = [:]
            for command in try body(db) {
                let id = ChatUUID.v7(now: now)
                let bytes = try ChatCommandEnvelope(commandId: id, org: key.orgId, type: command.type, args: command.args).encoded()
                var record = ChatCommandRecord(commandId: id, sessionId: connection.sessionId, type: command.type, bodyBytes: bytes,
                                               orderKey: command.order, dependsOn: command.dependsOn.flatMap { made[$0] ?? $0 },
                                               createdAt: now, state: .pending)
                record.seq = seq
                _ = try table.insert(db, record, seq: seq)
                made[command.type] = id
                seq += 1
            }
        }
        service.factStored(key)
    }

    // MARK: receive

    /// `submitted` here: the checks of 1.0.x's `start` — the agent here and
    /// on, published as it is, terms known — then `request.received`; a
    /// check that fails declines it right after, with the reason.
    private func receive(_ request: ChatRequest, _ key: ChatOrgKey) throws -> ChatActionResult {
        guard let service, let journal = service.journal else { return .later }
        let order = ChatService.requestKey(request.requestId)
        let agent = request.agentId.flatMap { service.localAgent($0) }
        let assignment = try request.agentId.flatMap { try journal.assignment(key, agentId: $0) }
        var refusal: String?
        let thread = service.orgSessions[key]?.store.map { service.threadLookup(request, store: $0, key: key) } ?? .unknown
        if request.conditionsVersion != 1 {
            refusal = "unsupported_conditions"
        } else if request.threadId != nil, thread == .unknown {
            // A thread this Mac never had with this caller and agent (D5b §3.2).
            refusal = "unknown_thread"
        } else if let agent, agent.enabled, let assignment, assignment.state == .active, assignment.accepted.matches(agent) {
            refusal = nil
        } else {
            refusal = "agent_unavailable"
        }
        try store(key) { db in
            guard try Self.told(db, key, order: order, type: "request.received") == nil else { return [] }
            try Self.supersede(db, key, order: order, type: "request.received")
            var commands: [(type: String, args: ChatJSON, order: String, dependsOn: String?)] = [
                ("request.received", .object(["request_id": .string(request.requestId)]), order, nil),
            ]
            if let refusal {
                commands.append(("request.decide", .object(["request_id": .string(request.requestId), "allow": .bool(false),
                                                             "reason": .string(refusal)]), order, "request.received"))
            }
            return commands
        }
        return .done
    }

    // MARK: The owner's decision

    /// A request first found in a snapshot may have no event delivery yet.
    /// Its receive acknowledgement is enough to present the decision. Only
    /// that transition is taken from the compact HTTP result; it cannot
    /// supply fixed fields, executor identity, approval or a run.
    private func receiptAnswered(_ key: ChatOrgKey, _ record: ChatCommandRecord, _ outcome: ChatCommandOutcome) {
        guard let service, let connection = service.connection, connection.orgKey == key,
              record.sessionId == connection.sessionId, let journal = service.journal,
              let generation = try? journal.generation(key), generation.pending == nil,
              record.sentGeneration != nil, record.sentGeneration == generation.generation,
              case .taken(let answer?) = outcome,
              let envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: record.bodyBytes),
              let id = envelope.args["request_id"]?.string, answer.result["request_id"]?.string == id,
              answer.result["state"]?.string == TeamRequestState.awaitingDecision.rawValue,
              let version = answer.result["version"]?.int,
              let store = service.orgSessions[key]?.store, let current = try? store.calls.request(id),
              current.hasFixed, current.onThisDevice, current.state == .submitted, version > current.version
        else { return }
        do {
            let wire = ChatRequestWire(requestId: id, state: TeamRequestState.awaitingDecision.rawValue, version: version)
            try store.apply(requests: [wire], facts: service.localFacts(key, [id]))
            service.onCallsChanged(key)
        } catch {
            service.orgSessions[key]?.sync?.requestSnapshot()
        }
    }

    /// Allow or Decline of the buttons — the only way an approval is made
    /// (DESIGN-D4 §0.1, decision Y4). Allow: the approval (D9) and
    /// `request.decide` in one journal transaction. Nil when done, else why not.
    func decide(_ key: ChatOrgKey, requestId: String, allow: Bool, reason: String?) -> String? {
        if (try? service?.orgSessions[key]?.store?.calls.request(requestId))?.kind == "channel" {
            return "Review this request in its channel."
        }
        return saveDecision(key, requestId: requestId, allow: allow, reason: reason)
    }

    /// Channel consent always fetches /content again at the Allow boundary.
    /// The synchronous personal-call path cannot reuse a displayed snapshot.
    func decideChannel(_ key: ChatOrgKey, requestId: String, allow: Bool, reason: String?) async -> String? {
        guard let service, let request = try? service.orgSessions[key]?.store?.calls.request(requestId), request.kind == "channel" else {
            return "The channel request is not available."
        }
        do {
            guard try await service.loadChannelContent(key, request: request, refresh: true) else {
                return "The channel or its current context is not available; try again."
            }
            return saveDecision(key, requestId: requestId, allow: allow, reason: reason)
        } catch { return "The current context could not be loaded; try again." }
    }

    private func saveDecision(_ key: ChatOrgKey, requestId: String, allow: Bool, reason: String?) -> String? {
        guard let service, let journal = service.journal, let connection = service.connection, connection.orgKey == key,
              let request = try? service.orgSessions[key]?.store?.calls.request(requestId)
        else { return "The server connection is not ready; try again." }
        guard request.onThisDevice, request.state == .awaitingDecision else {
            return request.onThisDevice ? nil : TeamServerCore.decidedElsewhere(request.executorDeviceName)
        }
        if request.kind == "channel", !service.channelDecisionReady(key, request: request) {
            return "The channel or its verified context is not available; try again."
        }
        let order = ChatService.requestKey(requestId)
        do {
            // An earlier call's approval under this id is never reused (review D5b3-1).
            try service.disownForeignApproval(key, request)
            var approval: ChatApproval?
            if allow {
                guard let agentId = request.agentId, let agent = service.localAgent(agentId),
                      let launch = service.launchRequest(requestId), let generation = try journal.generation(key).generation
                else { return "The agent or the request is not there any more." }
                approval = try TeamApprovals.make(request: launch, agent: agent, key: key, generation: generation, session: connection.sessionId,
                                                  initiator: request.initiatorAccountId)
            }
            try store(key) { db in
                // A decision the server has now stands; one an earlier
                // generation took, or one never sent, does not: the button
                // decides again (review D4-p1-2).
                guard try Self.told(db, key, order: order, type: "request.decide") == nil else { return [] }
                try Self.supersede(db, key, order: order, type: "request.decide")
                if let approval {
                    let held = try ChatApproval.fetchOne(db, sql: """
                        SELECT * FROM approvals WHERE server = ? AND account_id = ? AND org_id = ? AND request_id = ? AND kind = 'initial'
                        """, arguments: [key.server.description, key.accountId, key.orgId, requestId])
                    // Ran here before the server was restored: Allow keeps
                    // that approval and its run — nothing runs again; once the
                    // server says approved, its facts and result are told from
                    // the journal (`recover`, review D4c-p1-1).
                    if let held {
                        // A void one never spent gives way to the new one, in this transaction.
                        if held.consumedAt == nil, held.voidAt != nil {
                            _ = try held.delete(db)
                            try approval.insert(db)
                        }
                    } else {
                        try approval.insert(db)
                    }
                }
                var args: [String: ChatJSON] = ["request_id": .string(requestId), "allow": .bool(allow)]
                if !allow {
                    let text = (reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    args["reason"] = .string(text.isEmpty ? "declined by the owner" : String(text.prefix(300)))
                }
                let received = try Self.told(db, key, order: order, type: "request.received")
                return [("request.decide", .object(args), order, received?.state == .pending ? received?.commandId : nil)]
            }
            return nil
        } catch {
            return "The decision could not be saved: \(error.localizedDescription)"
        }
    }

    // MARK: start

    /// `approved`/`starting` with an approval here: `run.start` first, and
    /// only once the server says `starting`, the launch — through
    /// `TeamLauncher`, the one way to run (D9) — when a slot is free (two
    /// per Mac, one per agent). Its end is told by the launcher.
    /// Tests: how many times `start` was handed over.
    private(set) var startTurns = 0

    private func start(_ request: ChatRequest, _ key: ChatOrgKey) async throws -> ChatActionResult {
        startTurns += 1
        guard let service, let journal = service.journal, let launcher = service.launcher,
              let approval = try journal.approval(key, requestId: request.requestId), approval.consumedAt == nil
        else { return .done }
        // Voided, never spent: done only once its `run.failed_to_start` is
        // stored — the debt of the void (review D4b-p1-3).
        if approval.voidAt != nil { return try failStart(request, key) }
        let order = ChatService.runKey(approval.runId)
        func startTold() throws -> ChatCommandRecord? { try journal.queue.read { db in try Self.told(db, key, order: order, type: "run.start") } }
        let started = try startTold()
        if started == nil {
            guard let connection = service.connection, connection.orgKey == key else { return .later }
            // The slot is taken before `run.start`: a second request of the
            // agent waits in `approved`, and starts after the first, in its
            // thread's conversation as it then is (F6).
            guard hasSlot(for: approval, launcher: launcher, key: key) else { return .later }
            if writeFails() { throw ChatError.storage("a write failed (test)") }
            var seq = try ChatCommandTable.maxSeq([journal.runCommands(key)] + (service.orgSessions[key]?.store.map { [$0.outbox] } ?? [])) + 1
            let args: ChatJSON = .object(["request_id": .string(request.requestId), "run_id": .string(approval.runId)])
            let bytes = try ChatCommandEnvelope(commandId: approval.startCommandId, org: key.orgId, type: "run.start", args: args).encoded()
            var record = ChatCommandRecord(commandId: approval.startCommandId, sessionId: connection.sessionId, type: "run.start",
                                           bodyBytes: bytes, orderKey: order, dependsOn: nil, createdAt: Date(), state: .pending)
            record.seq = seq
            seq += 1
            _ = try journal.runCommands(key).enqueue(record, seq: record.seq)
            service.factStored(key)
            return .later
        }
        // Started only once the server said so (DESIGN-D4 I2).
        guard request.state == .starting else { return .later }
        // No slot: woken when one is freed (the end of a run below).
        guard hasSlot(for: approval, launcher: launcher, key: key) else { return .later }
        launching[approval.id] = (approval.agentId, approval.runId)
        // Only a slot really held and freed wakes what waits for one; a
        // launch refused before it began does not — its own row waits for
        // its pause (review D4-p1-4, D4b-p1-2).
        var heldSlot = false
        defer {
            launching[approval.id] = nil
            if heldSlot { service.runner(for: key).run() }
        }
        do {
            _ = try await launcher.launch(approvalId: approval.id)
            heldSlot = true
        } catch TeamLauncher.Failure.voided {
            return try failStart(request, key)
        } catch TeamLauncher.Failure.blocked, TeamLauncher.Failure.generationChanging, TeamLauncher.Failure.closed,
                TeamLauncher.Failure.recoveryFailed {
            // Again after a pause, not at once (review D4-p1-4).
            return .retry
        } catch {
            // Spent: the run ended badly, its end told with its outcome. Not
            // spent (a write that failed before the process): again after a
            // pause, never taken for done (review D4-p1-3, p2-4).
            if try journal.approval(approval.id)?.consumedAt == nil { return .retry }
            heldSlot = true
        }
        return .done
    }

    /// Two server runs on this Mac, one per agent — counted here only (DESIGN-D4 §0.5).
    private func hasSlot(for approval: ChatApproval, launcher: TeamLauncher, key: ChatOrgKey) -> Bool {
        let held = Array(launching.values) + reserved(key, before: approval)
        return Self.slotFree(busy: Self.busy(launching: held, live: launcher.live.values.map { ($0.agentId, $0.runId) }), agentId: approval.agentId)
    }

    /// Runs whose `run.start` is told and not launched yet, of requests still
    /// `approved` or `starting`, allowed before `approval`: their slots are
    /// taken (F6). Only earlier ones count — among those waiting, the
    /// earliest goes first, so two kept over a restart never wait for each
    /// other (review D9-1).
    private func reserved(_ key: ChatOrgKey, before approval: ChatApproval) -> [(agentId: String, runId: String)] {
        guard let service, let journal = service.journal else { return [] }
        let rows = (try? journal.queue.read { db in
            try ChatApproval.fetchAll(db, sql: """
                SELECT * FROM approvals a WHERE a.server = ? AND a.account_id = ? AND a.org_id = ? AND a.kind = 'initial'
                    AND a.consumed_at IS NULL AND a.void_at IS NULL AND a.id != ?
                    AND (a.created_at < ? OR (a.created_at = ? AND a.id < ?))
                    AND EXISTS(SELECT 1 FROM run_commands c WHERE c.order_key = 'exec:run:' || a.run_id AND c.type = 'run.start'
                               AND c.state IN ('pending', 'sent'))
                """, arguments: [key.server.description, key.accountId, key.orgId, approval.id, approval.createdAt, approval.createdAt, approval.id])
        }) ?? []
        return rows.filter { ["approved", "starting"].contains(service.requestState(key, $0.requestId)) }.map { ($0.agentId, $0.runId) }
    }

    /// The agents of runs going on, each run once: a launch already live is
    /// counted as live (review D4-p1-5).
    static func busy(launching: [(agentId: String, runId: String)], live: [(agentId: String, runId: String)]) -> [String] {
        let liveRuns = Set(live.map(\.runId))
        return launching.filter { !liveRuns.contains($0.runId) }.map(\.agentId) + live.map(\.agentId)
    }

    /// A slot is free for `agentId` when `busy` (the agents of runs going on) allows it.
    static func slotFree(busy: [String], agentId: String) -> Bool {
        busy.count < TeamCalls.maxRunningPerMac && !busy.contains(agentId)
    }

    // MARK: fail_start

    /// `approved`/`starting` with no approval to run here — none, void, or
    /// this Mac's session no longer the executor: the approval is voided,
    /// never spent, and `run.failed_to_start` goes. While the server refuses
    /// it (the earlier session still open: `403`) the action waits, kept in
    /// progress in the cache, and sends it again at the next connection's
    /// turn and at launch (DESIGN-D4 §0.3, review D4b-3).
    private func failStart(_ request: ChatRequest, _ key: ChatOrgKey) throws -> ChatActionResult {
        guard let service, let journal = service.journal else { return .later }
        let approval = try journal.approval(key, requestId: request.requestId)
        var reason = "no_local_approval"
        if let approval {
            if let void = approval.voidReason {
                reason = void
            } else if approval.consumedAt == nil {
                reason = request.onThisDevice ? "no_local_approval" : "executor_signed_out"
                try journal.void(approval.id, reason: reason)
            }
        }
        let order = approval.map { ChatService.runKey($0.runId) } ?? ChatService.requestKey(request.requestId)
        func current() throws -> (told: ChatCommandRecord?, last: ChatCommandRecord?) { try journal.queue.read { db in
            let last = try ChatCommandRecord.fetchAll(db, sql: """
                SELECT * FROM run_commands WHERE server = ? AND account_id = ? AND org_id = ? AND order_key = ? AND type = 'run.failed_to_start'
                ORDER BY seq, rowid
                """, arguments: [key.server.description, key.accountId, key.orgId, order]).last
            return (try Self.told(db, key, order: order, type: "run.failed_to_start"), last)
        } }
        // On its way or taken by this generation: wait for the server's word.
        // Unconfirmed, or taken by an earlier one: made anew (review D4-p2-2).
        let (told, last) = try current()
        if told != nil { return .later }
        if let last, last.state == .failed {
            if last.error != "forbidden" { return .failed(last.error ?? "refused") }
            // Refused while the earlier session is open: sent again after a pause.
            if !mayResend(last) { return .retry }
        }
        try store(key) { db in
            try Self.supersede(db, key, order: order, type: "run.failed_to_start")
            var args: [String: ChatJSON] = ["request_id": .string(request.requestId), "reason": .string(reason)]
            if let approval { args["run_id"] = .string(approval.runId) }
            return [("run.failed_to_start", .object(args), order, nil)]
        }
        return .later
    }

    // MARK: stop (D4b)

    /// `stop_requested` for a run of this Mac (DESIGN-D3b-D4b-D5b §2.1, §10.1–10.2):
    /// before its process, it never starts and `run.stopped` goes; while it
    /// runs, it is stopped and Y5's outcome told; a run that answered
    /// meanwhile tells its end.
    private func stop(_ request: ChatRequest, _ key: ChatOrgKey) async throws -> ChatActionResult {
        guard let service, let journal = service.journal, let launcher = service.launcher,
              let approval = try journal.approval(key, requestId: request.requestId)
        else { return .done }
        if writeFails() { throw ChatError.storage("a write failed (test)") }
        guard let run = try journal.run(approval.runId) else {
            // Spent meanwhile: the run began; its turn comes again.
            return try service.stopUnstarted(approval, key: key) ? .done : .retry
        }
        if run.outcome != nil { return .done }
        if let outcome = try await launcher.stopForServer(run.runId) {
            if let reason = outcome.stopFailedReason {
                try service.tellStopFailed(run, reason: reason)
            } else {
                guard TeamLauncher.finish(run, .stoppedLocally, reason: "stopped_by_owner", journal: journal, facts: service, at: Date()) else { return .retry }
            }
            return .done
        }
        // Not live: stopped by an earlier turn whose fact was not written,
        // or ended by itself (its end told by the launcher).
        if let now = try journal.run(run.runId), now.outcome == nil, now.stopReason != nil, launcher.live[run.runId] == nil {
            if now.stopConfirmedAt != nil {
                guard TeamLauncher.finish(now, .stoppedLocally, reason: "stopped_by_owner", journal: journal, facts: service, at: Date()) else { return .retry }
            } else {
                try service.tellStopFailed(now, reason: now.preflightPID == nil ? "processes_unknown" : "preflight_cleanup_unconfirmed")
            }
        }
        return .done
    }

    // MARK: deliver, recover

    /// The run's chain completed for the server's state now; a run without
    /// its outcome is D11's: its processes are checked first.
    private func tell(_ kind: ChatActionKind, _ request: ChatRequest, _ key: ChatOrgKey) async throws -> ChatActionResult {
        guard let service, let journal = service.journal,
              let approval = try journal.approval(key, requestId: request.requestId), let run = try journal.run(approval.runId)
        else { return .done }
        if run.outcome == nil {
            // Being stopped, its stop not confirmed: that is what it owes (review D4b-p1-3).
            if request.state == .stopRequested, run.stopReason != nil, run.stopConfirmedAt == nil, run.processesGoneAt == nil {
                switch try service.tellStopFailed(run, reason: run.preflightPID == nil ? "processes_unknown" : "preflight_cleanup_unconfirmed", mayResend: mayResend) {
                case .told: return .done
                case .waiting: return .later
                case .paused: return .retry
                }
            }
            if let recovery = service.recovery, case .failure = await recovery.check() { return .retry }
            // A successful check may still owe the atomic outcome/fact
            // write. Keep that debt on the runner's timed retry; once the
            // outcome exists, check the fact chain below as well.
            guard let recovered = try journal.run(run.runId) else { return .retry }
            if recovered.outcome == nil {
                return recovered.processesGoneAt != nil ? .retry : .later
            }
        }
        if writeFails() { throw ChatError.storage("a write failed (test)") }
        // Owed until the server has the chain: a step refused is sent again
        // after its pause, a refused delivery stays owed (review D4b-p2-1).
        switch try service.tellRun(run.runId, mayResend: mayResend) {
        case .told: return .done
        case .waiting: return .later
        case .paused: return .retry
        }
    }

    /// Refused commands seen once: the next sight, after the runner's
    /// pause, makes them anew — one resend per pause (review D4b-p1-2).
    private var seenRefused: Set<String> = []
    private func mayResend(_ refused: ChatCommandRecord) -> Bool {
        seenRefused.insert(refused.commandId).inserted == false
    }
}
