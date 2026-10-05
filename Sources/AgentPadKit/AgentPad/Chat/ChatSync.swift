import Foundation
import GRDB

/// Keeps one organization's cache in step with the server
/// (docs/agentpad/CHAT-PLAN.md C8): snapshot, then the snapshot's streams over
/// the socket, events applied through `ChatEvents`. Made for one
/// (server, account, organization) and one connection's token; the socket
/// is shared with the account's other organizations.
@MainActor
final class ChatSync: ChatStreamSink {
    enum State: Equatable {
        case starting
        case syncing
        case ready
        case failed(String)
    }

    let key: ChatOrgKey
    private let store: ChatStore
    private let api: ChatAPI
    private let token: String
    private weak var socket: ChatSocket?
    private weak var outbox: ChatOutbox?
    private(set) var state: State = .starting
    /// A new server generation was seen (D9 voids approvals of the old one).
    var onGenerationChanged: @MainActor (String) -> Void = { _ in }
    /// Voids approvals of other generations; a failure keeps the change pending.
    var voidApprovals: @MainActor (String) throws -> Void = { _ in }
    /// The run journal's record of the generation, when there is a journal.
    var generationState: ChatGenerationState?
    /// The requests of runs of this Mac without an outcome (the journal's).
    var runningRequests: () throws -> Set<String> = { [] }
    /// Tests: a step after the snapshot is written, that may fail.
    var afterSnapshotApplied: @MainActor () throws -> Void = {}
    /// The run journal's facts of these requests (D8); nil when there is no
    /// journal to ask.
    var localFacts: @MainActor ([String]) -> [String: ChatLocalFacts]? = { _ in nil }
    /// Requests changed and may owe actions: they run now (D8).
    var onCallsChanged: @MainActor () -> Void = {}
    /// The organization is in step with the server again: what waited for
    /// it may go on (review D8d-p2-4).
    var onInStep: @MainActor () -> Void = {}
    /// A snapshot and its pages are being read: changes are told once it is done.
    private var reading = false
    private var callsChangedOwed = false

    private func callsChanged() {
        if reading { callsChangedOwed = true } else { onCallsChanged() }
    }
    /// Snapshots taken, for tests and diagnostics.
    private(set) var snapshots = 0
    /// Rights of the user taken away, as seen: its own role changed, out of
    /// a team, out of the organization, the admin or a team stream dropped.
    /// A snapshot read before the latest of them may hold rights it no
    /// longer has: it is not applied, and another is read (review C6b p1-2).
    private(set) var revocations = 0
    /// Delay before snapshot retry `n`; shortened in tests.
    var retryDelay: (Int) -> TimeInterval = { n in max(1, min(60, pow(2, Double(n - 1)) * Double.random(in: 0.5...1.5))) }

    /// Snapshots asked for and the last one applied, counted: one is owed
    /// while a request is newer than what was applied — also while a snapshot
    /// is on its way, until its answer is applied (review C-10, C-14, C7-6).
    private var snapshotsAsked = 1 { didSet { onSnapshotOwed(needsSnapshot) } }
    private var snapshotsApplied = 0 { didSet { onSnapshotOwed(needsSnapshot) } }
    var needsSnapshot: Bool { snapshotsApplied < snapshotsAsked }
    /// Told whenever `needsSnapshot` may have changed (F2: what may be shown waits for it).
    var onSnapshotOwed: @MainActor (Bool) -> Void = { _ in }
    /// The socket epoch the last applied snapshot was read on.
    private(set) var snapshotEpoch: Int?
    /// The one snapshot on its way; only its owner starts another.
    private var snapshotting: Task<Void, Never>?
    private var retrying: Task<Void, Never>?
    private var failures = 0
    private var stopped = false
    /// The connection whose generation this organization began (`beginGeneration`).
    private var begun: Int?
    /// A connection it began readying but could not finish: `ready` is tried
    /// again after a pause, whatever step failed (review C16-1, C17-1).
    private var unfinished: ChatConnectionContext?
    private var readyRetry: Task<Void, Never>?
    private var readyFailures = 0

    init(key: ChatOrgKey, store: ChatStore, api: ChatAPI, socket: ChatSocket, outbox: ChatOutbox?, token: String) {
        self.key = key
        self.store = store
        self.api = api
        self.socket = socket
        self.outbox = outbox
        self.token = token
    }

    var myAccountId: String { key.accountId }
    /// The session this synchronizer's token is of: its snapshots confirm
    /// rights for it alone (C6i).
    var sessionId: String?
    private var memberStream: String { "member:\(key.orgId):\(key.accountId)" }

