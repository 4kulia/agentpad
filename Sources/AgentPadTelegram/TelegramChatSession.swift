import Foundation

/// Runs synchronously on LocalTDLibConnector's actor. One receive/reduce at a
/// time is its backpressure: there is no update task queue to grow or overflow.
final class TelegramChatSession {
    enum Purpose {
        case markRead(UUID, TelegramMarkReadStep), load(TelegramListKey, UInt64), attention(TelegramAttentionWork), search(UInt64, String), resolve(UUID), recent(Int64)
    }
    struct ReadAction {
        let chat: Int64
        let retry: Set<TelegramMarkReadStep>?
        let continuation: CheckedContinuation<TelegramMarkReadResult,Never>
        var steps: [(TelegramMarkReadStep,TDLibMessage)]?
        var result = TelegramMarkReadResult()
        var waiting = false
    }
    var readActions: [UUID:ReadAction] = [:]
    var readQueue: [UUID] = []
    struct Call { let purpose: Purpose; let started: Date }
    struct Search {
        let generation: UInt64
        let query: String
        let networkAfter: Date
        let continuation: AsyncStream<TelegramSearchSnapshot>.Continuation
        var waiting: Set<String>
        var hits: [String: TelegramSearchHit] = [:]
        var notice: String?
    }
    let index: TelegramChatIndex
    let send: (TDLibMessage) throws -> Void
    var active = false
    var notificationProtocolFailed = false
    var network = TelegramNetworkState.waiting
    var pause: String?
    var calls: [String: Call] = [:]
    var search: Search?
    var generation: UInt64 = 0
    var resolvers: [UUID: CheckedContinuation<TelegramChatRow?, Never>] = [:]
    var observers: [UUID: AsyncStream<TelegramChatSnapshot>.Continuation] = [:]
    var snapshot = TelegramChatSnapshot()
    private var listTurn = 0
    private var backgroundTurn = 0
    private var unsavedCompletions = Set<String>()
    private var checkpointRetryAt = Date.distantPast
    private var checkpointFailures = 0
    private var checkpointErrorReported = false
    private let checkpointError = "Telegram chat scan progress could not be saved on this Mac. Retrying…"
    private let writeCheckpoint: (String, Int64) throws -> Void
    private var retryAt: Int64 = 0
    var retryNotBefore: Date { Date(timeIntervalSince1970: Double(retryAt)) }
    func deferRequests(until date: Date) {
        retryAt = max(retryAt, Int64(date.timeIntervalSince1970.rounded(.up)))
        do { try writeCheckpoint("retryNotBefore", retryAt) }
        catch { index.error = "Telegram retry state could not be saved on this Mac."; index.dirty = true }
    }
    private var failures = 0
    private var reduced = 0
    private var lastPublish = Date.distantPast

