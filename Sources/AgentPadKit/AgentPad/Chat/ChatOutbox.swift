import Foundation

/// The send queue of one organization (docs/agentpad/CHAT-PLAN.md C2). A
/// command gets its `command_id` and its bytes once; every repeat sends the
/// same bytes. A first DM keeps its two wire IDs in one durable queue row,
/// resolving its peer address before posting. Commands with one `order_key` go one after another, except
/// suspended protocol work; its dependents remain suspended as well.
///
/// | Answer | What happens |
/// |---|---|
/// | network error, 5xx | repeated with the same id after 1…60 s, jittered |
/// | 429 | repeated after `Retry-After` (else as above) |
/// | 401 | the queue stops: sign in again; records stay |
/// | 400, 403, 404, 409, 413 | failed with the code, reported once |
@MainActor
@Observable
final class ChatOutbox {
    /// Commands whose business key carries them to a new session (6.4).
    static let carriedOver: Set<String> = [
        "request.create", ChatChannelAsk.commandType, "run.started", "run.finished", "run.failed", "run.failed_to_start", "result.deliver",
        // The user's word to end a call, and the facts of a stop (DESIGN-D3b-D4b-D5b §10.5, §11.4).
        "request.cancel", "request.stop", "run.stopped", "run.stop_failed",
    ]
    /// A command refused because its request has already ended: its debt is
    /// paid, never asked again (lead's rule after the server's d8d2ea0).
    static let requestEnded = "request_ended"
    /// Never sent again by hand after the server's generation changed.
    static func neverResent(_ type: String) -> Bool {
        ChatB1.commands.contains(type) || type.hasPrefix("run.") || type == "request.decide" || type == "request.decide_automatic"
            || type == "agent.channel_trust.set"
            || type == "message.post_with_attachments" || type == "request.create_in_channel_with_attachments"
            || type == "message.post_from_session" || type == "request.create_in_channel_v2" || ChatPublication.isDecision(type)
    }
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// Why the queue stopped; cleared only by what answers that reason.
    enum Pause: Equatable {
        case needsSignIn
        case generationChanged
        /// The queue could not be written: nothing goes until it can (review C-8).
        case storageFailed(String)
    }

    private(set) var queues: [ChatCommandTable]
    private let api: ChatAPI
    private var token: String
    private(set) var sessionId: String
    private(set) var paused: Pause?
    /// The connection whose `hello` confirmed the generation; nothing is sent
    /// without one, whatever `paused` says (review C2-1). Kept apart from
    /// `paused`: a new session does not lift it, only the next `hello` does.
    private(set) var allowedConnection: Int?
    /// The server generation of that connection.
    private(set) var allowedGeneration: String?
    /// The session whose rules the stored commands follow: set once the
    /// carry-over to it was written. Until it is `sessionId`, nothing is
    /// sent, and trying storage again repeats the carry-over (review C13-6).
    private var carriedTo: String?
    /// May send now.
    var isSending: Bool { paused == nil && allowedConnection != nil && carriedTo == sessionId }
    /// After a new generation, while the user has not decided on what was
    /// left unconfirmed: the run journal's commands made since still go. They
    /// are the executor's facts, rebuilt from the journal, and decisions of
    /// the buttons pressed since — no user consent is owed for them (D4,
    /// review D4-p2-1); the unconfirmed ones wait, as everything of the
    /// organization's queue does.
    private var sendsFacts: Bool {
        paused == .generationChanged && allowedConnection != nil && carriedTo == sessionId && queues.count > 1
    }

    private func may(send queue: ChatCommandTable) -> Bool {
        isSending || (sendsFacts && queue === queues[1])
    }