    /// The streams of the last snapshot: this organization's set on the socket.
    private(set) var followed: Set<String> = []
    /// F3: channels with an open tab (their ids), and the streams of those
    /// followed — within the socket's budget; not waited for to be ready.
    private var openChannels: Set<String> = []
    private(set) var followedChannels: Set<String> = []
    /// Open channels not followed: over the budget, or refused for the socket's limit.
    var onChannelsPaused: @MainActor (Set<String>) -> Void = { _ in }
    /// `readOne`s on their way (with their retries), by message id.
    private var oneInFlight: Set<String> = []
    /// The revision each single read must reach, raised by asks meanwhile.
    private var oneWanted: [String: Int] = [:]
    /// Single reads of messages the live feed brought without their text:
    /// their notice is decided once read (review F4b-3).
    private var oneLive: Set<String> = []
    /// The channels followed now, by id (F4).
    var onFollowed: @MainActor (Set<String>) -> Void = { _ in }
    /// A message deleted: its notice goes (F4).
    var onMessageGone: @MainActor (_ channel: String, _ messageId: String) -> Void = { _, _ in }
    /// A message the live feed brought, wholly in the cache now (F4).
    var onLiveMessage: @MainActor (_ channel: String, _ messageId: String) -> Void = { _, _ in }
    /// Pause before single read `n` again; shortened in tests.
    var oneRetryDelay: (Int) -> TimeInterval = { n in pow(2, Double(n)) }
    /// A single read ended, however: whoever waits looks again.
    var onOneRead: @MainActor (String) -> Void = { _ in }
    /// Single reads under way, and those asked again meanwhile, by message id.
    private var readingOne: Set<String> = []
    private var readOneAgain: Set<String> = []

    /// The first snapshot; retried until it works.
    func start() async {
        await snapshotNow()
    }

    func stop() {
        stopped = true
        snapshotting?.cancel()
        retrying?.cancel()
        readyRetry?.cancel()
        socket?.detach(self)
    }

    /// Asks for a snapshot; it is owed until one succeeds.
    func requestSnapshot() {
        askSnapshot()
        Task { await self.snapshotNow() }
    }

    private func askSnapshot() {
        notInStep()
        snapshotsAsked += 1
    }

    /// Takes the snapshot owed, one at a time: after every wait the owner is
    /// looked at again, so two never run together and an older answer is
    /// never applied after a newer one (review C7-6). A failure schedules a retry.
    func snapshotNow() async {
        while let running = snapshotting {
            await running.value
        }
        guard !stopped, needsSnapshot else { return }
        let asked = snapshotsAsked
        let task = Task { [weak self] in
            guard let self else { return }
            // Cleared by the task itself, before anyone waiting on it goes on.
            defer {
                self.snapshotting = nil
                self.recheckReady()
            }
            do {
                try await self.snapshot(answering: asked)
                self.failures = 0
            } catch ChatSyncError.readBeforeRevocation {
                // Not a failure: read again at once, by whoever waits, or here.
                if !self.stopped { Task { await self.snapshotNow() } }
            } catch {
                guard !self.stopped else { return }
                self.failures += 1
                if self.followed.isEmpty { self.state = .failed(error.localizedDescription) }
                self.scheduleRetry()
            }
        }
        snapshotting = task
        await task.value
    }

