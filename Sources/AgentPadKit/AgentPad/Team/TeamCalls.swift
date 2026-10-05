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
/// simply asks again (D-6). Calls are kept in `calls.json` — both the
/// history the Team tab shows (J-1, J-2) and the queues that let a call
/// survive a restart of either Mac (D-1).
@MainActor
@Observable
final class TeamCalls {
    /// A call from a colleague to one of this Mac's agents.
    struct Incoming: Codable, Identifiable, Equatable {
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
        /// The caller confirmed it has the outcome (D-7).
        var acknowledged: Bool?
        var state: TeamCallState = .awaitingApproval
        /// Server mode: the request's own state (6.9, or this Mac's
        /// `lost`, `resyncing`), for the rows' words (DESIGN-D6 §7.4).
        var serverState: String?
        var activity: String?
        var answer: TeamRunResult?
        var truncated = false
        var detail: String?
        var finishedAt: Date?
        /// Cleared from the Team tab; still answers a caller who comes back,
        /// and still recognizes a start delivered again (D-5).
        var hidden: Bool?
        /// Server mode (D8): the organization, the request's version and
        /// run, the device that executes it. The id is the `request_id`, the
        /// peer the initiator's account.
        var scope: TeamCallScope?
        var version: Int?
        var runId: String?
        var executorDeviceName: String?
        /// Server mode: this session executes it; another device of the
        /// owner only shows it.
        var onThisDevice: Bool?


        /// A decision is asked of this Mac: the one place every panel and the
        /// badge ask (review D8e-p3-9).
        var needsDecisionHere: Bool { state == .awaitingApproval && onThisDevice != false }

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
    struct Outgoing: Codable, Identifiable, Equatable {
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
        /// Cleared from the Team tab; kept for `team check` until it ages out.
        var hidden: Bool?
        /// What `call.start` carries again after a restart.
        var thread: String?
        var origin: TeamCallOrigin?
        /// The owner's Mac has the call; from now on it is followed with `call.attach`.
        var delivered = false
        /// Server mode (D8), as for `Incoming`; the peer is the owner's account.
        var scope: TeamCallScope?
        var version: Int?
        var runId: String?
        var executorDeviceName: String?
        /// Server mode: the owner's handle, the address's second half.
        var handle: String?
        /// Server mode (D10): the request's own state (6.9, or this Mac's
        /// `creating`, `lost`, `resyncing`); the result came; its text is no
        /// longer kept (history limit).
        var serverState: String?
        var answered: Bool?
        var answerTrimmed: Bool?

        var address: String { "\(agent)@\(handle ?? TeamHandle.make(colleague))" }
    }

    /// A conversation a colleague may continue: their key, the agent, and the
    /// Claude Code session that holds it (C-5).
    struct Thread: Codable, Equatable {
        let id: String
        let peer: String
        let agentId: UUID
        let createdAt: Date
    }

    /// A running call's agent asks for a folder outside its own (R-12).
    struct AccessRequest: Identifiable, Equatable {
        struct Scope: Equatable {
            let key: ChatOrgKey
            let kind: String
            let channelId: String?
        }
        enum State: String { case pending, deciding, once, always, denied, already }
        let id: String
        let callId: String
        let path: String
        let reason: String
        var state: State
        let at: Date
        let scope: Scope?
        var isChannel: Bool { scope?.kind == "channel" }
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
    /// A colleague may be away for days: a call waits a week to be delivered.
    static let defaultDeliveryWindow: TimeInterval = 7 * 24 * 60 * 60
    /// Finished calls are kept as long as their caller may still come back
    /// for the answer, and to recognize a start delivered again (D-5).
    /// Finished calls stay in the history this long (J-2) — longer than any
    /// caller may come back for an answer or deliver a start again (D-5).
    static let keepFinished: TimeInterval = 30 * 24 * 60 * 60
    /// History beyond this many finished calls a side drops the oldest —
    /// but never one the other Mac may still ask about (`protocolWindow`).
    static let maxHistory = 300
    static let protocolWindow: TimeInterval = defaultDeliveryWindow + followGrace + 3600
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
    /// Fires when a call this Mac sent ends: answered, declined, failed (D-4).
    var onOutgoingFinished: @MainActor (Outgoing) -> Void = { _ in }

    /// What carries calls to and from other Macs; none until the server's
    /// delivery is in (D4–D6): calls to colleagues then say so.
    weak var link: TeamCallLink?
    /// Server mode (D8): the organization whose cache holds the calls.
    private(set) var serverKey: ChatOrgKey?
    /// Requests of the organization that already ran on this Mac (the
    /// journal's spent approvals): a restored server asking to decide one
    /// again says so on the card (review D4c-p1-1). Set by the owner's side.
    var ranHere: (ChatOrgKey) -> Set<String> = { _ in [] }
    static let restoredRunNote = "The server was restored: this request already ran on this Mac. Allow to send its result again (nothing runs again); Decline to refuse it."
    private var serverCalls: ChatCallStore?
    /// Where Claude Code keeps conversations; replaced in tests.
    var sessionFilesRoot = TeamSessionFiles.root
    var conversationVisibility: () -> ChannelConversationFilter = { .current() }
    private let storage: TeamStorage
    /// Calls and threads on this Mac.
    private var store: TeamCallStore
    private let runner: TeamAgentRunner
    private var threads: [Thread] = []
    /// Runs in progress, until their process is really gone — a stopped
    /// call keeps its slot until then (R-8).
    private var runs: [String: Task<Void, Never>] = [:]
    private var runAgents: [String: UUID] = [:]
    /// Cancels that arrived before their `call.start`, by "peer/callId".
    private var cancelledEarly: [String: Date] = [:]
    private var deliveries: [String: Task<Void, Never>] = [:]
    /// Network tasks cancelled or sent off but maybe not ended yet: `drain`
    /// waits for every one (review C2-6).
    private var outstanding: [UUID: Task<Void, Never>] = [:]

    /// Keeps a task's handle until it really ends.
    private func keepUntilDone(_ task: Task<Void, Never>) {
        let id = UUID()
        outstanding[id] = task
        Task { [weak self] in
            await task.value
            self?.outstanding[id] = nil
        }
    }

    /// Cancels a delivery and keeps its handle until it really ends.
    private func cancelDelivery(_ id: String) {
        guard let task = deliveries.removeValue(forKey: id) else { return }
        task.cancel()
        keepUntilDone(task)
    }
    private var starts: [String: [Date]] = [:]
    /// Bumped on every change to a call, so waiters notice.
    private var versions: [String: Int] = [:]
    private var sweeper: Task<Void, Never>?
    private var saving: Task<Void, Never>?
    /// False from the start of a load until the log was read: a load that
    /// stopped earlier (a damaged neighbouring file) must not lead to an
    /// empty log written over a good one.
    private var logWritable = true

    /// Called first thing by `TeamService.load`.
    func beginLoading() { logWritable = false }
    /// The running delivery per call, so a late-ending old one cannot
    /// unregister its successor.
    private var deliveryTokens: [String: UUID] = [:]
    /// Folder requests of running calls, newest last; in memory only — they
    /// end with their run.
    private(set) var accessRequests: [AccessRequest] = []
    /// Folders granted to a call that its next run will get, with the rights
    /// the agent had when they were checked.
    private var grants: [String: [String]] = [:]
    private var grantAccess: [String: TeamAccessProfile] = [:]
    private var continuations: [String: Int] = [:]
    /// How many of a call's grants its runs already had.
    private var grantsUsed: [String: Int] = [:]
    static let maxContinuations = 3
    /// Fires when an agent asks for a folder, for the notification.
    var onAccessRequest: @MainActor (AccessRequest, Incoming) -> Void = { _, _ in }
    var pendingAccess: [AccessRequest] { accessRequests.filter { $0.state == .pending && !$0.isChannel } }
    var accessScope: @MainActor (String) throws -> AccessRequest.Scope? = { _ in nil }
    var channelAccessAllowed: @MainActor (AccessRequest.Scope) -> Bool = { _ in false }

    private func accessAllowed(_ request: AccessRequest) -> Bool {
        guard let scope = request.scope else { return !serverMode }
        return scope.key == serverKey && (!request.isChannel || channelAccessAllowed(scope))
    }

    /// Execution uses every incoming request; display continues to use the
    /// filtered incoming array. This lookup is only for folder continuations.
    func executionIncoming(_ id: String) -> Incoming? {
        if let serverCalls, let serverKey {
            return try? ChatTeamCallStore(calls: serverCalls, key: serverKey, forExecution: true).loadCall(id).incoming.first
        }
        return incoming.first { $0.id == id }
    }

    func channelPendingAccess(_ id: String) -> [AccessRequest] {
        accessRequests.filter { $0.callId == id && $0.isChannel && $0.state == .pending && accessAllowed($0) }
    }
    /// Calls whose end is not yet on disk, to be told once it is.
    private var unannounced: Set<String> = []
    /// Bumped by `nudge`: deliveries waiting for their next retry go now.
    private var nudges = 0

    struct Log: Codable, Equatable {
        var incoming: [Incoming]
        var outgoing: [Outgoing]
    }

