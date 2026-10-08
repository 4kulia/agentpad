import Foundation

/// Facts the executor owes the server about a run (D4, D11): one chain,
/// stored by the journal in the same transaction as the run's outcome
/// (review C2-18, DESIGN-D4 §0.2).
@MainActor
protocol TeamRunFacts: AnyObject {
    /// Writes `run`'s outcome — with its full result — and the chain of
    /// facts the server lacks for it, in `journal`, in one transaction; none
    /// for a request the server no longer has (`lost`). The server's state
    /// not known: the outcome alone (`recover` tells the end later) — or,
    /// `waitForState`, nothing (a run recovered after the app ended waits,
    /// review C8-4). Throws when it cannot be written: then neither is
    /// (review C3-11). True when written.
    func end(_ run: ChatRunRecord, outcome: ChatRunRecord.Outcome, reason: String, result: String?, at: Date,
             journal: ChatJournal, waitForState: Bool, diagnosis: ClaudeLaunchDiagnostic.Failure?) throws -> Bool
    /// The run's process exists: `run.started` (and what it needs) goes.
    func processStarted(_ run: ChatRunRecord)
    /// A fact was stored: the queue sends it when it can.
    func factStored(_ key: ChatOrgKey)
    /// The server's generation and the request's state are known now, so the
    /// fact for a run recovered after the app ended can be chosen (review C5-7).
    func canChooseFact(for run: ChatRunRecord) -> Bool
}

/// The only way a server-mode request reaches `TeamAgentRunner.run`
/// (6.8, D9). It starts a run only from an approval the owner made, only
/// once, and only with the parameters saved in it.
@MainActor
final class TeamLauncher {
    enum Failure: Error, Equatable, LocalizedError {
        case unknownApproval
        /// Spent already, or being spent now.
        case alreadyUsed
        /// Void, with the reason sent in `run.failed_to_start`:
        /// `expired`, `not_assigned`, `server_restored`, `params_changed`.
        case voided(String)
        /// An earlier run of this agent could not be confirmed stopped; the
        /// approval stays valid (D11).
        case blocked(agentId: String, pid: Int32?)
        /// The process was never created.
        case didNotStart(String)
        /// Runs are closed: Disconnect is stopping them (review C2-16).
        case closed
        /// The server generation is changing; the approval waits (review C3-3).
        case generationChanging
        /// The runs left from before could not be checked (the journal could
        /// not be read): nothing starts until they can (review C6-7).
        case recoveryFailed(String)

        var errorDescription: String? {
            switch self {
            case .recoveryFailed(let detail): "The earlier runs on this Mac could not be checked: \(detail)"
            case .unknownApproval: "No such approval on this Mac."
            case .alreadyUsed: "This approval was used already."
            case .voided(let reason): "The approval is void: \(reason)."
            case .blocked(_, let pid): "An earlier run of this agent could not be stopped\(pid.map { " (PID \($0))" } ?? "")."
            case .didNotStart(let detail): "The agent did not start: \(detail)"
            case .closed: "Runs are stopping on this Mac."
            case .generationChanging: "The server was restored; runs wait until this Mac caught up."
            }
        }
    }

    struct LiveRun {
        let runId: String
        let agentId: String
        let task: Task<Void, Never>
        var process: TeamProcessStart?
    }

    let journal: ChatJournal
    private let runner: TeamAgentRunner
    /// The agent as `agents.json` has it now; nil when it is gone.
    var agent: @MainActor (String) -> TeamPublishedAgent? = { _ in nil }
    /// The request as the cache has it now (D8).
    var request: @MainActor (String) -> TeamLaunchRequest? = { _ in nil }
    /// A server stop/final state learned while Y2 waits forbids execution,
    /// even before its stop action has had a turn to cancel the task.
    var requestCanExecute: @MainActor (String) -> Bool = { _ in true }
    /// The server generation of the organization now and a change of it
    /// under way, read together; a failure says nothing (review C7-8).
    var generationState: @MainActor (ChatOrgKey) throws -> (generation: String?, pending: String?) = { _ in (nil, nil) }
    var logURL: (String) -> URL? = { _ in nil }
    var now: () -> Date = Date.init
    /// Checks unfinished runs before each launch (D11).
    var recovery: TeamRunRecovery?
    weak var facts: TeamRunFacts?
    /// The processes of a run whose stop was not confirmed (the runner left it
    /// registered); nil when they are confirmed gone. Replaced in tests.
    var processesLeft: (TeamProcessStart) -> TeamPidSet? = { TeamProcesses.shared.seen(of: $0) }