    private func scheduleRetry() {
        retrying?.cancel()
        let wait = retryDelay(failures)
        retrying = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled, !self.stopped else { return }
            await self.snapshotNow()
        }
    }

    /// Readies a synchronizer made while a connection is up for that
    /// connection, then lets the queue send on it: the generation begun once,
    /// the snapshot and generation finished. Any step that fails is tried
    /// again after a pause, until it works or the connection is no longer
    /// current — without a reconnect (review C2-7, C16-1, C17-1).
    func ready(for context: ChatConnectionContext) async -> Bool {
        guard let socket, !stopped, socket.isCurrent(context) else { return false }
        unfinished = context
        if begun != context.id {
            guard beginGeneration(context) else { return readyAgainLater(context) }
            begun = context.id
        }
        guard await prepare(context), !stopped, socket.isCurrent(context) else { return readyAgainLater(context) }
        unfinished = nil
        readyFailures = 0
        outbox?.allow(connection: context.id, generation: context.generation)
        return true
    }

    /// Schedules `ready` for `context` again; false, for `ready` to return.
    private func readyAgainLater(_ context: ChatConnectionContext) -> Bool {
        guard !stopped, socket?.isCurrent(context) == true else {
            unfinished = nil
            return false
        }
        readyFailures += 1
        let wait = retryDelay(readyFailures)
        readyRetry?.cancel()
        readyRetry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled, !self.stopped, self.unfinished?.id == context.id else { return }
            _ = await self.ready(for: context)
        }
        return false
    }

    /// Takes the snapshot and makes the socket follow exactly its streams,
    /// each again from the snapshot's cursor: events applied while the
    /// snapshot was on its way were overwritten and come again (review C-9).
    private func snapshot(answering asked: Int) async throws {
        let epoch = socket?.epoch
        let revoked = revocations
        // Where the channel read's starting slice ends: taken before the
        // network, so a card an event writes meanwhile is not in it (review F2b-2).
        let channelStamp = try store.channelStamp()
        let state = try await api.orgState(key.orgId, token: token)
        // Read for another connection than the one now: not applied (review C3-2).
        guard !stopped, socket?.epoch == epoch else { throw CancellationError() }
        // Read before rights were taken away: it would give them back.
        guard revocations == revoked else {
            askSnapshot()
            throw ChatSyncError.readBeforeRevocation
        }
        // Actions wait for the whole read — snapshot, pages, what is lost —
        // also those events bring meanwhile (review D8d-p2-3).
        reading = true
        defer {
            reading = false
            if callsChangedOwed {
                callsChangedOwed = false
                onCallsChanged()
            }
        }
        callsChangedOwed = true
        snapshots += 1
        let wanted = Set(state.streams.keys)
        // The cache holds this organization only: any other cursor is a
        // stream it no longer has (a team left) — dropped with the snapshot,
        // a failure keeps it owed.
        let snapshot = state.snapshot
        let ids = Set(try store.calls.requestIds()).union((snapshot.requests ?? []).map(\.requestId))
        // Read after the last sign (else not applied, above): it ends the
        // doubt in its own transaction, so the model sees both at once.
        try store.apply(snapshot, following: wanted, facts: localFacts(Array(ids)), confirmsRights: sessionId)
        // The doubt is over: a write of it still owed is not made.
        doubtWrites += 1
        onStorageProblem(false)
        try afterSnapshotApplied()
        let before = followed
        followed = wanted
        guard let socket else { return }
        socket.unsubscribe(Array(before.subtracting(wanted)))
        socket.subscribe(Array(wanted.subtracting(before)), sink: self)
        socket.resubscribe(Array(wanted.intersection(before)))
        // Resubscribed now; the channels pages below may bring more, so it is done again after them.
        followChannels(resubscribe: true)
        // Channels the snapshot left out, then the read's end (F2). After
        // every wait, as for the snapshot: a page read before rights were
        // taken away would give them back (review F2-3).
        if let first = state.channels {
            var seen = Set(first.map(\.channelId))
            var after = state.channelsNext
            while let cursor = after {
                let page = try await api.channelsPage(key.orgId, after: cursor, token: token)
                guard !stopped, socket.epoch == epoch else { throw CancellationError() }
                guard revocations == revoked else {
                    askSnapshot()
                    throw ChatSyncError.readBeforeRevocation
                }
                seen.formUnion(try store.apply(channels: page.channels))
                after = page.next == cursor ? nil : page.next
            }
            try store.endChannelsRead(since: channelStamp, seen: seen)
            // The pages' cards and the cards gone: what is followed follows them (review F3b-p1-5).
            followChannels(resubscribe: false)
        }
        // Requests the snapshot left out, a page at a time; the rule of
        // versions makes their order against events not matter.
        var next = state.requestsNext
        while let before = next {
            let page = try await api.requestsPage(key.orgId, before: before, token: token)
            // Read for another connection than the one now — perhaps of an
            // earlier server generation: not applied (review D8-2).
            guard !stopped, socket.epoch == epoch else { throw CancellationError() }
            try store.apply(requests: page.requests, facts: localFacts(page.requests.map(\.requestId)))
            next = page.next == before ? nil : page.next
        }
        // The whole read is in: a call of this Mac being read anew that it
        // did not list is lost (a server without calls lists none: nothing
        // then); what history no longer shows loses its heavy texts.
        if state.requests != nil {
            try store.endResync(facts: localFacts(try store.calls.requestIds(in: .resyncing)))
        }
        try store.calls.trim()
        self.state = .syncing
        // Paid only once every step of it is done: a failure on the way keeps
        // it owed and the retry takes it again (review C8-6).
        snapshotsApplied = max(snapshotsApplied, asked)
        snapshotEpoch = epoch
    }

    // MARK: The connection's hello (called by ChatFeed)

    /// Readies the organization for connection `context`: the snapshot still
    /// owed, then the server generation. True when the queue may send on this
    /// connection. Each step checks the connection is still current before it
    /// changes anything (review C2-5).
    ///
    /// A new generation is handled durably (review C2-8): it is written as
    /// pending first, then the queues are marked unconfirmed and approvals of
    /// other generations voided, then a snapshot is taken, and only then is
    /// it stored as handled. A failure on the way leaves it pending; the next
    /// `hello` does it again.
    /// The first step of a hello, before anything waits: when the server
    /// generation is not the one kept, the change begins — written as
    /// pending with the cache's server part emptied (read anew: lead's
    /// decision after review D8h), approvals of other generations void, the
    /// queues unconfirmed — so nothing of the old generation can run or be
    /// sent meanwhile, and no action runs until it is settled (review C2-8,
    /// C3-3, D8h-p2-1). False when that could not be written.
    func beginGeneration(_ context: ChatConnectionContext) -> Bool {
        guard let socket, !stopped, socket.isCurrent(context) else { return false }
        let generation = context.generation
        do {
            let (known, pending) = try generationKept()
            // Commands kept from before with no generation recorded are not a
            // first connection: they may belong to a restored server (review C4-5).
            // (Commands made since this queue opened were made for this server now.)
            let since = outbox?.openedAt ?? .distantFuture
            let keptCommands = try (outbox?.queues ?? [store.outbox]).contains { table in
                try table.commands().contains { $0.state == .pending && $0.createdAt < since }
            }
            if known == nil, pending == nil, !keptCommands {
                // Nothing of this organization was ever kept: its first generation.
                for state in generationStates { try state.finish(key, generation) }
            } else if known == generation, pending == nil {
                // The same generation: every store records it (a journal made
                // after the cache, or migrated without it, learns it now).
                for state in generationStates where try state.generation(key).generation != generation {
                    try state.finish(key, generation)
                }
            } else {
                settled = nil
                try generationState?.setPending(key, generation)
                // Runs of this Mac without an outcome keep their request (review D8i-p2-5).
                try store.beginGeneration(generation, keeping: try runningRequests())
                try voidApprovals(generation)
                try outbox?.generationChanged()
                onGenerationChanged(generation)
                // The cache was emptied of the server's part: the view follows.
                callsChanged()
                askSnapshot()
            }
            return true
        } catch {
            return false
        }
    }

    /// The rest of a hello: the snapshot owed, then a pending generation is
    /// stored as handled. Each step checks the connection is still current
    /// before it changes anything (review C2-5). True when the queue may send
    /// on this connection.
    func prepare(_ context: ChatConnectionContext) async -> Bool {
        guard let socket, !stopped else { return false }
        // A snapshot owed or on its way is waited for: the hello is done only
        // with it applied (review C7-6).
        var tries = 0
        while needsSnapshot || snapshotting != nil {
            // A snapshot read on the connection before this one is not applied;
            // one more is taken for this one. Failing again, the hello is not done.
            guard socket.isCurrent(context), !stopped, tries < 3 else { return false }
            tries += 1
            await snapshotNow()
        }
        guard socket.isCurrent(context), !stopped, !needsSnapshot else { return false }
        do {
            if try generationKept().pending != nil {
                for state in generationStates { try state.finish(key, context.generation) }
            }
        } catch {
            return false
        }
        settled = context.id
        // Actions wait for this (review D8h-p2-1).
        onInStep()
        return true
    }

    /// The connection whose generation this organization settled: its
    /// snapshot read and the generation stored, in the journal and the cache.
    private var settled: Int?

    /// Actions may run on the socket's connection now: it is the one whose
    /// generation was settled here — a new generation begun clears it
    /// (review D8h-p2-1).
    func isSettled(on socket: ChatSocket) -> Bool {
        settled != nil && socket.context?.id == settled
    }

    /// The journal keeps the generation of the commands it holds: a cache
    /// deleted or made anew does not forget it (review C3-4).
    private var generationStates: [ChatGenerationState] { (generationState.map { [$0] } ?? []) + [store] }

    private func generationKept() throws -> (generation: String?, pending: String?) {
        let journalSays = try generationState?.generation(key)
        let cacheSays = try store.generation(key)
        return (journalSays?.generation ?? cacheSays.generation, journalSays?.pending ?? cacheSays.pending)
    }

    // MARK: ChatStreamSink

    func cursor(_ stream: String) -> Int { (try? store.cursor(stream)) ?? 0 }

    func apply(_ event: ChatEvent) -> Bool {
        // A sign of rights taken away counts before it is written: a write
        // that fails changes nothing of it (review C6e p1-2).
        if event.seq > cursor(event.stream), event.body["account_id"]?.string == myAccountId {
            if mayRevoke(event) {
                rightsInDoubt()
                if event.type == "member.remove" { onMembershipInDoubt() }
            } else if ["team.leave", "team.remove_member"].contains(event.type) {
                revocations += 1
            }
        }
        let applied: ChatStore.Applied
        // A request's event: the journal's facts of it, read first.
        let request = ChatCallStore.reads(event) ? event.body["request_id"]?.string : nil
        do { applied = try store.apply(event, facts: request.flatMap { localFacts([$0]) }) } catch {
            // Out of a team, not written: what it took out may still show (C6f p1-2).
            if event.body["account_id"]?.string == myAccountId, ["team.leave", "team.remove_member"].contains(event.type) {
                rightsInDoubt()
            }
            notInStep()
            return false
        }
        guard applied == .applied || applied == .passedOver else { return true }
        // F4: a post the live feed brought — not a catch-up, not during a snapshot — may owe a notice.
        if event.type == "message.post", event.stream.hasPrefix("channel:"), let id = event.body["message_id"]?.string {
            let channel = String(event.stream.dropFirst("channel:".count))
            let live = !reading && socket?.syncing.contains(event.stream) == false
            if event.message != nil {
                if live { onLiveMessage(channel, id) }
            } else if let seq = event.body["message_seq"]?.int {
                // Read in a catch-up too, whether or not its channel is open: the
                // count needs who wrote it (review F4b-2); told only if live.
                readOne(channel, id: id, seq: seq, atLeast: event.body["revision"]?.int ?? 0, live: live)
            }
        }
        if event.type == "message.delete", event.stream.hasPrefix("channel:"), let id = event.body["message_id"]?.string {
            onMessageGone(String(event.stream.dropFirst("channel:".count)), id)
        }
        // A channel that came — or went with a team — may be one open in a tab (F3).
        if ChatChannels.eventTypes.contains(event.type) || ["team.leave", "team.remove_member", "team.archive"].contains(event.type) {
            followChannels(resubscribe: false)
        }
        if request != nil {
            callsChanged()
        } else if Self.callViewTypes.contains(event.type) || ChatCallStore.reads(event) {
            // Names and the catalog the calls are shown with (review D8d-p2-11).
            callsChanged()
        }
        // An event this build did not wholly apply: its effect comes with a
        // snapshot, not lost in silence (review D8f-p3-1, D8g-p3-3).
        if applied == .passedOver { requestSnapshot() }
        // Added to a team, or joined one: its stream joins the set, with the
        // team's state from a new snapshot, without reconnecting; owed until
        // it works.
        let mine = event.body["account_id"]?.string == myAccountId
        if mine, ["team.add_member", "team.join"].contains(event.type), event.stream == memberStream {
            requestSnapshot()
        } else if mine, ["team.leave", "team.remove_member"].contains(event.type), let team = event.body["team_id"]?.string {
            // Out of the team (the cache dropped its cursor with the event):
            // the way of a stream the server stopped, readiness looked at again.
            let stream = "team:\(team)"
            if followed.contains(stream) {
                socket?.unsubscribe([stream])
                dropped(stream)
            }
        }
        return true
    }

    /// Whether the event may take a manager's rights or the organization
    /// away: the user's own role, or its own removal. Out of a team is no
    /// such sign — the event itself takes the team out of the cache — but a
    /// snapshot read before it would bring it back: it counts as a revocation.
    private func mayRevoke(_ event: ChatEvent) -> Bool {
        guard event.body["account_id"]?.string == myAccountId else { return false }
        return ["member.set_role", "member.remove"].contains(event.type)
    }

    // MARK: Rights in doubt (review C6e)

    /// Rights are never worked out here, nor taken away piece by piece. A
    /// sign they may have changed puts them in doubt: the window shows what
    /// any member sees, a snapshot is read, and one read before the latest
    /// sign is not applied. Only a snapshot applied after it ends the doubt.
    /// The doubt could not be written: the window shows nothing of the
    /// organization until it is — written on a retry, or ended by a snapshot.
    var onStorageProblem: @MainActor (Bool) -> Void = { _ in }
    /// Writes of the doubt: a retry counts only for the latest sign, and none
    /// after a snapshot ended it.
    private var doubtWrites = 0
    /// A sign the account may be out of the organization: `/v1/me` decides.
    var onMembershipInDoubt: @MainActor () -> Void = {}

    /// The doubt is written to the cache (kept across launches); a write
    /// that fails keeps it in memory instead (`onRightsInDoubt`).
    /// `snapshot`: false when the caller's own way already reads one (an
    /// `account.membership_changed` reads `/v1/me`, whose answer does).
    /// The doubt is kept only in the cache; a write that fails is tried
    /// again after a pause until it works (review C6g p1-2).
    func rightsInDoubt(snapshot: Bool = true) {
        revocations += 1
        doubtWrites += 1
        writeDoubt(doubtWrites, attempt: 1)
        if snapshot { requestSnapshot() }
    }

    private func writeDoubt(_ write: Int, attempt: Int) {
        guard !stopped, write == doubtWrites else { return }
        do {
            try store.putRightsInDoubt()
            onStorageProblem(false)
        } catch {
            onStorageProblem(true)
            let wait = retryDelay(attempt)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                self?.writeDoubt(write, attempt: attempt + 1)
            }
        }
    }

    func resync(_ stream: String) async throws {
        askSnapshot()
        await snapshotNow()
        if needsSnapshot { throw ChatError.storage("the snapshot could not be taken") }
    }

    func ready(_ stream: String, head: Int) { recheckReady() }

    /// Ready when every followed stream is caught up, none is stuck and no
    /// snapshot is owed or on its way (review C8-5); looked at again whenever
    /// the set of streams changes (review C8-7).
    private func recheckReady() {
        // Only `followed`: channel streams are not waited for (review F3-5).
        guard let socket, !needsSnapshot, snapshotting == nil, socket.syncing.isDisjoint(with: followed),
              socket.stuck.isDisjoint(with: followed), !followed.isEmpty || state == .syncing
        else { return }
        let was = readyEpoch
        state = .ready
        readyEpoch = socket.epoch
        // In step on this connection now — also after a reconnect that left
        // the state `.ready` (review D8e-p2-3).
        if was != readyEpoch { onInStep() }
    }

    func catchingUp(_ stream: String) { notInStep() }

    /// The socket epoch at which it became ready: ready for that connection only.
    private(set) var readyEpoch: Int?

    /// The cache fell out of step with the server (an event not written, a
    /// snapshot owed): not ready until it is again (review C6-5).
    private func notInStep() {
        if state == .ready { state = .syncing }
        readyEpoch = nil
    }

    /// Events without a request that change how calls are shown.
    static let callViewTypes: Set<String> = ["member.joined", "member.set_name", "agent.publish", "agent.unpublish"]

    func dropped(_ stream: String) {
        // A channel's stream refused: the rights are in doubt; its card is the snapshot's (F3).
        if stream.hasPrefix("channel:") {
            followedChannels.remove(stream)
            rightsInDoubt()
            channelsPausedChanged()
            return
        }
        followed.remove(stream)
        // The organization's own stream refused: perhaps out of it — `/v1/me`
        // decides, the core's way (C6f p1-4).
        if stream == "org:\(key.orgId)" {
            rightsInDoubt()
            onMembershipInDoubt()
        }
        // The admin stream refused: a manager's rights in doubt. A team's: the
        // team leaves the cache here; a snapshot read before must not bring it back.
        if stream.hasPrefix("org-admin:") { rightsInDoubt() } else if stream.hasPrefix("team:") { revocations += 1 }
        defer { callsChanged() }
        do { try store.drop(stream: stream) } catch {
            // Not removed: the cache is not in step; a snapshot drops it
            // (it is not among its streams), and the retries are its (review C9-5).
            // A team's data may still show: its rights are in doubt (C6f p1-2).
            if stream.hasPrefix("team:") { rightsInDoubt() }
            askSnapshot()
            Task { await self.snapshotNow() }
            return
        }
        recheckReady()
    }
}

