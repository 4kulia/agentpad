import Foundation
import GRDB

/// One row of `actions` (6.12).
struct ChatAction: Equatable, Sendable {
    enum State: String, Sendable {
        case pending
        case inProgress = "in_progress"
        case done
        case failed
    }

    var requestId: String
    var kind: ChatActionKind
    var state: State
    var error: String?
}

/// What a handler made of an action.
enum ChatActionResult: Equatable, Sendable {
    case done
    /// For good: a command refused (C2) and the like.
    case failed(String)
    /// Not now (no free slot, no connection): it stays in progress and is
    /// handed over again at the next run.
    case later
    /// A passing failure (a write that failed): it stays in progress and is
    /// handed over again after a pause, with no other event (DESIGN-D4 §0.4).
    case retry
}

/// Does one kind of action (D4: `receive`, `notify_decision`, `start`,
/// `fail_start`, `deliver`; D11: `recover`; D5: `notify_outcome`). Called
/// again for an action left in progress — after a restart too — so it does
/// its work idempotently, with the same command ids.
@MainActor
protocol ChatActionHandler: AnyObject {
    func perform(_ action: ChatAction, request: ChatRequest, key: ChatOrgKey) async -> ChatActionResult
}

/// Runs the actions of one organization after the transaction that made
/// them committed: every `pending` and `in_progress` row whose kind has a
/// handler, one at a time per row.
///
/// One runner per (server, account, organization) for the life of the app
/// (`ChatService.runners`): it outlives the organization's state, which only
/// hands it its context — the cache to read (`attach`), whether it may run
/// (`mayRun`). So a row is never run twice at once, by construction (lead's
/// decision after review D8e). A handler's ending writes to the cache its
/// action came from, never to a later one. A result that could not be
/// written is written again, never earned again (review D8d-p2-6).
@MainActor
final class ChatActionRunner {
    let key: ChatOrgKey
    /// The organization's cache now; nil while it has none.
    private(set) var calls: ChatCallStore?
    /// The handler of a kind; none yet leaves its rows waiting.
    var handler: @MainActor (ChatActionKind) -> ChatActionHandler? = { _ in nil }
    var now: () -> Date = Date.init
    /// Whether actions may be handed over now: in the app, while the
    /// organization is in step on the current connection. A pass refused
    /// here is taken when it is (`ChatSync.onInStep`).
    var mayRun: @MainActor () -> Bool = { true }
    /// Pause before writing an unwritten result again, or passing again
    /// after the cache could not be read or a row taken; shortened in tests.
    var rewriteDelay: Duration = .seconds(5)
    /// Tests: reading the due rows fails while true.
    var readFails: () -> Bool = { false }
    /// Tests: the check before a handler begins fails to read while true.
    var checkFails: () -> Bool = { false }
    /// Tests: a write of this state fails.
    var writeFails: (ChatAction.State) -> Bool = { _ in false }

    private var running: [String: Task<Void, Never>] = [:]
    /// Rows asked for again while their handler ran: they get one more turn
    /// when it ends (review D8-3). Marked by `run` from outside, and by an
    /// action that ended (`done`, `failed`) and so may have freed what
    /// another waits for (review D8c-4) — never by a turn that ended
    /// `.later`, so turns cannot breed turns (review D8b-2).
    private var again: Set<String> = []
    /// Results earned but not yet written, by row, with the cache they go to.
    private var unwritten: [String: Debt] = [:]
    private struct Debt {
        var calls: ChatCallStore
        /// The file's identity when the action was taken (`meta.instance`).
        var instance: String
        var action: ChatAction
        var state: ChatAction.State
        var error: String?
    }
    /// Rows that ended `.retry`: not handed over before their pause is
    /// over, whatever wakes the runner meanwhile — so rows that fail cannot
    /// wake one another at the pace of the main thread (review D4b-p1-2).
    private var notBefore: [String: ContinuousClock.Instant] = [:]
    private var rewriting: Task<Void, Never>?
    /// A pass owed after the cache could not be read or a row taken
    /// (review D8f-p2-4).
    private var retrying: Task<Void, Never>?

    init(key: ChatOrgKey, calls: ChatCallStore? = nil) {
        self.key = key
        self.calls = calls
    }

    /// The organization's state hands its cache (or takes it away).
    func attach(_ calls: ChatCallStore?) {
        self.calls = calls
        run()
    }

    /// Something changed: hands every due action to its handler, and asks
    /// those running for one more turn.
    func run() { pass(marking: true) }