    private(set) var live: [String: LiveRun] = [:]
    /// Runs the stopper asked to end: their outcome is `stopped_locally`.
    private var stopping: Set<String> = []
    /// Runs stopped because the server asked (`stop_requested`): the outcome
    /// of the stop is the caller's to tell (`stopForServer`), not written here.
    private var serverStopping: Set<String> = []
    private var stopOutcomes: [String: TeamStopOutcome] = [:]
    /// The conversation a thread goes on in, chosen at the start: its latest
    /// finished run's here; nil starts the approval's own (F6, D9).
    var threadConversation: @MainActor (ChatApproval) -> String? = { _ in nil }
    var resolveChannelConversation: @MainActor (String) -> String? = {
        try? ClaudeSessionResume.resolve($0, visibility: .init(channelIds: [])).get()
    }
    /// The session of this Mac now; an approval of another is not spent (review D4b-p1-1).
    var currentSession: @MainActor () -> String? = { nil }
    /// What a run does now (a tool's name), for its caller (D4b §2.4).
    var onActivity: @MainActor (ChatRunRecord, String) -> Void = { _, _ in }
    /// Runs whose ending (outcome, facts) is not written yet, and who waits for it.
    private var ending: Set<String> = []
    private var endWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var launching: Set<String> = []
    /// False from the start of Disconnect until the next start (review C2-16).
    private(set) var accepting = true

    init(journal: ChatJournal, runner: TeamAgentRunner) {
        self.journal = journal
        self.runner = runner
    }

    var prepareAttachmentFiles: @MainActor (TeamLaunchParams, ChatRunRecord) async throws -> ChatAttachmentCallFiles? = { params, _ in
        if params.inputs.attachments?.isEmpty == false { throw ChatAttachmentError.unavailable }; return nil
    }
    var verifyAttachmentFiles: @MainActor (ChatAttachmentCallFiles) async throws -> Void = { _ in throw ChatAttachmentError.unavailable }

    func isLive(_ runId: String) -> Bool { live[runId] != nil }

    /// No new run from now on; those accepted already go on until stopped.
    func close() { accepting = false }
    func open() { accepting = true }
    /// Launches past their checks but not yet live.
    var pendingLaunches: Int { launching.count }