    /// A command failed for good: the owner of the command ends what waits on it (D5).
    var onPermanentFailure: @MainActor (ChatCommandRecord, String) -> Void = { _, _ in }
    /// A command was accepted, with the server's answer.
    var onSent: @MainActor (ChatCommandRecord, ChatCommandAnswer?) -> Void = { _, _ in }
    /// A first DM's durable address was resolved. Hydration is presentation
    /// work; posting does not wait for it or depend on a DM snapshot epoch.
    var onDMOpened: @MainActor (String) -> Void = { _ in }
    /// The server refused a command for good (4xx but 401 and 429), told as
    /// the answer comes, before its record is written.
    var onRefused: @MainActor (ChatCommandRecord, String) -> Void = { _, _ in }
    /// 401: the session is closed; the user signs in again.
    var onUnauthorized: @MainActor () -> Void = {}
    /// The queue may send on a connection now — allowed for it (by its hello
    /// or a late readying) or going on after the user's Try Again: what
    /// waited for a known server is looked at again (review C18-1).
    var onReady: @MainActor () -> Void = {}
    var maySendCommand: @MainActor (ChatCommandRecord) -> Bool = { _ in true }
    /// Unsupported attachment work waits without blocking independent text.
    var isSuspended: @MainActor (ChatCommandRecord) -> Bool = { _ in false }
    var permanentRejection: @MainActor (ChatCommandRecord) -> String? = { _ in nil }
    /// The queue's storage failed; the queue stopped.
    var onStorageError: @MainActor (String) -> Void = { _ in }

    /// Delay before repeat `attempt` (1, 2, …) of a command; jittered.
    var retryDelay: (Int) -> TimeInterval = { attempt in
        let base = min(60, pow(2, Double(attempt - 1)))
        return max(1, min(60, base * Double.random(in: 0.5...1.5)))
    }
    var now: () -> Date = Date.init

    private var sending: Set<String> = []
    private var wake: Task<Void, Never>?
    /// Bumped by every decision a send in flight must not undo: a new
    /// generation, a new session, a stop (review C-5).
    private var epoch = 0
    /// Bumped by a new server generation only: an answer from before it
    /// confirms nothing about the restored server (review C2-2).
    private var generationEpoch = 0
    /// The tables' common place counter (review C2-4).
    private var lastSeq: Int64?

    /// When this queue was opened: commands older than that are kept from before.
    let openedAt = Date()

    /// `held`: waits for `allow(connection:)` (the connection's `hello`).
    init(queues: [ChatCommandTable], api: ChatAPI, token: String, sessionId: String, held: Bool = false) {
        self.queues = queues
        self.api = api
        self.token = token
        self.sessionId = sessionId
        carriedTo = sessionId
        allowedConnection = held ? nil : -1
    }

    /// The connection `id`'s `hello` confirmed the generation.
    func allow(connection id: Int, generation: String? = nil) {
        allowedConnection = id
        allowedGeneration = generation
        pump()
        onReady()
    }

    /// No confirmed connection: nothing goes until the next `hello`.
    func hold() {
        allowedConnection = nil
        epoch += 1
        wake?.cancel()
    }

    private func storageFailed(_ error: Error) {
        let text = error.localizedDescription
        paused = .storageFailed(text)
        epoch += 1
        wake?.cancel()
        onStorageError(text)
    }

    // MARK: Adding

    /// Stores the command and starts sending. `journal` picks the run
    /// journal's queue (executor commands), when there is one.
    @discardableResult
    func enqueue(org: String, type: String, args: ChatJSON, orderKey: String? = nil,
                 dependsOn: String? = nil, afterCreateOf requestId: String? = nil, journal: Bool = false) throws -> ChatCommandRecord {
        let id = ChatUUID.v7(now: now())
        let bytes = try ChatCommandEnvelope(commandId: id, org: org, type: type, args: args).encoded()
        let table = queue(journal: journal)
        // Executor commands have their own order keys and depend only on
        // each other: the two tables never share a key or an edge (review C2-3).
        let key = orderKey ?? org
        let executorKey = key.hasPrefix(Self.executorKeyPrefix)
        if (table !== queues[0]) != executorKey { throw ChatError.storage("order key \(key) does not belong to this queue") }
        if let dependsOn, try !table.contains(dependsOn) {
            throw ChatError.storage("a command depends only on a command of its own queue")
        }
        var record = ChatCommandRecord(
            commandId: id, sessionId: sessionId, type: type, bodyBytes: bytes, orderKey: key,
            dependsOn: dependsOn, createdAt: now(), state: .pending
        )
        record.seq = try nextSeq()
        let stored = try requestId.map { try table.enqueue(record, afterCreateOf: $0, seq: record.seq) } ?? table.enqueue(record, seq: record.seq)
        pump()
        return stored
    }