    init(index: TelegramChatIndex, send: @escaping (TDLibMessage) throws -> Void,
         writeCheckpoint: ((String, Int64) throws -> Void)? = nil) {
        self.index = index; self.send = send
        self.writeCheckpoint = writeCheckpoint ?? { try index.checkpoint($0, value: $1) }
        retryAt = index.initialRetryNotBefore
    }
    func activate(account: Int64, user: TDLibMessage?, now: Date) throws {
        if let user { try index.apply(TDLibMessage("updateUser", ["user": .object(user.fields)]), now: seconds(now)) }
        try index.bind(account, now: seconds(now)); active = true
        publish(now: now, force: true)
    }
    func stop() {
        active = false; calls.removeAll(); search?.continuation.finish(); search = nil
        for resolver in resolvers.values { resolver.resume(returning: nil) }; resolvers.removeAll()
        var stopped = TelegramMarkReadResult(); stopped.error = .unavailable
        for action in readActions.values { action.continuation.resume(returning: stopped) }
        readActions.removeAll(); readQueue.removeAll()
        snapshot = TelegramChatSnapshot()
        for observer in observers.values { observer.yield(snapshot) }
    }
    private func seconds(_ now: Date) -> Int64 { Int64(now.timeIntervalSince1970) }
    func receive(_ message: TDLibMessage, now: Date) {
        do {
            if try index.apply(message, now: seconds(now)) { reduced += 1 }
            if let token = message["@extra"]?.string, let call = calls.removeValue(forKey: token) {
                try response(message, call: call, now: now)
            }
        } catch is TelegramNotificationProtocolError {
            notificationProtocolFailed = true
        } catch { index.error = "Telegram chat data could not be saved on this Mac."; index.dirty = true }
    }
    func tick(now: Date) {
        guard active else { return }
        saveCompletions(now: now)
        do {
            let time = seconds(now)
            try index.expireNotificationHistory(now: time)
            if time >= index.attentionExpiry { index.attentionFullRebuild = true; index.changed() }
            try index.prepareAttentionScan(now: time)
            let required = try index.requiredLists()
            let listsDone = required.allSatisfy { index.listStates[$0]?.complete == true }
            let attentionPending = try index.hasAttentionWork()
            let newState: TelegramChatScanState
            if network != .ready { newState = .paused("Offline · saved chats") }
            else if listsDone && !attentionPending { newState = .complete }
            else if retryAt > time { newState = .paused("Waiting to retry Telegram") }
            else if let pause { newState = .paused(pause) }
            else if calls.values.contains(where: { Self.isBackground($0.purpose) && now.timeIntervalSince($0.started) > 40 }) {
                newState = .paused("Waiting for Telegram")
            } else { newState = .scanning }
            if newState != index.state {
                index.state = newState; index.dirty = true
            }
            if newState == .complete, index.error == nil { try index.finishMigrationScan() }

            // No calendar quota. Exactly one background slot, independent of
            // six interactive slots; a long TDLib wait keeps its slot/token.
            if newState == .scanning, !calls.values.contains(where: { Self.isBackground($0.purpose) }) {
                let lane = [0, 1, 0, 2, 0, 1][backgroundTurn % 6]; backgroundTurn += 1
                var work: TelegramAttentionWork?
                if lane != 2 || (listsDone) { work = try index.nextAttentionWork(lane: lane, now: time) }
                if work == nil && (lane != 2 || (listsDone)) {
                    for fallback in [0, 1, 2] where work == nil { work = try index.nextAttentionWork(lane: fallback, now: time) }
                }
                if let work { try request(work.method, work.fields, purpose: .attention(work), now: now) }
                else if !listsDone {
                    for offset in 0..<required.count {
                        let position = (listTurn + offset) % required.count, list = required[position]
                        guard let runtime = index.listStates[list], !runtime.complete else { continue }
                        listTurn = (position + 1) % required.count
                        try request("loadChats", ["chat_list": list.tdlib, "limit": .integer(50)], purpose: .load(list,runtime.generation), now: now)
                        break
                    }
                }
            }
            scheduleMarkReads(now: now)
            try scheduleSearch(now: now)
            try scheduleRecentlyOpened(now: now)
            if index.dirty, reduced >= 20 || now.timeIntervalSince(lastPublish) >= 0.05 { publish(now: now) }
        } catch { index.error = "Telegram chat data could not be saved on this Mac."; publish(now: now) }
    }
    var otherInteractiveCount: () -> Int = { 0 }
    private static func isBackground(_ purpose: Purpose) -> Bool {
        switch purpose { case .load, .attention: true; default: false }
    }
    var interactiveCount: Int { calls.values.filter { !Self.isBackground($0.purpose) }.count }
    private func request(_ method: String, _ fields: [String: TDLibValue], purpose: Purpose, now: Date) throws {
        let token = (Self.isBackground(purpose) ? "chats:background:" : "chats:") + UUID().uuidString
        var message = TDLibMessage(method, fields); message["@extra"] = .string(token)
        calls[token] = Call(purpose: purpose, started: now)
        do { try send(message) } catch { calls[token] = nil; throw error }
    }
    private func response(_ message: TDLibMessage, call: Call, now: Date) throws {
        let error = message.type == "error"
        let flood = error && message["code"]?.integer == 429
        if flood {
            // TDLib normally waits internally. Honor a surfaced server wait
            // across process restarts as well; never duplicate a pending call.
            let text = message["message"]?.string ?? ""
            let delay = text.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }.last ?? 60
            retryAt = max(retryAt, seconds(now) + max(1, delay) + 1)
            try writeCheckpoint("retryNotBefore", retryAt)
        }
        switch call.purpose {
        case .markRead(let id, let step):
            guard readActions[id] != nil else { return }
            if error || message.type != "ok" { readActions[id]!.result.failed.insert(step) }
            readActions[id]!.waiting = false
            scheduleMarkReads(now: now)
        case .load(let list, let generation):
            guard index.listStates[list]?.generation == generation else { return }
            if error, message["code"]?.integer == 404 {
                // TDLib has finished this list even if the checkpoint disk is
                // unavailable. Retry persistence, never repeat loadChats.
                try index.completeList(list, generation: generation)
                unsavedCompletions.insert(list.rawValue); failures = 0
                saveCompletions(now: now)
            } else if error || message.type != "ok" {
                if !flood {
                    failures = min(6, failures + 1); retryAt = seconds(now) + Int64(1 << failures)
                    try writeCheckpoint("retryNotBefore", retryAt)
                }
            } else { failures = 0 }
        case .attention(let work):
            try index.finishAttentionWork(work, response: message, now: seconds(now))
        case .search(let epoch, let method):
            guard search?.generation == epoch else { return }
            if error {
                // A public username miss is a completed source, not a failure
                // of the other local/server/contact searches.
                if !(method == "searchPublicChat" && message["code"]?.integer == 400) {
                    search?.notice = flood ? "Telegram asks us to wait · Saved results available" : "Some Telegram sources are unavailable"
                }
            } else if method == "searchContacts" {
                for id in (message["user_ids"]?.array ?? []).prefix(50) {
                    if let user = id.integer, let hit = try index.contact(user, now: seconds(now)) { merge(hit) }
                }
            } else if method == "searchPublicChat", let id = message["id"]?.integer {
                try index.apply(TDLibMessage("updateNewChat", ["chat": .object(message.fields)]), now: seconds(now))
                if let row = try index.get(id, now: seconds(now)) { merge(TelegramSearchHit(row: row)) }
            } else {
                for id in (message["chat_ids"]?.array ?? []).prefix(50) {
                    if let id = id.integer, let row = try index.get(id, now: seconds(now)) { merge(TelegramSearchHit(row: row)) }
                }
            }
            if (message[method == "searchContacts" ? "user_ids" : "chat_ids"]?.array.count ?? 0) >= 50 {
                search?.notice = "More matches may be available · Refine the name"
            }
            publishSearch(now: now)
        case .resolve(let id):
            var row: TelegramChatRow?
            if !error, message.type == "chat", let chat = message["id"]?.integer {
                try index.apply(TDLibMessage("updateNewChat", ["chat": .object(message.fields)]), now: seconds(now))
                row = try index.get(chat, now: seconds(now))
            }
            resolvers.removeValue(forKey: id)?.resume(returning: row)
        case .recent(let chat):
            if !flood { try index.finishOpened(chat) }
        }
    }
    private func saveCompletions(now: Date) {
        guard !unsavedCompletions.isEmpty, now >= checkpointRetryAt else { return }
        do {
            for list in unsavedCompletions.sorted() {
                try writeCheckpoint(list + "Done", 1)
                unsavedCompletions.remove(list)
            }
            checkpointFailures = 0
            if checkpointErrorReported, index.error == checkpointError { index.error = nil; index.dirty = true }
            checkpointErrorReported = false
        } catch {
            checkpointFailures = min(6, checkpointFailures + 1)
            checkpointRetryAt = now.addingTimeInterval(Double(1 << checkpointFailures))
            if !checkpointErrorReported {
                checkpointErrorReported = true; index.error = checkpointError; index.dirty = true
            }
        }
    }
    func publish(now: Date, force: Bool = false) {
        guard active else { return }
        do {
            snapshot = try index.project(now: seconds(now), force: force)
            lastPublish = now; reduced = 0
            for observer in observers.values { observer.yield(snapshot) }
        } catch {
            snapshot.error = "Telegram chat data could not be saved on this Mac."
            for observer in observers.values { observer.yield(snapshot) }
        }
    }
    func beginSearch(_ query: String, now: Date) -> AsyncStream<TelegramSearchSnapshot> {
        if index.dirty { publish(now: now) }
        search?.continuation.finish(); generation &+= 1; lastSearchSnapshot = nil
        let pair = AsyncStream<TelegramSearchSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let query = String(decoding: query.trimmingCharacters(in: .whitespacesAndNewlines).utf8.prefix(1024), as: UTF8.self)
        var methods: Set<String> = ["searchChats"]
        if !query.isEmpty {
            methods.formUnion(["searchChatsOnServer", "searchContacts"])
            if query.first == "@", query.count > 1, query.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) { methods.insert("searchPublicChat") }
        }
        search = Search(generation: generation, query: query, networkAfter: now.addingTimeInterval(0.15), continuation: pair.continuation, waiting: methods)
        do {
            for row in try index.localMatches(query, now: seconds(now)) { merge(.init(row: row)) }
            if ["saved messages", "избранное"].contains(query.lowercased()), let saved = try index.contact(index.account, now: seconds(now)) { merge(saved) }
            try scheduleSearch(now: now)
        } catch { search?.notice = "Known chats could not be loaded" }
        publishSearch(now: now)
        return pair.stream
    }
    func cancelSearch(_ generation: UInt64) {
        guard search?.generation == generation else { return }
        search?.continuation.finish(); search = nil
        // In-flight calls still occupy their slots until the real TDLib reply.
    }
    private func scheduleSearch(now: Date) throws {
        guard active, let search else { return }
        for method in ["searchChats", "searchChatsOnServer", "searchContacts", "searchPublicChat"] where search.waiting.contains(method) {
            guard interactiveCount + otherInteractiveCount() < 6 else { break }
            let networkMethod = method != "searchChats"
            if networkMethod && (now < search.networkAfter || network != .ready || seconds(now) < retryAt) { continue }
            if calls.values.contains(where: { if case .search(_, let current) = $0.purpose { current == method } else { false } }) { continue }
            var fields: [String: TDLibValue] = ["query": .string(search.query), "limit": .integer(50)]
            if method == "searchChats" || method == "searchChatsOnServer" { fields["type_filter"] = .null }
            if method == "searchPublicChat" { fields = ["username": .string(String(search.query.dropFirst()))] }
            self.search?.waiting.remove(method)
            try request(method, fields, purpose: .search(search.generation, method), now: now)
        }
        publishSearch(now: now)
    }
    private func merge(_ hit: TelegramSearchHit) {
        guard search != nil else { return }
        if hit.userID == nil, let user = try? index.privateUser(chat: hit.row.id.chat) {
            let alias = "\(hit.row.id.environment.rawValue):\(hit.row.id.account):user:\(user)"
            search!.hits[alias] = nil
        }
        // Contacts with a known chat already arrive with the chat identity.
        if search!.hits.count < 250 || search!.hits[hit.id] != nil { search!.hits[hit.id] = hit }
    }
    private var lastSearchSnapshot: TelegramSearchSnapshot?
    func publishSearch(now: Date) {
        guard let search else { return }
        let hits = search.query.isEmpty ? ((try? index.suggestions(now: seconds(now))) ?? []).map { TelegramSearchHit(row: $0) }
            : search.hits.values.sorted { TelegramSearchRank.precedes($0, $1, query: search.query) }
        let running = !search.waiting.isEmpty || calls.values.contains { if case .search(let epoch, _) = $0.purpose { epoch == search.generation } else { false } }
        let notice = seconds(now) < retryAt ? "Telegram asks us to wait · Saved results available"
            : network != .ready && !search.query.isEmpty ? "Known on this Mac · More results need a connection" : search.notice
        let value = TelegramSearchSnapshot(query: search.query, hits: hits, searching: running && network == .ready && seconds(now) >= retryAt, notice: notice)
        guard lastSearchSnapshot?.query != value.query || lastSearchSnapshot?.hits != value.hits || lastSearchSnapshot?.notice != value.notice || lastSearchSnapshot?.searching != value.searching else { return }
        lastSearchSnapshot = value; search.continuation.yield(value)
    }
    func resolve(_ hit: TelegramSearchHit, now: Date, continuation: CheckedContinuation<TelegramChatRow?, Never>) {
        guard active, hit.row.id.environment == index.environment, hit.row.id.account == index.account else { continuation.resume(returning: nil); return }
        guard let user = hit.userID else { continuation.resume(returning: try? index.get(hit.row.id.chat, now: seconds(now))); return }
        guard interactiveCount + otherInteractiveCount() < 6, retryAt <= seconds(now) else { continuation.resume(returning: nil); return }
        let id = UUID(); resolvers[id] = continuation
        do { try request("createPrivateChat", ["user_id": .integer(user), "force": .bool(false)], purpose: .resolve(id), now: now) }
        catch { resolvers.removeValue(forKey: id)?.resume(returning: nil) }
    }
    func opened(_ id: TelegramChatID, now: Date) {
        guard active, id.account == index.account, id.environment == index.environment else { return }
        do { try index.enqueueOpened(id.chat, now: seconds(now)); try scheduleRecentlyOpened(now: now) }
        catch { index.error = "The recently opened Telegram chat could not be saved."; index.dirty = true }
    }
    private func scheduleRecentlyOpened(now: Date) throws {
        guard interactiveCount + otherInteractiveCount() < 6, seconds(now) >= retryAt,
              !calls.values.contains(where: { if case .recent = $0.purpose { true } else { false } }),
              let chat = try index.nextOpened() else { return }
        try request("addRecentlyFoundChat", ["chat_id": .integer(chat)], purpose: .recent(chat), now: now)
    }
}