/// The account's own stream, `account:<id>` (C8): pointers only. Followed
/// from its head in `/v1/me`, so history never notifies; it lives whether
/// or not the account is in its organization.
@MainActor
final class ChatAccountFeed: ChatStreamSink {
    let stream: String
    private let sessionId: String
    /// Unknown until `/v1/me` answered; the stream is not followed before.
    private(set) var cursor: Int?
    private weak var socket: ChatSocket?
    /// Reads `/v1/me`; nil when it failed.
    var readMe: @MainActor () async -> ChatMe? = { nil }
    /// What `/v1/me` says, each time it is read.
    var onMe: @MainActor (ChatMe) async -> Void = { _ in }
    /// `account.membership_changed` of an organization.
    var onMembershipChanged: @MainActor (String) -> Void = { _ in }
    /// "A new device signed in to your account: <name>".
    var onNotice: @MainActor (String) -> Void = { _ in }
    var retryDelay: (Int) -> TimeInterval = { n in max(1, min(60, pow(2, Double(n - 1)) * Double.random(in: 0.5...1.5))) }

    /// `/v1/me` is owed until it is read (review C-14); `resetCursor` moves
    /// the cursor to its head even backwards (review C-12).
    private(set) var needsMe = true
    private var resetCursor = false
    private var lastGeneration: String?
    private var failures = 0
    private var retrying: Task<Void, Never>?
    private var reading = false
    private var stopped = false