    /// A command made but not stored: its id, bytes and next place in the
    /// whole queue, for a caller that stores it in its own transaction with
    /// what it belongs to, then `pump()`s (D5). A place not used leaves a
    /// gap, which the order does not mind.
    func prepare(org: String, type: String, args: ChatJSON) throws -> ChatCommandRecord {
        let id = ChatUUID.v7(now: now())
        let bytes = try ChatCommandEnvelope(commandId: id, org: org, type: type, args: args).encoded()
        var record = ChatCommandRecord(commandId: id, sessionId: sessionId, type: type, bodyBytes: bytes, orderKey: org,
                                       dependsOn: nil, createdAt: now(), state: .pending)
        record.seq = try nextSeq()
        return record
    }

    /// Executor commands (journal) use keys with this prefix, others never.
    static let executorKeyPrefix = "exec:"

    /// A new run journal: its table joins the queue (review C3-14). Whether
    /// the queue may send is not changed.
    func replaceJournal(_ table: ChatCommandTable?) {
        queues = [queues[0]] + (table.map { [$0] } ?? [])
        lastSeq = nil
        pump()
    }

    /// Something outside the queue stored a command: read the places again.
    func resetPlaces() { lastSeq = nil }

    /// The next place in the whole queue, across both tables (review C2-4).
    private func nextSeq() throws -> Int64 {
        let last = try lastSeq ?? ChatCommandTable.maxSeq(queues)
        lastSeq = last + 1
        return last + 1
    }

    private func queue(journal: Bool) -> ChatCommandTable {
        journal && queues.count > 1 ? queues[1] : queues[0]
    }

    // MARK: Sending

    /// Sends whatever is due: the oldest unfinished command of each
    /// `order_key`, one at a time per key, and only once the command it
    /// depends on was accepted.
    func pump() {
        guard isSending || sendsFacts, var all = loadAll() else { return }
        var rejected = false
        for (record, queue) in all where record.state == .pending && may(send: queue) && !sending.contains(record.orderKey) {
            guard let code = permanentRejection(record) else { continue }
            var record = record
            guard fail(&record, in: queue, code: code) else { return }
            rejected = true
        }
        if rejected {
            guard let again = loadAll() else { return }
            all = again
        }
        // A command whose parent failed fails too, before anything is sent;
        // each is decided once per pump, so a write that does not stick
        // cannot loop (review C-8).
        let failedIds = Set(all.filter { $0.0.state == .failed || $0.0.state == .dropped }.map(\.0.commandId))
        let known = Set(all.map(\.0.commandId))
        // A parent that failed, or that is not in this queue at all, is not
        // a confirmation (review C3-7).
        let orphans = all.filter { pair in
            pair.0.state == .pending && pair.0.dependsOn.map { failedIds.contains($0) || !known.contains($0) } == true
        }
        for (record, queue) in orphans {
            var r = record
            let missing = record.dependsOn.map { !known.contains($0) } ?? false
            guard fail(&r, in: queue, code: missing ? "dependency_missing" : "dependency_failed") else { return }
        }
        if !orphans.isEmpty {
            guard let again = loadAll() else { return }
            all = again
        }
        let state = Dictionary(all.map { ($0.0.commandId, $0.0.state) }, uniquingKeysWith: { a, _ in a })
        let at = now()
        var earliest: Date?
        var suspended = Set(all.filter { $0.0.state == .pending && ($0.0.isSessionDM || isSuspended($0.0)) }.map(\.0.commandId))
        var added = true
        while added {
            added = false
            for (record, _) in all where record.state == .pending && record.dependsOn.map(suspended.contains) == true {
                if suspended.insert(record.commandId).inserted { added = true }
            }
        }
        var heads: [String: (ChatCommandRecord, ChatCommandTable)] = [:]
        // `all` is in queue order: the first pending of a key is its head.
        for (record, queue) in all where record.state == .pending && heads[record.orderKey] == nil && may(send: queue) && !suspended.contains(record.commandId) {
            heads[record.orderKey] = (record, queue)
        }
        for (key, (record, queue)) in heads where !sending.contains(key) {
            guard maySendCommand(record) else { continue }
            // Waits for its parent's answer (a later `pump` sends it).
            if let parent = record.dependsOn, let parentState = state[parent], parentState != .sent { continue }
            if let due = record.nextAttemptAt, due > at {
                earliest = min(earliest ?? due, due)
                continue
            }
            sending.insert(key)
            let epoch = self.epoch, generationEpoch = self.generationEpoch
            Task { await self.send(record, in: queue, epoch: epoch, generationEpoch: generationEpoch) }
        }
        scheduleWake(earliest)
    }

