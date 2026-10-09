import Foundation
import GRDB
import Observation

/// The member stream discovers every DM; open conversations additionally share
/// the socket budget with channels. Tasks are fenced by access and window epochs.
@MainActor @Observable
final class ChatDMSync: ChatStreamSink {
    let key: ChatOrgKey
    let store: ChatStore
    private let api: ChatAPI
    private let token: String
    private weak var socket: ChatSocket?
    private(set) var enabled = false
    private(set) var ready = false
    private(set) var epoch = 0
    private(set) var openIDs = Set<String>()
    private(set) var followed = Set<String>()
    var isCurrent: () -> Bool = { true }
    var onAccessRefused: () -> Void = {}
    var onBudgetChanged: () -> Void = {}
    var onLiveMessage: (String, String) -> Void = { _, _ in }
    var onChanged: () -> Void = {}
    @ObservationIgnored private var work: [String: Task<Void, Never>] = [:]
    private var liveCandidates = Set<String>()
    private var stopped = false
    var sessionId: String?

    init(key: ChatOrgKey, store: ChatStore, api: ChatAPI, token: String, socket: ChatSocket) {
        self.key = key; self.store = store; self.api = api; self.token = token; self.socket = socket
    }
    func configure(_ supported: Bool) {
        guard enabled != supported else { return }
        enabled = supported
        invalidate()
    }
    func invalidate() {
        epoch += 1; ready = false; liveCandidates = []
        for task in work.values { task.cancel() }; work = [:]
        try? store.dmWrite { try ChatDMStore.invalidate($0) }
        socket?.unsubscribe(Array(followed)); followed = []
        onChanged()
    }
    func stop() { stopped = true; invalidate(); socket?.detach(self) }
    private func current(_ captured: Int) -> Bool { !stopped && enabled && isCurrent() && epoch == captured && !Task.isCancelled }

    func readable(_ id: String? = nil) -> Bool {
        guard enabled, ready, !stopped, isCurrent() else { return false }
        return (try? store.dmRead { db in
            guard try Bool.fetchOne(db, sql: "SELECT ready FROM dm_meta") == true,
                  try Bool.fetchOne(db, sql: "SELECT rights_in_doubt FROM meta WHERE id = 1") != true else { return false }
            if let sessionId, try String.fetchOne(db, sql: "SELECT rights_session FROM meta WHERE id = 1") != sessionId { return false }
            return try id.map { try ChatDMStore.card(db, $0) != nil } ?? true
        }) ?? false
    }

    /// Called after /state, whose personal watermark remains the catch-up start.
    func reloadCatalog(valid: () -> Bool) async throws {
        guard enabled, !stopped, isCurrent() else { return }
        invalidate()
        let captured = epoch, stamp = try store.dmRead { try ChatDMStore.stamp($0) }
        var after: String?, seen = Set<String>(), cursors = Set<String>()
        repeat {
            let page = try await api.dmPage(key.orgId, after: after, token: token)
            guard current(captured), valid() else { throw CancellationError() }
            try store.dmWrite { db in
                for card in page.dms {
                    guard card.peer.accountId != key.accountId else { continue }
                    try ChatDMStore.writeCard(db, card)
                    try ChatDMStore.restoreOutgoing(db, dm: card.dmId, me: key.accountId)
                    seen.insert(card.dmId)
                }
            }
            after = page.next
            if let after, !cursors.insert(after).inserted { throw ChatAPIError.unexpectedAnswer("Repeated DM catalog cursor") }
        } while after != nil
        guard current(captured), valid() else { throw CancellationError() }
        try store.dmWrite { try ChatDMStore.endRead($0, since: stamp, seen: seen) }
        ready = true; follow(resubscribe: true); onChanged()
        // A pointer delivered while reading may refer to a message beyond its window.
        let pending = try store.dmRead { try Row.fetchAll($0, sql: "SELECT dm_id, message_id, seq, revision FROM dm_pending") }
        for row in pending { readOne(row["dm_id"], id: row["message_id"], seq: row["seq"], revision: row["revision"], live: false) }
    }

