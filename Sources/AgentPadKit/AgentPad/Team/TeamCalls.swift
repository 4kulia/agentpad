import Foundation

/// Team work, stage 2: calls to colleagues' agents (docs/agentpad/TEAM.md
/// 6.2–6.4, 7.3–7.6).
///
/// The owner's side keeps what this Mac publishes, takes calls from
/// colleagues, waits for the owner's decision and runs them one at a time
/// per agent. The caller's side sends a call and follows it until it ends.
///
/// Every exchange is one request and one answer: `call.start` and
/// `call.attach` return the call as it stands, after waiting up to
/// `maxWaitSeconds` for it to change. A caller that loses the connection
/// simply asks again (D-6). Calls live in memory: after a restart of either
/// Mac a call in flight is lost and reported so (queues on disk are stage 4).
@MainActor
@Observable
final class TeamCalls {
    /// A call from a colleague to one of this Mac's agents.
    struct Incoming: Identifiable, Equatable {
        let id: String
        let peer: String
        var peerName: String
        let agentId: UUID
        let agentName: String
        let prompt: String
        let threadId: String
        /// The thread already has a Claude Code session to continue.
        let resume: Bool
        let origin: TeamCallOrigin?
        let receivedAt: Date
        /// Undecided past this, the call expires (R-4).
        let decideBy: Date
        var state: TeamCallState = .awaitingApproval
        var activity: String?
        var answer: TeamRunResult?
        var truncated = false
        var detail: String?
        var finishedAt: Date?

        var report: TeamCallReport {
            TeamCallReport(
                callId: id, state: state, threadId: state == .done ? threadId : nil,
                text: answer?.text, truncated: answer == nil ? nil : truncated,
                turns: answer?.turns, durationMs: answer?.durationMs,
                activity: state == .running ? activity : nil, detail: detail
            )
        }
    }

    /// A call this Mac sent.
    struct Outgoing: Identifiable, Equatable {
        let id: String
        let peer: String
        var colleague: String
        let agent: String
        let prompt: String
        let createdAt: Date
        let deliverBy: Date
        var report: TeamCallReport
        /// While not delivered: why, e.g. "colleague offline, retrying".
        var note: String?
        var finishedAt: Date?

        var address: String { "\(agent)@\(TeamHandle.make(colleague))" }
    }

    /// A conversation a colleague may continue: their key, the agent, and the
    /// Claude Code session that holds it (C-5).
    struct Thread: Codable, Equatable {
        let id: String
        let peer: String
        let agentId: UUID
        let createdAt: Date
    }

    /// What `team agents` lists.
    struct CatalogItem: Equatable, Sendable {
        let address: String
        let colleague: String
        let colleagueId: String
        let online: Bool
        let entry: TeamCatalogEntry
        let sameProject: Bool
    }

    static let maxPromptBytes = 32 * 1024
    static let maxAnswerBytes = 256 * 1024
    /// Longest a request waits for a change before answering (7.5).
    static let maxWaitSeconds = 20
    static let maxRunningPerMac = 2
    static let maxCallsPerHour = 20
    static let maxUndecidedPerPeer = 5
    static let defaultDeliveryWindow: TimeInterval = 24 * 60 * 60
    /// Finished calls are kept as long as their caller may still come back
    /// for the answer, and to recognize a start delivered again (D-5).
    static let keepFinished: TimeInterval = defaultDeliveryWindow + followGrace + 3600
    static let maxEarlyCancelsPerPeer = 50
    /// How long past its delivery deadline a delivered call is still followed.
    static let followGrace: TimeInterval = 3 * 60 * 60
    static let minPollInterval: Duration = .milliseconds(500)

    private(set) var agents: [TeamPublishedAgent] = []
    private(set) var incoming: [Incoming] = []
    private(set) var outgoing: [Outgoing] = []

    /// Fires when a colleague's call arrives, for the notification (R-1).
    var onIncomingCall: @MainActor (Incoming) -> Void = { _ in }
    /// Fires when the number of calls waiting for this user changes.
    var onPendingChange: @MainActor () -> Void = {}