    /// Every table's commands in queue order; nil (and the queue stopped)
    /// when one cannot be read.
    private func loadAll() -> [(ChatCommandRecord, ChatCommandTable)]? {
        do {
            return try queues.flatMap { queue in try queue.commands().map { ($0, queue) } }.sorted { $0.0.seq < $1.0.seq }
        } catch {
            storageFailed(error)
            return nil
        }
    }

    private func scheduleWake(_ at: Date?) {
        wake?.cancel()
        guard let at else { return }
        let delay = max(0.01, at.timeIntervalSince(now()))
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pump()
        }
    }

    private func send(_ original: ChatCommandRecord, in queue: ChatCommandTable, epoch sentIn: Int, generationEpoch generationSentIn: Int) async {
        var record = original
        defer {
            sending.remove(record.orderKey)
            pump()
        }
        guard may(send: queue), epoch == sentIn else { return }
        if let code = permanentRejection(original) {
            fail(&record, in: queue, code: code)
            return
        }
        guard !original.isSessionDM, !isSuspended(original), maySendCommand(original) else { return }
        // A button or revocation may have replaced/deleted a prepared send
        // before this task ran. Re-read the durable intent at the send boundary.
        let started: ChatCommandTable.SendStart
        do {
            guard let taken = try queue.beginSending(record) else {
                // A pending publication can wait on its channel's rights;
                // deleted/superseded records cannot be revived by this update.
                retry(&record, in: queue, after: 1)
                return
            }
            started = taken
        }
        catch { storageFailed(error); return }
        // The server refuses an id older than 30 days; it is not sent.
        if now().timeIntervalSince(ChatUUID.time(of: record.commandId) ?? record.createdAt) > Self.maxAge {
            fail(&record, in: queue, code: "command_expired")
            return
        }
        let answer: ChatAPI.Response
        let request: ChatCommandEnvelope?
        do {
            request = try ChatDMFirstSend.request(record)
            // Ordinary queue entries retain their exact stored bytes.
            let bytes = try request?.encoded() ?? record.bodyBytes
            answer = try await api.postCommand(bytes, token: token)
        } catch ChatAPIError.redirect(let status) {
            guard epoch == sentIn else { return }
            fail(&record, in: queue, code: "redirect_\(status)")
            return
        } catch {
            guard epoch == sentIn else { return }
            retry(&record, in: queue, after: nil)
            return
        }
        if (200..<300).contains(answer.status) {
            // Counted only for the connection it was sent under: after a drop
            // or a new generation the command stays as it is and goes again
            // (the same bytes; the server answers it from its record) once a
            // hello confirmed the generation (review C2-2, C3-1).
            guard generationEpoch == generationSentIn, epoch == sentIn else { return }
            if request?.type == "dm.open" {
                guard let opened = try? JSONDecoder().decode(ChatCommandAnswer.self, from: answer.body),
                      let dm = opened.result["dm_id"]?.string else {
                    retry(&record, in: queue, after: nil); return
                }
                do {
                    if try ChatDMFirstSend.opened(record, dm: dm, in: queue) { onDMOpened(dm) }
                } catch { storageFailed(error) }
                return // The next pump posts the same message, from disk.
            }
            // Accepted is accepted, whatever else was decided meanwhile.
            var sent = record
            sent.state = .sent
            sent.sentGeneration = allowedGeneration
            sent.error = nil
            sent.nextAttemptAt = nil
            do {
                // Don't send can cancel a DM while HTTP is in flight. A late
                // acceptance still wins; its owner hydrates the same message ID.
                _ = try queue.update(sent, ifState: .pending) || queue.update(sent, ifState: .unconfirmed)
                    || (sent.type == "dm.message.post" && queue.update(sent, ifState: .dropped))
                // Revocation may have erased the body while HTTP was in flight.
                // Its successful answer still belongs to the command's owner.
                onSent(sent, try? JSONDecoder().decode(ChatCommandAnswer.self, from: answer.body))
            } catch {
                storageFailed(error)
            }
            return
        }
        // Any other answer belongs to the decisions it was sent under.
        guard epoch == sentIn else { return }
        switch answer.status {
        case 401:
            paused = .needsSignIn
            hold()
            onUnauthorized()
        case 429:
            if record.type == "message.post_from_session" {
                // Expected quota refusal is terminal; a new explicit attempt
                // may try after the deadline. It must never create an auto loop.
                let seconds = max(1, Int(ceil(answer.retryAfter ?? 60)))
                let until = Int(now().timeIntervalSince1970) + seconds, commandId = record.commandId
                try? await queue.queue.write { db in
                    try db.execute(sql: "UPDATE session_posts SET retry_after = ? WHERE command_id = ?",
                                   arguments: [until, commandId])
                }
                onRefused(record, "rate_limited")
                fail(&record, in: queue, code: "rate_limited")
                return
            }
            // A throttle of this attempt says nothing about an earlier lost
            // answer. Only a fresh send's 429 unlocks the owner's decision.
            retry(&record, in: queue, after: answer.retryAfter, notAccepted: !started.repeatsUnanswered)
        case 500...:
            retry(&record, in: queue, after: nil)
        default:
            let body = try? JSONDecoder().decode(ChatErrorBody.self, from: answer.body)
            var code = body?.error ?? "http_\(answer.status)"
            // Refused because the request has already ended (its old
            // session closed by the server, say): nothing is owed any more —
            // said apart from a state that wants another command.
            if code == "invalid_state", let state = body?.state, TeamRequestState(rawValue: state).isFinal { code = Self.requestEnded }
            // Told before it is written: a refusal says something whether or
            // not its record can be saved (C6h).
            onRefused(record, code)
            fail(&record, in: queue, code: code)
        }
    }

    private func retry(_ record: inout ChatCommandRecord, in queue: ChatCommandTable, after seconds: TimeInterval?, notAccepted: Bool = false) {
        var next = record
        next.attempts += 1
        // Retry-After: 0 (including an HTTP date in the past) must not bypass
        // the pause. pump() is called by send's defer and by unrelated events.
        let delay = seconds.map { $0.isFinite ? max(1, $0) : retryDelay(next.attempts) } ?? retryDelay(next.attempts)
        next.nextAttemptAt = now().addingTimeInterval(delay)
        do {
            if try queue.update(next, ifState: .pending, notAccepted: notAccepted) { record = next }
        } catch {
            storageFailed(error)
        }
    }

    /// Failed for good, reported once; so does every command that depends on
    /// it. False when the queue stopped on a storage error.
    @discardableResult
    private func fail(_ record: inout ChatCommandRecord, in queue: ChatCommandTable, code: String) -> Bool {
        guard record.state == .pending else { return true }
        var failed = record
        failed.state = .failed
        failed.error = code
        failed.nextAttemptAt = nil
        do {
            guard try queue.update(failed, ifState: .pending) else { return true }
        } catch {
            storageFailed(error)
            return false
        }
        record = failed
        revision += 1
        onPermanentFailure(failed, code)
        guard let all = loadAll() else { return false }
        for (dependent, itsQueue) in all where dependent.dependsOn == failed.commandId && dependent.state == .pending {
            var d = dependent
            guard fail(&d, in: itsQueue, code: "dependency_failed") else { return false }
        }
        return true
    }

    // MARK: Sessions and generations

    /// Signed in again (6.4): commands of the earlier session with a
    /// business key go again under the new one with a new `command_id` and
    /// the same payload; the others are dropped and logged.
    func adoptSession(_ newSessionId: String, token newToken: String) {
        token = newToken
        sessionId = newSessionId
        carriedTo = nil
        epoch += 1
        guard carryOver() else { return }
        if paused == .needsSignIn { paused = nil }
        pump()
    }

    /// Moves the stored commands to the current session; false (and the
    /// queue stopped) when that could not be written.
    private func carryOver() -> Bool {
        do { try carryOverOrThrow() } catch { return false }
        return true
    }

    /// The same, throwing what stopped it.
    private func carryOverOrThrow() throws {
        do {
            for queue in queues {
                let (_, dropped) = try queue.carryOver(to: sessionId, carried: Self.carriedOver, newId: { ChatUUID.v7(now: now()) },
                                                       rebuild: Self.rebuilt)
                for record in dropped { NSLog("agentpad: chat command \(record.type) \(record.commandId) dropped with its session") }
            }
        } catch {
            storageFailed(error)
            throw error
        }
        carriedTo = sessionId
    }

    /// The server came back from a backup (a new `generation` in `hello`):
    /// unsent commands are not repeated by themselves — they wait as
    /// `unconfirmed` for the user to send them again.
    /// Throws when the queues could not be marked: then the generation must
    /// not count as handled (review C2-8).
    /// A carry-over to the session not yet written is done first, by the
    /// session's rules; what it carries then waits like the rest (review C14-1).
    func generationChanged() throws {
        if carriedTo != sessionId { try carryOverOrThrow() }
        paused = .generationChanged
        epoch += 1
        generationEpoch += 1
        wake?.cancel()
        defer { revision += 1 }
        do {
            for queue in queues { try queue.markUnconfirmed() }
        } catch {
            storageFailed(error)
            throw error
        }
    }

    /// The user sends an unconfirmed command again: a new command with a new
    /// id. Never for `run.*` and `request.decide`.
    @discardableResult
    func resend(_ commandId: String) throws -> ChatCommandRecord? {
        guard let (record, queue) = loadAll()?.first(where: { $0.0.commandId == commandId }),
              record.state == .unconfirmed, !Self.neverResent(record.type)
        else { return nil }
        let id = ChatUUID.v7(now: now())
        guard let bytes = Self.rebuilt(record.bodyBytes, id) else { return nil }
        var next = record
        next.commandId = id
        next.sessionId = sessionId
        next.bodyBytes = bytes
        next.createdAt = now()
        next.state = .pending
        next.attempts = 0
        next.nextAttemptAt = nil
        next.error = nil
        next.seq = try nextSeq()
        return try queue.enqueue(next, seq: next.seq)
    }

    /// The user asks to try a queue that stopped on storage again.
    func retryStorage() {
        guard case .storageFailed = paused else { return }
        paused = nil
        // A carry-over that failed is done first, by the new session's rules.
        if carriedTo != sessionId { guard carryOver() else { return } }
        guard loadAll() != nil else { return }
        pump()
    }

    /// Every unconfirmed command the user may send again — never `run.*` or
    /// `request.decide` — goes again with its chain (review C4-8).
    @discardableResult
    func resendUnconfirmed() throws -> [ChatCommandRecord] {
        var made: [ChatCommandRecord] = []
        defer { revision += 1 }
        for table in queues {
            let chosen = try table.commands().filter { $0.state == .unconfirmed && !Self.neverResent($0.type) }
            guard !chosen.isEmpty else { continue }
            let first = try nextSeq()
            made += try table.resend(chosen, session: sessionId, firstSeq: first, now: now(), newId: { ChatUUID.v7(now: now()) },
                                     rebuild: Self.rebuilt)
            lastSeq = nil
        }
        return made
    }

    /// Bumped by every change of the stored commands' states, so a view of
    /// them is redrawn (review C4-9).
    private(set) var revision = 0

    /// Commands waiting for the user after a new generation (stored, so also
    /// after a restart).
    var unconfirmed: [ChatCommandRecord] {
        _ = revision
        return (try? queues.flatMap { try $0.commands() }.filter { $0.state == .unconfirmed }) ?? []
    }

    /// Commands the server refused for good, until the user dismisses them.
    var refused: [ChatCommandRecord] {
        _ = revision
        return (try? queues.flatMap { try $0.refusedShown() }) ?? []
    }

    /// The user has seen the refused commands.
    func dismissRefused() {
        for table in queues { try? table.dismiss(nil) }
        revision += 1
    }

    /// The user has seen these refused commands, and only these: a window
    /// that showed some of them leaves the rest unread (review C6b p2-4).
    func dismissRefused(_ commandIds: Set<String>) {
        for table in queues { try? table.dismiss(commandIds) }
        revision += 1
    }

    /// Sending again after `generationChanged`, once the user has seen it.
    func resume() {
        guard paused == .generationChanged else { return }
        paused = nil
        if carriedTo != sessionId { guard carryOver() else { return } }
        pump()
        if allowedConnection != nil { onReady() }
    }

    private static func rebuilt(_ bytes: Data, _ commandId: String) -> Data? {
        guard var envelope = try? JSONDecoder().decode(ChatCommandEnvelope.self, from: bytes) else { return nil }
        envelope.commandId = commandId
        return try? envelope.encoded()
    }
}