    /// Checks the approval and starts its run; returns the answer.
    func launch(approvalId: String) async throws -> TeamRunResult {
        guard accepting else { throw Failure.closed }
        // Runs an earlier app left are checked first; everything about the
        // approval is checked after it, with nothing awaited until it is
        // spent (review C5-6). A check that could not be made refuses (review C6-7).
        if let recovery, case .failure(let error) = await recovery.check() { throw Failure.recoveryFailed(error.localizedDescription) }

        guard accepting else { throw Failure.closed }
        guard let approval = try journal.approval(approvalId) else { throw Failure.unknownApproval }
        if let reason = approval.voidReason { throw Failure.voided(reason) }
        guard approval.consumedAt == nil, !launching.contains(approvalId) else { throw Failure.alreadyUsed }
        // Not known, or changing: the approval waits (review C3-3, C7-8).
        let kept = approval.key.flatMap { try? generationState($0) }
        if approval.key != nil, kept == nil || kept?.pending != nil { throw Failure.generationChanging }
        var params = try TeamLaunchParams.decode(approval.params)
        guard let key = approval.key, let kept else { throw try void(approval, "params_changed") }

        // In order: the request's time, the assignment, the generation, the
        // parameters. The time is the request's as it stands now (review C2-13).
        let current = request(approval.requestId)
        if now() >= (current?.expiresAt ?? params.expiresAt) { throw try void(approval, "expired") }
        guard let assignment = try journal.assignment(key, agentId: approval.agentId), assignment.state == .active else {
            throw try void(approval, "not_assigned")
        }
        guard kept.generation == approval.generation else { throw try void(approval, "server_restored") }
        // Allowed under another session of this Mac — whichever way the
        // sign-in in between came: not run (review D4b-p1-1).
        guard params.session == currentSession() else { throw try void(approval, "executor_signed_out") }
        // What colleagues were shown — the name, description and rights the
        // server accepted — is what runs: a change not published refuses (D3).
        guard TeamLaunchParams.hash(Data(approval.params.utf8)) == approval.paramsHash,
              let agentNow = agent(approval.agentId), let current, assignment.accepted.matches(agentNow),
              TeamLaunchInputs(agent: agentNow, request: current) == params.inputs,
              current.channelId == params.channelId, current.threadRootId == params.threadRootId
        else { throw try void(approval, "params_changed") }

        do { try ChatAttachmentStorage.checkFolders([params.inputs.folder] + params.inputs.extraFolders + (params.grantedFolders ?? [])) }
        catch { throw try void(approval, error.localizedDescription) }

        // An earlier run of this agent whose processes are not confirmed gone
        // blocks it — from the journal, or left over in this app in any mode (review C7-11).
        let blocking = try recovery?.stuck ?? journal.unfinishedRuns().filter { $0.processesGoneAt == nil }
        if let stuck = blocking.first(where: { $0.agentId == approval.agentId && !isLive($0.runId) }) {
            throw Failure.blocked(agentId: approval.agentId, pid: stuck.pid)
        }
        if TeamProcesses.shared.blocks(agentId: approval.agentId) { throw Failure.blocked(agentId: approval.agentId, pid: nil) }

        launching.insert(approvalId)
        defer { launching.remove(approvalId) }
        // The thread's conversation, chosen now and written with the row
        // before any process: two Allows of one thread are alike, the later
        // run goes on in the earlier's conversation (F6, D9).
        if params.inputs.thread != nil, let conversation = threadConversation(approval) {
            if params.channelId == nil {
                params.conversationId = conversation
                params.resumes = true
            } else if let found = resolveChannelConversation(conversation) {
                params.conversationId = found
                params.resumes = true
            } else {
                params.conversationRestarted = true
            }
        }
        let row = ChatRunRecord(
            runId: params.runId, requestId: approval.requestId, approvalId: approval.id, agentId: approval.agentId,
            conversationId: params.conversationId, startedAt: now(), kind: params.channelId == nil ? "personal" : "channel",
            org: approval.orgId, channelId: params.channelId, threadRootId: params.threadRootId
        )
        // Spent and "starting" on disk before the process exists.
        guard try journal.consume(approval, run: row, at: now()) else { throw Failure.alreadyUsed }
        return try await run(params, row: row)
    }

    /// The run's continuation, checked as a launch is (D9: the request's
    /// time, the assignment, the generation, the parameters) and spent;
    /// nil when there is none, or it is refused (then voided).
    /// A continuation of a run: none granted, granted and spent now, or
    /// granted and refused (its check failed) — then the run fails with why,
    /// never ends with the reply it gave while waiting (review D4b-p2-5).
    enum Continuation {
        case none
        case go(TeamLaunchParams)
        case refused(String)
    }

    private func continuation(of row: ChatRunRecord, params initial: TeamLaunchParams) throws -> Continuation {
        guard let first = try journal.approval(row.approvalId), let approval = try journal.latestContinuation(of: first),
              approval.consumedAt == nil else { return .none }
        // Promised and voided meanwhile (a new session, a new generation): refused.
        if let reason = approval.voidReason { return .refused(reason) }
        guard let key = approval.key else { return .refused("not_found") }
        let params = try TeamLaunchParams.decode(approval.params)
        guard params.runId == row.runId, params.inputs == initial.inputs else {
            _ = try void(approval, "params_changed")
            return .refused("params_changed")
        }
        let current = request(approval.requestId)
        if now() >= (current?.expiresAt ?? params.expiresAt) {
            _ = try void(approval, "expired")
            return .refused("expired")
        }
        guard let assignment = try journal.assignment(key, agentId: approval.agentId), assignment.state == .active else {
            _ = try void(approval, "not_assigned")
            return .refused("not_assigned")
        }
        guard let kept = try? generationState(key), kept.pending == nil, kept.generation == approval.generation else {
            _ = try void(approval, "server_restored")
            return .refused("server_restored")
        }
        guard params.session == currentSession() else {
            _ = try void(approval, "executor_signed_out")
            return .refused("executor_signed_out")
        }
        guard let agentNow = agent(approval.agentId), let current, assignment.accepted.matches(agentNow),
              TeamLaunchInputs(agent: agentNow, request: current) == params.inputs,
              current.channelId == params.channelId, current.threadRootId == params.threadRootId
        else {
            _ = try void(approval, "params_changed")
            return .refused("params_changed")
        }
        guard try journal.consumeContinuation(approval, runId: row.runId, at: now()) else { return .refused("already_used") }
        // Its run's conversation, as chosen at the start — no new search (F6).
        var next = params
        next.conversationId = row.conversationId
        next.resumes = true
        next.conversationRestarted = initial.conversationRestarted
        return .go(next)
    }