    /// `only`: that one row; `marking`: rows running get one more turn.
    private func pass(marking: Bool, only: String? = nil) {
        flushUnwritten()
        guard let calls, mayRun() else { return }
        let due: [ChatAction]
        do {
            if readFails() { throw ChatError.storage("a read failed (test)") }
            due = try calls.queue.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT request_id, kind, state, error FROM actions WHERE state IN ('pending', 'in_progress')
                    ORDER BY created_at, request_id, kind
                    """).compactMap { row in
                    guard let kind = ChatActionKind(rawValue: row["kind"]), let state = ChatAction.State(rawValue: row["state"]) else { return nil }
                    return ChatAction(requestId: row["request_id"], kind: kind, state: state, error: row["error"])
                }
            }
        } catch {
            NSLog("agentpad: the actions of \(key.orgId) could not be read: \(error.localizedDescription)")
            retryPass()
            return
        }
        guard let instance = calls.instance else {
            retryPass()
            return
        }
        for action in due {
            let id = action.requestId + "/" + action.kind.rawValue
            if let only, id != only { continue }
            // Its result is earned; only writing it is owed. (A debt to
            // another cache file was given up by `flushUnwritten` above.)
            if unwritten[id] != nil { continue }
            if running[id] != nil {
                if marking { again.insert(id) }
                continue
            }
            if let due = notBefore[id] {
                guard due <= ContinuousClock.now else {
                    retryPass()
                    continue
                }
                notBefore[id] = nil
            }
            guard let handler = handler(action.kind) else { continue }
            guard set(calls, action, .inProgress) else {
                // Not taken now: tried again, not left until something else happens.
                retryPass()
                continue
            }
            var started = action
            started.state = .inProgress
            let key = self.key, taken = started
            running[id] = Task { [weak self] in
                // Still owed, in a context that may run, when it begins: a
                // row voided meanwhile (lost, moved) or a connection gone
                // does not begin (review D8f-p2-1). What a handler does once
                // begun is its own to check after each wait.
                guard let self else { return }
                // The cache it was taken from is still the attached one, the
                // server is known, and the row is still taken — a state that
                // no longer owes it voids it in the same transaction
                // (`ChatReconcile`). The handler gets the request as it is
                // now (review D8h-p2-4). A check that could not be read is
                // tried again, not taken as no (review D8g-p2-3, p2-4).
                let owed: Result<ChatRequest?, Error>
                if self.calls === calls, self.mayRun() { owed = Result { try self.stillOwed(calls, taken) } } else { owed = .success(nil) }
                guard case .success(let request?) = owed else {
                    self.running[id] = nil
                    if case .failure = owed { self.retryPass() } else if self.again.remove(id) != nil { self.run() }
                    return
                }
                let result = await handler.perform(taken, request: request, key: key)
                self.ended(id, calls, instance, taken, result)
            }
        }
    }

    private func ended(_ id: String, _ calls: ChatCallStore, _ instance: String, _ action: ChatAction, _ result: ChatActionResult) {
        running[id] = nil
        let askedAgain = again.remove(id) != nil
        switch result {
        case .done: write(id, calls, instance, action, .done)
        case .failed(let text): write(id, calls, instance, action, .failed, error: text)
        case .later: if askedAgain { pass(marking: false, only: id) }
        case .retry:
            notBefore[id] = .now + rewriteDelay
            retryPass()
        }
    }

    /// Writes an earned result, or keeps it to write again later; once
    /// written — first time or later — the action is settled.
    /// `instance`: the identity of the file the action was taken from.
    private func write(_ id: String, _ calls: ChatCallStore, _ instance: String, _ action: ChatAction, _ state: ChatAction.State, error: String? = nil) {
        guard set(calls, action, state, error: error) else {
            unwritten[id] = Debt(calls: calls, instance: instance, action: action, state: state, error: error)
            scheduleRewrite()
            return
        }
        settled()
    }

    /// An action ended for good (written): what it held may be what
    /// another waits for, so those running are asked for one more turn too
    /// (review D8c-4, D8e-p2-9).
    private func settled() { pass(marking: true) }

    private func flushUnwritten() {
        // A debt settled — written, or given up — wakes a pass.
        var wrote = false
        let attached = calls?.instance
        for (id, owed) in unwritten {
            if set(owed.calls, owed.action, owed.state, error: owed.error) {
                unwritten[id] = nil
                wrote = true
            } else if attached != nil, owed.instance != attached {
                // A file let go of for another one — another organization's,
                // or deleted and made anew at the same path: nothing will read
                // it again, and it does not hold the new one's row (review
                // D8g-p2-5, D8h-p2-2). The same file opened again is held.
                NSLog("agentpad: action \(owed.action.kind.rawValue) of \(owed.action.requestId): a cache let go of could not be written; given up")
                unwritten[id] = nil
                // Ended as a written one does: what it held is free (review D8i-p2-2).
                wrote = true
            }
        }
        if !unwritten.isEmpty { scheduleRewrite() }
        if wrote { Task { [weak self] in self?.settled() } }
    }

    /// The request, when the row is still taken: in progress (nil otherwise),
    /// read in one go.
    private func stillOwed(_ calls: ChatCallStore, _ action: ChatAction) throws -> ChatRequest? {
        if checkFails() { throw ChatError.storage("a read failed (test)") }
        return try calls.queue.read { db in
            guard try String.fetchOne(db, sql: "SELECT state FROM actions WHERE request_id = ? AND kind = ?",
                                      arguments: [action.requestId, action.kind.rawValue]) == ChatAction.State.inProgress.rawValue
            else { return nil }
            return try ChatCallStore.request(db, action.requestId)
        }
    }

    private func retryPass() {
        guard retrying == nil else { return }
        let delay = rewriteDelay
        retrying = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.retrying = nil
            self.run()
        }
    }

    private func scheduleRewrite() {
        guard rewriting == nil else { return }
        let delay = rewriteDelay
        rewriting = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            self.rewriting = nil
            self.flushUnwritten()
        }
    }

    /// A result goes only onto the row taken (in progress): a row voided or
    /// made anew meanwhile (a new generation) is not settled by an earlier
    /// handler — its result is then nobody's.
    @discardableResult
    private func set(_ calls: ChatCallStore, _ action: ChatAction, _ state: ChatAction.State, error: String? = nil) -> Bool {
        do {
            if writeFails(state) { throw ChatError.storage("a write failed (test)") }
            try calls.queue.write { db in
                try db.execute(sql: """
                    UPDATE actions SET state = ?, error = ?, updated_at = ?
                    WHERE request_id = ? AND kind = ? AND state IN (\(state == .inProgress ? "'pending', 'in_progress'" : "'in_progress'"))
                    """, arguments: [state.rawValue, error, now(), action.requestId, action.kind.rawValue])
            }
            return true
        } catch {
            NSLog("agentpad: action \(action.kind.rawValue) of \(action.requestId) could not be written: \(error.localizedDescription)")
            return false
        }
    }
}