    weak var service: TeamService?
    private let storage: TeamStorage
    private let runner: TeamAgentRunner
    private var threads: [Thread] = []
    /// Runs in progress, until their process is really gone — a stopped
    /// call keeps its slot until then (R-8).
    private var runs: [String: Task<Void, Never>] = [:]
    private var runAgents: [String: UUID] = [:]
    /// Cancels that arrived before their `call.start`, by "peer/callId".
    private var cancelledEarly: [String: Date] = [:]
    private var deliveries: [String: Task<Void, Never>] = [:]
    private var starts: [String: [Date]] = [:]
    /// Bumped on every change to a call, so waiters notice.
    private var versions: [String: Int] = [:]
    private var sweeper: Task<Void, Never>?

    init(storage: TeamStorage, runner: TeamAgentRunner) {
        self.storage = storage
        self.runner = runner
    }

    var awaitingDecision: [Incoming] { incoming.filter { $0.state == .awaitingApproval } }

    func load() throws {
        agents = try storage.load([TeamPublishedAgent].self, from: storage.agentsURL, default: [])
        threads = try storage.load([Thread].self, from: storage.threadsURL, default: [])
    }

    /// Team work turned off: nothing waits for decisions, nothing runs, no
    /// call is followed any more.
    func stopAll() {
        for (_, task) in deliveries { task.cancel() }
        deliveries = [:]
        for call in outgoing where !call.report.state.isFinal {
            update(call.id) { $0.report.state = .failed; $0.report.detail = "Team work was turned off."; $0.note = nil }
        }
        for i in incoming.indices where !incoming[i].state.isFinal {
            runs[incoming[i].id]?.cancel()
            finish(at: i, .cancelled, detail: "The owner turned team work off.")
        }
        sweeper?.cancel()
        sweeper = nil
        onPendingChange()
    }

    /// A colleague was removed: their calls stop at once, both ways (P-6).
    func peerRemoved(_ peer: String) {
        var undecided = false
        for i in incoming.indices where incoming[i].peer == peer && !incoming[i].state.isFinal {
            undecided = undecided || incoming[i].state == .awaitingApproval
            runs[incoming[i].id]?.cancel()
            finish(at: i, .cancelled, detail: "The colleague was removed.")
        }
        for call in outgoing where call.peer == peer && !call.report.state.isFinal {
            deliveries.removeValue(forKey: call.id)?.cancel()
            update(call.id) { $0.report.state = .cancelled; $0.report.detail = "The colleague was removed."; $0.note = nil }
        }
        if undecided { onPendingChange() }
        pump()
    }

    // MARK: Publishing (A-1…A-6)

    /// Adds or replaces an agent. Its git remotes are read now, so the
    /// catalog can say which project it belongs to.
    func save(_ agent: TeamPublishedAgent) async throws {
        var agent = agent
        agent.name = agent.name.trimmingCharacters(in: .whitespaces).lowercased()
        guard TeamPublishedAgent.isValidName(agent.name) else {
            throw TeamError.storage("an agent's name is lowercase letters, digits and dashes, up to 32")
        }
        for entry in agent.deniedPaths + agent.allowedCommands where !ClaudeCodeRunner.isValidRuleText(entry) {
            throw TeamError.storage("“\(entry)”: paths and commands cannot contain brackets")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: agent.folder, isDirectory: &isDir), isDir.boolValue else {
            throw TeamError.storage("folder \(agent.folder) does not exist")
        }
        let existed = agents.contains { $0.id == agent.id }
        // git reads the whole repository whatever folder it starts in, so a
        // profile with git publishes the repository, not a part of it.
        if agent.access != .read, let top = try await TeamGitRemote.topLevel(of: agent.folder),
           URL(fileURLWithPath: top).resolvingSymlinksInPath().path != URL(fileURLWithPath: agent.folder).resolvingSymlinksInPath().path {
            throw TeamError.storage("\(agent.folder) is inside the repository \(top): with git, publish the repository's top folder, or choose the Read rights")
        }
        agent.remotes = await TeamGitRemote.remotes(of: agent.folder)
        // Checked after the wait: another save or a removal may have happened.
        guard !agents.contains(where: { $0.name == agent.name && $0.id != agent.id }) else {
            throw TeamError.storage("an agent named \(agent.name) already exists")
        }
        guard !existed || agents.contains(where: { $0.id == agent.id }) else {
            throw TeamError.storage("\(agent.name) was removed meanwhile")
        }
        var next = agents
        if let i = next.firstIndex(where: { $0.id == agent.id }) { next[i] = agent } else { next.append(agent) }
        try storage.save(next, to: storage.agentsURL)
        agents = next
    }