    init(accountId: String, sessionId: String, socket: ChatSocket) {
        stream = "account:\(accountId)"
        self.sessionId = sessionId
        self.socket = socket
    }

    func stop() {
        stopped = true
        retrying?.cancel()
        socket?.detach(self)
    }

    /// Reads `/v1/me` if it is owed; retried until it works. A new reason
    /// to read it that comes while it is read reads it again.
    func refresh() async {
        guard needsMe, !reading, !stopped else { return }
        reading = true
        needsMe = false
        let reset = resetCursor
        resetCursor = false
        let epoch = socket?.epoch
        var answer = await readMe()
        reading = false
        guard !stopped else { return }
        // Read for another connection than the one now: not used (review C3-2).
        if socket?.epoch != epoch { answer = nil }
        guard let me = answer else {
            needsMe = true
            if reset { resetCursor = true }
            failures += 1
            let wait = retryDelay(failures)
            retrying?.cancel()
            retrying = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
            return
        }
        failures = 0
        let head = me.streams[stream] ?? 0
        if cursor == nil {
            cursor = head
            socket?.subscribe([stream], sink: self)
        } else if reset {
            cursor = head
            socket?.resubscribe([stream])
        }
        await onMe(me)
        if needsMe { await refresh() }
    }

    /// The connection's `hello` (called by ChatFeed): another generation
    /// means the head counts, wherever the cursor was.
    func prepare(_ context: ChatConnectionContext) async {
        if let lastGeneration, lastGeneration != context.generation {
            needsMe = true
            resetCursor = true
        }
        lastGeneration = context.generation
        await refresh()
    }