    /// `offStore`: the calls while team work is off — none in the app (the
    /// files of 1.0.x are not read); the file store when not given (tests).
    init(storage: TeamStorage, runner: TeamAgentRunner, offStore: TeamCallStore? = nil) {
        self.storage = storage
        self.offStore = offStore ?? TeamFileCallStore(storage: storage)
        self.store = self.offStore
        self.runner = runner
    }

    private let offStore: TeamCallStore

    /// This Mac's configuration of the call's agent — none for a call
    /// another Mac executes, whatever agent of the same id this one keeps
    /// (review D8g-p3-8).
    func localAgent(for call: Incoming) -> TeamPublishedAgent? {
        guard call.onThisDevice != false else { return nil }
        return agents.first { $0.id == call.agentId }
    }

    /// Waiting for a decision on this Mac: not a request another device of
    /// the owner executes (review D8d-p3-9).
    var awaitingDecision: [Incoming] { incoming.filter(\.needsDecisionHere) }

    func load() throws {
        logWritable = false
        agents = try storage.load([TeamPublishedAgent].self, from: storage.agentsURL, default: [])
        pruneVanishedSessions()
        threads = try store.loadThreads()
        let log = try store.loadLog()
        let now = Date()
        incoming = log.incoming.map { call in
            var call = call
            // (Load reads the store of team work off; a server's request
            // there is left as it is.)
            guard !call.localActionsRefused else { return call }
            // Allowed but not started: allowed again, never run on an old
            // decision — the stop or cancel since may not have been saved.
            if call.state == .queued {
                call.state = .awaitingApproval
                call.detail = "AgentPad restarted before it ran; allow it again."
            }
            // Its process ended with the app; undecided calls wait on.
            if call.state == .running {
                call.state = .failed
                call.detail = "AgentPad quit while the agent was running."
                call.activity = nil
                call.finishedAt = now
            }
            return call
        }
        outgoing = log.outgoing.map { call in
            var call = call
            if !call.report.state.isFinal, !call.localActionsRefused { call.note = "Waiting for team work to start." }
            return call
        }
        logWritable = true
        if !incoming.isEmpty || !outgoing.isEmpty { startSweeper() }
    }

    /// Server mode: the organization's cache becomes the store of calls and
    /// threads — the calls are its requests; nil goes back to the file store.
    /// The connection's current organization decides: its calls, or none.
    /// Moving to a server ends this queue's own work first: its runs,
    /// deliveries and folder requests do not go on beside the server's.
    func useServer(_ calls: ChatCallStore?, key: ChatOrgKey?) {
        saveNow()
        storeEpoch += 1
        // Scope lives on the pending object; disconnect/removal cannot turn
        // a channel's folder request into a personal Team card.
        accessRequests.removeAll { $0.scope != nil }
        for i in accessRequests.indices where [.pending, .deciding].contains(accessRequests[i].state) { accessRequests[i].state = .denied }
        grants = [:]
        grantAccess = [:]
        grantsUsed = [:]
        continuations = [:]
        onPendingChange()
        if calls != nil {
            stopAll()
        }
        if let calls, let key {
            serverCalls = calls
            serverKey = key
            store = ChatTeamCallStore(calls: calls, key: key)
            lastPrune = nil
            startSweeper()
        } else {
            serverCalls = nil
            serverKey = nil
            store = offStore
        }
        reload()
    }

    /// When the cache's history was last trimmed here.
    private var lastPrune: Date?
    /// Bumped by every change of store: what an operation began before an
    /// `await` is checked against it after (review D8e-p1-2).
    private var storeEpoch = 0
    /// Team work is in server mode (`TeamService`): the old path stays
    /// closed whether or not an organization's cache is in (review D8e-p1-1).
    var serverMode = false
    /// The server's delivery of calls this Mac asks is in (D5 sets it);
    /// until then `ask` in server mode refuses. Tests of the record set it.
    var deliversAsks = false
    /// D5: a command of the organization made but not stored, to store in
    /// the call's own transaction, and what to do once it is (`ChatService.prepareCommand`).
    /// Nil (tests of the record): made here, into the cache's own table.
    var prepareCommand: (@MainActor (ChatOrgKey, String, ChatJSON) throws -> (record: ChatCommandRecord, table: ChatCommandTable, sent: @MainActor () -> Void))?
    /// Tests: runs right after a folder decision's check, where other work
    /// may have happened meanwhile.
    var afterFolderCheck: @MainActor () async -> Void = {}
    /// Tests: runs right after a publication's agents were checked.
    var afterPrepare: @MainActor () async -> Void = {}

    /// Why the current store's calls could not be read; none are shown then.
    private(set) var storeProblem: String?

    /// The cache changed (D8): calls are read again from it, and whoever
    /// waits on one that changed or left (`check`, MCP) hears of it. A store
    /// that cannot be read shows no calls — never the calls of the one
    /// before (review D8d-p2-9) — and is not written to until it can be.
    /// Reads of the store so far: what reads the cache besides the calls follows it.
    private(set) var loads = 0

    func reload() {
        loads += 1
        var log = Log(incoming: [], outgoing: [])
        do {
            let read = try store.loadLog()
            threads = try store.loadThreads()
            log = read
            storeProblem = nil
        } catch {
            threads = []
            storeProblem = "The calls could not be read: \(error.localizedDescription)"
        }
        logWritable = storeProblem == nil
        let before = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let sent = Dictionary(uniqueKeysWithValues: outgoing.map { ($0.id, $0) })
        // What only this app knows of a run in progress (a move to a server
        // ends this queue's runs first, their activity with them: `stopAll`).
        let ran = serverKey.map { ranHere($0) } ?? []
        incoming = log.incoming.map { call in
            var call = call
            if call.state == .running { call.activity = before[call.id]?.activity }
            if call.state == .awaitingApproval, ran.contains(call.id) { call.detail = Self.restoredRunNote }
            return call
        }
        // What a server's run is doing now (`run.activity`): in memory only, until it ends.
        outgoing = log.outgoing.map { call in
            var call = call
            if !call.report.state.isFinal, call.report.activity == nil { call.report.activity = sent[call.id]?.report.activity }
            return call
        }
        for call in incoming where before[call.id] != call { touch(call.id) }
        for call in outgoing where sent[call.id] != call { touch(call.id) }
        // A call that left (history trimmed, another organization) drops its
        // mark: whoever waits on it sees the change and wakes (review
        // D8d-p2-12). Marks come from one counter that only grows, so a call
        // that leaves and comes back between two looks never repeats the
        // mark a waiter holds (review D8e-p2-11).
        let alive = Set(incoming.map(\.id) + outgoing.map(\.id))
        versions = versions.filter { alive.contains($0.key) }
        onPendingChange()
    }

    /// Team work is on: queued calls run, and calls this Mac sent are
    /// followed again — also those from before a restart (D-1).
    func resume() {
        guard link != nil else { return }
        for call in outgoing where !call.report.state.isFinal && deliveries[call.id] == nil && !refuses(call) {
            update(call.id) { $0.note = nil }
            startDelivery(call)
        }
        pump()
        onPendingChange()
    }

    private func startDelivery(_ call: Outgoing) {
        guard !refuses(call) else { return }
        let token = UUID()
        let start = Self.startMessage(for: call)
        deliveryTokens[call.id] = token
        deliveries[call.id] = Task { [weak self] in
            await self?.deliver(call.id, start: start)
            guard let self, self.deliveryTokens[call.id] == token else { return }
            self.deliveries[call.id] = nil
            self.deliveryTokens[call.id] = nil
        }
    }

    private static func startMessage(for call: Outgoing) -> TeamMessage {
        TeamMessage(
            type: .callStart, callId: call.id, agent: call.agent, prompt: call.prompt, threadId: call.thread,
            from: call.origin, deliverBy: call.deliverBy, waitSeconds: 0
        )
    }

    /// Finished calls leave the Team tab. They stay on disk, unseen, for as
    /// long as the other Mac may still ask about them.
    /// In server mode written first and shown only once written: a reload
    /// meanwhile cannot undo it (review D8d-p2-10). False when not saved.
    @discardableResult
    func clearHistory() -> Bool {
        var nextIn = incoming, nextOut = outgoing
        for i in nextIn.indices where nextIn[i].state.isFinal { nextIn[i].hidden = true }
        for i in nextOut.indices where nextOut[i].report.state.isFinal { nextOut[i].hidden = true }
        if serverCalls != nil {
            // The cache decides what is hidden — final there now — and the
            // view is read from it again (review D8h-p2-6).
            guard logWritable, (try? store.saveLog(Log(incoming: nextIn, outgoing: nextOut))) != nil else { return false }
            reload()
            return true
        }
        incoming = nextIn
        outgoing = nextOut
        return saveNow()
    }

    // MARK: Saving

    /// Soon, once a burst of changes settles — and again every few
    /// seconds while writing fails, until what is in memory is on disk.
    private func scheduleSave(after delay: Duration = .seconds(1)) {
        guard saving == nil else { return }
        saving = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.saving = nil
            self.saveNow()
        }
    }