    func unpublish(_ id: UUID) throws {
        let next = agents.filter { $0.id != id }
        try storage.save(next, to: storage.agentsURL)
        agents = next
    }

    // MARK: Owner: requests from colleagues

    /// Answers a catalog or call message from a paired colleague.
    func handle(_ message: TeamMessage, from contact: TeamContact) async -> TeamMessage {
        switch message.type {
        case .catalogGet:
            return TeamMessage(type: .catalog, agents: agents.filter { $0.isOpen(to: contact.id) }.map(\.catalogEntry))
        case .callStart:
            return await start(message, from: contact)
        case .callAttach:
            guard let id = message.callId, let call = incoming.first(where: { $0.id == id && $0.peer == contact.id }) else {
                return .error("unknown_call")
            }
            return await status(of: call.id, waiting: message.waitSeconds, known: message.call)
        case .callCancel:
            guard let id = message.callId, UUID(uuidString: id) != nil else { return .error("malformed") }
            guard let i = incoming.firstIndex(where: { $0.id == id && $0.peer == contact.id }) else {
                // The cancel overtook its start: remember it, so the start
                // that may still arrive is refused rather than shown.
                guard !incoming.contains(where: { $0.id == id }) else { return .error("unknown_call") }
                let now = Date()
                cancelledEarly = cancelledEarly.filter { now.timeIntervalSince($0.value) < Self.defaultDeliveryWindow }
                // Confirmed only once remembered; a full list says so instead.
                guard cancelledEarly.keys.filter({ $0.hasPrefix("\(contact.id)/") }).count < Self.maxEarlyCancelsPerPeer else {
                    return .error("busy_calls")
                }
                cancelledEarly["\(contact.id)/\(id)"] = now
                return TeamMessage(type: .callStatus, callId: id, call: TeamCallReport(
                    callId: id, state: .cancelled, detail: "Cancelled by the caller."
                ))
            }
            if !incoming[i].state.isFinal {
                let wasWaiting = incoming[i].state == .awaitingApproval
                runs[id]?.cancel()
                finish(at: i, .cancelled, detail: "Cancelled by the caller.")
                if wasWaiting { onPendingChange() }
                pump()
            }
            return await status(of: id, waiting: 0)
        default:
            return .error("unexpected")
        }
    }