    func setOpen(_ ids: Set<String>) { openIDs = ids; onBudgetChanged(); follow() }
    func follow(resubscribe: Bool = false) {
        guard let socket, enabled, !stopped, ready else { return }
        let ids = Set((try? store.dmRead { try ChatDMStore.cards($0).map(\.dmId) }) ?? [])
        let budget = max(0, ChatSync.socketStreams - socket.followedCount(excludingPrefix: "dm:") - ChatSync.streamsReserve)
        let wanted = Set(openIDs.intersection(ids).sorted().prefix(budget).map { "dm:\($0)" })
        let before = followed; followed = wanted
        socket.unsubscribe(Array(before.subtracting(wanted)))
        socket.subscribe(Array(wanted.subtracting(before)), sink: self)
        if resubscribe { socket.resubscribe(Array(wanted.intersection(before))) }
    }
    func cursor(_ stream: String) -> Int { (try? store.cursor(stream)) ?? 0 }
    func apply(_ event: ChatEvent) -> Bool {
        guard enabled, !stopped, isCurrent(), followed.contains(event.stream) else { return true }
        do {
            let result = try store.apply(event)
            if case .gap = result { return false }
            if result == .applied { receive(event, live: socket?.syncing.contains(event.stream) == false) }
            return true
        } catch { invalidate(); onAccessRefused(); return false }
    }
    func resync(_ stream: String) async throws {
        guard stream.hasPrefix("dm:") else { return }
        _ = try await refresh(String(stream.dropFirst(3)))
        socket?.resubscribe([stream])
    }
    func ready(_ stream: String, head: Int) {}
    func catchingUp(_ stream: String) {}
    func dropped(_ stream: String) {
        guard stream.hasPrefix("dm:") else { return }
        try? store.dmWrite { try ChatDMStore.remove($0, String(stream.dropFirst(3))) }
        invalidate(); onAccessRefused()
    }