    func cursor(_ stream: String) -> Int { cursor ?? 0 }

    func apply(_ event: ChatEvent) -> Bool {
        defer { cursor = event.seq }
        switch event.type {
        case "account.membership_changed":
            // The organization's rights in doubt too, until its snapshot (C6f p1-3).
            if let org = event.body["org_id"]?.string { onMembershipChanged(org) }
            readMeAgain()
        case "account.session_opened":
            guard event.body["session_id"]?.string != sessionId else { return true }
            onNotice("A new device signed in to your account: \(event.body["device_name"]?.string ?? "unnamed")")
        default:
            break
        }
        return true
    }

    /// `/v1/me` is read again, as on `account.membership_changed`.
    func readMeAgain() {
        needsMe = true
        Task { await refresh() }
    }

    func resync(_ stream: String) async throws {
        needsMe = true
        resetCursor = true
        await refresh()
        if needsMe { throw ChatError.storage("/v1/me could not be read") }
    }

    func ready(_ stream: String, head: Int) { cursor = max(cursor ?? 0, head) }
    func dropped(_ stream: String) {}
}

// MARK: Channels (F3)

extension ChatSync {
    /// Streams a socket may follow, and the room kept beside the organization's (review F3-5).
    static let streamsReserve = 10
    /// The server's limit; lowered in tests.
    static var socketStreams = 500