    private func void(_ approval: ChatApproval, _ reason: String) throws -> Failure {
        try journal.void(approval.id, reason: reason, at: now())
        return .voided(reason)
    }

    private func run(_ params: TeamLaunchParams, row: ChatRunRecord) async throws -> TeamRunResult {
        let runner = self.runner
        let journal = self.journal
        let runId = row.runId
        var request: TeamRunRequest
        var attachmentFiles: ChatAttachmentCallFiles?
        defer { attachmentFiles?.remove() }
        do {
            request = try params.runRequest(logURL: logURL(runId))
            attachmentFiles = try await prepareAttachmentFiles(params, row)
            try attachmentFiles?.apply(to: &request)
        } catch {
            ended(row, params.segment == nil ? .didNotStart : .failed, reason: error.localizedDescription, result: nil)
            throw error
        }
        let selectedFiles = attachmentFiles
        request.validateBeforeExecutor = { [weak self] in
            guard let self else { throw TeamRunnerError.didNotStart("executor_unavailable") }
            try self.validateWaitingSegment(params, row: row)
        }
        request.validateAttachmentFiles = { [weak self] in
            guard let self else { throw ChatAttachmentError.unavailable }
            if let selectedFiles { try await self.verifyAttachmentFiles(selectedFiles) }
            try self.validateWaitingSegment(params, row: row)
        }
        request.onPreflightProcess = { start in try journal.recordPreflightProcess(runId, start) }
        var outcome: Result<TeamRunResult, Error> = .failure(CancellationError())
        let started = TeamStartBox()
        let task = Task { [weak self] in
            do {
                var answer = try await runner.run(request, onActivity: { text in
                    Task { @MainActor in self?.onActivity(row, text) }
                }, onProcessStarted: { start in
                    // On disk before it runs; when it cannot be, it does not run (D11).
                    try journal.recordProcess(runId, start)
                    started.set(start)
                    Task { @MainActor in
                        self?.live[runId]?.process = start
                        self?.facts?.processStarted(row)
                    }
                })
                if params.conversationRestarted == true, !answer.isError {
                    answer.text += "\n\nstarted anew: the earlier conversation was not found."
                }
                outcome = .success(answer)
            } catch {
                outcome = .failure(error)
            }
        }
        live[runId] = LiveRun(runId: runId, agentId: row.agentId, task: task)
        ending.insert(runId)
        defer {
            ending.remove(runId)
            endWaiters.removeValue(forKey: runId)?.forEach { $0.resume() }
        }
        await task.value
        live[runId] = nil
        let cancelledBeforeExecutor: Bool
        if case .failure(let error) = outcome { cancelledBeforeExecutor = error as? TeamRunnerError == .cancelledBeforeExecutor }
        else { cancelledBeforeExecutor = false }
        let stopped = stopping.remove(runId) != nil || cancelledBeforeExecutor
        // An unconfirmed service process is not a failed-to-start fact. Its
        // separate identity survives a crash and keeps the agent blocked.
        if case .failure(let error) = outcome,
           case .preflightCleanupUnconfirmed(let service, _) = error as? TeamRunnerError {
            try journal.recordPreflightProcess(runId, service)
            try journal.markStopping(runId, reason: "preflight_cleanup_unconfirmed")
            if serverStopping.remove(runId) != nil {
                stopOutcomes[runId] = .unknown("preflight_cleanup_unconfirmed")
            }
            throw error
        }
        // Stopped for the server: unless it answered by itself, the stop's
        // outcome goes back to whoever asked, and the row stays open, being
        // stopped — never written as stopped on a guess (DESIGN-D3b-D4b-D5b §10.1).
        if serverStopping.remove(runId) != nil {
            if case .success(let answer) = outcome, !answer.isError {
                ended(row, .finished, reason: "", result: answer.text)
                return answer
            }
            let stop = Self.stopOutcome(outcome)
            stopOutcomes[runId] = stop
            switch outcome {
            case .success(let answer): return answer
            case .failure(let error): throw error
            }
        }
        // A local stop uses the same Y5 verdict. Without confirmation the
        // row stays open for recovery; an answer racing the stop still wins.
        if stopped, !{ if case .success(let answer) = outcome { return !answer.isError } else { return false } }() {
            let confirmed = Self.stopOutcome(outcome) == .stopped
            try journal.markStopping(runId, reason: "stopped_by_owner", confirmed: confirmed)
            if confirmed { finish(row, .stoppedLocally, reason: "stopped_by_owner") }
            switch outcome {
            case .success(let answer): return answer
            case .failure(let error): throw error
            }
        }
        // The outcome is final only once its processes are confirmed gone;
        // otherwise the row stays open with them, for recovery (review C2-17, C6-3).
        if let process = started.get(), processesLeft(process) != nil {
            switch outcome {
            case .success(let answer): return answer
            case .failure(let error): throw error
            }
        }
        // Folders granted during the run: the same run goes on with them
        // under its continuation record, once each (D4b §2.5).
        if case .success(let answer) = outcome, !stopped, !answer.isError {
            switch (try? continuation(of: row, params: params)) ?? .refused("the continuation could not be read") {
            case .go(let next): return try await run(next, row: row)
            case .refused(let why):
                ended(row, .failed, reason: "The folder was granted, but the run could not go on (\(why)).", result: nil)
                return answer
            case .none: break
            }
        }
        switch outcome {
        case .success(let answer):
            if answer.isError {
                ended(row, .failed, reason: "The agent's run ended with an error.", result: nil)
            } else {
                ended(row, .finished, reason: "", result: answer.text)
            }
            return answer
        case .failure(let error):
            let diagnosis = (error as? TeamRunnerError)?.diagnosis
            if let notStarted = Self.notStarted(error) {
                // Only the first segment did not start; a continuation that
                // could not is a run that failed (review D4b2-3).
                if params.segment != nil {
                    ended(row, .failed, reason: notStarted, result: nil, diagnosis: diagnosis)
                    throw error
                }
                ended(row, .didNotStart, reason: notStarted, result: nil, diagnosis: diagnosis)
                throw Failure.didNotStart(notStarted)
            } else {
                ended(row, .failed, reason: error.localizedDescription, result: nil, diagnosis: diagnosis)
            }
            throw error
        }
    }