    /// Also called for member pointers, after their transaction advances the cursor.
    func receive(_ event: ChatEvent, live: Bool) {
        guard enabled, !stopped, isCurrent(), ChatDMStore.events.contains(event.type), let dm = event.body["dm_id"]?.string else { return }
        let captured = epoch
        if live && ["dm.created", "dm.message.post"].contains(event.type) { try? store.dmWrite { try ChatDMStore.liveBaseline($0, dm) } }
        if !event.type.hasPrefix("dm.message.") {
            schedule("card:\(dm)") { [weak self] in _ = try await self?.refresh(dm) }
        } else if let id = event.body["message_id"]?.string, let seq = event.body["message_seq"]?.int {
            readOne(dm, id: id, seq: seq, revision: event.body["revision"]?.int ?? 0, live: live && event.type == "dm.message.post", captured: captured)
        }
        onChanged()
    }
    private func schedule(_ name: String, operation: @escaping @MainActor () async throws -> Void) {
        // Do not cancel a live candidate when its duplicate arrives from the other stream.
        guard work[name] == nil else { return }
        let captured = epoch
        work[name] = Task { [weak self] in
            var attempt = 0
            while let self, current(captured) {
                do { try await operation(); break }
                catch is CancellationError { break }
                catch ChatAPIError.server(let status, _, _) where status == 401 || status == 403 || status == 404 { if current(captured) { onAccessRefused() }; break }
                catch {
                    attempt += 1
                    try? await Task.sleep(for: .seconds(min(30, pow(2, Double(min(attempt, 5))))))
                }
            }
            if let self, epoch == captured { work[name] = nil }
        }
    }
    func opened(_ id: String) {
        schedule("card:\(id)") { [weak self] in _ = try await self?.refresh(id) }
    }
    @discardableResult func refresh(_ id: String) async throws -> ChatDMCard {
        let captured = epoch
        guard current(captured) else { throw CancellationError() }
        do {
            let card = try await api.dm(key.orgId, id: id, token: token)
            guard current(captured), card.dmId == id, card.peer.accountId != key.accountId else { throw CancellationError() }
            try store.dmWrite { db in
                try ChatDMStore.writeCard(db, card)
                try ChatDMStore.restoreOutgoing(db, dm: card.dmId, me: key.accountId)
            }
            follow(); onChanged(); return card
        } catch ChatAPIError.server(let status, let code, let retry) where status == 403 || status == 404 {
            if current(captured) { try store.dmWrite { try ChatDMStore.remove($0, id) }; invalidate(); onAccessRefused() }
            throw ChatAPIError.server(status: status, code: code, retryAfter: retry)
        }
    }
    func readOne(_ dm: String, id: String, seq: Int, revision: Int, live: Bool, captured: Int? = nil) {
        let captured = captured ?? epoch
        let candidate = "\(dm):\(id)"
        if live { liveCandidates.insert(candidate) }
        schedule("message:\(dm):\(id)") { [weak self] in
            guard let self, current(captured) else { throw CancellationError() }
            if try store.dmRead({ try ChatDMStore.card($0, dm) }) == nil { _ = try await refresh(dm) }
            guard current(captured) else { throw CancellationError() }
            let window = try store.dmRead { try ChatDMStore.windowEpoch($0, dm) }
            let page = try await api.dmMessages(key.orgId, id: dm, before: seq == Int.max ? seq : seq + 1, token: token)
            guard current(captured) else { throw CancellationError() }
            guard try store.dmRead({ try ChatDMStore.windowEpoch($0, dm) }) == window else {
                throw ChatAPIError.unexpectedAnswer("The DM window changed; reading the live message again")
            }
            let wanted = max(revision, (try store.dmRead { try Int.fetchOne($0, sql: "SELECT revision FROM dm_pending WHERE dm_id = ? AND message_id = ?", arguments: [dm, id]) }) ?? 0)
            guard let message = page.messages.first(where: { $0.dmId == dm && $0.messageId == id && $0.seq == seq && $0.revision >= wanted }) else {
                throw ChatAPIError.unexpectedAnswer("DM message revision is not available yet")
            }
            let live = liveCandidates.contains(candidate) && readable(dm)
            let owed = try store.dmWrite { db in
                try ChatDMStore.write(db, message)
                return try live && ChatDMStore.owe(db, dm: dm, message: id, me: key.accountId)
            }
            liveCandidates.remove(candidate)
            if owed, readable(dm) { onLiveMessage(dm, id) }
            onChanged()
        }
    }
    func page(_ dm: String, root: String? = nil, before: Int?) async throws -> ChatDMMessagesPage {
        let captured = epoch
        guard readable(dm) else { throw ChatError.notConnected }
        let window = try store.dmRead { try ChatDMStore.windowEpoch($0, dm) }
        do {
            let page = try await api.dmMessages(key.orgId, id: dm, root: root, before: before, token: token)
            guard current(captured), readable(dm), try store.dmRead({ try ChatDMStore.windowEpoch($0, dm) }) == window else { throw CancellationError() }
            guard page.messages.allSatisfy({ $0.dmId == dm && (root == nil || $0.messageId == root || $0.threadRootId == root) }) else {
                throw ChatAPIError.unexpectedAnswer("Invalid DM page address")
            }
            try store.dmWrite { db in
                for message in page.messages { try ChatDMStore.write(db, message) }
                if root == nil {
                    try db.execute(sql: "UPDATE dm_cards SET history_next = ? WHERE dm_id = ? AND history_next IS ?", arguments: [page.next, dm, before])
                }
            }
            return page
        } catch ChatAPIError.server(let status, let code, let retry) where status == 403 || status == 404 {
            if current(captured) { try store.dmWrite { try ChatDMStore.remove($0, dm) }; invalidate(); onAccessRefused() }
            throw ChatAPIError.server(status: status, code: code, retryAfter: retry)
        }
    }
}