    /// The channels with an open tab now (DESIGN-F3, "Подписка").
    func setOpenChannels(_ ids: Set<String>) {
        openChannels = ids
        followChannels(resubscribe: false)
    }

    /// Follows the open channels that have a card and a cursor, in the
    /// budget the socket leaves after the organization's streams.
    func followChannels(resubscribe: Bool) {
        guard let socket, !stopped else { return }
        // Every channel with a cursor, the latest active first (F4: unread and
        // notices of channels not open too); open tabs before all of them.
        let kept = (try? store.queue.read { db in
            try String.fetchAll(db, sql: "SELECT substr(stream, 9) FROM cursors WHERE stream LIKE 'channel:%' ORDER BY seq DESC, stream")
        }) ?? []
        let budget = max(0, Self.socketStreams - socket.followedCount(excludingPrefix: "channel:") - Self.streamsReserve)
        let open = kept.filter { openChannels.contains($0) }.sorted()
        let order = open + kept.filter { !openChannels.contains($0) }
        let wanted = Set(order.prefix(budget).map { "channel:\($0)" })
        let before = followedChannels
        followedChannels = wanted
        socket.unsubscribe(Array(before.subtracting(wanted)))
        socket.subscribe(Array(wanted.subtracting(before)), sink: self)
        if resubscribe { socket.resubscribe(Array(wanted.intersection(before))) }
        channelsPausedChanged()
        onFollowed(Set(wanted.map { String($0.dropFirst("channel:".count)) }))
    }

    /// Open channels without live events: not followed, or held by the socket's limit.
    var pausedChannels: Set<String> {
        let limited = socket?.limitedStreams ?? []
        return Set(openChannels.filter { !followedChannels.contains("channel:\($0)") || limited.contains("channel:\($0)") })
    }

    private func channelsPausedChanged() { onChannelsPaused(pausedChannels) }

    enum ChannelRead: Equatable {
        /// The continuous history, down from `history_next`.
        case history
        /// A thread: its first page, or (`more`) on from its own cursor.
        case thread(root: String, more: Bool)
        /// One message only; the window stays (review F3-3).
        case one(id: String, seq: Int)
    }

    /// Reads a page of `channel` and applies it only in the window, the
    /// rights and the connection it was asked in (DESIGN-F3, "Чтения с
    /// эпохой"). A refusal of access puts the rights in doubt (review F3-1).
    enum ChannelReadOutcome: Equatable {
        case applied
        /// Not applied: another window, connection or rights since — or one already on its way.
        case void
        /// No answer, or the server failed: worth asking again after a pause.
        case failed
        /// Access refused: the rights are in doubt now.
        case refused
    }