    /// A run that ended by itself: its outcome, its result and the chain of
    /// its facts in one transaction (D4); without facts, the outcome alone.
    private func ended(_ row: ChatRunRecord, _ outcome: ChatRunRecord.Outcome, reason: String, result: String?, diagnosis: ClaudeLaunchDiagnostic.Failure? = nil) {
        if let facts {
            _ = try? facts.end(row, outcome: outcome, reason: reason, result: result, at: now(), journal: journal, waitForState: false, diagnosis: diagnosis)
        } else {
            _ = try? journal.finish(row.runId, outcome, at: now(), result: result, diagnosis: diagnosis)
        }
    }

    /// The outcome and its fact, together; neither when the fact cannot be
    /// made (the row stays open for recovery). True when written.
    @discardableResult
    func finish(_ row: ChatRunRecord, _ outcome: ChatRunRecord.Outcome, reason: String) -> Bool {
        Self.finish(row, outcome, reason: reason, journal: journal, facts: facts, at: now())
    }

    ///
    /// Called only with the run's processes confirmed gone. Every final fact
    /// waits until the server's state of the request is known (review C7-9):
    /// meanwhile the row keeps "processes gone" (and, for a local stop, why)
    /// and recovery writes the outcome and fact later.
    static func finish(_ row: ChatRunRecord, _ outcome: ChatRunRecord.Outcome, reason: String, journal: ChatJournal,
                       facts: TeamRunFacts?, at: Date = Date()) -> Bool {
        func wait() -> Bool {
            if outcome == .stoppedLocally { try? journal.markStopping(row.runId, reason: reason) }
            try? journal.markProcessesGone(row.runId, at: at)
            return false
        }
        if let facts, !facts.canChooseFact(for: row) { return wait() }
        let current = ((try? journal.run(row.runId)) ?? nil) ?? row
        if let facts {
            // Made from what it reads itself; not made — the row waits (review C8-4).
            do { return try facts.end(current, outcome: outcome, reason: reason, result: nil, at: at, journal: journal, waitForState: true, diagnosis: current.launchFailure) } catch {
                return wait()
            }
        }
        return (try? journal.finish(row.runId, outcome, at: at)) == true
    }