extension TelegramChatSession {
    func markAsRead(_ chat: Int64, retry: Set<TelegramMarkReadStep>?, now: Date,
                    continuation: CheckedContinuation<TelegramMarkReadResult,Never>) {
        let id = UUID(); readActions[id] = ReadAction(chat: chat, retry: retry, continuation: continuation); readQueue.append(id)
        scheduleMarkReads(now: now)
    }
    private func scheduleMarkReads(now: Date) {
        for id in readQueue {
            guard var action = readActions[id], !action.waiting else { continue }
            guard interactiveCount + otherInteractiveCount() < TelegramChatLimits.interactiveCalls, seconds(now) >= retryAt else { break }
            do {
                if action.steps == nil {
                    let plan = try index.markReadPlan(chat: action.chat, only: action.retry)
                    action.steps = plan.0; action.result.openChatRequired = plan.1
                }
                if action.steps!.isEmpty {
                    readActions[id] = nil; action.continuation.resume(returning: action.result); continue
                }
                let (step,message) = action.steps!.removeFirst()
                action.waiting = true; readActions[id] = action
                do { try request(message.type, message.fields.filter { $0.key != "@type" }, purpose: .markRead(id,step), now: now) }
                catch { readActions[id]!.result.failed.insert(step); readActions[id]!.waiting = false }
            } catch {
                action.result.error = error as? TelegramFolderError ?? .storage
                readActions[id] = nil; action.continuation.resume(returning: action.result)
            }
        }
        readQueue.removeAll { readActions[$0] == nil }
    }
}
