import AppKit
import GRDB
import Observation

struct ChatAvatarReference: Hashable, Sendable {
    let key: ChatOrgKey
    let subject: ChatAvatarSubject
    static func account(_ id: String, _ key: ChatOrgKey?) -> Self? { key.map { .init(key: $0, subject: .account(id)) } }
    static func agent(_ id: String, _ key: ChatOrgKey?) -> Self? { key.map { .init(key: $0, subject: .agent(id)) } }
}
struct ChatAvatarContext: Hashable, Sendable {
    let key: ChatOrgKey
    let session: String
    let generation: String
    let epoch: Int
}
struct ChatAvatarAuthorization {
    let context: ChatAvatarContext
    let api: ChatAPI
    let token: String
    var limits: ChatAvatarLimits = .init()
}

/// Membership and rights writes advance the display fence at commit time,
/// including writes outside the live feed. Reading the fence never reads SQL.
@Observable
final class ChatAvatarAccessEpoch: @unchecked Sendable {
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var observation: AnyDatabaseCancellable?

    var value: Int {
        access(keyPath: \.value)
        return lock.withLock { revision }
    }
    private func advance() {
        withMutation(keyPath: \.value) { lock.withLock { revision += 1 } }
    }
    init(queue: DatabaseQueue) {
        observation = DatabaseRegionObservation(tracking:
            Table("members").select(Column("account_id")),
            Table("agents_catalog").select(Column("agent_id"), Column("owner_account_id")),
            Table("agent_channels").select(Column("agent_id"), Column("owner_account_id"), Column("channel_id")),
            Table("channels").select(Column("channel_id")),
            Table("meta").select(Column("rights_in_doubt"), Column("rights_session"), Column("pending_generation"), Column("generation")))
            .start(in: queue, onError: { [weak self] _ in self?.advance() }) { [weak self] _ in self?.advance() }
    }
}

/// Only current images, held in bounded memory. No avatar URL or bytes are
/// written to a store, a window restoration record, or URLCache.
@MainActor @Observable
final class ChatAvatarCache {
    private(set) var context: ChatAvatarContext?
    private(set) var metadata: [ChatAvatarSubject: ChatAvatarMetadata] = [:]
    private struct ImageEntry { let version: ChatAvatarMetadata; let image: NSImage; let cost: Int }
    private var images: [ChatAvatarSubject: ImageEntry] = [:]
    private struct PendingRead {
        let ticket: UUID
        let task: Task<Void, Never>
        var consumers: [UUID: CheckedContinuation<NSImage?, Never>]
    }
    private struct ReadWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    @ObservationIgnored private var pending: [ChatAvatarSubject: PendingRead] = [:]
    @ObservationIgnored private var readWaiters: [ReadWaiter] = []
    @ObservationIgnored private var attempted: [ChatAvatarSubject: Date] = [:]
    @ObservationIgnored private var activeReads = 0
    @ObservationIgnored private var recent: [ChatAvatarSubject] = []
    @ObservationIgnored private var visible: [UUID: ChatAvatarReference] = [:]
    @ObservationIgnored private var visibility: [ChatAvatarReference: Bool] = [:]
    @ObservationIgnored private var nextGeneration = 0
    private var clearedGeneration = 0
    private var imageGenerations: [ChatAvatarSubject: Int] = [:]
    @ObservationIgnored let authorization: (ChatAvatarReference) -> ChatAvatarAuthorization?
    @ObservationIgnored private let isCurrent: (ChatAvatarContext) -> Bool
    @ObservationIgnored private let validate: ((ChatAvatarReference, ChatAvatarContext) async -> Bool)?
    @ObservationIgnored var onUnauthorized: (ChatAvatarContext) -> Void = { _ in }
    var byteLimit = 16 * 1024 * 1024
    var countLimit = 96