    private static func stopOutcome(_ result: Result<TeamRunResult, Error>) -> TeamStopOutcome {
        // A positive runner verdict, never an inference from a missing PID.
        if case .failure(let error) = result, error as? TeamRunnerError == .cancelledBeforeExecutor { return .stopped }
        if case .failure(let error) = result, case .stopped(let outcome) = error as? TeamRunnerError { return outcome }
        return .unknown("the runner did not report the stop's outcome")
    }

    /// D9 remains spent while Y2 waits, but its terms, time and authority
    /// remain binding. No second approval or journal run is created here.
    private func validateWaitingSegment(_ params: TeamLaunchParams, row: ChatRunRecord) throws {
        func refuse(_ reason: String) throws -> Never { throw TeamRunnerError.didNotStart(reason) }
        guard accepting, let approval = try journal.approval(row.approvalId), approval.kind == "initial",
              approval.consumedAt != nil, approval.voidReason == nil,
              let savedRun = try journal.run(row.runId), savedRun.outcome == nil else { try refuse("approval_void") }
        guard let current = request(row.requestId) else { try refuse("params_changed") }
        guard requestCanExecute(row.requestId) else { throw TeamRunnerError.cancelledBeforeExecutor }
        if now() >= min(current.expiresAt, params.expiresAt) { try refuse("expired") }
        guard let key = approval.key, let assignment = try journal.assignment(key, agentId: row.agentId),
              assignment.state == .active else { try refuse("not_assigned") }
        guard let kept = try? generationState(key), kept.pending == nil, kept.generation == params.generation else {
            try refuse("server_restored")
        }
        guard params.session == currentSession() else { try refuse("executor_signed_out") }
        guard let agentNow = agent(row.agentId), assignment.accepted.matches(agentNow),
              TeamLaunchInputs(agent: agentNow, request: current) == params.inputs,
              current.channelId == params.channelId, current.threadRootId == params.threadRootId else { try refuse("params_changed") }
        try ChatAttachmentStorage.checkFolders([params.inputs.folder] + params.inputs.extraFolders + (params.grantedFolders ?? []))
        if params.segment != nil {
            guard let continuation = try journal.latestContinuation(of: approval), continuation.consumedAt != nil,
                  continuation.voidReason == nil,
                  try TeamLaunchParams.decode(continuation.params).segment == params.segment else { try refuse("approval_void") }
        }
    }

    private static func notStarted(_ error: Error) -> String? {
        switch error as? TeamRunnerError {
        case .didNotStart(let detail, _): detail
        case .claudeNotFound: TeamRunnerError.claudeNotFound.localizedDescription
        default: nil
        }
    }

    /// Stops a live run because the server asked: its outcome is the
    /// stop's, to be told as a fact; nil when it was not live, or answered
    /// by itself meanwhile (its end told as any).
    func stopForServer(_ runId: String) async throws -> TeamStopOutcome? {
        if live[runId] != nil {
            serverStopping.insert(runId)
            _ = await stop(runId)
            // Its ending written first: the outcome, or its own end.
            if ending.contains(runId) { await withCheckedContinuation { endWaiters[runId, default: []].append($0) } }
        }
        guard let outcome = stopOutcomes[runId] else { return nil }
        // Persist before handing it to the caller. A failed write keeps the
        // actual verdict for the stop action's next attempt, even though the
        // process is no longer live.
        try journal.markStopping(runId, reason: "stopped_by_owner", confirmed: outcome == .stopped)
        stopOutcomes.removeValue(forKey: runId)
        return outcome
    }

    /// Ends a live run for the stopper: its outcome is `stopped_locally`
    /// once its group is confirmed gone.
    func stop(_ runId: String) async -> LiveRun? {
        guard let run = live[runId] else { return nil }
        stopping.insert(runId)
        run.task.cancel()
        await run.task.value
        return run
    }
}

extension TeamStopOutcome {
    /// The `reason` of `run.stop_failed`.
    var stopFailedReason: String? {
        switch self {
        case .stopped: nil
        case .stillAlive: "processes_alive"
        case .unknown(let reason): reason == "preflight_cleanup_unconfirmed" ? reason : "processes_unknown"
        }
    }
}

/// What the runner reported about the process, readable after the run.
final class TeamStartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var start: TeamProcessStart?
    func set(_ value: TeamProcessStart) { lock.withLock { start = value } }
    func get() -> TeamProcessStart? { lock.withLock { start } }
}