    /// Now: at quit, and after explicit changes.
    @discardableResult
    func saveNow() -> Bool {
        saving?.cancel()
        saving = nil
        guard logWritable else { return false }
        let ok = (try? store.saveLog(Log(incoming: incoming, outgoing: outgoing))) != nil
        // Any failed write is tried again every few seconds until one works.
        if !ok { scheduleSave(after: .seconds(5)) }
        if ok, !unannounced.isEmpty {
            // Ends that could not be saved at the time are told now.
            let ids = unannounced
            unannounced = []
            for call in outgoing where ids.contains(call.id) { onOutgoingFinished(call) }
        }
        return ok
    }

    /// Team work turned off: nothing runs and no call is followed. Running
    /// calls stop; undecided, queued and sent ones wait for team work to
    /// come back on (`resume`).
    func stopAll() {
        for id in Array(deliveries.keys) { cancelDelivery(id) }
        for call in outgoing where !call.report.state.isFinal && !refuses(call) {
            update(call.id) { $0.note = "Team work is off; the call goes on when it is on again." }
        }
        for i in incoming.indices where incoming[i].state == .running && !refuses(incoming[i]) {
            runs[incoming[i].id]?.cancel()
            finish(at: i, .cancelled, detail: "The owner turned team work off.")
        }
        onPendingChange()
    }

    /// A call is running here.
    /// (A server's request runs through `TeamLauncher`; its processes are
    /// `TeamProcesses`', not this queue's.)
    var hasRunningCalls: Bool { !runs.isEmpty || incoming.contains { $0.state == .running && !refuses($0) } }

    /// Waits until cancelled deliveries and runs are really gone — a run
    /// until its process group is.
    func drain() async {
        while let (id, task) = outstanding.first {
            await task.value
            outstanding[id] = nil
        }
        while let task = deliveries.values.first ?? runs.values.first {
            await task.value
            // A finished task that did not unregister itself (a newer one
            // took its slot, or it ended on cancellation) must not be awaited again.
            if let id = deliveries.first(where: { $0.value == task })?.key { deliveries[id] = nil }
            if let id = runs.first(where: { $0.value == task })?.key { runs[id] = nil; runAgents[id] = nil }
        }
    }

    // MARK: Publishing (A-1…A-6)

    /// Adds or replaces an agent. Its git remotes are read now, so the
    /// catalog can say which project it belongs to.
    func save(_ agent: TeamPublishedAgent) async throws {
        try await save([agent])
    }

    /// Adds or replaces several agents at once: every one is checked first,
    /// then all are written together — or none is.
    func save(_ batch: [TeamPublishedAgent]) async throws {
        try commit(try await prepared(batch))
    }

    /// Server mode: colleagues' agents of the organization's catalog, as the
    /// cache has them now (D3, answer (а)); read again whenever the calls are.
    var colleaguesAgents: [CatalogItem] {
        _ = loads
        guard let serverCalls, let serverKey else { return [] }
        return serverCalls.colleaguesCatalog(me: serverKey.accountId)
    }

    /// The owner's decision on a server's request (D4: `ChatOwnerSide`); set by the app.
    var decideOnServer: (@MainActor (Incoming, Bool, String?) -> String?)?
    /// The owner's Stop of a server's request (D4b: `request.stop`); nil when
    /// asked, else why not. Set by the app.
    var stopOnServer: (@MainActor (Incoming) -> String?)?
    /// The caller's cancel of a call through the server (D5b:
    /// `request.cancel`); nil when asked, else why not. Set by the app.
    var cancelOnServer: (@MainActor (Outgoing) -> String?)?
    /// CLI cancellation by id uses the channel gate, without exposing a
    /// channel request through the personal call store.
    var cancelChannelOnServer: (@MainActor (String) -> String?)?
    /// The conversation a server's call's thread goes on in here — its
    /// latest run of the server's generation now, for the same caller (F6);
    /// nil when there is none. Set by the app.
    var serverConversation: (@MainActor (Incoming) -> String?)?
    /// Folders granted to a server's run (D4b §2.5): the continuation record
    /// for the same run, with every folder granted so far; nil when written,
    /// else why not. Set by the app.
    var continueOnServer: (@MainActor (Incoming, [String]) -> String?)?
    /// A server's run waits for the owner to grant a folder: told to its
    /// caller (`run.access_wait`). Set by the app.
    var onAccessWait: @MainActor (Incoming) -> Void = { _ in }

    /// A hint from the server about an outgoing call's run (D4b §2.4): what
    /// it does now, or that it waits for a folder. Never its state.
    func serverActivity(_ requestId: String, _ text: String) {
        guard let i = outgoing.firstIndex(where: { $0.id == requestId }), !outgoing[i].report.state.isFinal else { return }
        outgoing[i].report.activity = String(text.prefix(200))
        bump(requestId, durable: false)
    }

    /// Another session of this Mac (lead's rule on review D4b2-A): folder
    /// grants and waiting folder requests of the server's calls are
    /// forgotten — nothing given under the earlier session is given again.
    func forgetServerFolderGrants() {
        for id in Array(grants.keys) where incoming.first(where: { $0.id == id }).map(refuses) ?? true {
            grants[id] = nil
            grantAccess[id] = nil
            grantsUsed[id] = nil
            continuations[id] = nil
        }
        accessRequests.removeAll { $0.scope != nil }
        onPendingChange()
    }

    /// Folders may be asked and granted for `call`: this queue's own, or a
    /// server's run once continuations through the server exist (D4b).
    private func foldersServed(_ call: Incoming) -> Bool { !refuses(call) || continueOnServer != nil }

    /// Publishing to the organization (D3); set by the app.
    weak var publishing: TeamPublishing?

    /// Server mode: the agents are checked, then — with the connection still
    /// the one this began with — written and, those with Published on,
    /// published to `teams` (`TeamPublishing.publish`), with nothing awaited
    /// between the two. Published off: saved only (lead's decision on review
    /// D3b-4). A failed publication leaves the agents written: what differs
    /// from what the server has is shown and refused to run until published.
    /// `key`: the organization the form was opened for — the publication is
    /// refused if the connection is another one once the checks are done
    /// (review D3-9, D3-p1-3).
    func saveAndPublish(_ batch: [TeamPublishedAgent], teams: [String], key: ChatOrgKey) async throws {
        guard serverMode, serverKey != nil, let publishing else { throw TeamError.notConnected }
        let checked = try await prepared(batch)
        await afterPrepare()
        guard serverKey == key else { throw TeamError.notYet(TeamServerCore.changedMeanwhile) }
        let published = checked.map(\.agent).filter(\.enabled)
        if !published.isEmpty, teams.isEmpty { throw TeamError.storage("choose one or more of your teams to publish to") }
        try commit(checked)
        if !published.isEmpty { try publishing.publish(published, teams: teams, key: key) }
    }

    private func prepared(_ batch: [TeamPublishedAgent]) async throws -> [(agent: TeamPublishedAgent, existed: Bool)] {
        // Which agents existed is fixed before any wait: one removed while
        // git answers must not come back.
        let existing = Set(batch.filter { agent in agents.contains { $0.id == agent.id } }.map(\.id))
        var prepared: [(agent: TeamPublishedAgent, existed: Bool)] = []
        for agent in batch {
            prepared.append((try await prepare(agent), existing.contains(agent.id)))
        }
        return prepared
    }

    /// Writes checked agents; no wait inside.
    private func commit(_ prepared: [(agent: TeamPublishedAgent, existed: Bool)]) throws {
        // Checked after the waits: another save or a removal may have happened.
        let names = prepared.map(\.agent.name)
        guard Set(names).count == names.count else { throw TeamError.storage("the two agents need different names") }
        for (agent, existed) in prepared {
            guard !agents.contains(where: { $0.name == agent.name && $0.id != agent.id }) else {
                throw TeamError.storage("an agent named \(agent.name) already exists")
            }
            guard !existed || agents.contains(where: { $0.id == agent.id }) else {
                throw TeamError.storage("\(agent.name) was removed meanwhile")
            }
            // Published to a server: not paused here before D3b (review D3-8).
            if !agent.enabled, publishing?.isAssigned(agent.id) == true { throw TeamError.notYet(TeamServerCore.pauseNotYet) }
        }
        var next = agents
        for (agent, _) in prepared {
            if let i = next.firstIndex(where: { $0.id == agent.id }) { next[i] = agent } else { next.append(agent) }
        }
        try storage.save(next, to: storage.agentsURL)
        agents = next
    }

