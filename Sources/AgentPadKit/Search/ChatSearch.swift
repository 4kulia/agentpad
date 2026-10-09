import Foundation
import Observation
import GRDB

struct ChatSearchRequest: Codable, Equatable, Sendable {
    enum Scope: String, Codable, CaseIterable, Sendable { case all, channel, dm }
    var query: String
    var scope: Scope = .all
    var targetID: String?
    var authorAccountID: String?
    var from: String?
    var to: String?
    var limit = 20
    var cursor: String?
    enum CodingKeys: String, CodingKey {
        case query, scope, from, to, limit, cursor
        case targetID = "target_id", authorAccountID = "author_account_id"
    }
    func validate() throws {
        _ = try SearchQuery(query)
        guard (1...50).contains(limit), targetID == nil || (scope != .all && UUID(uuidString: targetID!) != nil),
              authorAccountID == nil || UUID(uuidString: authorAccountID!) != nil else { throw SearchProblem.invalidQuery }
        if let from { guard ChatStore.date(from) != nil else { throw SearchProblem.invalidQuery } }
        if let to { guard ChatStore.date(to) != nil else { throw SearchProblem.invalidQuery } }
        if let from, let to, let start = ChatStore.date(from), let end = ChatStore.date(to), start >= end { throw SearchProblem.invalidQuery }
    }
}

struct ChatSearchHit: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case channel, dm }
    var kind: Kind
    var targetID: String
    var messageID: String
    var threadRootID: String?
    var messageSeq: Int
    var revision: Int
    var authorAccountID: String
    var authorAgentID: String?
    var authorSessionName: String?
    var createdAt: String
    var snippet: String
    var id: String { kind.rawValue + ":" + messageID }
    enum CodingKeys: String, CodingKey {
        case kind, revision, snippet
        case targetID = "target_id", messageID = "message_id", threadRootID = "thread_root_id", messageSeq = "message_seq"
        case authorAccountID = "author_account_id", authorAgentID = "author_agent_id", authorSessionName = "author_session_name", createdAt = "created_at"
    }
}
struct ChatSearchPage: Codable, Equatable, Sendable { var hits: [ChatSearchHit]; var next: String? }

extension ChatAPI {
    func search(_ org: String, request: ChatSearchRequest, token: String) async throws -> ChatSearchPage {
        try request.validate()
        let answer = try await send("POST", "/v1/orgs/\(org)/chat/search", token: token, body: JSONEncoder().encode(request))
        try Self.check(answer)
        guard answer.body.count <= 262_144 else { throw ChatAPIError.unexpectedAnswer("Search response too large") }
        let page: ChatSearchPage
        do { page = try JSONDecoder().decode(ChatSearchPage.self, from: answer.body) }
        catch { throw ChatAPIError.unexpectedAnswer("Invalid search response") }
        guard page.hits.count <= request.limit, page.hits.allSatisfy({ $0.snippet.count <= 320 && $0.messageSeq > 0 && $0.messageSeq < Int.max }) else {
            throw ChatAPIError.unexpectedAnswer("Invalid search page")
        }
        return page
    }
}

struct ChatSearchContext: Equatable, Sendable {
    var key: ChatOrgKey
    var session: String
    var generation: String
    var revision: Int
    var storeID: ObjectIdentifier? = nil
}

private final class SearchRevision: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    func advance() { lock.withLock { revision += 1 } }
    var value: Int { lock.withLock { revision } }
}

enum ChatSearchAvailability: Equatable {
    case ready, noTeam, unsupported, offline, checking
    var message: String? {
        switch self {
        case .ready: nil
        case .noTeam: "Local results only. Connect a team to search messages."
        case .unsupported: "Local results only. This server does not support message search."
        case .offline: "Messages unavailable while offline. Local results are available."
        case .checking: "Checking access to messages. Local results are available."
        }
    }
}