/// Runs left without an outcome (6.8, D11; manual after the seventh client
/// review, narrowed after the ninth). AgentPad stops nothing by itself here
/// and sends no signal: a row whose processes are not confirmed gone blocks
/// its agent, and the Team window shows its recorded leader — by PID and start
/// time, written before the process went on — with what this app saw under
/// it, and offers "Stop These Processes" (the leader and its group, and what
/// was seen, each confirmed at the press) and "They Are Gone" (checked again
/// first; refused while any is seen). A row without a recorded leader cannot
/// be looked at: the owner is asked to check. Once its processes are
/// confirmed gone, the outcome and fact wait for the server's state of the request.
@MainActor
@Observable
final class TeamRunRecovery {
    /// A run whose processes are not confirmed gone.
    struct Blocked: Identifiable, Equatable {
        let run: ChatRunRecord
        let leader: TeamProcessStart?
        /// Its processes found now; nil when they could not be looked for.
        let found: [ProcessIdentity]?
        var id: String { run.runId }
        var agentId: String { run.agentId }
    }

    let journal: ChatJournal
    private let isLive: (String) -> Bool
    weak var facts: TeamRunFacts?
    /// What blocks agents now.
    private(set) var blocked: [Blocked] = []
    /// Journal rows that block their agents.
    var stuck: [ChatRunRecord] { blocked.map(\.run) }
    /// Rows whose processes are confirmed gone, waiting for the server to be
    /// known before their outcome and fact.
    private(set) var awaitingFact: [ChatRunRecord] = []
    /// Why the last check could not be made (the journal could not be read).
    private(set) var problem: String?
    /// Looks for a blocked run's live processes; nil when that cannot be told
    /// (a read that failed, or no leader recorded). Replaced in tests.
    var find: (TeamProcessStart?) -> [ProcessIdentity]? = { TeamRunRecovery.processes(leader: $0) }
    /// How long "Stop These Processes" waits after SIGTERM before SIGKILL.
    var stopGrace: Duration = .seconds(5)
    private var checking: Task<Result<Void, Error>, Never>?

    init(journal: ChatJournal, isLive: @escaping (String) -> Bool) {
        self.journal = journal
        self.isLive = isLive
    }

    /// At start, before each launch, when the server becomes known, and on
    /// "Check Again"; one at a time. A failure means the journal could not be
    /// read: nothing was checked, nothing may start.
    @discardableResult
    func check() async -> Result<Void, Error> {
        let previous = checking
        let task = Task {
            _ = await previous?.value
            return self.checkNow()
        }
        checking = task
        return await task.value
    }

    private func checkNow() -> Result<Void, Error> {
        let rows: [ChatRunRecord]
        do { rows = try journal.unfinishedRuns() } catch {
            problem = error.localizedDescription
            return .failure(error)
        }
        problem = nil
        var nowBlocked: [Blocked] = []
        var waiting: [ChatRunRecord] = []
        for run in rows where !isLive(run.runId) {
            guard run.processesGoneAt != nil else {
                let leader = Self.leader(of: run)
                nowBlocked.append(Blocked(run: run, leader: leader, found: find(leader)))
                continue
            }
            // A quit that was stopping it says why; else the app restarted.
            let outcome: ChatRunRecord.Outcome = run.stopReason == nil ? .executorRestarted : .stoppedLocally
            let reason = run.stopReason ?? "executor_restarted"
            if !TeamLauncher.finish(run, outcome, reason: reason, journal: journal, facts: facts) { waiting.append(run) }
        }
        blocked = nowBlocked
        awaitingFact = waiting
        return .success(())
    }

    private static func leader(of run: ChatRunRecord) -> TeamProcessStart? {
        if let pid = run.preflightPID, pid > 1, let start = run.preflightStartedAt {
            return TeamProcessStart(pid: pid, pgid: run.preflightPGID ?? pid, startTime: start)
        }
        guard let pid = run.pid, pid > 1, let start = run.processStartedAt else { return nil }
        return TeamProcessStart(pid: pid, pgid: run.pgid ?? pid, startTime: start)
    }