    init(isCurrent: @escaping (ChatAvatarContext) -> Bool,
         validate: ((ChatAvatarReference, ChatAvatarContext) async -> Bool)? = nil,
         authorization: @escaping (ChatAvatarReference) -> ChatAvatarAuthorization?) {
        self.isCurrent = isCurrent; self.validate = validate; self.authorization = authorization
    }
    func clear() {
        let reads = pending; pending = [:]
        for read in reads.values {
            read.task.cancel()
            read.consumers.values.forEach { $0.resume(returning: nil) }
        }
        let waiters = readWaiters; readWaiters = []
        waiters.forEach { $0.continuation.resume(returning: false) }
        context = nil; metadata = [:]; images = [:]; attempted = [:]; recent = []; visibility = [:]
        nextGeneration += 1; clearedGeneration = nextGeneration; imageGenerations = [:]
    }
    private func adopt(_ next: ChatAvatarContext) {
        if context != next { clear(); context = next }
    }
    /// Called by loading/authorization, never by a view body. Both grants and
    /// denials last only for this reference's access epoch.
    func isVisible(_ ref: ChatAvatarReference, context: ChatAvatarContext, read: () -> Bool) -> Bool {
        adopt(context)
        if let allowed = visibility[ref] { return allowed }
        let allowed = read()
        visibility[ref] = allowed
        return allowed
    }
    func receive(_ value: ChatAvatarMetadata?, for ref: ChatAvatarReference, context: ChatAvatarContext) {
        guard let value, value.valid, ref.key == context.key else { return }
        adopt(context)
        if let old = metadata[ref.subject] {
            guard value.revision > old.revision || value == old else { return }
        }
        if metadata[ref.subject] != value {
            images[ref.subject] = nil
            metadata[ref.subject] = value
        }
        attempted[ref.subject] = Date()
    }
    func image(_ ref: ChatAvatarReference) -> NSImage? {
        guard let context, ref.key == context.key, isCurrent(context),
              let entry = images[ref.subject], entry.version == metadata[ref.subject] else { return nil }
        touch(ref.subject)
        return entry.image
    }
    func imageGeneration(_ ref: ChatAvatarReference) -> Int { imageGenerations[ref.subject] ?? clearedGeneration }
    func setVisible(_ ref: ChatAvatarReference?, id: UUID) {
        visible[id] = ref
        if let ref, ref.key == context?.key, images[ref.subject] != nil { touch(ref.subject) }
    }
    private func touch(_ subject: ChatAvatarSubject) {
        recent.removeAll { $0 == subject }; recent.append(subject)
    }
    private func cache(_ entry: ImageEntry, for ref: ChatAvatarReference) {
        guard entry.cost <= byteLimit, countLimit > 0 else { return }
        let mounted = Set(visible.values.filter { $0.key == ref.key }.map(\.subject))
        while images.count >= countLimit || images.values.reduce(0, { $0 + $1.cost }) + entry.cost > byteLimit {
            guard let victim = recent.first(where: { !mounted.contains($0) }) else {
                // All cached images are on screen. The caller retains the new
                // display image without making mounted photos evict each other.
                return
            }
            images[victim] = nil; recent.removeAll { $0 == victim }
            nextGeneration += 1; imageGenerations[victim] = nextGeneration
        }
        images[ref.subject] = entry; touch(ref.subject)
    }
    @discardableResult
    func load(_ ref: ChatAvatarReference, refresh: Bool = false) async -> NSImage? {
        guard !Task.isCancelled, let auth = authorization(ref) else { return nil }
        adopt(auth.context)
        let version = metadata[ref.subject]
        let consumer = UUID()
        let image: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if pending[ref.subject] != nil {
                    pending[ref.subject]?.consumers[consumer] = continuation
                } else {
                    let ticket = UUID()
                    let task = Task { [weak self] in
                        guard let self else { return }
                        let image = await self.read(ref, auth: auth, refresh: refresh)
                        self.finish(ref.subject, ticket: ticket, image: image)
                    }
                    pending[ref.subject] = .init(ticket: ticket, task: task, consumers: [consumer: continuation])
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(ref.subject, consumer: consumer) }
        }
        guard current(ref, auth) else { return nil }
        if image == nil, version != metadata[ref.subject], metadata[ref.subject]?.imageId != nil,
           images[ref.subject] == nil { return await load(ref) }
        return image
    }
    private func finish(_ subject: ChatAvatarSubject, ticket: UUID, image: NSImage?) {
        guard let read = pending[subject], read.ticket == ticket else { return }
        pending[subject] = nil
        read.consumers.values.forEach { $0.resume(returning: image) }
    }
    private func cancel(_ subject: ChatAvatarSubject, consumer: UUID) {
        guard let continuation = pending[subject]?.consumers.removeValue(forKey: consumer) else { return }
        continuation.resume(returning: nil)
        if let read = pending[subject], read.consumers.isEmpty {
            pending[subject] = nil
            read.task.cancel()
        }
    }
    private func acquireReadSlot() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                if activeReads < 4 { activeReads += 1; continuation.resume(returning: true) }
                else { readWaiters.append(.init(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.readWaiters.firstIndex(where: { $0.id == id }) else { return }
                self.readWaiters.remove(at: index).continuation.resume(returning: false)
            }
        }
    }
    private func releaseReadSlot() {
        activeReads -= 1
        if !readWaiters.isEmpty {
            activeReads += 1
            readWaiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func current(_ ref: ChatAvatarReference, _ auth: ChatAvatarAuthorization) -> Bool {
        !Task.isCancelled && context == auth.context && isCurrent(auth.context)
    }
    private func allowed(_ ref: ChatAvatarReference, _ auth: ChatAvatarAuthorization) async -> Bool {
        guard current(ref, auth) else { return false }
        if let validate, !(await validate(ref, auth.context)) { return false }
        return current(ref, auth)
    }
    private func read(_ ref: ChatAvatarReference, auth: ChatAvatarAuthorization, refresh: Bool) async -> NSImage? {
        guard await acquireReadSlot() else { return nil }
        defer { releaseReadSlot() }
        guard await allowed(ref, auth) else { return nil }
        var requestedImage = false
        do {
            if refresh || metadata[ref.subject] == nil || Date().timeIntervalSince(attempted[ref.subject] ?? .distantPast) > 60 {
                // A failed mount does not create an immediate retry loop.
                if !refresh, let date = attempted[ref.subject], metadata[ref.subject] == nil, Date().timeIntervalSince(date) < 10 { return nil }
                let reply = try await auth.api.avatarMetadata(ref.subject, key: ref.key, generation: auth.context.generation, token: auth.token)
                guard await allowed(ref, auth) else { return nil }
                receive(reply.avatar, for: ref, context: auth.context)
            }
            guard current(ref, auth), let version = metadata[ref.subject], version.imageId != nil else { return nil }
            if let entry = images[ref.subject], entry.version == version { touch(ref.subject); return entry.image }
            requestedImage = true
            let data = try await auth.api.avatarImage(ref.subject, key: ref.key, metadata: version, generation: auth.context.generation, token: auth.token)
            guard await allowed(ref, auth), metadata[ref.subject] == version else { return nil }
            let pixels = try ChatAvatarImage.read(data)
            let entry = ImageEntry(version: version, image: NSImage(cgImage: pixels, size: .zero), cost: pixels.bytesPerRow * pixels.height)
            cache(entry, for: ref)
            return entry.image
        } catch {
            guard current(ref, auth), !(error is CancellationError) else { return nil }
            // Successful metadata is dated by receive; only completed failures
            // consume the retry budget. A cancelled row can reload immediately.
            if !requestedImage { attempted[ref.subject] = Date() }
            if case ChatAPIError.server(let status, _, _) = error, [401, 403, 404].contains(status) {
                images[ref.subject] = nil
                // Retain a tombstone's revision; never revive an older ID.
                if status == 401 { onUnauthorized(auth.context) }
                if status == 404, requestedImage,
                   let reply = try? await auth.api.avatarMetadata(ref.subject, key: ref.key, generation: auth.context.generation, token: auth.token),
                   await allowed(ref, auth) {
                    // The random ID can have been replaced since the contact
                    // was read. Refresh once; load follows a newer version.
                    receive(reply.avatar, for: ref, context: auth.context)
                }
            } else if case ChatAPIError.unexpectedAnswer = error { images[ref.subject] = nil }
        }
        return nil
    }
}

extension ChatService {
    func invalidateAvatars() {
        avatarInvalidations += 1; avatars.clear(); avatarTransport = nil
        avatarUploads.values.forEach { $0.1.cancel() }; avatarUploads = [:]
        avatarEdits.values.forEach { $0.invalidate() }; avatarEdits = [:]
    }
    /// Rights and membership changes invalidate the epoch at their feed boundary.
    /// This fast fence complements the asynchronous store validation below.
    func avatarDownloadIsCurrent(_ context: ChatAvatarContext) -> Bool {
        guard avatarContext(context.key, ready: false) == context, let session = orgSessions[context.key] else { return false }
        return !session.snapshotOwed && !session.doubtNotWritten && session.store != nil
    }
    /// The render path reads only the observed access epoch and readiness flags.
    /// Database authorization and transport creation belong to loading tasks.
    func avatarDisplayContext(_ key: ChatOrgKey) -> ChatAvatarContext? {
        guard let context = avatarContext(key, ready: false), avatarDownloadIsCurrent(context) else { return nil }
        return context
    }
    func avatarDownloadAllowed(_ ref: ChatAvatarReference, context: ChatAvatarContext) async -> Bool {
        guard avatarDownloadIsCurrent(context), let store = orgSessions[ref.key]?.store else { return false }
        let allowed = (try? await store.queue.read { db in
            try Self.avatarVisible(ref, context: context, in: db)
        }) == true
        return allowed && avatarDownloadIsCurrent(context)
    }
    func avatarAPI(for context: ChatAvatarContext) -> ChatAPI {
        if let (scope, api) = avatarTransport, scope == context { return api }
        let api = makeAPI(context.key.server)
        avatarTransport = (context, api)
        return api
    }

    /// This is deliberately a local read. It never probes /v1/server, opens a
    /// team connection, or creates credentials from a view in .off.
    func avatarContext(_ key: ChatOrgKey, ready: Bool = true) -> ChatAvatarContext? {
        guard state == .signedIn, connection?.orgKey == key, let connection, token != nil,
              supports("chat.avatars", key: key), let generation = avatarGenerations[key.server] else { return nil }
        if ready {
            guard let session = orgSessions[key], !session.snapshotOwed, !session.doubtNotWritten, let store = session.store,
                  (try? store.queue.read { db in
                      try Bool.fetchOne(db, sql: "SELECT rights_in_doubt = 0 AND rights_session = ? AND pending_generation IS NULL AND generation = ? FROM meta WHERE id = 1", arguments: [connection.sessionId, generation])
                  }) == true else { return nil }
        }
        return .init(key: key, session: connection.sessionId, generation: generation, epoch: avatarEpoch)
    }
    func avatarAuthorization(_ ref: ChatAvatarReference) -> ChatAvatarAuthorization? {
        guard let context = avatarContext(ref.key, ready: false), avatarDownloadIsCurrent(context),
              let token, let store = orgSessions[ref.key]?.store else { return nil }
        let visible = avatars.isVisible(ref, context: context) {
            (try? store.queue.read { try Self.avatarVisible(ref, context: context, in: $0) }) == true
        }
        guard visible else { return nil }
        return .init(context: context, api: avatarAPI(for: context), token: token, limits: avatarLimits[ref.key.server] ?? .init())
    }
    nonisolated private static func avatarVisible(_ ref: ChatAvatarReference, context: ChatAvatarContext, in db: Database) throws -> Bool {
        let visibility: String
        var arguments: StatementArguments = [context.session, context.generation]
        switch ref.subject {
        case .account(let id):
            visibility = "EXISTS(SELECT 1 FROM members WHERE account_id = ?)"
            arguments += [id]
        case .agent(let id):
            visibility = """
                EXISTS(SELECT 1 FROM agents_catalog a JOIN members m ON m.account_id = a.owner_account_id WHERE a.agent_id = ?)
                    OR EXISTS(SELECT 1 FROM agent_channels a JOIN channels c ON c.channel_id = a.channel_id
                              JOIN members m ON m.account_id = a.owner_account_id WHERE a.agent_id = ?)
                """
            arguments += [id, id]
        }
        return try Bool.fetchOne(db, sql: """
            SELECT rights_in_doubt = 0 AND rights_session = ? AND pending_generation IS NULL AND generation = ?
                AND (\(visibility)) FROM meta WHERE id = 1
            """, arguments: arguments) == true
    }
    func configureAvatars(_ info: ChatServerInfo, server: ChatServerAddress) {
        if avatarGenerations[server] != info.generation { invalidateAvatars() }
        avatarGenerations[server] = info.generation; avatarLimits[server] = info.limits?.avatars
    }
    func receiveAvatars(_ snapshot: ChatOrgState, key: ChatOrgKey) {
        guard let context = avatarContext(key, ready: false) else { return }
        for member in snapshot.members {
            avatars.receive(member.avatar, for: .init(key: key, subject: .account(member.accountId)), context: context)
        }
        for agent in (snapshot.agents ?? []) + (snapshot.agentChannels ?? []).compactMap(\.agent) {
            avatars.receive(agent.avatar, for: .init(key: key, subject: .agent(agent.agentId)), context: context)
        }
    }
    func avatarEvent(_ event: ChatEvent, key: ChatOrgKey) {
        guard state == .signedIn, connection?.orgKey == key else { return }
        if ["member.remove", "member.set_role", "team.leave", "team.remove_member", "team.archive", "agent.unpublish",
            "agent.remove_from_channel", "channel.archive"].contains(event.type) { invalidateAvatars(); return }
        guard let context = avatarContext(key, ready: false) else { return }
        let card = event.type == "agent.publish" ? ChatCallStore.decode(ChatAgentCard.self, event.body)
            : event.type == "agent.add_to_channel" ? ChatCallStore.decode(ChatChannelAgentWire.self, event.body)?.agent : nil
        if let card { avatars.receive(card.avatar, for: .init(key: key, subject: .agent(card.agentId)), context: context) }
    }
}

extension AttentionItem {
    @MainActor var remoteAvatar: ChatAvatarReference? {
        guard localProfileID == nil, let scope = avatarScope, let id = subjectID,
              let server = try? ChatServerAddress(parsing: scope.server) else { return nil }
        let key = ChatOrgKey(server: server, accountId: scope.account, orgId: scope.organization)
        guard ChatService.shared.avatarDisplayContext(key)?.generation == scope.generation else { return nil }
        return .init(key: key, subject: subjectIsAgent ? .agent(id) : .account(id))
    }
}