/// Memory-only, cancellable search. Context is checked after every suspension;
/// cancellation alone cannot fence a late URLSession reply or revoked access.
@MainActor @Observable
final class ChatSearchModel {
    typealias Fetch = @MainActor (ChatSearchContext, ChatSearchRequest) async throws -> ChatSearchPage
    private var retainedHits: [ChatSearchHit] = []
    var hits: [ChatSearchHit] {
        guard (loadedHistoryOnly && historyRevision == revision.value && historyAllowed()) || (adopted != nil && adopted == context()) else { return [] }
        return retainedHits.filter(hitAllowed)
    }
    private(set) var next: String?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var loadedHistoryOnly = false
    @ObservationIgnored var context: () -> ChatSearchContext?
    @ObservationIgnored var availability: () -> ChatSearchAvailability
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var serial = UUID()
    @ObservationIgnored private var adopted: ChatSearchContext?
    @ObservationIgnored private var request: ChatSearchRequest?
    @ObservationIgnored private var watch: AnyDatabaseCancellable?
    @ObservationIgnored private var messageWatch: AnyDatabaseCancellable?
    @ObservationIgnored private weak var observedStore: ChatStore?
    @ObservationIgnored private var watchID = UUID()
    @ObservationIgnored private var hitAllowed: (ChatSearchHit) -> Bool = { _ in true }
    @ObservationIgnored private var observedKey: ChatOrgKey?
    @ObservationIgnored private let revision = SearchRevision()
    @ObservationIgnored private var historyRevision = 0
    @ObservationIgnored private var historyAllowed: () -> Bool = { false }
    @ObservationIgnored var onInvalidation: (() -> Void)?
    init(context: @escaping () -> ChatSearchContext?, availability: @escaping () -> ChatSearchAvailability, fetch: @escaping Fetch) {
        self.context = context; self.availability = availability; self.fetch = fetch
    }
    convenience init(service: ChatService = .shared) {
        self.init(context: { nil }, availability: { service.searchAvailability }, fetch: { context, request in
            guard service.connection?.orgKey == context.key, service.connection?.sessionId == context.session,
                  service.searchAvailability == .ready, let token = service.token else { throw SearchProblem.unavailable }
            let api = service.makeAPI(context.key.server)
            do { return try await api.search(context.key.orgId, request: request, token: token) }
            catch let error as ChatAPIError {
                if case .server(404, _, _) = error, request.targetID == nil {
                    let info = try? await api.serverInfo()
                    if service.connection?.sessionId == context.session, let info { service.serverCapabilities[context.key.server] = Set(info.capabilities) }
                }
                throw error
            }
        })
        hitAllowed = { [weak service] hit in
            guard let service, let key = service.connection?.orgKey, let store = service.orgSessions[key]?.store else { return false }
            switch hit.kind {
            case .channel: guard ChatNotifications.allowed(service, key, channel: hit.targetID) else { return false }
            case .dm: guard service.dmAllowed(key, hit.targetID) else { return false }
            }
            return (try? SearchCache.read(store.queue) { db in
                switch hit.kind {
                case .channel:
                    return try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM messages WHERE channel_id=? AND message_id=? AND (revision>? OR stale>? OR deleted_at IS NOT NULL))",
                        arguments: [hit.targetID, hit.messageID, hit.revision, hit.revision])!
                case .dm:
                    return try !Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM dm_revisions WHERE dm_id=? AND message_id=? AND (revision>? OR deleted=1)) OR EXISTS(SELECT 1 FROM dm_messages WHERE dm_id=? AND message_id=? AND (revision>? OR stale>? OR deleted=1))",
                        arguments: [hit.targetID, hit.messageID, hit.revision, hit.targetID, hit.messageID, hit.revision, hit.revision])!
                }
            }) == true
        }
        context = { [weak self, weak service] in
            guard let self, let service, service.searchAvailability == .ready, let connection = service.connection, let key = connection.orgKey,
                  let store = service.orgSessions[key]?.store, let generation = try? store.generation else { return nil }
            self.observe(key, store: store)
            return ChatSearchContext(key: key, session: connection.sessionId, generation: generation, revision: self.revision.value, storeID: ObjectIdentifier(store))
        }
    }
    private func observe(_ key: ChatOrgKey, store: ChatStore) {
        guard observedKey != key || observedStore !== store else { return }
        watch = nil; messageWatch = nil; observedKey = key; observedStore = store; revision.advance()
        let id = UUID(); watchID = id
        let change = CoalescedMainActorAction { [weak self] in
            guard let self, self.watchID == id else { return }
            self.invalidate(); self.onInvalidation?()
        }
        // Access/generation changes fence late replies synchronously. Observe
        // only DM card identity/content here: navigation also writes activity.
        watch = DatabaseRegionObservation(tracking:
            SQLRequest<Row>(sql: "SELECT generation,pending_generation,rights_in_doubt,rights_session,channels_served FROM meta"),
            Table("teams"), Table("team_members"), Table("members"), Table("channels"), Table("dm_meta"),
            SQLRequest<Row>(sql: "SELECT dm_id,body,epoch FROM dm_cards"))
            .start(in: store.queue, onError: { [revision] _ in revision.advance(); change.schedule() }) { [revision] _ in revision.advance(); change.schedule() }
        // Cache fills are not changes to a server search. Revalidate existing
        // snippets against known edits/deletions without dropping pages/cursor.
        let content = CoalescedMainActorAction { [weak self] in
            guard let self, self.watchID == id else { return }
            self.retainedHits = self.retainedHits.filter(self.hitAllowed)
        }
        messageWatch = DatabaseRegionObservation(tracking: Table("messages"), Table("dm_messages"), Table("dm_revisions"))
            .start(in: store.queue, onError: { [revision] _ in revision.advance(); change.schedule() }) { _ in content.schedule() }
    }
    func invalidate() {
        serial = UUID(); task?.cancel(); task = nil; retainedHits = []; next = nil; loading = false; error = nil; loadedHistoryOnly = false; adopted = nil
        watchID = UUID(); watch = nil; messageWatch = nil; observedKey = nil; observedStore = nil
    }
    func checkContext() {
        if adopted != nil, context() != adopted { invalidate() }
    }
    func search(_ value: ChatSearchRequest, more: Bool = false, debounce: Bool = true) {
        if !more, debounce, request == value, adopted != nil, adopted == context(), (loading || error == nil), !loadedHistoryOnly { return }
        task?.cancel(); serial = UUID(); let id = serial
        if !more { retainedHits = []; next = nil }
        error = nil; loadedHistoryOnly = false; request = value
        guard availability() == .ready, let captured = context() else { invalidate(); return }
        var value = value
        if more { guard let next, adopted == captured else { invalidate(); return }; value.cursor = next }
        do { try value.validate() } catch { self.error = error.localizedDescription; loading = false; return }
        adopted = captured; loading = true
        let sent = value
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                guard serial == id, context() == captured, !Task.isCancelled else { return }
                let page = try await fetch(captured, sent)
                guard serial == id, context() == captured, !Task.isCancelled else { return }
                var known = Set(retainedHits.map(\.id)); retainedHits += page.hits.filter { known.insert($0.id).inserted }
                next = page.next; loading = false
            } catch {
                guard serial == id, context() == captured, !Task.isCancelled else { return }
                loading = false
                switch error {
                case ChatAPIError.server(429, _, let delay): self.error = "Message search rate limited. Retry in \(Int(delay ?? 60)) seconds."
                case ChatAPIError.server(400, _, _): self.error = "Refine your query or filters, then retry message search."
                case ChatAPIError.server(404, _, _): self.error = "Message search or the selected place is unavailable."
                default: self.error = "Message search failed. Local results are available. Retry."
                }
            }
        }
    }
    func useLoadedHistory(_ values: [ChatSearchHit], key: ChatOrgKey, store: ChatStore, allowed: @escaping () -> Bool) {
        invalidate(); observe(key, store: store); historyRevision = revision.value; historyAllowed = allowed
        retainedHits = values; loadedHistoryOnly = true
    }
}

extension ChatService {
    var searchAvailability: ChatSearchAvailability {
        guard let connection, let key = connection.orgKey, token != nil, state != .off else { return .noTeam }
        guard supports("chat.search", key: key), supports("chat.dm", key: key) else { return .unsupported }
        guard ChatAttention.personalAllowed(key, self) else { return .checking }
        if let socket {
            switch socket.state { case .connected: break; default: return .offline }
        }
        return .ready
    }
}