    /// "Stop These Processes": SIGTERM to what was shown and is found again
    /// now as the same processes — the leader with its group while it is
    /// confirmed, the others by identity — then SIGKILL to those still there
    /// after the grace. Nil when sent; else why not.
    func stopProcesses(_ id: String) async -> String? {
        guard let item = blocked.first(where: { $0.id == id }) else { return nil }
        guard let found = find(item.leader) else { return "AgentPad cannot look for its processes." }
        let shown = Set(item.found ?? [])
        let targets = found.filter(shown.contains)
        let leader = item.leader.flatMap { targets.contains($0.identity) ? $0 : nil } ?? TeamProcessStart(pid: 0, pgid: 0, startTime: 0)
        let others = TeamPidSet(targets.filter { $0 != leader.identity })
        let grace = stopGrace
        await Task.detached {
            TeamProcesses.signal(leader, SIGTERM, also: others)
            let deadline = ContinuousClock.now + grace
            while ContinuousClock.now < deadline, TeamProcesses.liveness(leader, also: others) == .alive {
                try? await Task.sleep(for: .milliseconds(100))
            }
            TeamProcesses.signal(leader, SIGKILL, also: others)
        }.value
        await check()
        return nil
    }

    /// "They Are Gone": the owner says the run's processes are gone. Checked
    /// again first; refused while any is seen or a read fails. A run without
    /// a recorded leader is the owner's word alone.
    func confirmGone(_ id: String) async -> String? {
        guard let item = blocked.first(where: { $0.id == id }) else { return nil }
        if item.leader != nil {
            guard let found = find(item.leader) else { return "AgentPad could not look for its processes; try again." }
            guard found.isEmpty else {
                return "Still running: PID " + found.map { String($0.pid) }.sorted().joined(separator: ", ") + "."
            }
        }
        do { try journal.markProcessesGone(item.run.runId) } catch { return error.localizedDescription }
        if let leader = item.leader { TeamProcesses.shared.remove(leader) }
        await check()
        return nil
    }

    /// The live processes of a run's recorded leader: the leader alive as
    /// itself and what this app saw under it. Nil when there is no leader to
    /// look for or a read failed.
    static func processes(leader: TeamProcessStart?) -> [ProcessIdentity]? {
        guard let leader else { return nil }
        var found: Set<ProcessIdentity> = []
        switch TeamProcesses.liveness(leader.identity) {
        case .unknown: return nil
        case .alive: found.insert(leader.identity)
        case .gone: break
        }
        for identity in TeamProcesses.shared.seen(of: leader)?.identities ?? [] {
            switch TeamProcesses.liveness(identity) {
            case .unknown: return nil
            case .alive: found.insert(identity)
            case .gone: break
            }
        }
        return found.sorted { $0.pid < $1.pid }
    }
}

/// Stops every server-mode run on this Mac (D11): on Disconnect, before the
/// session closes, and when the app quits.
@MainActor
final class TeamRunStopper {
    private let launcher: TeamLauncher

    init(launcher: TeamLauncher) {
        self.launcher = launcher
    }

    /// No run is accepted from the first moment (review C2-16); every live
    /// run is stopped and waited for — those accepted meanwhile too — and each
    /// gets `stopped_locally` with its fact once its processes are gone. Then
    /// the journal's other open rows: their processes are stopped when
    /// confirmed, and their outcome waits for the server (review C3-10).
    /// The runs of one organization only (out of it: §10.3); others go on.
    func stopAll(of key: ChatOrgKey) async {
        let runs = launcher.live.keys.filter { runId in
            guard let run = try? launcher.journal.run(runId), let approval = try? launcher.journal.approval(run.approvalId) else { return false }
            return approval.key == key
        }
        for runId in runs { _ = await launcher.stop(runId) }
    }

    /// Every live run, the launcher left open (another session: lead's rule on review D4b2-A).
    func stopRuns() async {
        for runId in Array(launcher.live.keys) { _ = await launcher.stop(runId) }
    }

    func stopAll() async {
        launcher.close()
        var asked: Set<String> = []
        while !launcher.live.isEmpty || launcher.pendingLaunches > 0 {
            if let runId = launcher.live.keys.first(where: { !asked.contains($0) }) {
                asked.insert(runId)
                _ = await launcher.stop(runId)
            } else {
                // Stopped runs finish their rows; accepted launches get live.
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        await launcher.recovery?.check()
    }

    /// At quit, where nothing can wait: every run's group is killed and its
    /// row marked as being stopped; the next start confirms it gone and only
    /// then writes the outcome and its fact (review C2-17).
    func stopAllAtQuit() {
        launcher.close()
        for (runId, run) in launcher.live {
            try? launcher.journal.markStopping(runId, reason: "stopped_by_owner")
            guard let process = run.process else { continue }
            TeamProcesses.signal(process, SIGKILL, also: TeamProcesses.shared.seen(of: process))
        }
    }
}