    private func start(_ message: TeamMessage, from contact: TeamContact) async -> TeamMessage {
        guard let callId = message.callId, UUID(uuidString: callId) != nil,
              let name = message.agent, let prompt = message.prompt
        else { return .error("malformed") }
        if cancelledEarly["\(contact.id)/\(callId)"] != nil {
            return TeamMessage(type: .callStatus, callId: callId, call: TeamCallReport(
                callId: callId, state: .cancelled, detail: "Cancelled by the caller."
            ))
        }
        // Delivered again (D-5): the same call, not a second run.
        if let existing = incoming.first(where: { $0.id == callId }) {
            guard existing.peer == contact.id else { return .error("unknown_call") }
            return await status(of: callId, waiting: message.waitSeconds)
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= Self.maxPromptBytes
        else { return .error("too_large") }
        // An agent closed to this colleague does not exist for them.
        guard let agent = agents.first(where: { $0.name == name && $0.isOpen(to: contact.id) }) else {
            return .error("unknown_agent")
        }
        let now = Date()
        if let deliverBy = message.deliverBy, deliverBy <= now { return .error("expired") }
        let recent = starts[contact.id, default: []].filter { now.timeIntervalSince($0) < 3600 }
        guard recent.count < Self.maxCallsPerHour else { return .error("rate_limited") }
        guard awaitingDecision.filter({ $0.peer == contact.id }).count < Self.maxUndecidedPerPeer else {
            return .error("busy_calls")
        }
        let threadId: String, resume: Bool
        if let requested = message.threadId {
            guard threads.contains(where: { $0.id == requested && $0.peer == contact.id && $0.agentId == agent.id }) else {
                return .error("unknown_thread")
            }
            (threadId, resume) = (requested, true)
        } else {
            (threadId, resume) = (UUID().uuidString.lowercased(), false)
        }
        starts[contact.id] = recent + [now]
        let latest = now.addingTimeInterval(Self.defaultDeliveryWindow)
        let call = Incoming(
            id: callId, peer: contact.id, peerName: contact.displayName,
            agentId: agent.id, agentName: agent.name,
            prompt: prompt, threadId: threadId, resume: resume,
            origin: message.from.map(Self.clean), receivedAt: now,
            decideBy: min(message.deliverBy ?? latest, latest)
        )
        incoming.append(call)
        bump(callId)
        startSweeper()
        onIncomingCall(call)
        onPendingChange()
        return await status(of: callId, waiting: message.waitSeconds)
    }

    private static func clean(_ origin: TeamCallOrigin) -> TeamCallOrigin {
        TeamCallOrigin(
            session: origin.session.map { String(TeamInviteLink.sanitizedName($0).prefix(80)) },
            project: origin.project.map { String($0.prefix(200)) }
        )
    }

    /// The call's report, after waiting up to `waiting` seconds for a change.
    /// When what the caller last saw (`known`) is already out of date, the
    /// answer goes at once: the change happened between two rounds.
    private func status(of id: String, waiting: Int?, known: TeamCallReport? = nil) async -> TeamMessage {
        let current = incoming.first { $0.id == id }?.report
        let stale = known.map { $0.state != current?.state || $0.activity != current?.activity } ?? false
        if !stale { await waitForChange(id, seconds: min(max(waiting ?? 0, 0), Self.maxWaitSeconds)) }
        guard let call = incoming.first(where: { $0.id == id }) else { return .error("unknown_call") }
        return TeamMessage(type: .callStatus, callId: id, call: call.report)
    }

    /// The owner's decision (R-3). Allowed calls queue for a free slot.
    func decide(_ id: String, allow: Bool, reason: String? = nil) {
        guard let i = incoming.firstIndex(where: { $0.id == id }), incoming[i].state == .awaitingApproval else { return }
        if incoming[i].decideBy <= Date() {
            finish(at: i, .expired, detail: "The owner did not decide in time.")
            onPendingChange()
            return
        }
        if allow {
            incoming[i].state = .queued
            bump(id)
            pump()
        } else {
            let why = reason.map { String($0.prefix(300)) }.flatMap { $0.isEmpty ? nil : $0 }
            finish(at: i, .denied, detail: why.map { "Declined: \($0)" } ?? "The owner declined the call.")
        }
        onPendingChange()
    }

    /// Stops a call that is waiting or running on this Mac (R-6).
    func stop(_ id: String) {
        guard let i = incoming.firstIndex(where: { $0.id == id }), !incoming[i].state.isFinal else { return }
        let wasWaiting = incoming[i].state == .awaitingApproval
        runs[id]?.cancel()
        finish(at: i, .cancelled, detail: "Stopped by the owner.")
        if wasWaiting { onPendingChange() }
        pump()
    }

    /// Starts queued calls while slots are free: one per agent, two per Mac (R-8).
    private func pump() {
        guard let service, service.isOn, service.config.enabled else { return }
        while runs.count < Self.maxRunningPerMac,
              let i = incoming.firstIndex(where: { call in
                  call.state == .queued && !runAgents.values.contains(call.agentId)
              })
        {
            run(at: i)
        }
    }

    private func run(at i: Int) {
        let call = incoming[i]
        // Read again: the owner may have changed or closed the agent since.
        guard let agent = agents.first(where: { $0.id == call.agentId }), agent.isOpen(to: call.peer) else {
            finish(at: i, .failed, detail: "The agent is no longer published.")
            return
        }
        incoming[i].state = .running
        bump(call.id)
        let request = TeamRunRequest(
            agent: agent, prompt: call.prompt, sessionId: call.threadId, resume: call.resume,
            callerName: call.peerName, callerProject: call.origin?.project
        )
        let runner = self.runner
        let callId = call.id
        let onActivity: @Sendable (String) -> Void = { [weak self] tool in
            Task { @MainActor in self?.setActivity(callId, tool) }
        }
        runAgents[call.id] = agent.id
        runs[call.id] = Task { [weak self] in
            let outcome: Result<TeamRunResult, Error>
            do {
                outcome = .success(try await runner.run(request, onActivity: onActivity))
            } catch {
                outcome = .failure(error)
            }
            self?.completed(call.id, outcome)
        }
    }

    private func setActivity(_ id: String, _ tool: String) {
        guard let i = incoming.firstIndex(where: { $0.id == id }), incoming[i].state == .running else { return }
        incoming[i].activity = String(tool.prefix(60))
        bump(id)
    }

    private func completed(_ id: String, _ outcome: Result<TeamRunResult, Error>) {
        runs.removeValue(forKey: id)
        runAgents.removeValue(forKey: id)
        defer { pump() }
        guard let i = incoming.firstIndex(where: { $0.id == id }), incoming[i].state == .running else { return }
        switch outcome {
        case .success(var answer):
            let truncated = answer.text.utf8.count > Self.maxAnswerBytes
            if truncated { answer.text = Self.prefix(answer.text, bytes: Self.maxAnswerBytes) }
            incoming[i].answer = answer
            incoming[i].truncated = truncated
            if answer.isError {
                finish(at: i, .failed, detail: answer.text.isEmpty ? "The agent stopped with an error." : String(answer.text.prefix(300)))
            } else {
                rememberThread(incoming[i])
                finish(at: i, .done, detail: nil)
            }
        case .failure(let error):
            if error is CancellationError { return }
            finish(at: i, .failed, detail: (error as? LocalizedError)?.errorDescription ?? "The agent could not run.")
        }
    }

    private func rememberThread(_ call: Incoming) {
        guard !threads.contains(where: { $0.id == call.threadId }) else { return }
        threads.append(Thread(id: call.threadId, peer: call.peer, agentId: call.agentId, createdAt: Date()))
        try? storage.save(threads, to: storage.threadsURL)
    }

    private func finish(at i: Int, _ state: TeamCallState, detail: String?) {
        incoming[i].state = state
        incoming[i].detail = detail
        incoming[i].activity = nil
        incoming[i].finishedAt = Date()
        bump(incoming[i].id)
    }

    static func prefix(_ text: String, bytes: Int) -> String {
        var out = ""
        var used = 0
        for ch in text {
            let n = String(ch).utf8.count
            if used + n > bytes { break }
            out.append(ch)
            used += n
        }
        return out
    }

    /// Expires undecided calls (R-4) and forgets old finished ones.
    private func startSweeper() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                if self.sweep() { self.sweeper = nil; return }
            }
        }
    }

    /// True when nothing is left to watch.
    @discardableResult
    func sweep(now: Date = Date()) -> Bool {
        var changed = false
        for i in incoming.indices where incoming[i].state == .awaitingApproval && incoming[i].decideBy <= now {
            finish(at: i, .expired, detail: "The owner did not decide in time.")
            changed = true
        }
        if changed { onPendingChange() }
        incoming.removeAll { call in
            guard let done = call.finishedAt, now.timeIntervalSince(done) > Self.keepFinished else { return false }
            versions[call.id] = nil
            return true
        }
        // Answers stay for `team check` a day after they arrived.
        outgoing.removeAll { call in
            guard let done = call.finishedAt, now.timeIntervalSince(done) > Self.defaultDeliveryWindow else { return false }
            versions[call.id] = nil
            return true
        }
        return incoming.isEmpty && outgoing.isEmpty
    }

    // MARK: Caller

    /// The agents colleagues opened to this Mac; same project first (C-3).
    func catalog(projectRemotes: [String] = []) async -> [CatalogItem] {
        guard let service else { return [] }
        let contacts = service.contacts
        // Asked side by side; each colleague answers or times out on its own.
        let asks = contacts.map { contact in
            Task { @MainActor () -> (TeamContact, [TeamCatalogEntry]?) in
                let reply = try? await service.send(TeamMessage(type: .catalogGet), to: contact.id, timeout: .seconds(15))
                return (contact, reply?.type == .catalog ? (reply?.agents ?? []) : nil)
            }
        }
        var answers: [(TeamContact, [TeamCatalogEntry]?)] = []
        for ask in asks { answers.append(await ask.value) }
        var items: [CatalogItem] = []
        for (contact, entries) in answers {
            guard let entries else { continue }
            // Two colleagues with one name are told apart by key.
            let handle = TeamHandle.resolve(TeamHandle.make(contact.displayName), in: contacts)?.id == contact.id
                ? TeamHandle.make(contact.displayName)
                : String(contact.id.prefix(12))
            for entry in entries.prefix(100) where TeamPublishedAgent.isValidName(entry.name) {
                items.append(CatalogItem(
                    address: "\(entry.name)@\(handle)",
                    colleague: contact.displayName, colleagueId: contact.id, online: true,
                    entry: Self.clean(entry),
                    sameProject: !Set(entry.remotes).isDisjoint(with: projectRemotes)
                ))
            }
        }
        return items.sorted {
            if $0.sameProject != $1.sameProject { return $0.sameProject }
            return $0.address < $1.address
        }
    }

    /// A catalog entry from another Mac, cut down to sane sizes.
    private static func clean(_ entry: TeamCatalogEntry) -> TeamCatalogEntry {
        var e = entry
        e.description = String(e.description.prefix(1000))
        e.skills = e.skills.prefix(20).map { String($0.prefix(60)) }
        e.remotes = e.remotes.prefix(10).map { String($0.prefix(200)) }
        return e
    }

    /// Sends a call to `agent@colleague` and follows it in the background.
    /// Returns at once; `check` waits for the outcome.
    func ask(_ address: String, prompt: String, threadId: String?, origin: TeamCallOrigin?,
             deliverBy: Date? = nil) throws -> Outgoing {
        guard let service, service.isOn else { throw TeamError.notEnabled }
        let parts = address.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, TeamPublishedAgent.isValidName(parts[0]) else {
            throw TeamError.storage("an agent's address is name@colleague, e.g. backend@masha")
        }
        guard let contact = TeamHandle.resolve(parts[1], in: service.contacts) else {
            throw TeamError.storage("no colleague matches '\(parts[1])'")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TeamError.storage("the request is empty") }
        guard prompt.utf8.count <= Self.maxPromptBytes else { throw TeamError.refused("too_large") }
        if let threadId, UUID(uuidString: threadId) == nil { throw TeamError.storage("a thread id is a UUID") }
        let now = Date()
        let call = Outgoing(
            id: UUID().uuidString.lowercased(), peer: contact.id, colleague: contact.displayName, agent: parts[0],
            prompt: prompt, createdAt: now, deliverBy: deliverBy ?? now.addingTimeInterval(Self.defaultDeliveryWindow),
            report: TeamCallReport(callId: "", state: .queued), note: nil
        )
        var stored = call
        stored.report.callId = call.id
        outgoing.append(stored)
        bump(call.id)
        let start = TeamMessage(
            type: .callStart, callId: call.id, agent: call.agent, prompt: prompt, threadId: threadId?.lowercased(),
            from: origin, deliverBy: call.deliverBy, waitSeconds: 0
        )
        deliveries[call.id] = Task { [weak self] in await self?.deliver(call.id, start: start) }
        startSweeper()
        return stored
    }

    /// Delivers `call.start`, then asks for news until the call ends.
    private func deliver(_ id: String, start: TeamMessage) async {
        defer { deliveries[id] = nil }
        let backoff: [Double] = [5, 15, 30, 60]
        var failures = 0
        var delivered = false
        var lastAsked = ContinuousClock.now - .seconds(10)
        while !Task.isCancelled, let call = outgoing.first(where: { $0.id == id }), !call.report.state.isFinal {
            guard let service else { return }
            // Checked every round, whatever the other Mac answers.
            let now = Date()
            if !delivered, now >= call.deliverBy {
                update(id) { $0.report.state = .expired; $0.report.detail = "Not delivered: \(call.colleague) was not online in time."; $0.note = nil }
                return
            }
            if now >= call.deliverBy.addingTimeInterval(Self.followGrace) {
                update(id) { $0.report.state = .failed; $0.report.detail = "No answer from \(call.colleague)'s Mac in time."; $0.note = nil }
                return
            }
            // A Mac that answers at once instead of waiting is not asked in a tight loop.
            let since = ContinuousClock.now - lastAsked
            if since < Self.minPollInterval { try? await Task.sleep(for: Self.minPollInterval - since) }
            lastAsked = ContinuousClock.now
            let message = delivered
                ? TeamMessage(type: .callAttach, callId: id, waitSeconds: Self.maxWaitSeconds,
                              call: TeamCallReport(callId: id, state: call.report.state, activity: call.report.activity))
                : start
            do {
                let reply = try await service.send(message, to: call.peer, timeout: .seconds(Double(Self.maxWaitSeconds) + 20))
                // Cancelled while the request was out: a late answer must not
                // bring the call back to life.
                if Task.isCancelled { return }
                failures = 0
                switch reply.type {
                case .callStatus where reply.call?.callId == id:
                    delivered = true
                    update(id) { $0.report = Self.clean(reply.call!); $0.note = nil }
                case .error:
                    let code = reply.code ?? "error"
                    update(id) {
                        $0.report.state = .failed
                        $0.report.detail = TeamError.refusalText(code)
                        $0.note = nil
                    }
                default:
                    update(id) { $0.report.state = .failed; $0.report.detail = "Unexpected answer from the other Mac." }
                }
            } catch {
                if Task.isCancelled { return }
                failures += 1
                update(id) { $0.note = "\(call.colleague) is not reachable; trying again (attempt \(failures + 1))" }
                try? await Task.sleep(for: .seconds(backoff[min(failures - 1, backoff.count - 1)]))
            }
        }
    }

    private static func clean(_ report: TeamCallReport) -> TeamCallReport {
        var r = report
        r.text = r.text.map { prefix($0, bytes: maxAnswerBytes) }
        r.activity = r.activity.map { String($0.prefix(60)) }
        r.detail = r.detail.map { String($0.prefix(400)) }
        return r
    }

    private func update(_ id: String, _ change: (inout Outgoing) -> Void) {
        guard let i = outgoing.firstIndex(where: { $0.id == id }) else { return }
        change(&outgoing[i])
        if outgoing[i].report.state.isFinal, outgoing[i].finishedAt == nil { outgoing[i].finishedAt = Date() }
        bump(id)
    }

    /// The call this Mac sent, after waiting up to `seconds` for a change.
    func check(_ id: String, wait seconds: Int) async -> Outgoing? {
        guard let call = outgoing.first(where: { $0.id == id.lowercased() }) else { return nil }
        if !call.report.state.isFinal { await waitForChange(call.id, seconds: seconds) }
        return outgoing.first { $0.id == call.id }
    }

    func cancel(_ id: String) async -> Outgoing? {
        guard let call = outgoing.first(where: { $0.id == id.lowercased() }) else { return nil }
        guard !call.report.state.isFinal else { return call }
        deliveries.removeValue(forKey: call.id)?.cancel()
        let reply = try? await service?.send(TeamMessage(type: .callCancel, callId: call.id), to: call.peer, timeout: .seconds(15))
        update(call.id) {
            if let report = reply?.call, reply?.type == .callStatus, report.callId == call.id, report.state.isFinal {
                $0.report = Self.clean(report)
            } else {
                $0.report.state = .cancelled
                $0.report.detail = "Cancelled here; \(call.colleague)'s Mac did not confirm it stopped."
            }
            $0.note = nil
        }
        return outgoing.first { $0.id == call.id }
    }

    // MARK: Waiting

    private func bump(_ id: String) { versions[id, default: 0] += 1 }

    private func waitForChange(_ id: String, seconds: Int) async {
        guard seconds > 0 else { return }
        let start = versions[id, default: 0]
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline, versions[id, default: 0] == start, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