    /// One agent checked and completed: name, rules, folder, session, git.
    private func prepare(_ agent: TeamPublishedAgent) async throws -> TeamPublishedAgent {
        var agent = agent
        agent.name = agent.name.trimmingCharacters(in: .whitespaces).lowercased()
        guard TeamPublishedAgent.isValidName(agent.name) else {
            throw TeamError.storage("“\(agent.name)”: an agent's name is lowercase letters, digits and dashes, up to 32")
        }
        for entry in agent.deniedPaths + agent.allowedCommands where !ClaudeCodeRunner.isValidRuleText(entry) {
            throw TeamError.storage("“\(entry)”: paths and commands cannot contain brackets")
        }
        if let session = agent.sessionId {
            // A copy of a conversation resumes only from the folder it ran in.
            guard TeamSessionFiles.isValidId(session), let cwd = TeamSessionFiles.workingDirectory(of: session, root: sessionFilesRoot) else {
                throw TeamError.storage("the Claude Code conversation \(session) was not found")
            }
            agent.sessionId = session.lowercased()
            agent.folder = cwd
            agent.sessionTitle = agent.sessionTitle.map { String(TeamText.sanitizedName($0).prefix(120)) }
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: agent.folder, isDirectory: &isDir), isDir.boolValue else {
            throw TeamError.storage("folder \(agent.folder) does not exist")
        }
        // git reads the whole repository whatever folder it starts in, so a
        // profile with git publishes the repository, not a part of it.
        if agent.access.usesGit, let top = try await TeamGitRemote.topLevel(of: agent.folder),
           URL(fileURLWithPath: top).resolvingSymlinksInPath().path != URL(fileURLWithPath: agent.folder).resolvingSymlinksInPath().path {
            throw TeamError.storage("\(agent.folder) is inside the repository \(top): with git, publish the repository's top folder, or choose the Read rights")
        }
        // More folders: absolute, existing, distinct; with git rights each
        // is a repository's top folder too.
        var extra: [String] = []
        let stored = Set(agents.first { $0.id == agent.id }?.extraFolders ?? [])
        for raw in agent.extraFolders ?? [] {
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let path = try await Self.checkedFolder(raw, access: agent.access, allowFile: false)
            // A folder given earlier was stored with its links resolved; if
            // it leads elsewhere now, that is not the folder the owner gave.
            if stored.contains(raw), path != raw {
                throw TeamError.storage("\(raw) now leads to \(path); remove it, or add the folder you mean")
            }
            if path != agent.folder, !extra.contains(path) { extra.append(path) }
        }
        agent.extraFolders = extra.isEmpty ? nil : extra
        agent.remotes = await TeamGitRemote.remotes(of: agent.folder)
        return agent
    }

    /// Adds an already checked folder to the agent as it is now — no wait in
    /// between, so a pause, new rules or lower rights saved meanwhile stay.
    private func addFolder(_ path: String, to agentId: UUID) throws {
        guard let i = agents.firstIndex(where: { $0.id == agentId }) else { throw TeamError.storage("the agent is gone") }
        var next = agents
        if !(next[i].extraFolders ?? []).contains(path), next[i].folder != path {
            next[i].extraFolders = (next[i].extraFolders ?? []) + [path]
        }
        try storage.save(next, to: storage.agentsURL)
        agents = next
    }

    /// Session agents whose conversation was deleted stop existing (the
    /// owner's rule: a session agent lives as long as its session).
    /// One published to a server stays (removal is D3b): it cannot run and
    /// is not announced (review D3-7).
    func pruneVanishedSessions() {
        let gone = agents.filter { agent in
            agent.sessionId.map { !TeamSessionFiles.exists($0, root: sessionFilesRoot) } ?? false && publishing?.isAssigned(agent.id) != true
        }
        guard !gone.isEmpty else { return }
        let next = agents.filter { agent in !gone.contains { $0.id == agent.id } }
        guard (try? storage.save(next, to: storage.agentsURL)) != nil else { return }
        agents = next
    }

    /// The agents published from one conversation.
    func agents(forSession sessionId: String) -> [TeamPublishedAgent] {
        agents.filter { $0.sessionId == sessionId.lowercased() }
    }

    /// Every removal passes here — Remove, CLI `unpublish`, Stop Publishing
    /// This Session: one published to a server is not removed before D3b.
    func unpublish(_ id: UUID) throws {
        // Published to a server: the server is asked first; the agent goes
        // once it took it (`removeUnpublished`, D3b).
        if let publishing, publishing.isAssigned(id) {
            // The organization it is published to — connected, or said (review D3b2-2).
            guard let key = publishing.assignmentKey(id) ?? serverKey else { throw TeamError.notConnected }
            guard key == serverKey else {
                throw TeamError.storage("it is published to another organization (\(key.server.host)); connect to it to unpublish it")
            }
            try publishing.unpublish(id, key: key)
            return
        }
        try removeUnpublished(id)
    }

    /// The agent leaves this Mac's list: unpublished here, or by the server.
    func removeUnpublished(_ id: UUID) throws {
        let next = agents.filter { $0.id != id }
        guard next.count != agents.count else { return }
        try storage.save(next, to: storage.agentsURL)
        agents = next
    }

    // MARK: Owner: requests from colleagues