    /// The one way a single message is read (review F3c-2): one at a time
    /// for each, and asked again after a pause — 2ⁿ s, at most a minute —
    /// while it fails; any other outcome ends it.
    /// `atLeast`: the revision wanted; asked while a read is on its way, it
    /// is kept, and the read goes again until the cache has it (review F3d-2).
    func readOne(_ channel: String, id: String, seq: Int, atLeast revision: Int = 0, live: Bool = false) {
        oneWanted[id] = max(oneWanted[id] ?? 0, revision)
        if live { oneLive.insert(id) }
        guard !oneInFlight.contains(id) else { return }
        oneInFlight.insert(id)
        Task { [weak self] in
            var failures = 0, voids = 0, short = 0
            var last = ChannelReadOutcome.void
            while let self, !self.stopped {
                let outcome = await self.readChannel(channel, .one(id: id, seq: seq))
                last = outcome
                if outcome == .void, voids < 3 {
                    // Read in a window or connection since replaced: again, in this one.
                    voids += 1
                    continue
                }
                if outcome == .applied {
                    // A newer revision wanted meanwhile, and the page had an older one: again, after a pause.
                    let have = (try? await self.store.queue.read { db in
                        try Int.fetchOne(db, sql: "SELECT revision FROM messages WHERE message_id = ? AND has_mutable = 1", arguments: [id])
                    }) ?? nil
                    guard (have ?? 0) < (self.oneWanted[id] ?? 0), short < 3 else { break }
                    short += 1
                    try? await Task.sleep(for: .seconds(min(60, self.oneRetryDelay(short))))
                    continue
                }
                guard outcome == .failed else { break }
                failures += 1
                try? await Task.sleep(for: .seconds(min(60, self.oneRetryDelay(failures))))
            }
            self?.oneInFlight.remove(id)
            self?.oneWanted[id] = nil
            // Read: its notice decided now; not read — none (review F4b-3).
            if self?.oneLive.remove(id) != nil, last == .applied { self?.onLiveMessage(channel, id) }
            self?.onOneRead(id)
        }
    }

    @discardableResult
    func readChannel(_ channel: String, _ kind: ChannelRead) async -> ChannelReadOutcome {
        if case .one(let id, _) = kind {
            guard !readingOne.contains(id) else { readOneAgain.insert(id); return .void }
            readingOne.insert(id)
        }
        defer {
            if case .one(let id, let seq) = kind {
                readingOne.remove(id)
                if readOneAgain.remove(id) != nil { Task { await self.readChannel(channel, .one(id: id, seq: seq)) } }
            }
        }
        let epoch = socket?.epoch
        let revoked = revocations
        guard let window = try? await store.queue.read({ db -> (epoch: Int, next: Int?, thread: Int??) in
            let row = try Row.fetchOne(db, sql: "SELECT epoch, history_next FROM channel_windows WHERE channel_id = ?", arguments: [channel])
            var thread: Int?? = nil
            if case .thread(let root, true) = kind {
                thread = try Row.fetchOne(db, sql: "SELECT next FROM thread_cursors WHERE channel_id = ? AND root_id = ?",
                                          arguments: [channel, root]).map { $0["next"] as Int? }
            }
            return (row?["epoch"] ?? 0, row?["history_next"], thread)
        }) else { return .failed }
        let before: Int?
        var root: String?
        switch kind {
        case .history:
            guard let next = window.next else { return .void }
            before = next
        case .thread(let r, let more):
            root = r
            if more {
                guard case .some(.some(let next)) = window.thread else { return .void }
                before = next
            } else {
                before = nil
            }
        case .one(_, let seq):
            before = seq + 1
        }
        do {
            let page = try await api.messagesPage(key.orgId, channel: channel, root: root, before: before, token: token)
            guard !stopped, socket?.epoch == epoch, revocations == revoked else { return .void }
            return try await store.queue.write { db -> ChannelReadOutcome in
                guard try ChatMessages.current(db, channel, epoch: window.epoch) else { return .void }
                switch kind {
                case .history: try ChatMessages.applyHistory(db, channel: channel, page: page)
                case .thread(let r, _): try ChatMessages.applyThread(db, channel: channel, root: r, epoch: window.epoch, page: page)
                case .one(let id, _): try ChatMessages.applyOne(db, id: id, page: page)
                }
                return .applied
            }
        } catch ChatAPIError.server(_, let code, _) where code == "forbidden" || code == "not_found" {
            rightsInDoubt()
            if code == "not_found" { onMembershipInDoubt() }
            return .refused
        } catch {
            return .failed
        }
    }
}

enum ChatSyncError: Error {
    /// A snapshot read before the user's rights were taken away.
    case readBeforeRevocation
}
