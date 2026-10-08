import Foundation
import GRDB

/// One reader per organization, shared by every window. Durable debt lives in GRDB;
/// only the currently requested surfaces and live notification candidates are in memory.
@MainActor
final class ChatB1Sync {
    let key: ChatOrgKey
    let store: ChatStore
    let api: ChatAPI
    let token: String
    weak var socket: ChatSocket?
    private(set) var capabilities: Set<String> = []
    private var configured = false
    private(set) var limits = ChatB1.Limits()
    var onCapabilities: (ChatServerInfo) -> Void = { _ in }
    var onAccessRefused: (Int) -> Void = { _ in }
    var onEligible: (String, String) -> Void = { _, _ in }
    var canNotify: (String) -> Bool = { _ in false }
    private var windows: [UUID: (String, Set<String>)] = [:]
    private var pins: [UUID: String] = [:]
    private var watch: AnyDatabaseCancellable?
    private var reading: Task<Void, Never>?
    private var again = false
    private var stopped = false
    private var active = false
    private var candidates: [String: Task<Void, Never>] = [:]
    private var replyConfirmationVersion = 0
    var retryDelay: (Int) -> TimeInterval = { min(60, pow(2, Double($0))) }

    init(key: ChatOrgKey, store: ChatStore, api: ChatAPI, token: String, socket: ChatSocket) {
        self.key = key; self.store = store; self.api = api; self.token = token; self.socket = socket
        let change = CoalescedMainActorAction { [weak self] in self?.schedule() }
        watch = DatabaseRegionObservation(tracking: Table("b1_metadata"), Table("b1_pins"), Table("b1_participation"), Table("meta"), Table("channels"))
            .start(in: store.queue, onError: { _ in }) { _ in change.schedule() }
    }
    private func readDB<T>(_ body: (Database) throws -> T) throws -> T { try store.queue.read(body) }
    private func writeDB<T>(_ body: (Database) throws -> T) throws -> T { try store.queue.write(body) }
    func configure(_ capabilities: Set<String>, limits: ChatB1.Limits? = nil, reconnect: Bool = false) {
        let next = capabilities.intersection(ChatB1.capabilities)
        let changed = !configured || next != self.capabilities
        configured = true
        self.capabilities = next
        if let limits { self.limits = limits }
        guard changed || reconnect else { return }
        cancelReads()
        try? writeDB { db in
            try ChatB1.setParticipation(db, enabled: next.contains("chat.thread_participation"))
            if changed { try ChatB1.reset(db) } else { try ChatB1.refresh(db) }
        }
        schedule()
    }
    func resume() { active = true; schedule() }
    func suspend() { active = false; cancelReads() }
    func stop() { stopped = true; watch = nil; suspend(); windows = [:]; pins = [:] }
    private func cancelReads() {
        reading?.cancel(); reading = nil
        for task in candidates.values { task.cancel() }
        candidates = [:]
    }
    func show(_ owner: UUID, channel: String, ids: Set<String>) {
        guard windows[owner]?.0 != channel || windows[owner]?.1 != ids else { return }
        windows[owner] = (channel, ids)
        try? writeDB { try ChatB1.watch($0, channel: channel, ids: Array(ids)) }
        schedule()
    }
    func hide(_ owner: UUID) { windows[owner] = nil; pins[owner] = nil }
    func showPins(_ owner: UUID, channel: String, shown: Bool) {
        pins[owner] = shown ? channel : nil
        if shown { try? writeDB { try $0.execute(sql: "INSERT OR IGNORE INTO b1_pins (channel_id) VALUES (?)", arguments: [channel]) } }
        schedule()
    }
    func schedule() {
        guard active, !stopped else { return }
        if reading != nil { again = true; return }
        reading = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            repeat {
                self.again = false
                do { try await self.read(); failures = 0 }
                catch {
                    guard !Task.isCancelled, self.active, !self.stopped else { return }
                    failures += 1
                    self.again = true
                    try? await Task.sleep(for: .seconds(self.retryDelay(failures)))
                }
            } while self.again && self.active && !self.stopped && !Task.isCancelled
            if !Task.isCancelled { self.reading = nil }
        }
    }
    private func valid(_ epoch: Int?) -> Bool { !stopped && active && !Task.isCancelled && socket?.epoch == epoch }
    private func read() async throws {
        let epoch = socket?.epoch
        guard let scope = try readDB({ try ChatB1.readToken($0) }) else { return }
        if !capabilities.isDisjoint(with: ["chat.reactions", "chat.pins", "chat.thread_summary"]) {
            var visible: [String: Set<String>] = [:]
            for (channel, ids) in windows.values { visible[channel, default: []].formUnion(ids) }
            for (channel, ids) in visible {
                guard valid(epoch), let readToken = try readDB({ try ChatB1.readToken($0, channel: channel) }) else { continue }
                let rows = try readDB { try Row.fetchAll($0, sql: "SELECT message_id, ticket FROM b1_metadata WHERE channel_id = ? AND dirty = 1", arguments: [channel]) }
                    .filter { ids.contains($0["message_id"]) }
                let size = max(1, min(100, limits.metadataIds))
                for start in stride(from: 0, to: rows.count, by: size) {
                    let tickets = Dictionary(uniqueKeysWithValues: rows[start..<min(rows.count, start + size)].map { ($0["message_id"] as String, $0["ticket"] as Int) })
                    do {
                        let page = try await api.messageMetadata(key.orgId, channel: channel, ids: tickets.keys.sorted(), token: token)
                        guard valid(epoch) else { return }
                        let applied = try writeDB { try ChatB1.apply($0, page: page, channel: channel, token: readToken, tickets: tickets) }
                        if !applied { throw ChatAPIError.unexpectedAnswer("Metadata read is older than its invalidation") }
                    } catch {
                        try await handle(error, channel: channel, epoch: epoch, scope: readToken,
                                         required: ["chat.reactions", "chat.pins", "chat.thread_summary"], metadata: Array(tickets.keys))
                    }
                }
            }
        }
        if capabilities.contains("chat.pins") {
            for channel in Set(pins.values) {
                guard valid(epoch), let readToken = try readDB({ try ChatB1.readToken($0, channel: channel) }),
                      let ticket = try readDB({ try Int.fetchOne($0, sql: "SELECT ticket FROM b1_pins WHERE channel_id = ? AND dirty = 1", arguments: [channel]) }) else { continue }
                do {
                    let page = try await api.pins(key.orgId, channel: channel, token: token)
                    guard valid(epoch) else { return }
                    let applied = try writeDB { try ChatB1.apply($0, page: page, channel: channel, token: readToken, ticket: ticket) }
                    if !applied { throw ChatAPIError.unexpectedAnswer("Pins read is older than its invalidation") }
                } catch { try await handle(error, channel: channel, epoch: epoch, scope: readToken, required: ["chat.pins"]) }
            }
        }
        if capabilities.contains("chat.thread_participation"), valid(epoch),
           let ticket = try readDB({ try Int.fetchOne($0, sql: "SELECT ticket FROM b1_participation WHERE dirty = 1") }) {
            let confirmations = replyConfirmationVersion
            var items: [ChatB1.Participation] = [], after: String?, head: Int?
            var seen = Set<String>()
            do {
                repeat {
                    let page = try await api.myThreads(key.orgId, after: after, at: head, limit: max(1, min(200, limits.myThreadsMax)), token: token)
                    guard valid(epoch) else { return }
                    if let head, head != page.memberHead { throw ChatAPIError.unexpectedAnswer("Participation head changed") }
                    head = page.memberHead; items += page.items; after = page.next
                    if let after, !seen.insert(after).inserted { throw ChatAPIError.unexpectedAnswer("Repeated participation cursor") }
                } while after != nil
                // A point check completed after this pass began. Its reply may
                // be absent from the older member snapshot, before the member
                // signal arrives. Read again before withdrawing any notices.
                guard confirmations == replyConfirmationVersion else { again = true; return }
                let applied = try writeDB { try ChatB1.applyThreads($0, items: items, head: head ?? 0, token: scope, ticket: ticket) }
                if !applied { throw ChatAPIError.unexpectedAnswer("Participation changed while loading") }
            } catch { try await handle(error, channel: nil, epoch: epoch, scope: scope, required: ["chat.thread_participation"]) }
        }
    }
    /// Every B1 endpoint uses the same access gate. A missing route on an older
    /// server is a capability change; a refused read on a supported route is not.
    private func handle(_ error: Error, channel: String?, epoch: Int?, scope: ChatB1.ReadToken,
                        required: Set<String>, metadata: [String]? = nil) async throws {
        guard valid(epoch), try readDB({ try ChatB1.readToken($0, channel: channel) }) == scope else { throw CancellationError() }
        var scope = scope
        if case ChatAPIError.server(let status, let code, _) = error {
            if status == 404, code != "unsupported" {
                // Compatibility checks may be slow. Hide all B1 content and
                // invalidate in-flight pages before waiting for /v1/server.
                do {
                    guard let cleared = try writeDB({ db in
                        try ChatB1.reset(db)
                        return try ChatB1.readToken(db, channel: channel)
                    }) else { throw CancellationError() }
                    scope = cleared
                } catch { onAccessRefused(status); throw error }
            }
            if code == "unsupported" || status == 404 {
                let info: ChatServerInfo
                do { info = try await api.serverInfo() }
                catch {
                    // Failure to check compatibility is not evidence of access.
                    if status == 404, valid(epoch), try readDB({ try ChatB1.readToken($0, channel: channel) }) == scope {
                        onAccessRefused(status)
                    }
                    throw error
                }
                guard valid(epoch), try readDB({ try ChatB1.readToken($0, channel: channel) }) == scope else { throw CancellationError() }
                onCapabilities(info)
                configure(Set(info.capabilities), limits: info.limits?.chatB1)
                if capabilities.isDisjoint(with: required) { return }
            }
            if (status == 403 || status == 404), code != "unsupported" {
                onAccessRefused(status)
                throw error
            }
        }
        if let channel, metadata != nil || required == ["chat.pins"] {
            let table = metadata == nil ? "b1_pins" : "b1_metadata"
            let predicate = "channel_id = ?" + (metadata.map { " AND message_id IN (\(Array(repeating: "?", count: $0.count).joined(separator: ",")))" } ?? "")
            try? writeDB { db in
                try db.execute(sql: "UPDATE \(table) SET error = 'Could not load. Please retry.' WHERE \(predicate) AND error IS NULL",
                               arguments: StatementArguments([channel] + (metadata ?? [])))
            }
        }
        throw error
    }

    func cancelCandidate(_ id: String) { candidates.removeValue(forKey: id)?.cancel() }

    /// Live candidates only. The point query never trusts an incomplete/stale my_threads.
    func checkReply(channel: String, id: String, root: String) {
        guard candidates[id] == nil, capabilities.contains("chat.thread_participation"), active else { return }
        let epoch = socket?.epoch
        let scope = try? readDB { try ChatB1.readToken($0, channel: channel) }
        candidates[id] = Task { [weak self] in
            guard let self, let scope else { return }
            defer { if self.socket?.epoch == epoch { self.candidates[id] = nil } }
            for attempt in 0..<4 {
                guard self.valid(epoch), self.canNotify(channel),
                      (try? self.readDB { try ChatB1.readToken($0, channel: channel) }) == scope else { return }
                do {
                    let answer = try await self.api.participation(self.key.orgId, channel: channel, root: root, reply: id, token: self.token)
                    guard self.valid(epoch), self.canNotify(channel) else { return }
                    let fresh = try self.readDB { db in
                        try ChatB1.readToken(db, channel: channel) == scope &&
                            answer.asOfSeq >= (Int.fetchOne(db, sql: "SELECT seq FROM b1_reply_heads WHERE channel_id = ?", arguments: [channel]) ?? 0)
                    }
                    if fresh {
                        if answer.eligibleForReply {
                            self.replyConfirmationVersion += 1
                            self.onEligible(channel, id)
                        }
                        return
                    }
                } catch {
                    try? await self.handle(error, channel: channel, epoch: epoch, scope: scope, required: ["chat.thread_participation"])
                    if case ChatAPIError.server(let status, _, _) = error, (400..<500).contains(status), status != 429 { return }
                }
                try? await Task.sleep(for: .seconds(self.retryDelay(attempt)))
            }
        }
    }

    /// A panel owns its pages; this validates every page before returning it to the UI.
    func reactors(channel: String, message: String, emoji: String, after: String?, at: Int?) async throws -> ChatB1.ReactorsPage {
        let epoch = socket?.epoch
        guard capabilities.contains("chat.reactions"), let scope = try readDB({ try ChatB1.readToken($0, channel: channel) }) else { throw CancellationError() }
        let page: ChatB1.ReactorsPage
        do {
            page = try await api.reactors(key.orgId, channel: channel, message: message, emoji: emoji, after: after, at: at,
                                         limit: max(1, min(100, limits.reactionAccountsMax)), token: token)
        } catch {
            try await handle(error, channel: channel, epoch: epoch, scope: scope, required: ["chat.reactions"])
            throw error
        }
        guard valid(epoch), capabilities.contains("chat.reactions"),
              try readDB({ db in
                  try ChatB1.readToken(db, channel: channel) == scope &&
                      page.asOfSeq >= (Int.fetchOne(db, sql: "SELECT MAX(invalidated, as_of_seq) FROM b1_metadata WHERE message_id = ?", arguments: [message]) ?? 0) &&
                      String.fetchOne(db, sql: "SELECT deleted_at FROM messages WHERE message_id = ?", arguments: [message]) == nil
              }) else { throw CancellationError() }
        return page
    }
}