    /// Answers a catalog or call message from a paired colleague.
    func handle(_ message: TeamMessage, from contact: TeamCaller) async -> TeamMessage {
        // The old protocol is closed while a server holds the calls, and
        // never knows a server's request.
        if refuses(nil) || message.callId.map({ id in incoming.contains { $0.id == id && refuses($0) } }) == true {
            return .error("unknown_call")
        }
        switch message.type {
        case .catalogGet:
            pruneVanishedSessions()
            return TeamMessage(type: .catalog, agents: agents.filter { $0.isOpen(to: contact.id) }.map(\.catalogEntry))
        case .callStart:
            return await start(message, from: contact)
        case .callAttach:
            guard let id = message.callId, let call = incoming.first(where: { $0.id == id && $0.peer == contact.id }) else {
                return .error("unknown_call")
            }
            return await status(of: call.id, waiting: message.waitSeconds, known: message.call)
        case .callAck:
            guard let id = message.callId, let i = incoming.firstIndex(where: { $0.id == id && $0.peer == contact.id }) else {
                return .error("unknown_call")
            }
            if incoming[i].state.isFinal, incoming[i].acknowledged != true {
                incoming[i].acknowledged = true
                scheduleSave()
            }
            return TeamMessage(type: .callStatus, callId: id, call: incoming[i].report)
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

    private func start(_ message: TeamMessage, from contact: TeamCaller) async -> TeamMessage {
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
        // An agent closed to this colleague does not exist for them, nor
        // does a session whose conversation is gone.
        pruneVanishedSessions()
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
        // Accepted only once on disk: the caller follows it by id from now on.
        guard bump(callId) else {
            incoming.removeAll { $0.id == callId }
            return .error("storage")
        }
        startSweeper()
        onIncomingCall(call)
        onPendingChange()
        return await status(of: callId, waiting: message.waitSeconds)
    }

    private static func clean(_ origin: TeamCallOrigin) -> TeamCallOrigin {
        TeamCallOrigin(
            session: origin.session.map { String(TeamText.sanitizedName($0).prefix(80)) },
            project: origin.project.map { String($0.prefix(200)) }
        )
    }

    /// The call's report, after waiting up to `waiting` seconds for a change.
    /// When what the caller last saw (`known`) is already out of date, the
    /// answer goes at once: the change happened between two rounds.
    private func status(of id: String, waiting: Int?, known: TeamCallReport? = nil) async -> TeamMessage {
        let current = incoming.first { $0.id == id }?.report
        let stale = known.map { $0.state != current?.state || $0.activity != current?.activity } ?? false
        let began = storeEpoch
        if !stale { await waitForChange(id, seconds: min(max(waiting ?? 0, 0), Self.maxWaitSeconds)) }
        // Other calls came meanwhile: this one is not theirs (review D8h-p2-7).
        guard storeEpoch == began, let call = incoming.first(where: { $0.id == id }) else { return .error("unknown_call") }
        return TeamMessage(type: .callStatus, callId: id, call: call.report)
    }

    /// The owner's decision (R-3). Allowed calls queue for a free slot.
    /// A server's request is refused, with the text why (until D4).
    @discardableResult
    func decide(_ id: String, allow: Bool, reason: String? = nil) -> String? {
        guard let i = incoming.firstIndex(where: { $0.id == id }), incoming[i].state == .awaitingApproval else { return nil }
        // A server's request on its executor: through the server (D4) — the
        // buttons are this function's only callers (DESIGN-D4 §0.1).
        if incoming[i].scope != nil, incoming[i].onThisDevice != false, let decideOnServer {
            return decideOnServer(incoming[i], allow, reason)
        }
        if let refusal = refusal(.decide, for: incoming[i]) { return refusal }
        if incoming[i].decideBy <= Date() {
            finish(at: i, .expired, detail: "The owner did not decide in time.")
            onPendingChange()
            return nil
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
        return nil
    }

    /// Stops a call that is waiting or running on this Mac (R-6).
    @discardableResult
    func stop(_ id: String) -> String? {
        guard let i = incoming.firstIndex(where: { $0.id == id }), !incoming[i].state.isFinal else { return nil }
        if let refusal = refusal(.stop, for: incoming[i]) { return refusal }
        // A server's request: asked of the server; never ended here before
        // its word (DESIGN-D3b-D4b-D5b §2.1).
        if refuses(incoming[i]), let stopOnServer { return stopOnServer(incoming[i]) }
        let wasWaiting = incoming[i].state == .awaitingApproval
        runs[id]?.cancel()
        finish(at: i, .cancelled, detail: "Stopped by the owner.")
        if wasWaiting { onPendingChange() }
        pump()
        return nil
    }

    /// Starts queued calls while slots are free: one per agent, two per Mac (R-8).
    private func pump() {

        while runs.count < Self.maxRunningPerMac,
              let i = incoming.firstIndex(where: { call in
                  // A server's request starts only through its approval (D4, D9).
                  call.state == .queued && !refuses(call) && !runAgents.values.contains(call.agentId)
              })
        {
            run(at: i)
        }
    }

    private func run(at i: Int) {
        let call = incoming[i]
        guard !refuses(call) else { return }
        // Read again: the owner may have changed or closed the agent since.
        guard let agent = agents.first(where: { $0.id == call.agentId }), agent.isOpen(to: call.peer) else {
            finish(at: i, .failed, detail: "The agent is no longer published.")
            return
        }
        if let session = agent.sessionId, !call.resume, !TeamSessionFiles.exists(session, root: sessionFilesRoot) {
            pruneVanishedSessions()
            finish(at: i, .failed, detail: "The session this agent copied no longer exists.")
            return
        }
        incoming[i].state = .running
        // On disk before the process starts: a crash right after must not
        // leave it queued, to run a second time without a new Allow.
        guard bump(call.id) else {
            finish(at: i, .failed, detail: "The owner's Mac could not save the call, so it did not run.")
            return
        }
        launch(call, agent: agent, prompt: call.prompt, resume: call.resume, continuing: false)
    }

    /// Starts a run of `call`: its first one, or a continuation after the
    /// owner granted folders.
    private func launch(_ call: Incoming, agent: TeamPublishedAgent, prompt: String, resume: Bool, continuing: Bool) {
        // Every run of this queue, first or carried on, passes here (review D8d-p1-1).
        guard !refuses(call) else { return }
        var request = TeamRunRequest(
            agent: agent, prompt: prompt, sessionId: call.threadId, resume: resume,
            callerName: call.peerName, callerProject: call.origin?.project,
            logURL: storage.runLogURL(callId: call.id)
        )
        request.runToolsCallId = call.id
        request.continuesLog = continuing
        let runner = self.runner
        let callId = call.id
        // The run's callbacks belong to the store it began in (review D8h-p2-9).
        let epoch = storeEpoch
        let onActivity: @Sendable (String) -> Void = { [weak self] tool in
            Task { @MainActor in self?.setActivity(callId, tool, epoch: epoch) }
        }
        runAgents[call.id] = agent.id
        runs[call.id] = Task { [weak self] in
            let outcome: Result<TeamRunResult, Error>
            do {
                outcome = .success(try await runner.run(request, onActivity: onActivity))
            } catch {
                outcome = .failure(error)
            }
            self?.completed(call.id, outcome, epoch: epoch)
        }
    }

    private func setActivity(_ id: String, _ tool: String, epoch: Int) {
        guard storeEpoch == epoch, let i = incoming.firstIndex(where: { $0.id == id }), incoming[i].state == .running,
              !refuses(incoming[i]) else { return }
        incoming[i].activity = String(tool.prefix(60))
        bump(id, durable: false)
    }

    private func completed(_ id: String, _ outcome: Result<TeamRunResult, Error>, epoch: Int) {
        runs.removeValue(forKey: id)
        runAgents.removeValue(forKey: id)
        defer { pump() }
        guard storeEpoch == epoch, let i = incoming.firstIndex(where: { $0.id == id }), incoming[i].state == .running, !refuses(incoming[i]) else { return }
        // Folders were granted during the run: the conversation goes on with
        // them, as the agent was told, without a new Allow.
        if case .success(let answer) = outcome, !answer.isError, let dirs = grants[id], dirs.count > grantsUsed[id, default: 0],
           continuations[id, default: 0] < Self.maxContinuations,
           var agent = agents.first(where: { $0.id == incoming[i].agentId }), agent.isOpen(to: incoming[i].peer),
           // A folder checked under other rights is not given under these:
           // with git now allowed, a subfolder would open its whole repository.
           grantAccess[id] == agent.access {
            continuations[id, default: 0] += 1
            let fresh = Array(dirs.dropFirst(grantsUsed[id, default: 0]))
            grantsUsed[id] = grants[id]?.count ?? 0
            // Every folder granted during the call so far, not only the last.
            agent.extraFolders = (agent.extraFolders ?? []) + dirs.filter { !(agent.extraFolders ?? []).contains($0) }
            incoming[i].activity = nil
            bump(id, durable: false)
            let list = fresh.joined(separator: ", ")
            launch(incoming[i], agent: agent,
                   prompt: "The owner of this Mac granted access to: \(list). Continue with the colleague's request.",
                   resume: true, continuing: true)
            return
        }
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
            // A stopped run says how its stop ended (Y5); D4b shows it.
            if case TeamRunnerError.stopped = error { return }
            finish(at: i, .failed, detail: (error as? LocalizedError)?.errorDescription ?? "The agent could not run.")
        }
    }

    private func rememberThread(_ call: Incoming) {
        guard !threads.contains(where: { $0.id == call.threadId }) else { return }
        threads.append(Thread(id: call.threadId, peer: call.peer, agentId: call.agentId, createdAt: Date()))
        try? store.saveThreads(threads)
    }

    private func finish(at i: Int, _ state: TeamCallState, detail: String?) {
        let id = incoming[i].id
        if accessRequests.contains(where: { $0.callId == id && $0.state == .pending }) {
            for j in accessRequests.indices where accessRequests[j].callId == id && accessRequests[j].state == .pending {
                accessRequests[j].state = .denied
            }
            onPendingChange()
        }
        grants[id] = nil
        grantAccess[id] = nil
        grantsUsed[id] = nil
        continuations[id] = nil
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
        // The server decides expiry; what history no longer shows loses its
        // heavy texts about once an hour, and the shown set is read again.
        if let serverCalls {
            if lastPrune.map({ now.timeIntervalSince($0) >= 3600 }) ?? true {
                lastPrune = now
                try? serverCalls.trim(now: now)
                reload()
            }
            return false
        }
        var changed = false
        for i in incoming.indices where incoming[i].state == .awaitingApproval && incoming[i].decideBy <= now
            && !refuses(incoming[i]) {
            finish(at: i, .expired, detail: "The owner did not decide in time.")
            changed = true
        }
        if changed { onPendingChange() }
        let countBefore = incoming.count + outgoing.count
        let incomingBefore = Set(incoming.map(\.id))
        incoming = Self.trimmed(incoming, now: now, finishedAt: \.finishedAt, start: \.receivedAt)
        outgoing = Self.trimmed(outgoing, now: now, finishedAt: \.finishedAt, start: \.createdAt)
        if incoming.count + outgoing.count != countBefore {
            let alive = Set(incoming.map(\.id) + outgoing.map(\.id))
            // A call's run log goes with its record.
            for id in incomingBefore where !alive.contains(id) {
                try? FileManager.default.removeItem(at: storage.runLogURL(callId: id))
            }
            versions = versions.filter { alive.contains($0.key) }
            scheduleSave()
        }
        return incoming.isEmpty && outgoing.isEmpty
    }

    /// History older than `keepFinished`, and the oldest beyond
    /// `maxHistory`, goes; calls still open always stay.
    private static func trimmed<Call>(_ calls: [Call], now: Date, finishedAt: KeyPath<Call, Date?>, start: KeyPath<Call, Date>) -> [Call] {
        var kept = calls.filter { call in
            guard let done = call[keyPath: finishedAt] else { return true }
            return now.timeIntervalSince(done) <= keepFinished
        }
        let finished = kept.filter { $0[keyPath: finishedAt] != nil }
        if finished.count > maxHistory {
            let cutoff = finished.map { $0[keyPath: start] }.sorted(by: >)[maxHistory - 1]
            kept.removeAll { call in
                guard let done = call[keyPath: finishedAt] else { return false }
                // Acknowledged: the caller has it, nothing needs the record (D-7).
                let settled = (call as? Incoming)?.acknowledged == true || now.timeIntervalSince(done) > protocolWindow
                return call[keyPath: start] < cutoff && settled
            }
        }
        return kept
    }

    // MARK: Caller

    /// The agents colleagues opened to this Mac; same project first (C-3).
    func catalog(projectRemotes: [String] = []) async -> [CatalogItem] {
        // Server mode: the organization's catalog (D8), colleagues' agents by `name@handle`.
        if let serverCalls, let serverKey { return serverCalls.colleaguesCatalog(me: serverKey.accountId) }
        guard let link else { return [] }
        let contacts = link.colleagues
        // Asked side by side; each colleague answers or times out on its own.
        let asks = contacts.map { contact in
            Task { @MainActor () -> (TeamCaller, [TeamCatalogEntry]?) in
                let reply = try? await link.send(TeamMessage(type: .catalogGet), to: contact.id, timeout: .seconds(15))
                return (contact, reply?.type == .catalog ? (reply?.agents ?? []) : nil)
            }
        }
        var answers: [(TeamCaller, [TeamCatalogEntry]?)] = []
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
        e.kind = e.kind == "session" ? "session" : "agent"
        e.session = e.session.map { String(TeamText.sanitizedName($0).prefix(120)) }
        return e
    }

    /// Sends a call to `agent@colleague` and follows it in the background.
    /// Returns at once; `check` waits for the outcome.
    /// `area`: the organization the asker began with (CLI, MCP); a call
    /// is not moved to another one that became current meanwhile.
    func ask(_ address: String, prompt: String, threadId: String?, origin: TeamCallOrigin?,
             deliverBy: Date? = nil, area: ChatOrgKey?? = .none) throws -> Outgoing {
        if case .some(let began) = area, began != serverKey {
            throw TeamError.storage("the organization changed while the call was being made; nothing was sent")
        }
        if serverMode, serverCalls == nil { throw TeamError.notConnected }
        if let serverCalls, let serverKey {
            return try askServer(address, prompt: prompt, threadId: threadId, origin: origin, deliverBy: deliverBy,
                                 calls: serverCalls, key: serverKey)
        }
        guard let link else { throw TeamError.notConnected }
        let parts = address.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, TeamPublishedAgent.isValidName(parts[0]) else {
            throw TeamError.storage("an agent's address is name@colleague, e.g. backend@masha")
        }
        guard let contact = TeamHandle.resolve(parts[1], in: link.colleagues) else {
            throw TeamError.storage("no colleague matches '\(parts[1])'")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TeamError.storage("the request is empty") }
        guard prompt.utf8.count <= Self.maxPromptBytes else { throw TeamError.refused("too_large") }
        if let threadId, UUID(uuidString: threadId) == nil { throw TeamError.storage("a thread id is a UUID") }
        let now = Date()
        let id = UUID().uuidString.lowercased()
        let call = Outgoing(
            id: id, peer: contact.id, colleague: contact.displayName, agent: parts[0],
            prompt: prompt, createdAt: now, deliverBy: deliverBy ?? now.addingTimeInterval(Self.defaultDeliveryWindow),
            report: TeamCallReport(callId: id, state: .queued), note: nil,
            thread: threadId?.lowercased(), origin: origin
        )
        let stored = call
        outgoing.append(stored)
        // On disk before it leaves: a restart must still know to follow it.
        guard bump(call.id) else {
            outgoing.removeAll { $0.id == call.id }
            throw TeamError.storage("the call could not be saved, so it was not sent")
        }
        startDelivery(call)
        startSweeper()
        return stored
    }

    /// Server mode (D8): the address is an agent of the organization's
    /// catalog and a member's handle — no contacts; the call is the request
    /// kept in the cache, the same checks as before. Sending it is D5's.
    private func askServer(_ address: String, prompt: String, threadId: String?, origin: TeamCallOrigin?, deliverBy: Date?,
                           calls: ChatCallStore, key: ChatOrgKey) throws -> Outgoing {
        let parts = address.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2, TeamPublishedAgent.isValidName(parts[0]) else {
            throw TeamError.storage("an agent's address is name@colleague, e.g. backend@masha")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TeamError.storage("the request is empty") }
        guard prompt.utf8.count <= Self.maxPromptBytes else { throw TeamError.refused("too_large") }
        // Nothing sends it yet (D5): said so, rather than a call nobody serves (review D8f-p3-7).
        guard deliversAsks else { throw TeamError.notYet(TeamServerCore.askNotYet) }
        // The call and its `request.create` are written together or not at
        // all (D5): the command's place is taken first — it is shared with
        // the run journal, another database — and stored in the call's transaction.
        let agent = try calls.queue.read { try ChatCallStore.resolve($0, address: address) }
        // A thread goes on only with the agent it was had with (D5b §3.2).
        let thread = threadId?.lowercased()
        if let thread, try !calls.queue.read({ try ChatCallStore.knowsThread($0, thread, agentId: agent.agentId, initiator: key.accountId) }) {
            throw TeamError.storage("unknown thread \(thread) for \(address): continue a thread of a call you made to this agent")
        }
        let requestId = UUID().uuidString.lowercased()
        var args: [String: ChatJSON] = [
            "request_id": .string(requestId), "agent_id": .string(agent.agentId), "text": .string(prompt),
            "origin": origin.map { o in .object(["session": o.session.map(ChatJSON.string) ?? .null, "project": o.project.map(ChatJSON.string) ?? .null]) } ?? .null,
            "conditions_version": .number(1), "thread_id": thread.map(ChatJSON.string) ?? .null,
        ]
        if let deliverBy { args["deliver_by"] = .string(ChatCallStore.timestamp(deliverBy)) }
        let command = try prepareCommand?(key, "request.create", .object(args)) ?? {
            let table = ChatCommandTable(queue: calls.queue, table: "outbox")
            let id = ChatUUID.v7()
            var record = ChatCommandRecord(commandId: id, sessionId: "", type: "request.create",
                                           bodyBytes: try ChatCommandEnvelope(commandId: id, org: key.orgId, type: "request.create", args: .object(args)).encoded(),
                                           orderKey: key.orgId, dependsOn: nil, createdAt: Date(), state: .pending)
            record.seq = try ChatCommandTable.maxSeq([table]) + 1
            return (record, table, {})
        }()
        let made: ChatRequest
        do {
            made = try calls.createOutgoing(address: address, text: prompt, origin: origin, initiator: key.accountId, deliverBy: deliverBy,
                                            requestId: requestId, threadId: thread) { db, wire in
                // The agent the command names is the one the call is for.
                guard wire.agentId == agent.agentId else { throw TeamError.refused("unknown_agent") }
                _ = try command.table.insert(db, command.record, seq: command.record.seq)
            }
        } catch {
            throw (error as? TeamError) ?? TeamError.storage("the call could not be saved, so it was not sent")
        }
        command.sent()
        reload()
        // Made and kept: its id goes back even when the calls could not be
        // read again (review D8e-p2-10).
        if let call = outgoing.first(where: { $0.id == made.requestId }) { return call }
        var call = Outgoing(
            id: made.requestId, peer: made.ownerAccountId ?? "", colleague: parts[1], agent: made.agentName ?? parts[0], prompt: prompt,
            createdAt: Date(), deliverBy: deliverBy ?? Date().addingTimeInterval(Self.defaultDeliveryWindow),
            report: TeamCallReport(callId: made.requestId, state: .queued), note: storeProblem
        )
        call.scope = TeamCallScope(key)
        call.handle = made.ownerHandle ?? parts[1]
        return call
    }

    /// Delivers `call.start`, then asks for news until the call ends.
    private func deliver(_ id: String, start: TeamMessage) async {
        let backoff: [Double] = [5, 15, 30, 60]
        var failures = 0
        var delivered = outgoing.first { $0.id == id }?.delivered ?? false
        var lastAsked = ContinuousClock.now - .seconds(10)
        while !Task.isCancelled, let call = outgoing.first(where: { $0.id == id }), !call.report.state.isFinal {
            guard let link else { return }
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
                let reply = try await link.send(message, to: call.peer, timeout: .seconds(Double(Self.maxWaitSeconds) + 20))
                // Cancelled while the request was out: a late answer must not
                // bring the call back to life.
                if Task.isCancelled { return }
                failures = 0
                switch reply.type {
                case .callStatus where reply.call?.callId == id:
                    delivered = true
                    let saved = update(id) { $0.report = Self.clean(reply.call!); $0.note = nil; $0.delivered = true }
                    if reply.call!.state.isFinal, saved { acknowledge(id) }
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
                await waitForRetry(seconds: backoff[min(failures - 1, backoff.count - 1)])
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

    @discardableResult
    private func update(_ id: String, _ change: (inout Outgoing) -> Void) -> Bool {
        guard let i = outgoing.firstIndex(where: { $0.id == id }) else { return false }
        let unchanged = outgoing[i]
        let before = (outgoing[i].report, outgoing[i].delivered, outgoing[i].hidden)
        change(&outgoing[i])
        // A poll that brought nothing new writes nothing.
        if outgoing[i] == unchanged { return true }
        if outgoing[i].report.state.isFinal, outgoing[i].finishedAt == nil { outgoing[i].finishedAt = Date() }
        // Anything the owner reported is written at once; a note can wait.
        let after = (outgoing[i].report, outgoing[i].delivered, outgoing[i].hidden)
        let durable = before != after
        let saved = bump(id, durable: durable)
        // Told only once it is on disk: an unsaved cancel is rolled back,
        // and any other end is told when a later write succeeds.
        if !before.0.state.isFinal, after.0.state.isFinal {
            if saved { onOutgoingFinished(outgoing[i]) } else { unannounced.insert(id) }
        }
        return durable && saved
    }

    /// The calls a check reads: an organization's (`TeamCallScope`), or this
    /// Mac's own file ("local").
    static func scopeToken(_ scope: TeamCallScope?) -> String {
        scope.map { "\($0.server)|\($0.accountId)|\($0.orgId)" } ?? "local"
    }

    var scopeToken: String { Self.scopeToken(serverKey.map(TeamCallScope.init)) }

    /// The call this Mac sent, after waiting up to `seconds` for a change.
    /// Also a call history no longer shows, read from its store by id
    /// (review D8f-p2-7, p3-3).
    /// A wait never changes the calls it reads — within this round, nor over
    /// the rounds of one follow (`scope`, the token the first round gave):
    /// when other calls came meanwhile, it ends and says so (review D8g-p2-8,
    /// D8h-p2-7, p3-4).
    func check(_ id: String, wait seconds: Int, scope: String? = nil) async throws -> Outgoing? {
        if let scope, scope != scopeToken { throw TeamError.scopeChanged }
        guard let call = outgoing(id) else { return nil }
        let began = storeEpoch
        if !call.report.state.isFinal { await waitForChange(call.id, seconds: seconds) }
        guard storeEpoch == began else { throw TeamError.scopeChanged }
        return outgoing(call.id)
    }

    /// A call this Mac sent, by id: in view, or in its store. A store that
    /// cannot be read says so (`storeProblem`), not "no such call" (review D8g-p3-7).
    func outgoing(_ id: String) -> Outgoing? {
        let id = id.lowercased()
        if let shown = outgoing.first(where: { $0.id == id }) { return shown }
        do { return try store.loadCall(id).outgoing.first } catch {
            storeProblem = "The calls could not be read: \(error.localizedDescription)"
            return nil
        }
    }

    func cancel(_ id: String) async -> Outgoing? {
        guard let call = outgoing(id) else { return nil }
        guard !call.report.state.isFinal else { return call }
        // Through the server: asked of it; the call ends by the server's word
        // (`cancelled`, `stopped`, `finished`, `stop_failed`) — D5b. Refused
        // otherwise: the call as it is (`refusal(.cancel, for:)`).
        if refuses(call) {
            guard let cancelOnServer else { return call }
            if let problem = cancelOnServer(call), let i = outgoing.firstIndex(where: { $0.id == call.id }) {
                outgoing[i].note = problem
                bump(call.id, durable: false)
            }
            return outgoing.first { $0.id == call.id } ?? call
        }
        cancelDelivery(call.id)
        // Cancelled here first, on disk: quitting while the other Mac is
        // asked must not bring the call back after a restart. If that cannot
        // be written, the cancel does not happen and says so.
        let saved = update(call.id) {
            $0.report.state = .cancelled
            $0.report.detail = "Cancelled here; \(call.colleague)'s Mac did not confirm it stopped."
            $0.note = nil
        }
        guard saved else {
            unannounced.remove(call.id)
            if let i = outgoing.firstIndex(where: { $0.id == call.id }) {
                outgoing[i] = call
                outgoing[i].note = "The cancel could not be saved, so the call goes on."
                bump(call.id, durable: false)
            }
            if link != nil { startDelivery(call) }
            return outgoing.first { $0.id == call.id }
        }
        // Its own task, kept until it ends, so `drain` waits for it.
        let sending = Task { [weak link] in
            try? await link?.send(TeamMessage(type: .callCancel, callId: call.id), to: call.peer, timeout: .seconds(15))
        }
        keepUntilDone(Task { _ = await sending.value })
        let began = storeEpoch
        let reply = await sending.value
        // The answer is for the calls it was asked in, not another store's (review D8g-p2-8).
        guard storeEpoch == began else { return call }
        if let report = reply?.call, reply?.type == .callStatus, report.callId == call.id, report.state.isFinal {
            if update(call.id, { $0.report = Self.clean(report); $0.delivered = true }) { acknowledge(call.id) }
        }
        return outgoing.first { $0.id == call.id }
    }

    // MARK: Folder access (R-12)

    /// A folder as the agent will get it: absolute, existing, its symlinks
    /// resolved (so what the owner allowed cannot later point elsewhere),
    /// a file's folder when `allowFile`; with git rights, a repository's top
    /// folder, since git reads the whole repository from any folder in it.
    /// Checked off the main actor, bounded in time: a path on a dead network
    /// volume must not freeze the app.
    static func checkedFolder(_ raw: String, access: TeamAccessProfile, allowFile: Bool) async throws -> String {
        let expanded = (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw TeamError.storage("\(raw) is not an absolute path") }
        let probe: (String, Bool)? = (try? await teamDeadline(.seconds(3)) {
            await Task.detached { () -> (String, Bool)? in
                let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return nil }
                return (url.path, isFolder.boolValue)
            }.value
        }) ?? nil
        guard let (resolved, isFolder) = probe else { throw TeamError.storage("\(expanded) does not exist or does not answer") }
        guard isFolder || allowFile else { throw TeamError.storage("\(resolved) is not a folder") }
        let path = isFolder ? resolved : URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        if access.usesGit, let top = try await TeamGitRemote.topLevel(of: path),
           URL(fileURLWithPath: top).resolvingSymlinksInPath().path != path {
            throw TeamError.storage("\(path) is inside the repository \(top): with git rights, only a repository's top folder can be given")
        }
        return path
    }

    /// A running call's agent asks for `path`. Already reachable folders are
    /// answered at once; otherwise the owner decides.
    func requestAccess(callId: String, path raw: String, reason: String) async throws -> AccessRequest {
        // Checked before anything of the old model is assumed (review D8d-p3-10).
        if let refusal = refusal(.folders, for: executionIncoming(callId.lowercased())) { throw TeamError.notYet(refusal) }
        guard let call = executionIncoming(callId.lowercased()), call.state == .running,
              let agent = agents.first(where: { $0.id == call.agentId })
        else { throw TeamError.storage("no running call \(callId)") }
        let scope = try accessScope(call.id)
        if serverMode, scope == nil { throw TeamError.storage("the run's saved scope is not available") }

        // Past the last continuation a grant could not take effect.
        guard continuations[call.id, default: 0] < Self.maxContinuations else {
            throw TeamError.storage("this call cannot be given more folders")
        }
        let began = storeEpoch
        let path = try await Self.checkedFolder(raw, access: agent.access, allowFile: true)
        await afterFolderCheck()
        // The same call, of the same store, still allowed (review D8e-p1-2).
        guard storeEpoch == began, let now = executionIncoming(call.id), now.state == .running,
              now.agentId == call.agentId, foldersServed(now)
        else { throw TeamError.storage("the call ended") }
        let reachable = [agent.folder] + (agent.extraFolders ?? []) + (grants[call.id] ?? [])
        // Stored folders are already resolved: compared as strings, without
        // touching the disk on the main actor.
        let inside = reachable.contains { root in
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        let mine = accessRequests.filter { $0.callId == call.id }
        guard mine.filter({ $0.state == .pending }).count < 3, mine.count < 10 else {
            throw TeamError.storage("too many folder requests for one call")
        }
        let request = AccessRequest(
            id: UUID().uuidString.lowercased(), callId: call.id, path: path,
            reason: String(TeamText.sanitizedName(reason).prefix(300)),
            state: inside ? .already : .pending, at: Date(), scope: scope
        )
        guard accessAllowed(request) else { throw TeamError.storage("the channel is no longer available") }
        accessRequests.append(request)
        bump(request.id, durable: false)
        if !inside {
            onAccessRequest(request, call)
            onPendingChange()
            if refuses(call) { onAccessWait(call) }
        }
        return request
    }

    /// The owner's answer: once for this call, always for this agent, or no.
    /// The folder is checked again first (it may have changed since it was
    /// asked for); one that fails the check is not granted at all.
    @discardableResult
    func decideAccess(_ id: String, _ state: AccessRequest.State) async -> String? {
        guard let i = accessRequests.firstIndex(where: { $0.id == id }), accessRequests[i].state == .pending,
              [.once, .always, .denied].contains(state)
        else { return nil }
        let request = accessRequests[i]
        if !accessAllowed(request) { return "The channel is no longer available." }
        if let refusal = refusal(.folders, for: executionIncoming(request.callId)) { return refusal }
        guard state != .denied else {
            accessRequests[i].state = .denied
            bump(id, durable: false)
            onPendingChange()
            return nil
        }
        // No second answer while this one is being checked and saved.
        accessRequests[i].state = .deciding
        onPendingChange()
        var problem: String?
        var granted = false
        var checkedUnder: TeamAccessProfile?
        let began = storeEpoch
        if let call = executionIncoming(request.callId),
           let before = agents.first(where: { $0.id == call.agentId }) {
            do {
                let access = before.access
                let path = try await Self.checkedFolder(request.path, access: access, allowFile: false)
                await afterFolderCheck()
                // Team work did not move meanwhile, and the call is still this
                // queue's own: nothing is given otherwise (review D8e-p1-2).
                guard storeEpoch == began, accessRequests.first(where: { $0.id == id })?.state == .deciding,
                      let now = executionIncoming(request.callId), now.agentId == call.agentId, foldersServed(now),
                      accessAllowed(request)
                else { throw TeamError.storage("team work moved meanwhile; the folder was not given") }
                guard path == request.path else { throw TeamError.storage("\(request.path) now leads elsewhere (\(path))") }
                // Read again after the wait, and given only under the rights
                // it was checked for.
                guard let agent = agents.first(where: { $0.id == call.agentId }), agent.access == access else {
                    throw TeamError.storage("the agent's rights changed meanwhile; ask again")
                }
                // A server's agent is run as it was published: "always" is
                // granted for this call only (D4b §2.5).
                if state == .always, !refuses(call) { try addFolder(path, to: agent.id) }
                checkedUnder = access
                granted = true
            } catch {
                problem = (error as? LocalizedError)?.errorDescription ?? "The folder could not be given."
            }
        } else {
            problem = "The call or its agent is gone."
        }
        guard let j = accessRequests.firstIndex(where: { $0.id == id }) else { return problem }
        accessRequests[j].state = granted ? state : .denied
        if granted, executionIncoming(request.callId)?.state == .running, let access = checkedUnder {
            // All of a call's grants are checked under the same rights.
            if let earlier = grantAccess[request.callId], earlier != access {
                grants[request.callId] = []
                grantsUsed[request.callId] = 0
            }
            grantAccess[request.callId] = access
            grants[request.callId, default: []].append(request.path)
            // A server's run goes on through its continuation record (D4b §2.5).
            if let call = executionIncoming(request.callId), refuses(call), let continueOnServer,
               let failed = continueOnServer(call, grants[call.id] ?? []) {
                accessRequests[j].state = .denied
                problem = failed
            }
        }
        bump(id, durable: false)
        onPendingChange()
        return problem
    }

    func accessStatus(_ id: String, wait seconds: Int) async -> AccessRequest? {
        guard let request = accessRequests.first(where: { $0.id == id }) else { return nil }
        if request.state == .pending || request.state == .deciding { await waitForChange(id, seconds: seconds) }
        return accessRequests.first { $0.id == id }
    }

    /// The owner may now let its record go (D-7). Sent only for an outcome
    /// received from the owner and saved here; best effort.
    private func acknowledge(_ id: String) {
        guard let call = outgoing.first(where: { $0.id == id }), !refuses(call), let link else { return }
        // Kept so `drain` waits for it too (review C2-6).
        keepUntilDone(Task { _ = try? await link.send(TeamMessage(type: .callAck, callId: call.id), to: call.peer, timeout: .seconds(15)) })
    }

    /// The colleague came online, the Mac woke up or the network changed:
    /// every delivery waiting to retry tries now (D-3).
    func nudge() { nudges += 1 }

    private func waitForRetry(seconds: Double) async {
        let seen = nudges
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline, nudges == seen, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: Waiting

    /// A change to a call: waiters notice, and the log is written — at once
    /// for a new state (a crash must not undo a cancel or a decision), a
    /// moment later for activity and notes.
    @discardableResult
    private func bump(_ id: String, durable: Bool = true) -> Bool {
        touch(id)
        // A failed write schedules its own retry (`saveNow`).
        if durable { return saveNow() }
        scheduleSave()
        return true
    }

    /// The counter every change mark comes from.
    private var revision = 0

    private func touch(_ id: String) {
        revision += 1
        versions[id] = revision
    }

    private func waitForChange(_ id: String, seconds: Int) async {
        guard seconds > 0 else { return }
        let start = versions[id, default: 0]
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline, versions[id, default: 0] == start, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}

/// Where `TeamCalls` keeps its call log and threads (C0).
/// What carries calls to and from other Macs: the server's delivery, which
/// comes with D8 and D4–D6.
@MainActor
protocol TeamCallLink: AnyObject {
    var colleagues: [TeamCaller] { get }
    func send(_ message: TeamMessage, to colleague: String, timeout: Duration) async throws -> TeamMessage
}

protocol TeamCallStore {
    func loadLog() throws -> TeamCalls.Log
    /// One call by id, also one `loadLog` leaves out.
    func loadCall(_ id: String) throws -> TeamCalls.Log
    func saveLog(_ log: TeamCalls.Log) throws
    func loadThreads() throws -> [TeamCalls.Thread]
    func saveThreads(_ threads: [TeamCalls.Thread]) throws
}

/// `calls.json` and `threads.json` beside the published agents.
struct TeamFileCallStore: TeamCallStore {
    let storage: TeamStorage

    func loadCall(_ id: String) throws -> TeamCalls.Log {
        let log = try loadLog()
        return TeamCalls.Log(incoming: log.incoming.filter { $0.id == id }, outgoing: log.outgoing.filter { $0.id == id })
    }

    func loadLog() throws -> TeamCalls.Log {
        try storage.load(TeamCalls.Log.self, from: storage.callsURL, default: TeamCalls.Log(incoming: [], outgoing: []))
    }

    func saveLog(_ log: TeamCalls.Log) throws { try storage.save(log, to: storage.callsURL) }

    func loadThreads() throws -> [TeamCalls.Thread] {
        try storage.load([TeamCalls.Thread].self, from: storage.threadsURL, default: [])
    }

    func saveThreads(_ threads: [TeamCalls.Thread]) throws { try storage.save(threads, to: storage.threadsURL) }
}

extension TeamCalls {
    /// What may be refused of a call: every action that changes it or
    /// starts anything for it.
    enum LocalAction { case decide, stop, cancel, watch, carryOn, folders }

    /// The one gate (review D8c, D8d-p1-1): the local path of 1.0.x — its
    /// queue, runs, protocol, watching, carrying on — is closed while a
    /// server holds the calls, and for any server's request; the record's
    /// own `scope` is not the only word.
    func refuses(_ record: TeamServerRecord?) -> Bool {
        serverMode || serverKey != nil || record?.localActionsRefused == true
    }

    /// Why `action` is refused for `record`, for whoever asked; nil when not.
    func refusal(_ action: LocalAction, for record: TeamServerRecord?) -> String? {
        guard refuses(record) else { return nil }
        switch action {
        case .decide, .stop:
            if let call = record as? Incoming, call.onThisDevice == false {
                return TeamServerCore.decidedElsewhere(call.executorDeviceName)
            }
            // The executor decides and stops through the server (D4, D4b).
            if action == .decide, record is Incoming, decideOnServer != nil { return nil }
            if action == .stop, record is Incoming, stopOnServer != nil { return nil }
            return TeamServerCore.decideNotYet
        case .cancel: return record is Outgoing && cancelOnServer != nil ? nil : TeamServerCore.cancelNotYet
        // The owner's Continue… of a server's call: a copy of its thread's
        // conversation (F6), once the app can find it; watching is not yet.
        case .carryOn: return record is Incoming && serverConversation != nil ? nil : TeamServerCore.watchNotYet
        case .watch: return TeamServerCore.watchNotYet
        case .folders: return record is Incoming && continueOnServer != nil ? nil : TeamServerCore.foldersNotYet
        }
    }
}

/// A call that is a server's request (D8). Shown and read like any call;
/// every action that would change it or start anything for it — decide,
/// stop, cancel, the old protocol's messages, delivery, the queue's runs,
/// watching, carrying on its conversation, folders — goes through this one
/// check and is refused until the server's path does it (D4, D5, D5b)
/// (review D8c, by class). The UI only mirrors it.
protocol TeamServerRecord {
    var scope: TeamCallScope? { get }
}

extension TeamServerRecord {
    var localActionsRefused: Bool { scope != nil }
}

extension TeamCalls.Incoming: TeamServerRecord {}
extension TeamCalls.Outgoing: TeamServerRecord {}

/// What team work through a server does not do yet, in one place: each is
/// a debt of the hardening tasks, owed before release as it worked in
/// 1.0.x — continuing a thread and cancelling (D5b), folders (D4b).
/// Publishing to the organization (D3): `ChatService` in the app.
@MainActor
protocol TeamPublishing: AnyObject {
    /// An assignment of the agent exists (any state): it is unpublished
    /// through the server before it goes; it may not be paused yet.
    func isAssigned(_ agentId: UUID) -> Bool
    /// Asks the publication of `agents` to `teams`, in one transaction of the journal.
    func publish(_ agents: [TeamPublishedAgent], teams: [String], key: ChatOrgKey) throws
    /// Asks the server to stop publishing the agent (D3b).
    func unpublish(_ agentId: UUID, key: ChatOrgKey) throws
    /// The organization the agent is published to, whichever is connected.
    func assignmentKey(_ agentId: UUID) -> ChatOrgKey?
}

enum TeamServerCore {
    static let publishFromWindow = "Publish agents from the AgentPad window for now."
    static let pauseNotYet = "Pausing an agent published to a server is not available in this build yet."
    static let changedMeanwhile = "The server connection changed while the agent was checked; nothing was published."
    static let cancelNotYet = "Cancelling a call through a server is not available yet."
    static let foldersNotYet = "Extending folder access through a server is not available yet."
    static let decideNotYet = "Deciding and stopping calls through a server is not available in this build yet."
    static let askNotYet = "Calling a colleague's agent through a server is not available in this build yet."
    static let watchNotYet = "Watching or carrying on a call through a server is not available in this build yet."
    static func decidedElsewhere(_ device: String?) -> String {
        "Decided on \(device.map { "“\($0)”" } ?? "the owner's other Mac")."
    }
}

/// The calls while team work is off: none. The files of 1.0.x are not
/// read (owner's decision); nothing is written.
struct TeamOffCallStore: TeamCallStore {
    func loadLog() throws -> TeamCalls.Log { TeamCalls.Log(incoming: [], outgoing: []) }
    func loadCall(_ id: String) throws -> TeamCalls.Log { try loadLog() }
    func saveLog(_ log: TeamCalls.Log) throws {}
    func loadThreads() throws -> [TeamCalls.Thread] { [] }
    func saveThreads(_ threads: [TeamCalls.Thread]) throws {}
}
